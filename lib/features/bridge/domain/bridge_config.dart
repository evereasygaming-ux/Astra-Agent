import 'dart:math';

import '../../../core/constants/app_info.dart';

enum BridgeMode { embedded, external }

class BridgeConfig {
  const BridgeConfig({
    this.mode = BridgeMode.external,
    this.url = 'http://127.0.0.1:1234',
    this.token = '',
  });

  final BridgeMode mode;
  final String url;
  final String token;

  bool get isExternal => mode == BridgeMode.external;

  bool get isLoopback => const {
    '127.0.0.1',
    'localhost',
    '::1',
  }.contains(baseUri.host.toLowerCase());

  String get trimmedUrl =>
      url.trim().isEmpty ? 'http://127.0.0.1:1234' : url.trim();

  Uri get baseUri => Uri.parse(trimmedUrl);

  int get port => baseUri.hasPort ? baseUri.port : 1234;

  Uri resolve(String path) {
    if (!isExternal) {
      return Uri.parse(
        'http://${AppInfo.bridgeHost}:${AppInfo.bridgePort}$path',
      );
    }
    final root = trimmedUrl.endsWith('/')
        ? trimmedUrl.substring(0, trimmedUrl.length - 1)
        : trimmedUrl;
    return Uri.parse('$root$path');
  }

  BridgeConfig copyWith({BridgeMode? mode, String? url, String? token}) {
    return BridgeConfig(
      mode: mode ?? this.mode,
      url: url ?? this.url,
      token: token ?? this.token,
    );
  }

  factory BridgeConfig.fromMap(Map<String, Object?> map) {
    final mode = map['mode'] == 'external'
        ? BridgeMode.external
        : BridgeMode.embedded;
    return BridgeConfig(
      mode: mode,
      url: (map['url'] as String?)?.trim().isNotEmpty == true
          ? map['url'] as String
          : 'http://127.0.0.1:1234',
      token: map['token'] as String? ?? '',
    );
  }

  Map<String, Object?> toMap() => {
    'mode': isExternal ? 'external' : 'embedded',
    'url': trimmedUrl,
    'token': token,
  };

  static bool isValidToken(String token) =>
      RegExp(r'^[0-9a-z]{12}$').hasMatch(token);

  static String generateToken() {
    const chars = '0123456789abcdefghijklmnopqrstuvwxyz';
    final random = Random.secure();
    return List.generate(12, (_) => chars[random.nextInt(chars.length)]).join();
  }
}
