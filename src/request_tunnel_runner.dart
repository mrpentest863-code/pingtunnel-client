import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'log_buffer.dart';

const String _defaultPayload =
    'CONNECT cdn.cloudflare.com:443 HTTP/1.1\r\n'
    'Host: cdn.cloudflare.com\r\n'
    'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)\r\n'
    'Proxy-Connection: keep-alive\r\n'
    '\r\n';

class RequestTunnelRunner {
  RequestTunnelRunner({required this.logBuffer});

  final LogBuffer logBuffer;
  ServerSocket? _server;
  int? _workingServerPort;
  final List<Socket> _active = [];
  bool _running = false;

  bool get isRunning => _running;

  Future<void> start(TunnelConfig config) async {
    if (_running) await stop();

    _server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      config.localSocksPort,
    );
    _running = true;
    logBuffer.add(
      '[requestTunnel] SOCKS5 listening on 127.0.0.1:${config.localSocksPort}',
    );

    _server!.listen((socket) {
      _active.add(socket);
      _handleClient(socket, config);
    });
  }

  Future<void> stop() async {
    _running = false;
    _workingServerPort = null;
    for (final s in _active) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _active.clear();
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
    logBuffer.add('[requestTunnel] Stopped');
  }

  Future<void> _handleClient(Socket client, TunnelConfig config) async {
    Socket? remote;
    final reader = _Reader(client);
    try {
      // ───── 1. SOCKS5 greeting depuis tun2socks ─────
      final greeting = await reader.readN(2);
      if (greeting[0] != 0x05) throw Exception('Not SOCKS5');
      final nMethods = greeting[1];
      if (nMethods > 0) await reader.readN(nMethods);
      client.add([0x05, 0x00]); // no-auth accepté côté local

      // ───── 2. SOCKS5 CONNECT depuis tun2socks ─────
      final req = await reader.readN(4);
      if (req[0] != 0x05 || req[1] != 0x01) {
        throw Exception('Only SOCKS5 CONNECT supported');
      }
      final atyp = req[3];
      String targetHost;
      if (atyp == 0x01) {
        targetHost = (await reader.readN(4)).join('.');
      } else if (atyp == 0x03) {
        final len = (await reader.readN(1))[0];
        targetHost = String.fromCharCodes(await reader.readN(len));
      } else if (atyp == 0x04) {
        final b = await reader.readN(16);
        final parts = <String>[];
        for (var i = 0; i < 16; i += 2) {
          parts.add(((b[i] << 8) | b[i + 1]).toRadixString(16));
        }
        targetHost = parts.join(':');
      } else {
        throw Exception('Unknown atyp $atyp');
      }
      final portB = await reader.readN(2);
      final targetPort = (portB[0] << 8) | portB[1];

      // ───── 3. Connexion TCP vers serveur (80/8080) ─────
      final tryPorts = <int>[
        if (config.serverPort != null) config.serverPort!,
        if (config.serverPort == null) ...[80, 8080],
      ];
      if (_workingServerPort != null) {
        tryPorts.remove(_workingServerPort);
        tryPorts.insert(0, _workingServerPort!);
      }

      for (final p in tryPorts) {
        try {
          remote = await Socket.connect(
            config.serverHost,
            p,
            timeout: const Duration(seconds: 5),
          );
          _workingServerPort = p;
          break;
        } catch (_) {
          try {
            remote?.destroy();
          } catch (_) {}
          remote = null;
        }
      }
      if (remote == null) {
        throw Exception('Cannot reach ${config.serverHost} on 80/8080');
      }
      final remoteReader = _Reader(remote);
      logBuffer.add(
        '[requestTunnel] ${config.serverHost}:$_workingServerPort '
        'for $targetHost:$targetPort',
      );

      // ───── 4. Envoi du payload HTTP CONNECT ─────
      var payload = (config.customPayload?.isNotEmpty ?? false)
          ? config.customPayload!
          : _defaultPayload;
      payload = payload.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
      remote.add(utf8.encode(payload));

      final httpReply = await remoteReader
          .readUntil('\r\n\r\n')
          .timeout(const Duration(seconds: 10));
      if (!httpReply.contains('200')) {
        throw Exception(
          'HTTP CONNECT failed: ${httpReply.split('\r\n').first}',
        );
      }

      // ───── 5. SOCKS5 auth vers le serveur ─────
      String? user;
      String? pass;
      if (config.key != null) {
        user = 'key';
        pass = config.key.toString();
      } else if (config.username != null && config.password != null) {
        user = config.username;
        pass = config.password;
      }

      if (user != null && pass != null) {
        remote.add([0x05, 0x01, 0x02]); // user/pass
        final hr = await remoteReader.readN(2);
        if (hr[1] != 0x02) {
          throw Exception('Server rejected user/pass method');
        }
        final uB = utf8.encode(user);
        final pB = utf8.encode(pass);
        remote.add([0x01, uB.length, ...uB, pB.length, ...pB]);
        final ar = await remoteReader.readN(2);
        if (ar[1] != 0x00) throw Exception('SOCKS5 auth refused');
      } else {
        remote.add([0x05, 0x01, 0x00]); // no auth
        final hr = await remoteReader.readN(2);
        if (hr[1] != 0x00) throw Exception('Server requires auth');
      }

      // ───── 6. SOCKS5 CONNECT vers target réel ─────
      final tB = utf8.encode(targetHost);
      remote.add([
        0x05,
        0x01,
        0x00,
        0x03,
        tB.length,
        ...tB,
        (targetPort >> 8) & 0xFF,
        targetPort & 0xFF,
      ]);
      final cr = await remoteReader.readN(4);
      if (cr[1] != 0x00) {
        throw Exception('SOCKS5 CONNECT refused (code ${cr[1]})');
      }
      // consomme l'adresse liée
      if (cr[3] == 0x01) {
        await remoteReader.readN(6);
      } else if (cr[3] == 0x03) {
        final len = (await remoteReader.readN(1))[0];
        await remoteReader.readN(len + 2);
      } else if (cr[3] == 0x04) {
        await remoteReader.readN(18);
      }

      // ───── 7. Succès → réponse à tun2socks ─────
      client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);

      // ───── 8. Bridge bidirectionnel ─────
      await Future.wait([
        reader.drainTo(remote),
        remoteReader.drainTo(client),
      ]);
    } catch (e) {
      logBuffer.add('[requestTunnel] Error: $e');
      try {
        client.add([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      } catch (_) {}
      try {
        client.destroy();
      } catch (_) {}
      try {
        remote?.destroy();
      } catch (_) {}
    } finally {
      _active.remove(client);
    }
  }
}

class _Reader {
  _Reader(Socket s) : _it = StreamIterator(s);
  final StreamIterator<List<int>> _it;
  final List<int> _buf = [];

  Future<void> _fill() async {
    if (!await _it.moveNext()) throw Exception('EOF');
    _buf.addAll(_it.current);
  }

  Future<Uint8List> readN(int n) async {
    while (_buf.length < n) {
      await _fill();
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  Future<String> readUntil(String delim) async {
    final dBytes = utf8.encode(delim);
    while (true) {
      for (var i = 0; i <= _buf.length - dBytes.length; i++) {
        var ok = true;
        for (var j = 0; j < dBytes.length; j++) {
          if (_buf[i + j] != dBytes[j]) {
            ok = false;
            break;
          }
        }
        if (ok) {
          final end = i + dBytes.length;
          final s = utf8.decode(_buf.sublist(0, end), allowMalformed: true);
          _buf.removeRange(0, end);
          return s;
        }
      }
      await _fill();
    }
  }

  Future<void> drainTo(Socket out) async {
    if (_buf.isNotEmpty) {
      out.add(Uint8List.fromList(_buf));
      _buf.clear();
    }
    while (await _it.moveNext()) {
      out.add(_it.current);
    }
  }
}
