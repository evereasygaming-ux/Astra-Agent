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
}
