import 'package:flutter/services.dart';

class BridgeChannel {
  static const MethodChannel _channel = MethodChannel('com.astra.agent/bridge');

  Future<Map<String, Object?>> start({
    required String token,
    required int port,
    required int hubPort,
    String? workspace,
  }) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('start', {
      'token': token,
      'port': port,
      'hubPort': hubPort,
      'workspace': workspace,
    });
    return result?.cast<String, Object?>() ?? const {};
  }

  Future<Map<String, Object?>> stop() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('stop');
    return result?.cast<String, Object?>() ?? const {};
  }

  Future<Map<String, Object?>> status() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('status');
    return result?.cast<String, Object?>() ?? const {};
  }

  Future<String> token() async {
    return await _channel.invokeMethod<String>('token') ?? '';
  }

  Future<String> logs() async {
    return await _channel.invokeMethod<String>('logs') ?? '';
  }

  Future<void> clearLogs() async {
    await _channel.invokeMethod<void>('clearLogs');
  }

  Future<void> openUrl(String url) async {
    await _channel.invokeMethod<void>('openUrl', {'url': url});
  }

  Future<Map<String, Object?>> config() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getBridgeConfig',
    );
    return result?.cast<String, Object?>() ?? const {};
  }

  Future<Map<String, Object?>> saveConfig({
    required String mode,
    required String url,
    required String token,
  }) async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'setBridgeConfig',
      {'mode': mode, 'url': url, 'token': token},
    );
    return result?.cast<String, Object?>() ?? const {};
  }

  Future<Map<String, Object?>> termuxStatus() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'termuxStatus',
    );
    return result?.cast<String, Object?>() ?? const {};
  }

  Future<void> termuxRequestPermission() async {
    await _channel.invokeMethod<void>('termuxRequestPermission');
  }

  Future<void> termuxRun({
    required String script,
    bool background = false,
  }) async {
    await _channel.invokeMethod<void>('termuxRun', {
      'script': script,
      'background': background,
    });
  }

  Future<void> termuxOpen() async {
    await _channel.invokeMethod<void>('termuxOpen');
  }

  Future<void> termuxOpenSettings() async {
    await _channel.invokeMethod<void>('termuxOpenSettings');
  }

  Future<int> termuxAssetPort() async {
    final result = await _channel.invokeMethod<int>('termuxAssetPort');
    return result ?? 0;
  }

  Future<Map<String, Object?>> agyStatus() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('agyStatus');
    return result?.cast<String, Object?>() ?? const {};
  }

  Future<Map<String, Object?>> agyInstall() async {
    final result = await _channel.invokeMethod<Map<Object?, Object?>>('agyInstall');
    return result?.cast<String, Object?>() ?? const {};
  }
}
