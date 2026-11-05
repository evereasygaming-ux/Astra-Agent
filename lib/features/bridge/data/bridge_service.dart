import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/constants/app_info.dart';
import '../domain/bridge_config.dart';
import '../domain/bridge_status.dart';
import 'bridge_channel.dart';
import 'bridge_config_store.dart';

class BridgeException implements Exception {
  BridgeException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BridgeService {
  BridgeService({BridgeChannel? channel, BridgeConfigStore? configStore})
    : _channel = channel ?? BridgeChannel(),
      _configStore = configStore ?? BridgeConfigStore(channel: channel);

  final BridgeChannel _channel;
  final BridgeConfigStore _configStore;

  Future<BridgeConfig> config({bool refresh = false}) =>
      _configStore.load(refresh: refresh);

  Future<Uri> resolve(String path) async {
    final current = await _configStore.load();
    return current.resolve(path);
  }

  Future<BridgeStatus> start() async {
    final current = await _configStore.load(refresh: true);
    if (current.isExternal) {
      final version = await _probe(current);
      if (version == null) {
        throw BridgeException(
          'Debian bridge is not reachable at ${current.trimmedUrl}.\n'
          'Start agy_ide_bridge inside Debian proot, then try again.',
        );
      }
      return BridgeStatus(
        phase: BridgePhase.running,
        port: current.port,
        healthVersion: version,
      );
    }

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

    final version = await _waitForHealth(current);
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

  Future<String> testExternal() async {
    final current = await _configStore.load(refresh: true);
    if (!current.isExternal) {
      return 'embedded';
    }
    final version = await _probe(current);
    if (version == null) {
      throw BridgeException(
        'Bridge is not reachable at ${current.trimmedUrl}.\n'
        'Start agy_ide_bridge inside Debian proot, then try again.',
      );
    }
    final headers = await authHeaders();
    final http.Response response;
    try {
      response = await http
          .get(current.resolve('/api/status'), headers: headers)
          .timeout(const Duration(seconds: 4));
    } catch (error) {
      throw BridgeException('Cannot reach the bridge: $error');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw BridgeException(
        'Bridge rejected the token. Use the same --token value in Termux '
        'and in AstraAgent Settings.',
      );
    }
    if (response.statusCode != 200) {
      throw BridgeException('Bridge returned HTTP ${response.statusCode}');
    }
    return version;
  }

  Future<BridgeStatus> stop() async {
    final current = await _configStore.load();
    if (current.isExternal) {
      return BridgeStatus(phase: BridgePhase.stopped, port: current.port);
    }
    final raw = await _channel.stop();
    return _fromNative(raw)
        .copyWith(phase: BridgePhase.stopped, clearError: true);
  }

  Future<BridgeStatus> status() async {
    final current = await _configStore.load();
    if (current.isExternal) {
      final version = await _probe(current);
      return BridgeStatus(
        phase: version == null ? BridgePhase.stopped : BridgePhase.running,
        port: current.port,
        healthVersion: version,
      );
    }
    final raw = await _channel.status();
    return _fromNative(raw);
  }

  Future<String> logs() async {
    final current = await _configStore.load();
    if (current.isExternal) {
      return 'External bridge: logs are shown in the Termux session running '
          'agy_ide_bridge.';
    }
    return _channel.logs();
  }

  Future<void> clearLogs() async {
    final current = await _configStore.load();
    if (current.isExternal) {
      return;
    }
    await _channel.clearLogs();
  }

  Future<String> token() async {
    final current = await _configStore.load();
    if (current.isExternal) {
      return current.token;
    }
    return _channel.token();
  }

  Future<Map<String, String>> authHeaders() async {
    final token = await this.token();
    return {'x-ag${token}_9qx': 'true'};
  }

  Future<String?> _probe(BridgeConfig config) async {
    try {
      final response = await http
          .get(config.resolve('/api/health'))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic>) {
          return body['version'] as String? ?? 'ok';
        }
        return 'ok';
      }
    } catch (_) {
      // External bridge is not running.
    }
    return null;
  }

  Future<String?> _waitForHealth(BridgeConfig config) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      final version = await _probe(config);
      if (version != null) {
        return version;
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
      pid: _parseInt(raw['pid']) ?? 0,
      port: _parseInt(raw['port']) ?? AppInfo.bridgePort,
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

int? _parseInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
