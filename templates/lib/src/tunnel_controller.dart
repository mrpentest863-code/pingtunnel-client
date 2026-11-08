import 'dart:io';

import 'asset_manager.dart';
import 'android_runner.dart';
import 'config.dart';
import 'desktop_runner.dart';
import 'log_buffer.dart';
import 'request_tunnel_runner.dart';
import 'socks5_probe.dart';

enum TunnelStatus { disconnected, connecting, connected, error }

class TunnelController {
  TunnelController() : logBuffer = LogBuffer(), assets = AssetManager() {
    _desktopRunner = DesktopRunner(assets: assets, logBuffer: logBuffer);
    _androidRunner = AndroidRunner();
    _requestTunnelRunner = RequestTunnelRunner(logBuffer: logBuffer);
  }

  final LogBuffer logBuffer;
  final AssetManager assets;
  late final DesktopRunner _desktopRunner;
  late final AndroidRunner _androidRunner;
  late final RequestTunnelRunner _requestTunnelRunner;

  TunnelStatus status = TunnelStatus.disconnected;
  String? lastError;

  Future<String> testConnection(TunnelConfig config) async {
    if (config.mode == TunnelMode.vpn ||
        config.mode == TunnelMode.proxyPerApp ||
        config.mode == TunnelMode.requestTunnel) {
      final socksProbe = Socks5Probe();
      logBuffer.add('[test] VPN mode: checking tunnel core via SOCKS5...');
      try {
        final ip = await socksProbe.run(socksPort: config.localSocksPort);
        logBuffer.add('[test] OK (socks): $ip');
        return ip;
      } catch (err) {
        final message = err.toString();
        logBuffer.add('[test] FAILED: $message');
        rethrow;
      }
    }
    final probe = Socks5Probe();
    logBuffer.add('[test] Starting SOCKS5 probe...');
    try {
      final ip = await probe.run(socksPort: config.localSocksPort);
      logBuffer.add('[test] OK: $ip');
      return ip;
    } catch (err) {
      final message = err.toString();
      logBuffer.add('[test] FAILED: $message');
      rethrow;
    }
  }

  Future<void> start(TunnelConfig config) async {
    status = TunnelStatus.connecting;
    lastError = null;
    logBuffer.clear();

    try {
      final runtimeConfig = await _resolveServerHost(config);

      if (Platform.isAndroid) {
        if (runtimeConfig.mode == TunnelMode.requestTunnel) {
          final ok = await _androidRunner.prepareVpn();
          if (!ok) {
            throw StateError('VPN permission not granted');
          }
          await _requestTunnelRunner.start(runtimeConfig);
          await _androidRunner.startVpn(runtimeConfig);
        } else if (runtimeConfig.mode == TunnelMode.vpn ||
            runtimeConfig.mode == TunnelMode.proxyPerApp) {
          final ok = await _androidRunner.prepareVpn();
          if (!ok) {
            throw StateError('VPN permission not granted');
          }
          await _androidRunner.startVpn(runtimeConfig);
        } else {
          await _androidRunner.startProxy(runtimeConfig);
        }
      } else {
        if (runtimeConfig.mode == TunnelMode.requestTunnel) {
          throw UnsupportedError(
            'Request tunnel mode is only supported on Android',
          );
        }
        if (runtimeConfig.mode == TunnelMode.proxy) {
          await _desktopRunner.startProxy(runtimeConfig);
        } else {
          await _desktopRunner.startVpn(runtimeConfig);
        }
      }

      if (runtimeConfig.mode == TunnelMode.proxy) {
        logBuffer.add(
          '[proxy] Mixed SOCKS5/HTTP: 127.0.0.1:${runtimeConfig.localSocksPort}',
        );
      }

      status = TunnelStatus.connected;
    } catch (err) {
      lastError = err.toString();
      status = TunnelStatus.error;
      try {
        await _requestTunnelRunner.stop();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await _androidRunner.stop();
    } else {
      await _desktopRunner.stop();
    }
    await _requestTunnelRunner.stop();
    status = TunnelStatus.disconnected;
  }

  Future<bool> isAndroidRunning() async {
    if (!Platform.isAndroid) {
      return false;
    }
    return _androidRunner.isRunning();
  }

  Future<List<AndroidAppInfo>> listAndroidLaunchableApps() async {
    if (!Platform.isAndroid) {
      return <AndroidAppInfo>[];
    }
    return _androidRunner.listLaunchableApps();
  }

  void markDisconnectedExternally() {
    status = TunnelStatus.disconnected;
    lastError = null;
  }

  Future<TunnelConfig> _resolveServerHost(TunnelConfig config) async {
    final host = config.serverHost.trim();
    if (host.isEmpty) {
      return config;
    }
    if (InternetAddress.tryParse(host) != null) {
      return config;
    }

    try {
      final resolved = await InternetAddress.lookup(host);
      if (resolved.isEmpty) {
        return config;
      }

      InternetAddress? ipv4;
      for (final address in resolved) {
        if (address.type == InternetAddressType.ipv4) {
          ipv4 = address;
          break;
        }
      }
      if (ipv4 == null) {
        logBuffer.add('[dns] No IPv4 address for $host, using hostname');
        return config;
      }

      final resolvedHost = ipv4.address;
      logBuffer.add('[dns] Resolved $host -> $resolvedHost');
      return config.copyWith(serverHost: resolvedHost);
    } catch (err) {
      logBuffer.add('[dns] Host lookup failed for $host: $err');
      return config;
    }
  }
}
