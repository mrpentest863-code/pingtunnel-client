import 'dart:convert';

enum TunnelMode { proxy, vpn, proxyPerApp }

// Clé secrète pour le chiffrement
const String _secretKey = "PingTunnelSecretKey2024!";

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
    if (serverPort == null) {
      return serverHost;
    }
    return "$serverHost:$serverPort";
  }

  int localProxyBackendSocksPort() {
    if (localSocksPort < 1 || localSocksPort > 65535) {
      return 1081;
    }
    if (localSocksPort == 65535) {
      return 65534;
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

  // Encoder avec clé secrète
  String encode() {
    final jsonString = jsonEncode(toMap());
    final bytes = utf8.encode(jsonString);
    final encrypted = List<int>.generate(bytes.length, (i) {
      return bytes[i] ^ _secretKey.codeUnitAt(i % _secretKey.length);
    });
    return base64Url.encode(encrypted);
  }

  // Décoder avec clé secrète
  static TunnelConfig decode(String encoded) {
    final encrypted = base64Url.decode(encoded);
    final decrypted = List<int>.generate(encrypted.length, (i) {
      return encrypted[i] ^ _secretKey.codeUnitAt(i % _secretKey.length);
    });
    final jsonString = utf8.decode(decrypted);
    final map = jsonDecode(jsonString) as Map<String, dynamic>;
    return TunnelConfig.fromMap(map);
  }

  // Créer depuis un map
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
      proxyPerAppPackages: (map['proxyPerAppPackages'] as List?)?.cast<String>() ?? [],
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
    final keyText = params['key'] ?? '';
    final key = keyText.isEmpty ? null : int.tryParse(keyText);
    final username = params['user'] ?? params['username'];
    final password = params['pass'] ?? params['password'];
    final hwid = params['hwid'];

    final localPort =
        int.tryParse(params['lport'] ?? params['local_port'] ?? '') ?? 1080;
    final serverPort = int.tryParse(
      params['port'] ?? params['server_port'] ?? '',
    );

    final modeValue = (params['mode'] ?? params['vpn'] ?? 'proxy')
        .toLowerCase();
    final mode = switch (modeValue) {
      'vpn' || '1' => TunnelMode.vpn,
      'proxy_per_app' ||
      'proxy-per-app' ||
      'per_app' ||
      'app' ||
      'app_proxy' => TunnelMode.proxyPerApp,
      _ => TunnelMode.proxy,
    };
    final proxyPerAppPackages =
        (params['apps'] ?? '')
            .split(',')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    final encryptValue =
        (params['encrypt'] ??
                params['encrypt_mode'] ??
                params['encryptMode'] ??
                params['enc'] ??
                '')
            .toLowerCase();
    final validEncryptModes = {'aes128', 'aes256', 'chacha20'};
    final encryptMode =
        encryptValue.isEmpty ||
            encryptValue == '0' ||
            encryptValue == 'none' ||
            !validEncryptModes.contains(encryptValue)
        ? null
        : encryptValue;
    final encryptKey =
        params['encrypt-key'] ?? params['encrypt_key'] ?? params['encryptKey'];

    if (encryptMode == null && key == null && 
        (username == null || username.isEmpty || password == null || password.isEmpty)) {
      throw const FormatException('Missing key or username/password');
    }
    if (encryptMode != null && (encryptKey == null || encryptKey.isEmpty)) {
      throw const FormatException('Missing encrypt_key');
    }
    if (keyText.isNotEmpty && key == null) {
      throw const FormatException('Key must be an integer');
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
