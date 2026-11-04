import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/constants/app_info.dart';
import '../domain/bridge_status.dart';
import 'bridge_channel.dart';

class BridgeException implements Exception {
  BridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BridgeService {
  BridgeService({BridgeChannel? channel})
    : _channel = channel ?? BridgeChannel();

  final BridgeChannel _channel;

  Uri get _healthUri => Uri.parse(
    'http://${AppInfo.bridgeHost}:${AppInfo.bridgePort}/api/health',
  );

  Future<BridgeStatus> start() async {
    final token = await _channel.token();
    final raw = await _channel.start(
      token: token,
      port: AppInfo.bridgePort,
      hubPort: AppInfo.hubPort,
    );
    var status = _fromNative(raw);
    if (!status.isRunning) {
      throw BridgeException(status.error ?? 'Bridge failed to start');
    }

    final version = await _waitForHealth();
    if (version == null) {
      final logs = await _channel.logs();
      final latest = _fromNative(await _channel.status());
      if (!latest.isRunning) {
        throw BridgeException(
          latest.error ?? 'Bridge stopped during startup\n${_tail(logs)}',
        );
      }
      throw BridgeException('Bridge did not become healthy\n${_tail(logs)}');
    }

    status = status.copyWith(
      phase: BridgePhase.running,
      healthVersion: version,
      log: await _channel.logs(),
    );
    return status;
  }

  Future<BridgeStatus> stop() async {
    final raw = await _channel.stop();
    return _fromNative(raw)
        .copyWith(phase: BridgePhase.stopped, clearError: true);
  }

  Future<BridgeStatus> status() async {
    final raw = await _channel.status();
    return _fromNative(raw);
  }

  Future<String> logs() => _channel.logs();

  Future<void> clearLogs() => _channel.clearLogs();

  Future<String> token() => _channel.token();

  Future<Map<String, String>> authHeaders() async {
    final token = await _channel.token();
    return {'x-ag${token}_9qx': 'true'};
  }

  Future<String?> _waitForHealth() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        final response = await http
            .get(_healthUri)
            .timeout(const Duration(seconds: 1));
        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          if (body is Map<String, dynamic>) {
            return body['version'] as String? ?? 'ok';
          }
          return 'ok';
        }
      } catch (_) {
        // Bridge is still booting.
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  BridgeStatus _fromNative(Map<String, Object?> raw) {
    final running = raw['running'] == true;
    final error = raw['error'] as String?;
    final phase = running
        ? BridgePhase.running
        : error == null
        ? BridgePhase.stopped
        : BridgePhase.error;
    return BridgeStatus(
      phase: phase,
      pid: (raw['pid'] as num?)?.toInt() ?? 0,
      port: (raw['port'] as num?)?.toInt() ?? AppInfo.bridgePort,
      error: error,
      log: raw['log'] as String? ?? '',
    );
  }

  String _tail(String text) {
    const max = 1200;
    if (text.length <= max) {
      return text;
    }
    return text.substring(text.length - max);
  }
}
