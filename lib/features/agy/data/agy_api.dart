import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/constants/app_info.dart';
import '../../bridge/data/bridge_channel.dart';
import '../../bridge/data/bridge_service.dart';
import '../domain/agy_models.dart';

class AgyApiException implements Exception {
  AgyApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AgyApi {
  AgyApi({BridgeService? bridge}) : _bridge = bridge ?? BridgeService();

  final BridgeService _bridge;
  final BridgeChannel _channel = BridgeChannel();

  Uri _uri(String path) => Uri.parse(
    'http://${AppInfo.bridgeHost}:${AppInfo.bridgePort}$path',
  );

  Future<AgyRuntimeStatus> runtime() async {
    final raw = await _channel.agyStatus();
    return AgyRuntimeStatus.fromJson(raw);
  }

  Future<AgyRuntimeStatus> install() async {
    final raw = await _channel.agyInstall();
    return AgyRuntimeStatus.fromJson(raw);
  }

  Future<AgyHubStatus> hubStatus() async {
    final json = await _request('GET', '/api/status');
    final hub = json['hub'];
    return hub is Map<String, dynamic>
        ? AgyHubStatus.fromJson(hub)
        : const AgyHubStatus();
  }

  Future<void> startLogin() async {
    final json = await _request(
      'POST',
      '/api/auth/start-login',
      body: const {},
      timeout: const Duration(seconds: 30),
    );
    if (json['success'] != true) {
      throw AgyApiException(json['message'] as String? ?? 'Login failed');
    }
  }

  Future<AgyLoginUrl> loginUrl() async {
    final json = await _request('GET', '/api/auth/login-url');
    return AgyLoginUrl.fromJson(json);
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final headers = await _bridge.authHeaders();
    headers['Content-Type'] = 'application/json';
    final uri = _uri(path);
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) {
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      final streamed = await request.send().timeout(timeout);
      response = await http.Response.fromStream(streamed);
    } catch (error) {
      throw AgyApiException('Cannot reach the local bridge: $error');
    }

    final text = response.body.trim();
    final isJson = text.startsWith('{');
    if (!isJson) {
      throw AgyApiException(
        'HTTP ${response.statusCode}${text.isEmpty ? '' : ': $text'}',
      );
    }

    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw AgyApiException('Unexpected bridge response');
    }
    return decoded;
  }
}
