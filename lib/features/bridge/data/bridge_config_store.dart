import '../domain/bridge_config.dart';
import 'bridge_channel.dart';

class BridgeConfigStore {
  BridgeConfigStore({BridgeChannel? channel})
    : _channel = channel ?? BridgeChannel();

  final BridgeChannel _channel;
  BridgeConfig? _cached;

  Future<BridgeConfig> load({bool refresh = false}) async {
    if (_cached != null && !refresh) {
      return _cached!;
    }
    final config = BridgeConfig.fromMap(await _channel.config());
    _cached = config;
    return config;
  }

  Future<BridgeConfig> save(BridgeConfig config) async {
    final raw = await _channel.saveConfig(
      mode: config.isExternal ? 'external' : 'embedded',
      url: config.trimmedUrl,
      token: config.token,
    );
    final saved = BridgeConfig.fromMap(raw);
    _cached = saved;
    return saved;
  }
}
