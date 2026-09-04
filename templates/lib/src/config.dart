import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;

enum TunnelMode { proxy, vpn, proxyPerApp }

const String _secretKey = "PingTunnelSecretKey2024!";

// Liste de mots chargée depuis l'asset (2048 mots)
List<String> _wordList = [];
bool _wordListLoaded = false;

/// Charge la liste de mots depuis l'asset (à appeler une fois au démarrage)
Future<void> loadWordList() async {
  if (_wordListLoaded) return;
  final raw = await rootBundle.loadString('assets/wordlist_fr.txt');
  _wordList = raw
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  if (_wordList.length != 2048) {
    throw Exception('La liste de mots doit contenir exactement 2048 entrées');
  }
  _wordListLoaded = true;
}

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
    int? serverPort,
    int? localSocksPort,
    int? key,
    String? username,
    String? password,
    String? hwid,
    TunnelMode? mode,
    String? encryptMode,
    String? encryptKey,
    String? interfaceName,
    String? tunDevice,
    String? dns,
    List<String>? proxyPerAppPackages,
  }) {
    return TunnelConfig(
      serverHost: serverHost ?? this.serverHost,
      serverPort: serverPort ?? this.serverPort,
      localSocksPort: localSocksPort ?? this.localSocksPort,
      key: key ?? this.key,
      username: username ?? this.username,
      password: password ?? this.password,
      hwid: hwid ?? this.hwid,
      mode: mode ?? this.mode,
      encryptMode: encryptMode ?? this.encryptMode,
      encryptKey: encryptKey ?? this.encryptKey,
      interfaceName: interfaceName ?? this.interfaceName,
      tunDevice: tunDevice ?? this.tunDevice,
      dns: dns ?? this.dns,
      proxyPerAppPackages: proxyPerAppPackages != null
          ? List<String>.from(proxyPerAppPackages)
          : this.proxyPerAppPackages,
    );
  }

  String serverAddress() {
    if (serverPort == null) return serverHost;
    return "$serverHost:$serverPort";
  }

  int localProxyBackendSocksPort() {
    if (localSocksPort < 1 || localSocksPort > 65535) return 1081;
    if (localSocksPort == 65535) return 65534;
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

  // Encodage en phrase courte (12-24 mots) utilisant BIP39-like
  String encode() {
    if (!_wordListLoaded) {
      throw StateError('Word list not loaded. Call loadWordList() first.');
    }

    // 1. JSON -> bytes
    final jsonString = jsonEncode(toMap());
    final bytes = utf8.encode(jsonString);
    // 2. XOR encrypt
    final encrypted = List<int>.generate(bytes.length, (i) {
      return bytes[i] ^ _secretKey.codeUnitAt(i % _secretKey.length);
    });
    // 3. gzip compress
    final compressed = gzip.encode(encrypted);
    // 4. Convert bytes to bits
    final bits = <int>[];
    for (final byte in compressed) {
      for (int i = 7; i >= 0; i--) {
        bits.add((byte >> i) & 1);
      }
    }
    // 5. Pad to multiple of 11
    while (bits.length % 11 != 0) {
      bits.add(0);
    }
    // 6. Convert each 11-bit chunk to word index
    final words = <String>[];
    for (int i = 0; i < bits.length; i += 11) {
      int index = 0;
      for (int j = 0; j < 11; j++) {
        index = (index << 1) | bits[i + j];
      }
      words.add(_wordList[index]);
    }
    return words.join('-');
  }

  // Décodage depuis une phrase
  static TunnelConfig decode(String phrase) {
    if (!_wordListLoaded) {
      throw StateError('Word list not loaded. Call loadWordList() first.');
    }

    final words = phrase.split('-');
    // Convert words to bits
    final bits = <int>[];
    for (final word in words) {
      final index = _wordList.indexOf(word);
      if (index < 0) throw FormatException('Mot inconnu: $word');
      for (int i = 10; i >= 0; i--) {
        bits.add((index >> i) & 1);
      }
    }
    // Remove padding (we added zeros to make multiple of 11, now remove until multiple of 8)
    while (bits.length % 8 != 0) {
      bits.removeLast();
    }
    // Convert bits to bytes
    final compressed = <int>[];
    for (int i = 0; i < bits.length; i += 8) {
      int byte = 0;
      for (int j = 0; j < 8; j++) {
        byte = (byte << 1) | bits[i + j];
      }
      compressed.add(byte);
    }
    // gzip decompress
    final encrypted = gzip.decode(compressed);
    // XOR decrypt
    final decrypted = List<int>.generate(encrypted.length, (i) {
      return encrypted[i] ^ _secretKey.codeUnitAt(i % _secretKey.length);
    });
    final jsonString = utf8.decode(decrypted);
    final map = jsonDecode(jsonString) as Map<String, dynamic>;
    return TunnelConfig.fromMap(map);
  }

  static TunnelConfig fromMap(Map<String, dynamic> map) {
    final modeStr = map['mode'] as String? ?? 'proxy';
    final mode = switch (modeStr) {
      'vpn' => TunnelMode.vpn,
      'proxy_per_app' => TunnelMode.proxyPerApp,
      _ => TunnelMode.proxy,
    };

    return TunnelConfig(
      serverHost: map['serverHost'] as String,
      serverPort: map['serverPort'] as int?,
      localSocksPort: map['localSocksPort'] as int? ?? 1080,
      key: map['key'] as int?,
      username: map['username'] as String?,
      password: map['password'] as String?,
      hwid: map['hwid'] as String?,
      mode: mode,
      encryptMode: map['encryptMode'] as String?,
      encryptKey: map['encryptKey'] as String?,
      interfaceName: map['interfaceName'] as String?,
      tunDevice: map['tunDevice'] as String?,
      dns: map['dns'] as String?,
      proxyPerAppPackages:
          (map['proxyPerAppPackages'] as List?)?.cast<String>() ?? [],
    );
  }

  // Parse une URI. Supporte uniquement le format princ://p/phrase
  static TunnelConfig parse(String uriText) {
    final uri = Uri.parse(uriText.trim());
    if (uri.scheme != 'princ') {
      throw const FormatException('URI scheme must be princ://');
    }
    if (uri.host != 'p') {
      throw const FormatException('Only princ://p/... is supported');
    }
    final phrase = uri.path.replaceAll('/', '');
    return decode(phrase);
  }
}
