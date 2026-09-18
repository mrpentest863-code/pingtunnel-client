import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

enum TunnelMode { proxy, vpn, proxyPerApp }

// Clé secrète servant à dériver la clé AES-256 (via SHA-256).
const String _secretKey = ".........................................................";

const int _defaultLocalSocksPort = 1080;
const int _minPort = 1;
const int _maxPort = 65535;
const Set<String> _validEncryptModes = {'aes128', 'aes256', 'chacha20'};
const int _aesIvLength = 16;

// Sentinelle pour copyWith.
const Object _unset = Object();

// Clé AES-256 dérivée du secret (32 octets = SHA-256).
final enc.Key _aesKey = enc.Key(
  Uint8List.fromList(sha256.convert(utf8.encode(_secretKey)).bytes),
);

bool _isValidPort(int? port) =>
    port == null || (port >= _minPort && port <= _maxPort);

class TunnelConfig {
  TunnelConfig({
    required this.serverHost,
    this.serverPort,
    required this.localSocksPort,
    this.key,
    this.username,
    this.password,
    this.hwid,
    required this.mode,
    this.encryptMode,
    this.encryptKey,
    this.interfaceName,
    this.tunDevice,
    this.dns,
    this.proxyPerAppPackages = const <String>[],
  });

  final String serverHost;
  final int? serverPort;
  final int localSocksPort;
  final int? key;
  final String? username;
  final String? password;
  final String? hwid;
  final TunnelMode mode;
  final String? encryptMode;
  final String? encryptKey;
  final String? interfaceName;
  final String? tunDevice;
  final String? dns;
  final List<String> proxyPerAppPackages;

  TunnelConfig copyWith({
    String? serverHost,
    Object? serverPort = _unset,
    int? localSocksPort,
    Object? key = _unset,
    Object? username = _unset,
    Object? password = _unset,
    Object? hwid = _unset,
    TunnelMode? mode,
    Object? encryptMode = _unset,
    Object? encryptKey = _unset,
    Object? interfaceName = _unset,
    Object? tunDevice = _unset,
    Object? dns = _unset,
    List<String>? proxyPerAppPackages,
  }) {
    return TunnelConfig(
      serverHost: serverHost ?? this.serverHost,
      serverPort:
          identical(serverPort, _unset) ? this.serverPort : serverPort as int?,
      localSocksPort: localSocksPort ?? this.localSocksPort,
      key: identical(key, _unset) ? this.key : key as int?,
      username:
          identical(username, _unset) ? this.username : username as String?,
      password:
          identical(password, _unset) ? this.password : password as String?,
      hwid: identical(hwid, _unset) ? this.hwid : hwid as String?,
      mode: mode ?? this.mode,
      encryptMode: identical(encryptMode, _unset)
          ? this.encryptMode
          : encryptMode as String?,
      encryptKey: identical(encryptKey, _unset)
          ? this.encryptKey
          : encryptKey as String?,
      interfaceName: identical(interfaceName, _unset)
          ? this.interfaceName
          : interfaceName as String?,
      tunDevice:
          identical(tunDevice, _unset) ? this.tunDevice : tunDevice as String?,
      dns: identical(dns, _unset) ? this.dns : dns as String?,
      proxyPerAppPackages: proxyPerAppPackages != null
          ? List<String>.from(proxyPerAppPackages)
          : this.proxyPerAppPackages,
    );
  }

  String serverAddress() {
    if (serverPort == null) {
      return serverHost;
    }
    return "$serverHost:$serverPort";
  }

  int localProxyBackendSocksPort() {
    if (localSocksPort < _minPort || localSocksPort > _maxPort) {
      return _defaultLocalSocksPort + 1;
    }
    if (localSocksPort == _maxPort) {
      return _maxPort - 1;
    }
    return localSocksPort + 1;
  }

  Map<String, Object?> toMap() {
    return {
      'serverHost': serverHost,
      'serverPort': serverPort,
      'localSocksPort': localSocksPort,
      'key': key,
      'username': username,
      'password': password,
      'hwid': hwid,
      'mode': switch (mode) {
        TunnelMode.proxy => 'proxy',
        TunnelMode.vpn => 'vpn',
        TunnelMode.proxyPerApp => 'proxy_per_app',
      },
      'encryptMode': encryptMode,
      'encryptKey': encryptKey,
      'interfaceName': interfaceName,
      'tunDevice': tunDevice,
      'dns': dns,
      'proxyPerAppPackages': proxyPerAppPackages,
    };
  }

  /// Chiffre la config en AES-256-CBC avec IV aléatoire.
  /// Format : base64url( IV(16 octets) || ciphertext ).
  String encode() {
    final jsonString = jsonEncode(toMap());
    final iv = enc.IV.fromSecureRandom(_aesIvLength);
    final encrypter = enc.Encrypter(enc.AES(_aesKey));
    final encrypted = encrypter.encrypt(jsonString, iv: iv);

    final combined = Uint8List(iv.bytes.length + encrypted.bytes.length);
    combined.setRange(0, iv.bytes.length, iv.bytes);
    combined.setRange(iv.bytes.length, combined.length, encrypted.bytes);

    return base64Url.encode(combined);
  }

  /// Déchiffre une config produite par [encode].
  static TunnelConfig decode(String encoded) {
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(encoded);
    } on FormatException catch (e) {
      throw FormatException('Invalid encoded config: ${e.message}');
    }
    if (bytes.length <= _aesIvLength) {
      throw const FormatException('Encoded config too short');
    }

    final iv = enc.IV(Uint8List.fromList(bytes.sublist(0, _aesIvLength)));
    final ciphertext =
        enc.Encrypted(Uint8List.fromList(bytes.sublist(_aesIvLength)));
    final encrypter = enc.Encrypter(enc.AES(_aesKey));

    final String jsonString;
    try {
      jsonString = encrypter.decrypt(ciphertext, iv: iv);
    } catch (e) {
      throw FormatException('Failed to decrypt config: $e');
    }

    final map = jsonDecode(jsonString) as Map<String, dynamic>;
    return TunnelConfig.fromMap(map);
  }

  /// Construit depuis une map (avec vérifications explicites).
  static TunnelConfig fromMap(Map<String, dynamic> map) {
    final host = map['serverHost'];
    if (host is! String || host.isEmpty) {
      throw const FormatException(
        'fromMap: "serverHost" is required and must be a non-empty string',
      );
    }

    final serverPort = map['serverPort'];
    if (serverPort != null && serverPort is! int) {
      throw const FormatException(
        'fromMap: "serverPort" must be an int or null',
      );
    }
    if (!_isValidPort(serverPort as int?)) {
      throw FormatException(
        'fromMap: "serverPort" out of range ($_minPort-$_maxPort): $serverPort',
      );
    }

    final localSocksPortRaw = map['localSocksPort'];
    if (localSocksPortRaw != null && localSocksPortRaw is! int) {
      throw const FormatException(
        'fromMap: "localSocksPort" must be an int or null',
      );
    }
    final localSocksPort =
        (localSocksPortRaw as int?) ?? _defaultLocalSocksPort;
    if (!_isValidPort(localSocksPort)) {
      throw FormatException(
        'fromMap: "localSocksPort" out of range ($_minPort-$_maxPort): '
        '$localSocksPort',
      );
    }

    final modeStr = map['mode'] as String? ?? 'proxy';
    final mode = switch (modeStr) {
      'vpn' => TunnelMode.vpn,
      'proxy_per_app' => TunnelMode.proxyPerApp,
      'proxy' => TunnelMode.proxy,
      _ => throw FormatException('fromMap: invalid mode "$modeStr"'),
    };

    final encryptMode = map['encryptMode'] as String?;
    if (encryptMode != null && !_validEncryptModes.contains(encryptMode)) {
      throw FormatException(
        'fromMap: invalid encryptMode "$encryptMode" '
        '(allowed: ${_validEncryptModes.join(", ")})',
      );
    }

    final packages = (map['proxyPerAppPackages'] as List?)
            ?.map((e) => e?.toString() ?? '')
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];

    return TunnelConfig(
      serverHost: host,
      serverPort: serverPort as int?,
      localSocksPort: localSocksPort,
      key: map['key'] as int?,
      username: map['username'] as String?,
      password: map['password'] as String?,
      hwid: map['hwid'] as String?,
      mode: mode,
      encryptMode: encryptMode,
      encryptKey: map['encryptKey'] as String?,
      interfaceName: map['interfaceName'] as String?,
      tunDevice: map['tunDevice'] as String?,
      dns: map['dns'] as String?,
      proxyPerAppPackages: packages,
    );
  }

  static TunnelConfig parse(String uriText) {
    final uri = Uri.parse(uriText.trim());
    if (uri.scheme != 'princ') {
      throw const FormatException('URI scheme must be princ://');
    }

    String host = uri.host;

    // Si c'est une URL encodée
    if (host == 'encoded' || (host.isEmpty && uri.path.isNotEmpty)) {
      final encoded = uri.path.replaceAll('/', '');
      if (encoded.isNotEmpty) {
        return decode(encoded);
      }
    }

    if (host.isEmpty) {
      host = uri.path;
    }
    if (host.isEmpty) {
      throw const FormatException('Missing server host');
    }

    final params = uri.queryParameters;

    // --- Ports ---
    final serverPortRaw = params['port'] ?? params['server_port'];
    final serverPort = serverPortRaw == null || serverPortRaw.isEmpty
        ? null
        : int.tryParse(serverPortRaw);
    if (serverPortRaw != null &&
        serverPortRaw.isNotEmpty &&
        serverPort == null) {
      throw FormatException(
        'server_port must be an integer: "$serverPortRaw"',
      );
    }
    if (!_isValidPort(serverPort)) {
      throw FormatException(
        'server_port out of range ($_minPort-$_maxPort): $serverPort',
      );
    }

    final localPortRaw = params['lport'] ?? params['local_port'];
    final localPort = localPortRaw == null || localPortRaw.isEmpty
        ? _defaultLocalSocksPort
        : int.tryParse(localPortRaw);
    if (localPortRaw != null &&
        localPortRaw.isNotEmpty &&
        localPort == null) {
      throw FormatException('local_port must be an integer: "$localPortRaw"');
    }
    if (!_isValidPort(localPort)) {
      throw FormatException(
        'local_port out of range ($_minPort-$_maxPort): $localPort',
      );
    }

    // --- Auth ---
    final keyText = params['key'] ?? '';
    final int? key;
    if (keyText.isEmpty) {
      key = null;
    } else {
      key = int.tryParse(keyText);
      if (key == null) {
        throw const FormatException('Key must be an integer');
      }
    }
    final username = params['user'] ?? params['username'];
    final password = params['pass'] ?? params['password'];
    final hwid = params['hwid'];

    // --- Mode ---
    final modeValue =
        (params['mode'] ?? params['vpn'] ?? 'proxy').toLowerCase();
    final mode = switch (modeValue) {
      'vpn' || '1' => TunnelMode.vpn,
      'proxy_per_app' ||
      'proxy-per-app' ||
      'per_app' ||
      'app' ||
      'app_proxy' =>
        TunnelMode.proxyPerApp,
      'proxy' || '0' || '' => TunnelMode.proxy,
      _ => throw FormatException('Invalid mode: "$modeValue"'),
    };

    final proxyPerAppPackages =
        (params['apps'] ?? '')
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    // --- Chiffrement : mode invalide = erreur explicite ---
    final rawEncrypt =
        (params['encrypt'] ??
                params['encrypt_mode'] ??
                params['encryptMode'] ??
                params['enc'] ??
                '')
            .toLowerCase();
    final String? encryptMode;
    if (rawEncrypt.isEmpty || rawEncrypt == '0' || rawEncrypt == 'none') {
      encryptMode = null;
    } else if (_validEncryptModes.contains(rawEncrypt)) {
      encryptMode = rawEncrypt;
    } else {
      throw FormatException(
        'Invalid encrypt mode "$rawEncrypt" '
        '(allowed: ${_validEncryptModes.join(", ")}, none)',
      );
    }

    final encryptKey =
        params['encrypt-key'] ?? params['encrypt_key'] ?? params['encryptKey'];

    if (encryptMode == null &&
        key == null &&
        (username == null ||
            username.isEmpty ||
            password == null ||
            password.isEmpty)) {
      throw const FormatException('Missing key or username/password');
    }
    if (encryptMode != null && (encryptKey == null || encryptKey.isEmpty)) {
      throw const FormatException('Missing encrypt_key');
    }

    return TunnelConfig(
      serverHost: host,
      serverPort: serverPort,
      localSocksPort: localPort,
      key: key,
      username: username?.isNotEmpty == true ? username : null,
      password: password?.isNotEmpty == true ? password : null,
      hwid: hwid,
      mode: mode,
      encryptMode: encryptMode,
      encryptKey: encryptKey,
      interfaceName: params['iface'] ?? params['interface'],
      tunDevice: params['tun'] ?? params['tun_device'],
      dns: params['dns'],
      proxyPerAppPackages: proxyPerAppPackages,
    );
  }
}
