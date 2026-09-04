import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

import 'src/config.dart';
import 'src/tunnel_controller.dart';

const _buildVersionName = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
const _buildVersionCode = String.fromEnvironment('APP_BUILD', defaultValue: '0');
const _buildGitSha = String.fromEnvironment('GIT_SHA', defaultValue: 'local');

String _shortGitSha(String value) => value.length <= 8 ? value : value.substring(0, 8);
String get _buildLabel => 'v$_buildVersionName+$_buildVersionCode (${_shortGitSha(_buildGitSha)})';

const String _secretPhrase = "respire";

Future<String> getDeviceHwid() async {
  final deviceInfo = DeviceInfoPlugin();
  String rawId = '';

  try {
    if (Platform.isAndroid) {
      final android = await deviceInfo.androidInfo;
      rawId = android.id;
    } else if (Platform.isIOS) {
      final ios = await deviceInfo.iosInfo;
      rawId = ios.identifierForVendor ?? 'unknown';
    } else if (Platform.isLinux) {
      try {
        rawId = File('/etc/machine-id').readAsStringSync().trim();
      } catch (_) {
        final info = await deviceInfo.linuxInfo;
        rawId = info.machineId ?? 'unknown';
      }
    } else if (Platform.isWindows) {
      final info = await deviceInfo.windowsInfo;
      rawId = info.deviceId;
    } else if (Platform.isMacOS) {
      final info = await deviceInfo.macOsInfo;
      rawId = info.systemGUID ?? 'unknown';
    }
  } catch (_) {
    rawId = 'unknown';
  }

  final digest = sha256.convert(utf8.encode(rawId));
  return digest.toString().substring(0, 32);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isLinux) await windowManager.ensureInitialized();
  runApp(const PingtunnelApp());
}

class PingtunnelApp extends StatefulWidget {
  const PingtunnelApp({super.key});
  @override
  State<PingtunnelApp> createState() => _PingtunnelAppState();
}

class _PingtunnelAppState extends State<PingtunnelApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('theme_mode');
    if (!mounted) return;
    setState(() {
      _themeMode = switch (saved) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    });
  }

  Future<void> _setTheme(ThemeMode mode) async {
    setState(() => _themeMode = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  @override
  Widget build(BuildContext context) {
    final primary = const Color(0xFF0E7A6A);
    final lightScheme = ColorScheme.fromSeed(seedColor: primary, brightness: Brightness.light);
    final darkScheme = ColorScheme.fromSeed(seedColor: primary, brightness: Brightness.dark);

    return MaterialApp(
      title: 'PRINC LTE VPN',
      theme: ThemeData(useMaterial3: true, colorScheme: lightScheme),
      darkTheme: ThemeData(useMaterial3: true, colorScheme: darkScheme),
      themeMode: _themeMode,
      home: ConnectionListPage(themeMode: _themeMode, onThemeModeChanged: _setTheme),
    );
  }
}

class ConnectionEntry {
  ConnectionEntry({required this.uri, required this.config, this.locked = false});
  final String uri;
  final TunnelConfig config;
  final bool locked;
  String get id => uri;
  String get title => config.serverHost.isEmpty ? 'PRINC LTE VPN' : config.serverHost;
}

typedef SaveConnection = void Function(ConnectionEntry entry, {bool showMessage});

String buildConnectionUri(TunnelConfig config) => 'princ://encoded/${config.encode()}';

class ConnectionListPage extends StatefulWidget {
  const ConnectionListPage({super.key, required this.themeMode, required this.onThemeModeChanged});
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  @override
  State<ConnectionListPage> createState() => _ConnectionListPageState();
}

class _ConnectionListPageState extends State<ConnectionListPage> with WindowListener {
  static const _prefsKeyConnections = 'connections';
  static const _prefsKeySelected = 'selected_connection';
  static const MethodChannel _linuxTrayChannel = MethodChannel('pingtunnel_tray_linux');

  final TunnelController _controller = TunnelController();
  final List<ConnectionEntry> _entries = [];
  String? _activeId;
  String? _selectedId;
  bool _testing = false;
  String? _lastProbeError;
  DateTime? _lastProbeAt;
  Timer? _uiTimer;
  bool _loading = true;
  bool _linuxTrayReady = false;
  bool _linuxExitRequested = false;
  bool _syncingAndroidStatus = false;
  int _androidSyncTick = 0;
  int _androidNotRunningSamples = 0;

  @override
  void initState() {
    super.initState();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
      if (_isAndroid) {
        _androidSyncTick = (_androidSyncTick + 1) % 2;
        if (_androidSyncTick == 0) unawaited(_syncAndroidRuntimeState());
      }
    });
    _initLinuxTray();
    _loadConnections();
    if (_isAndroid) unawaited(_syncAndroidRuntimeState());
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    if (_isLinux) {
      _linuxTrayChannel.setMethodCallHandler(null);
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  bool get _isLinux => Platform.isLinux;
  bool get _isAndroid => Platform.isAndroid;

  Future<void> _initLinuxTray() async {
    if (!_isLinux) return;
    windowManager.addListener(this);
    try {
      _linuxTrayChannel.setMethodCallHandler(_onLinuxTrayMethodCall);
      await windowManager.setPreventClose(true);
      _linuxTrayReady = true;
      await _refreshLinuxTrayState();
    } catch (_) {
      _linuxTrayReady = false;
    }
  }

  void _scheduleLinuxTrayRefresh() {
    if (!_linuxTrayReady) return;
    unawaited(_refreshLinuxTrayState());
  }

  Future<void> _refreshLinuxTrayState() async {
    if (!_linuxTrayReady) return;
    final active = _activeEntry();
    final selected = _selectedEntry();
    final target = active ?? selected;
    final mode = target?.config.mode == TunnelMode.vpn || target?.config.mode == TunnelMode.proxyPerApp
        ? 'vpn'
        : target?.config.mode == TunnelMode.proxy
        ? 'proxy'
        : 'none';
    try {
      await _linuxTrayChannel.invokeMethod<void>('updateState', {
        'connected': _activeId != null,
        'mode': mode,
        'hasTarget': target != null,
      });
    } catch (_) {}
  }

  ConnectionEntry? _trayTargetEntry() => _activeEntry() ?? _selectedEntry() ?? (_entries.isNotEmpty ? _entries.first : null);

  Future<void> _showWindowFromTray() async {
    if (!_isLinux) return;
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _syncAndroidRuntimeState() async {
    if (!_isAndroid || _syncingAndroidStatus) return;
    _syncingAndroidStatus = true;
    try {
      final running = await _controller.isAndroidRunning();
      if (!mounted) return;
      if (running) {
        _androidNotRunningSamples = 0;
        return;
      }
      _androidNotRunningSamples++;
      if (_androidNotRunningSamples < 2) return;
      if (_activeId != null || _controller.status == TunnelStatus.connected || _controller.status == TunnelStatus.connecting) {
        _controller.markDisconnectedExternally();
        setState(() => _activeId = null);
      }
    } catch (_) {
    } finally {
      _syncingAndroidStatus = false;
    }
  }

  Future<void> _onLinuxTrayMethodCall(MethodCall call) async {
    if (call.method != 'onTrayEvent') return;
    final args = call.arguments;
    var event = '';
    if (args is Map) event = args['event']?.toString() ?? '';
    switch (event) {
      case 'connect':
        await _connectSelected();
        break;
      case 'show':
        await _showWindowFromTray();
        break;
      case 'disconnect':
        await _disconnectActive(showMessage: false);
        break;
      case 'switch_proxy':
        await _switchModeFromTray(TunnelMode.proxy);
        break;
      case 'switch_vpn':
        await _switchModeFromTray(TunnelMode.vpn);
        break;
      case 'exit':
        await _exitFromTray();
        break;
    }
  }

  Future<void> _switchModeFromTray(TunnelMode mode) async {
    final target = _trayTargetEntry();
    if (target == null) {
      await _showWindowFromTray();
      _showMessage('Add a connection first');
      return;
    }
    final wasActive = _activeId == target.id;
    final updatedConfig = target.config.copyWith(mode: mode);
    final updated = ConnectionEntry(uri: buildConnectionUri(updatedConfig), config: updatedConfig, locked: target.locked);
    _updateEntry(target, updated, showMessage: false);
    _selectEntry(updated);
    if (wasActive) {
      try {
        await _controller.stop();
        await _controller.start(updated.config);
        setState(() => _activeId = updated.id);
      } catch (err) {
        setState(() => _activeId = null);
        _showMessage('Failed to switch mode: $err');
        _scheduleLinuxTrayRefresh();
        return;
      }
    }
    _showMessage('Mode set to ${mode == TunnelMode.vpn ? "VPN" : "Proxy"}');
    _scheduleLinuxTrayRefresh();
  }

  Future<void> _exitFromTray() async {
    _linuxExitRequested = true;
    try {
      if (_activeId != null) await _controller.stop();
    } catch (_) {}
    if (_isLinux) {
      await windowManager.setPreventClose(false);
      try {
        await _linuxTrayChannel.invokeMethod<void>('exitNow');
        return;
      } catch (_) {}
      await windowManager.close();
    }
  }

  @override
  void onWindowClose() async {
    if (!_isLinux || _linuxExitRequested) return;
    final preventClose = await windowManager.isPreventClose();
    if (preventClose) await windowManager.hide();
  }

  Future<void> _loadConnections() async {
    final prefs = await SharedPreferences.getInstance();
    final uris = prefs.getStringList(_prefsKeyConnections) ?? <String>[];
    final selected = prefs.getString(_prefsKeySelected);
    final loaded = <ConnectionEntry>[];
    for (final uri in uris) {
      try {
        final config = TunnelConfig.parse(uri);
        final locked = uri.startsWith('princ://encoded/');
        loaded.add(ConnectionEntry(uri: uri, config: config, locked: locked));
      } catch (_) {}
    }
    setState(() {
      _entries..clear()..addAll(loaded);
      _selectedId = selected;
      if (_selectedId == null || !_entries.any((e) => e.id == _selectedId)) {
        _selectedId = _entries.isNotEmpty ? _entries.first.id : null;
      }
      _loading = false;
    });
    _scheduleLinuxTrayRefresh();
  }

  Future<void> _persistConnections() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKeyConnections, _entries.map((e) => e.uri).toList());
    if (_selectedId != null) {
      await prefs.setString(_prefsKeySelected, _selectedId!);
    } else {
      await prefs.remove(_prefsKeySelected);
    }
  }

  ConnectionEntry? _selectedEntry() => _entries.where((e) => e.id == _selectedId).firstOrNull;
  ConnectionEntry? _activeEntry() => _entries.where((e) => e.id == _activeId).firstOrNull;

  void _selectEntry(ConnectionEntry entry) {
    setState(() => _selectedId = entry.id);
    _persistConnections();
    _scheduleLinuxTrayRefresh();
  }

  Future<void> _addFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      final result = await _showAddDialog();
      if (result != null && result.isNotEmpty) _handleAddText(result);
      return;
    }
    _handleAddText(text);
  }

  Future<String?> _showAddDialog() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add connection'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'paste URL please'),
          minLines: 1,
          maxLines: 3,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    return result;
  }

  void _handleAddText(String text) {
    if (text.trim() == _secretPhrase) {
      final config = TunnelConfig(serverHost: '', localSocksPort: 1080, mode: TunnelMode.proxy);
      final entry = ConnectionEntry(uri: '', config: config, locked: false);
      _openDetails(entry);
      return;
    }
    if (text.trim().startsWith('princ://encoded/')) {
      _addEntryFromUri(text.trim());
    } else {
      _showMessage('invalid');
    }
  }

  void _addEntryFromUri(String uriText) {
    try {
      if (!uriText.startsWith('princ://encoded/')) throw const FormatException('Only encoded URIs are allowed');
      final config = TunnelConfig.parse(uriText);
      final locked = true;
      final existingIndex = _entries.indexWhere((e) => e.uri == uriText);
      setState(() {
        if (existingIndex >= 0) {
          final entry = _entries.removeAt(existingIndex);
          _entries.insert(0, entry);
          _selectedId = entry.id;
        } else {
          final entry = ConnectionEntry(uri: uriText, config: config, locked: locked);
          _entries.insert(0, entry);
          _selectedId = entry.id;
        }
      });
      _persistConnections();
      _scheduleLinuxTrayRefresh();
      _showMessage('Connection added');
    } catch (err) {
      _showMessage('Invalid URI: $err');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openDetails(ConnectionEntry entry) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConnectionDetailPage(
          entry: entry,
          controller: _controller,
          activeId: _activeId,
          onActiveChanged: (id) {
            setState(() => _activeId = id);
            _scheduleLinuxTrayRefresh();
          },
          onSave: (updated, {showMessage = true}) => _updateEntry(entry, updated, showMessage: showMessage),
          locked: entry.locked,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  void _updateEntry(ConnectionEntry original, ConnectionEntry updated, {bool showMessage = true}) {
    final existingIndex = _entries.indexWhere((e) => e.id == original.id);
    setState(() {
      if (existingIndex >= 0) {
        _entries[existingIndex] = updated;
      } else {
        _entries.insert(0, updated);
        _selectedId = updated.id;
      }
      final duplicates = _entries.where((e) => e.id == updated.id).toList();
      if (duplicates.length > 1) {
        final keep = duplicates.first;
        _entries.removeWhere((e) => e.id == updated.id && e != keep);
      }
      if (_selectedId == original.id) _selectedId = updated.id;
      if (_activeId == original.id) _activeId = updated.id;
    });
    _persistConnections();
    _scheduleLinuxTrayRefresh();
    if (showMessage) _showMessage('Connection saved');
  }

  Future<void> _connectSelected() async {
    final entry = _selectedEntry();
    if (entry == null) {
      _showMessage('Select a connection first');
      return;
    }
    if (entry.config.hwid != null && entry.config.hwid!.isNotEmpty) {
      final deviceHwid = await getDeviceHwid();
      if (entry.config.hwid != deviceHwid) {
        _showMessage('HWID non autorisé pour cet appareil');
        return;
      }
    }
    try {
      if (_activeId != null && _activeId != entry.id) await _controller.stop();
      await _controller.start(entry.config);
      setState(() => _activeId = entry.id);
      _scheduleLinuxTrayRefresh();
    } catch (err) {
      _showMessage(err.toString());
    }
  }

  Future<void> _disconnectActive({bool showMessage = true}) async {
    if (_activeId == null) {
      if (showMessage) _showMessage('Nothing is connected');
      return;
    }
    await _controller.stop();
    setState(() => _activeId = null);
    _scheduleLinuxTrayRefresh();
  }

  Future<void> _testSelected() async {
    final entry = _selectedEntry();
    if (entry == null) {
      _showMessage('Select a connection first');
      return;
    }
    if (_activeId != entry.id || _controller.status != TunnelStatus.connected) {
      _showMessage('Connect first');
      return;
    }
    setState(() => _testing = true);
    try {
      final result = await _controller.testConnection(entry.config);
      setState(() {
        _lastProbeError = null;
        _lastProbeAt = DateTime.now();
      });
      _showMessage('Test OK: $result');
    } catch (err) {
      setState(() {
        _lastProbeError = err.toString();
        _lastProbeAt = DateTime.now();
      });
      _showMessage('Test failed: $err');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<bool> _confirmDelete(ConnectionEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete connection?'),
        content: Text(entry.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _deleteEntry(ConnectionEntry entry) async {
    if (_activeId == entry.id) {
      _showMessage('Disconnect to delete');
      return;
    }
    final confirmed = await _confirmDelete(entry);
    if (confirmed) {
      _removeEntry(entry);
      _persistConnections();
    }
  }

  void _removeEntry(ConnectionEntry entry) {
    setState(() {
      _entries.removeWhere((e) => e.id == entry.id);
      if (_activeId == entry.id) _activeId = null;
      if (_selectedId == entry.id) _selectedId = _entries.isNotEmpty ? _entries.first.id : null;
    });
    _scheduleLinuxTrayRefresh();
  }

  Future<void> _showHwidDialog() async {
    final hwid = await getDeviceHwid();
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('HWID'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(hwid),
            const SizedBox(height: 8),
            Text('your HWID.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('close')),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: hwid));
              Navigator.pop(context);
              _showMessage('HWID copie');
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copie'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    final selected = _selectedEntry();
    final active = _activeEntry();
    final isSelectedActive = selected != null && selected.id == _activeId;
    final status = isSelectedActive ? _controller.status : TunnelStatus.disconnected;
    final canTest = isSelectedActive && status == TunnelStatus.connected && !_testing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PRINC LTE VPN'),
        actions: [
          IconButton(icon: const Icon(Icons.devices), tooltip: 'HWID', onPressed: _showHwidDialog),
          PopupMenuButton<ThemeMode>(
            initialValue: widget.themeMode,
            tooltip: 'Theme',
            onSelected: widget.onThemeModeChanged,
            itemBuilder: (context) => ThemeMode.values.map((mode) => PopupMenuItem<ThemeMode>(
              value: mode,
              child: Text(mode == ThemeMode.light ? 'Light' : mode == ThemeMode.dark ? 'Dark' : 'System'),
            )).toList(),
            icon: Icon(widget.themeMode == ThemeMode.light ? Icons.light_mode : widget.themeMode == ThemeMode.dark ? Icons.dark_mode : Icons.brightness_auto),
          ),
          IconButton(icon: const Icon(Icons.content_paste), tooltip: 'Paste URI', onPressed: _addFromClipboard),
          IconButton(icon: const Icon(Icons.add), tooltip: 'Add URI', onPressed: () async {
            final result = await _showAddDialog();
            if (result != null && result.isNotEmpty) _handleAddText(result);
          }),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? _EmptyState(onPaste: _addFromClipboard)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
              itemCount: entries.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final entry = entries[index];
                final isActive = _activeId == entry.id;
                return _ConnectionTile(
                  entry: entry,
                  isActive: isActive,
                  isSelected: _selectedId == entry.id,
                  status: isActive ? _controller.status : TunnelStatus.disconnected,
                  onSelect: () => _selectEntry(entry),
                  onDetails: () => _openDetails(entry),
                  onDelete: () => _deleteEntry(entry),
                );
              },
            ),
      bottomNavigationBar: _loading ? null : SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(selected == null ? 'Select a connection' : 'Selected: ${selected.title}',
                style: Theme.of(context).textTheme.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (active != null && active.id != selected?.id) ...[
                const SizedBox(height: 2),
                Text('Active: ${active.title}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
              const SizedBox(height: 10),
              Row(children: [
                Expanded(flex: 3, child: FilledButton.tonalIcon(
                  onPressed: canTest ? _testSelected : null,
                  icon: const Icon(Icons.network_check),
                  label: Text(_testing ? 'Testing...' : 'Test'),
                )),
                const SizedBox(width: 12),
                Expanded(flex: 5, child: SizedBox(height: 52, child: FilledButton.icon(
                  onPressed: status == TunnelStatus.connecting ? null : (isSelectedActive ? _disconnectActive : _connectSelected),
                  icon: Icon(isSelectedActive ? Icons.stop : Icons.play_arrow),
                  label: Text(status == TunnelStatus.connecting ? 'Connecting...' : (isSelectedActive ? 'Disconnect' : 'Connect')),
                ))),
              ]),
              if (_lastProbeAt != null) ...[
                const SizedBox(height: 6),
                Text(_lastProbeError != null ? 'Last test failed' : 'Last test OK',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
              ],
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerRight, child: _BuildInfoText()),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPaste});
  final VoidCallback onPaste;
  @override
  Widget build(BuildContext context) {
    return Center(child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.link, size: 48, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        Text('No connections yet', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text('paste your URL here.', style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: onPaste, icon: const Icon(Icons.content_paste), label: const Text('Paste URI')),
      ]),
    ));
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({required this.entry, required this.isActive, required this.isSelected, required this.status, required this.onSelect, required this.onDetails, required this.onDelete});
  final ConnectionEntry entry;
  final bool isActive;
  final bool isSelected;
  final TunnelStatus status;
  final VoidCallback onSelect;
  final VoidCallback onDetails;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final modeText = switch (entry.config.mode) {
      TunnelMode.proxy => 'Proxy',
      TunnelMode.vpn => 'VPN',
      TunnelMode.proxyPerApp => 'Proxy per app (${entry.config.proxyPerAppPackages.length})',
    };
    final subtitle = '$modeText  •  Local ${entry.config.localSocksPort}';
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: isSelected ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant, width: isSelected ? 1.4 : 1)),
      child: ListTile(
        onTap: onSelect,
        selected: isSelected,
        title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: _StatusChip(isActive: isActive, status: status),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(onPressed: isActive ? null : onDelete, icon: const Icon(Icons.delete_outline), tooltip: isActive ? 'Disconnect to delete' : 'Delete'),
          IconButton(onPressed: onDetails, icon: const Icon(Icons.chevron_right)),
        ]),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.isActive, required this.status});
  final bool isActive;
  final TunnelStatus status;
  @override
  Widget build(BuildContext context) {
    String label;
    Color color;
    final colors = Theme.of(context).colorScheme;
    if (!isActive) { label = 'Idle'; color = colors.outline; }
    else {
      switch (status) {
        case TunnelStatus.connected: label = 'Connected'; color = colors.primary; break;
        case TunnelStatus.connecting: label = 'Connecting'; color = colors.secondary; break;
        case TunnelStatus.error: label = 'Error'; color = colors.error; break;
        case TunnelStatus.disconnected: label = 'Disconnected'; color = colors.outline; break;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999), border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class ConnectionDetailPage extends StatefulWidget {
  const ConnectionDetailPage({super.key, required this.entry, required this.controller, required this.activeId, required this.onActiveChanged, required this.onSave, this.locked = false});
  final ConnectionEntry entry;
  final TunnelController controller;
  final String? activeId;
  final ValueChanged<String?> onActiveChanged;
  final SaveConnection onSave;
  final bool locked;
  @override
  State<ConnectionDetailPage> createState() => _ConnectionDetailPageState();
}

class _ConnectionDetailPageState extends State<ConnectionDetailPage> {
  Timer? _uiTimer;
  bool _testing = false;
  String? _lastProbeResult;
  String? _lastProbeError;
  DateTime? _lastProbeAt;
  bool _isActive = false;
  bool _dirty = true;
  String? _error;
  final _formKey = GlobalKey<FormState>();
  late ConnectionEntry _entry;
  late final TextEditingController _hostController;
  late final TextEditingController _keyController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  late final TextEditingController _hwidController;
  late final TextEditingController _localPortController;
  late final TextEditingController _encryptKeyController;
  late TunnelMode _mode;
  late String _encryptMode;
  late List<String> _proxyPerAppPackages;

  @override
  void initState() {
    super.initState();
    _entry = widget.entry;
    _isActive = widget.activeId == _entry.id;
    _dirty = true;
    _mode = _entry.config.mode;
    _hostController = TextEditingController(text: _entry.config.serverHost);
    _keyController = TextEditingController(text: _entry.config.key?.toString() ?? '');
    _usernameController = TextEditingController(text: _entry.config.username ?? '');
    _passwordController = TextEditingController(text: _entry.config.password ?? '');
    _hwidController = TextEditingController(text: _entry.config.hwid ?? '');
    _localPortController = TextEditingController(text: _entry.config.localSocksPort.toString());
    _encryptKeyController = TextEditingController(text: _entry.config.encryptKey ?? '');
    _encryptMode = _entry.config.encryptMode ?? 'none';
    _proxyPerAppPackages = [..._entry.config.proxyPerAppPackages]..sort();
    _uiTimer = Timer.periodic(const Duration(milliseconds: 500), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _hostController.dispose();
    _keyController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _hwidController.dispose();
    _localPortController.dispose();
    _encryptKeyController.dispose();
    super.dispose();
  }

  bool get _isProxyPerAppMode => _mode == TunnelMode.proxyPerApp;

  Future<bool> _applyEditsIfNeeded({bool showMessage = false}) async {
    final config = _buildConfigFromFields();
    if (config == null) {
      _showMessage('Champs invalides');
      return false;
    }
    final uri = buildConnectionUri(config);
    final updated = ConnectionEntry(uri: uri, config: config, locked: widget.locked);
    widget.onSave(updated, showMessage: showMessage);
    setState(() { _entry = updated; _dirty = false; });
    return true;
  }

  Future<void> _connect() async {
    if (!await _applyEditsIfNeeded()) return;
    if (_entry.config.hwid != null && _entry.config.hwid!.isNotEmpty) {
      final deviceHwid = await getDeviceHwid();
      if (_entry.config.hwid != deviceHwid) {
        setState(() => _error = 'HWID no valid');
        return;
      }
    }
    setState(() => _error = null);
    try {
      if (!_isActive && widget.controller.status == TunnelStatus.connected) await widget.controller.stop();
      await widget.controller.start(_entry.config);
      setState(() => _isActive = true);
      widget.onActiveChanged(_entry.id);
    } catch (err) {
      setState(() => _error = err.toString());
    }
  }

  Future<void> _disconnect() async {
    await widget.controller.stop();
    widget.onActiveChanged(null);
    setState(() => _isActive = false);
  }

  Future<void> _testConnection() async {
    if (!await _applyEditsIfNeeded()) return;
    if (!_isActive) { _showMessage('Connect first'); return; }
    setState(() => _testing = true);
    try {
      final result = await widget.controller.testConnection(_entry.config);
      setState(() { _lastProbeResult = result; _lastProbeError = null; _lastProbeAt = DateTime.now(); });
    } catch (err) {
      setState(() { _lastProbeError = err.toString(); _lastProbeResult = null; _lastProbeAt = DateTime.now(); });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _copyUri() async {
    await Clipboard.setData(ClipboardData(text: _entry.uri));
    _showMessage('URI copie');
  }

  TunnelConfig? _buildConfigFromFields() {
    final host = _hostController.text.trim();
    final keyText = _keyController.text.trim();
    final key = keyText.isEmpty ? null : int.tryParse(keyText);
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();
    final hwid = _hwidController.text.trim();
    final localPort = int.tryParse(_localPortController.text.trim());
    final encryptMode = _encryptMode == 'none' ? null : _encryptMode;
    final encryptKey = _encryptKeyController.text.trim().isEmpty ? null : _encryptKeyController.text.trim();
    if (host.isEmpty || localPort == null) return null;
    if (_encryptMode == 'none' && key == null && (username.isEmpty || password.isEmpty)) return null;
    if (_encryptMode != 'none' && encryptKey == null) return null;
    if (_isProxyPerAppMode && _proxyPerAppPackages.isEmpty) return null;
    return TunnelConfig(
      serverHost: host,
      serverPort: null,
      localSocksPort: localPort,
      key: _encryptMode == 'none' ? key : null,
      username: username.isEmpty ? null : username,
      password: password.isEmpty ? null : password,
      hwid: hwid.isEmpty ? null : hwid,
      mode: _mode,
      encryptMode: encryptMode,
      encryptKey: encryptKey,
      proxyPerAppPackages: [..._proxyPerAppPackages]..sort(),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final status = _isActive ? widget.controller.status : TunnelStatus.disconnected;
    final errorText = _error ?? widget.controller.lastError;
    final logLines = _isActive ? widget.controller.logBuffer.lines : <String>[];
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.locked ? 'PRINC LTE VPN' : _entry.config.serverHost),
        actions: [
          if (!widget.locked)
            IconButton(onPressed: _copyUri, icon: const Icon(Icons.copy), tooltip: 'Copie URI encode'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
        children: [
          _StatusCard(status: status, error: errorText),
          const SizedBox(height: 12),
          if (!widget.locked) _DetailsFormCard(
            formKey: _formKey,
            hostController: _hostController,
            keyController: _keyController,
            usernameController: _usernameController,
            passwordController: _passwordController,
            hwidController: _hwidController,
            localPortController: _localPortController,
            encryptKeyController: _encryptKeyController,
            mode: _mode,
            onModeChanged: (value) { if (_isActive) return; setState(() { _mode = value; _dirty = true; }); },
            encryptMode: _encryptMode,
            onEncryptModeChanged: (value) { if (_isActive) return; setState(() { _encryptMode = value; _dirty = true; }); },
            readOnly: _isActive,
            onSave: _saveEdits,
          ),
          const SizedBox(height: 12),
          _DiagnosticsCard(lastProbeResult: _lastProbeResult, lastProbeError: _lastProbeError, lastProbeAt: _lastProbeAt),
          const SizedBox(height: 12),
          _LogsCard(lines: logLines),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(flex: 3, child: FilledButton.tonalIcon(onPressed: _testing ? null : _testConnection, icon: const Icon(Icons.network_check), label: Text(_testing ? 'Testing...' : 'Test'))),
              const SizedBox(width: 12),
              Expanded(flex: 5, child: SizedBox(height: 52, child: FilledButton.icon(
                onPressed: status == TunnelStatus.connecting ? null : (_isActive ? _disconnect : _connect),
                icon: Icon(_isActive ? Icons.stop : Icons.play_arrow),
                label: Text(_isActive ? 'Disconnect' : 'Connect'),
              ))),
            ]),
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerRight, child: _BuildInfoText()),
          ]),
        ),
      ),
    );
  }

  Future<void> _saveEdits() async { await _applyEditsIfNeeded(showMessage: true); }
}

class _BuildInfoText extends StatelessWidget {
  const _BuildInfoText();
  @override
  Widget build(BuildContext context) {
    return Text(_buildLabel, style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 10, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)));
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.error});
  final TunnelStatus status;
  final String? error;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (title, subtitle, icon, color) = switch (status) {
      TunnelStatus.connected => ('Connected', 'Tunnel is active', Icons.check_circle, colors.primary),
      TunnelStatus.connecting => ('Connecting', 'Working...', Icons.hourglass_top, colors.secondary),
      TunnelStatus.error => ('Error', 'Check logs', Icons.error, colors.error),
      TunnelStatus.disconnected => ('Disconnected', 'Not connected', Icons.radio_button_unchecked, colors.outline),
    };
    return SizedBox(height: 72, child: Card(child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
      Icon(icon, color: color),
      const SizedBox(width: 12),
      Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 2),
        Text(error?.isNotEmpty == true ? error! : subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurface.withValues(alpha: 0.7)), maxLines: 1, overflow: TextOverflow.ellipsis),
      ])),
      _StatusChip(isActive: true, status: status),
    ]))));
  }
}

class _DetailsFormCard extends StatelessWidget {
  const _DetailsFormCard({
    required this.formKey,
    required this.hostController,
    required this.keyController,
    required this.usernameController,
    required this.passwordController,
    required this.hwidController,
    required this.localPortController,
    required this.encryptKeyController,
    required this.mode,
    required this.onModeChanged,
    required this.encryptMode,
    required this.onEncryptModeChanged,
    required this.readOnly,
    required this.onSave,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController hostController;
  final TextEditingController keyController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final TextEditingController hwidController;
  final TextEditingController localPortController;
  final TextEditingController encryptKeyController;
  final TunnelMode mode;
  final ValueChanged<TunnelMode> onModeChanged;
  final String encryptMode;
  final ValueChanged<String> onEncryptModeChanged;
  final bool readOnly;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('Details', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                FilledButton(onPressed: readOnly ? null : onSave, child: const Text('Save')),
              ]),
              const SizedBox(height: 12),
              TextFormField(controller: hostController, enabled: !readOnly, decoration: const InputDecoration(labelText: 'Host')),
              const SizedBox(height: 12),
              DropdownButtonFormField<TunnelMode>(
                initialValue: mode,
                decoration: const InputDecoration(labelText: 'Mode'),
                items: const [
                  DropdownMenuItem(value: TunnelMode.proxy, child: Text('Proxy')),
                  DropdownMenuItem(value: TunnelMode.vpn, child: Text('VPN')),
                  DropdownMenuItem(value: TunnelMode.proxyPerApp, child: Text('Proxy per app')),
                ],
                onChanged: readOnly ? null : (v) => onModeChanged(v!),
              ),
              const SizedBox(height: 12),
              TextFormField(controller: usernameController, enabled: !readOnly && encryptMode == 'none', decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person))),
              const SizedBox(height: 12),
              TextFormField(controller: passwordController, enabled: !readOnly && encryptMode == 'none', obscureText: true, decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock))),
              const SizedBox(height: 12),
              TextFormField(controller: hwidController, enabled: !readOnly, decoration: const InputDecoration(labelText: 'HWID Autorisé (optionnel)', prefixIcon: Icon(Icons.devices), hintText: 'Laisser vide pour tous')),
              const SizedBox(height: 12),
              TextFormField(controller: keyController, enabled: !readOnly && encryptMode == 'none', keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Key (legacy)')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: encryptMode,
                decoration: const InputDecoration(labelText: 'Encryption'),
                items: const [
                  DropdownMenuItem(value: 'none', child: Text('None')),
                  DropdownMenuItem(value: 'aes128', child: Text('AES-128')),
                  DropdownMenuItem(value: 'aes256', child: Text('AES-256')),
                  DropdownMenuItem(value: 'chacha20', child: Text('ChaCha20')),
                ],
                onChanged: readOnly ? null : (v) => onEncryptModeChanged(v!),
              ),
              const SizedBox(height: 12),
              TextFormField(controller: encryptKeyController, enabled: !readOnly && encryptMode != 'none', decoration: const InputDecoration(labelText: 'Encryption key')),
              const SizedBox(height: 12),
              TextFormField(controller: localPortController, enabled: !readOnly, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Local port')),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({required this.lastProbeResult, required this.lastProbeError, required this.lastProbeAt});
  final String? lastProbeResult;
  final String? lastProbeError;
  final DateTime? lastProbeAt;
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Diagnostics', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text('Test status: ${lastProbeError != null ? 'Failed' : lastProbeResult != null ? 'OK' : 'Not tested'}'),
          const SizedBox(height: 6),
          Text(lastProbeError ?? lastProbeResult ?? 'Run test to verify.'),
          const SizedBox(height: 10),
          Text('Last test: ${lastProbeAt == null ? '—' : lastProbeAt.toString()}'),
        ]),
      ),
    );
  }
}

class _LogsCard extends StatelessWidget {
  const _LogsCard({required this.lines});
  final List<String> lines;
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Logs', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            constraints: const BoxConstraints(minHeight: 120),
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            child: SelectableText(lines.isEmpty ? 'No logs yet.' : lines.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ]),
      ),
    );
  }
}
