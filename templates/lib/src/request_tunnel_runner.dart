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
  final Set<Socket> _active = {};
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
    _server!.listen(
      (socket) {
        _active.add(socket);
        // Évite les erreurs asynchrones non gérées (broken pipe, reset...)
        socket.done.catchError((_) {});
        try {
          socket.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        _handleClient(socket, config);
      },
      onError: (Object e) => logBuffer.add('[requestTunnel] Server error: $e'),
    );
  }

  Future<void> stop() async {
    _running = false;
    _workingServerPort = null;
    for (final s in _active.toList()) {
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
    var replied = false; // true une fois la réponse SOCKS5 finale envoyée
    final reader = _Reader(client);
    try {
      // 1. SOCKS5 greeting
      final greeting = await reader.readN(2).timeout(const Duration(seconds: 15));
      if (greeting[0] != 0x05) throw Exception('Not SOCKS5');
      final nMethods = greeting[1];
      if (nMethods > 0) await reader.readN(nMethods);
      client.add([0x05, 0x00]);

      // 2. SOCKS5 request
      final req = await reader.readN(4);
      if (req[0] != 0x05) throw Exception('Not SOCKS5 (v${req[0]})');
      final cmd = req[1];
      final atyp = req[3];

      // 3. adresse cible (lue pour TOUTES les commandes afin de garder le flux cohérent)
      String targetHost;
      Uint8List targetRaw;
      if (atyp == 0x01) {
        targetRaw = await reader.readN(4);
        targetHost = targetRaw.join('.');
      } else if (atyp == 0x03) {
        final len = (await reader.readN(1))[0];
        targetRaw = await reader.readN(len);
        targetHost = String.fromCharCodes(targetRaw);
      } else if (atyp == 0x04) {
        targetRaw = await reader.readN(16);
        final parts = <String>[];
        for (var i = 0; i < 16; i += 2) {
          parts.add(((targetRaw[i] << 8) | targetRaw[i + 1]).toRadixString(16));
        }
        targetHost = parts.join(':');
      } else {
        throw Exception('Unknown atyp $atyp');
      }
      final portB = await reader.readN(2);
      final targetPort = (portB[0] << 8) | portB[1];

      // UDP ASSOCIATE : succès simulé, paquets ignorés, socket gardée ouverte.
      if (cmd == 0x03) {
        client.add([0x05, 0x00, 0x00, 0x01, 0x7F, 0, 0, 1, 0, 1]);
        replied = true;
        logBuffer.add('[requestTunnel] UDP associé mais ignoré (DNS)');
        await reader.discard(); // lit et jette jusqu'à fermeture
        return;
      }

      if (cmd != 0x01) {
        // 0x07 = command not supported
        client.add([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        replied = true;
        throw Exception('Unsupported cmd 0x${cmd.toRadixString(16)}');
      }

      // 4. TCP vers serveur
      final tryPorts = <int>[
        if (config.serverPort != null) config.serverPort!,
        if (config.serverPort == null) ...[80, 8080],
      ];
      final wp = _workingServerPort;
      if (wp != null) {
        tryPorts.remove(wp);
        tryPorts.insert(0, wp);
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
          remote = null;
        }
      }
      if (remote == null) {
        throw Exception(
            'Cannot reach ${config.serverHost} on ${tryPorts.join('/')}');
      }
      final rs = remote; // non-null
      _active.add(rs);
      rs.done.catchError((_) {});
      try {
        rs.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      final remoteReader = _Reader(rs);
      logBuffer.add(
        '[requestTunnel] ${config.serverHost}:$_workingServerPort for $targetHost:$targetPort',
      );

      // 5. payload HTTP CONNECT
      var payload = (config.customPayload?.isNotEmpty ?? false)
          ? config.customPayload!
          : _defaultPayload;
      payload = payload.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
      if (!payload.endsWith('\r\n\r\n')) {
        payload = payload.endsWith('\r\n') ? '$payload\r\n' : '$payload\r\n\r\n';
      }
      rs.add(utf8.encode(payload));
      final httpReply = await remoteReader
          .readUntil('\r\n\r\n')
          .timeout(const Duration(seconds: 10));
      final statusLine = httpReply.split('\r\n').first;
      final statusParts = statusLine.split(' ');
      if (statusParts.length < 2 || statusParts[1] != '200') {
        throw Exception('HTTP CONNECT failed: $statusLine');
      }

      // 6. auth SOCKS5
      String? user;
      String? pass;
      if (config.key != null) {
        user = 'key';
        pass = config.key.toString();
      } else if (config.username != null && config.password != null) {
        user = config.username;
        pass = config.password;
      }

      const t = Duration(seconds: 10);
      if (user != null && pass != null) {
        rs.add([0x05, 0x01, 0x02]);
        final hr = await remoteReader.readN(2).timeout(t);
        if (hr[1] != 0x02) throw Exception('Server rejected user/pass method');
        final uB = utf8.encode(user);
        final pB = utf8.encode(pass);
        if (uB.length > 255 || pB.length > 255) {
          throw Exception('Username/password too long');
        }
        rs.add([0x01, uB.length, ...uB, pB.length, ...pB]);
        final ar = await remoteReader.readN(2).timeout(t);
        if (ar[1] != 0x00) throw Exception('SOCKS5 auth refused');
      } else {
        rs.add([0x05, 0x01, 0x00]);
        final hr = await remoteReader.readN(2).timeout(t);
        if (hr[1] != 0x00) throw Exception('Server requires auth');
      }

      // 7. CONNECT cible (on conserve le type d'adresse d'origine)
      rs.add([
        0x05, 0x01, 0x00, atyp,
        if (atyp == 0x03) targetRaw.length,
        ...targetRaw,
        (targetPort >> 8) & 0xFF, targetPort & 0xFF,
      ]);
      final cr = await remoteReader.readN(4).timeout(t);
      if (cr[1] != 0x00) {
        throw Exception('SOCKS5 CONNECT refused (code ${cr[1]})');
      }
      if (cr[3] == 0x01) {
        await remoteReader.readN(6);
      } else if (cr[3] == 0x03) {
        final len = (await remoteReader.readN(1))[0];
        await remoteReader.readN(len + 2);
      } else if (cr[3] == 0x04) {
        await remoteReader.readN(18);
      }

      // 8. succès
      client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      replied = true;

      // 9. bridge : dès qu'un côté se ferme, on ferme l'autre
      final done = Completer<void>();
      void finish() {
        if (!done.isCompleted) done.complete();
      }

      reader.drainTo(rs).catchError((_) {}).whenComplete(finish);
      remoteReader.drainTo(client).catchError((_) {}).whenComplete(finish);
      await done.future;
    } catch (e) {
      logBuffer.add('[requestTunnel] Error: $e');
      if (!replied) {
        try {
          client.add([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        } catch (_) {}
      }
    } finally {
      _active.remove(client);
      try {
        client.destroy();
      } catch (_) {}
      if (remote != null) {
        _active.remove(remote);
        try {
          remote.destroy();
        } catch (_) {}
      }
    }
  }
}

class _Reader {
  _Reader(Socket s) : _it = StreamIterator<List<int>>(s);
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

  Future<String> readUntil(String delim, {int maxBytes = 64 * 1024}) async {
    final dBytes = utf8.encode(delim);
    var from = 0;
    while (true) {
      for (var i = from; i <= _buf.length - dBytes.length; i++) {
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
      from = _buf.length - dBytes.length + 1;
      if (from < 0) from = 0;
      if (_buf.length > maxBytes) throw Exception('Header too large');
      await _fill();
    }
  }

  /// Lit et jette tout jusqu'à la fermeture (utilisé pour UDP ASSOCIATE).
  /// On ne peut pas appeler socket.drain() : le flux est déjà écouté par l'itérateur.
  Future<void> discard() async {
    _buf.clear();
    try {
      while (await _it.moveNext()) {}
    } catch (_) {}
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
