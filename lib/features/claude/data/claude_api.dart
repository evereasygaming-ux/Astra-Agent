import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/constants/app_info.dart';
import '../../bridge/data/bridge_service.dart';
import '../domain/claude_models.dart';

class ClaudeApiException implements Exception {
  ClaudeApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ClaudeApi {
  ClaudeApi({BridgeService? bridge}) : _bridge = bridge ?? BridgeService();

  final BridgeService _bridge;

  Uri _uri(String path) => Uri.parse(
    'http://${AppInfo.bridgeHost}:${AppInfo.bridgePort}/api/claude$path',
  );

  Future<ClaudeCliStatus> status() async {
    final json = await _request(
      'GET',
      '/status',
      timeout: const Duration(seconds: 70),
    );
    return ClaudeCliStatus.fromJson(json);
  }

  Future<ClaudeJob?> job() async {
    final json = await _request('GET', '/cli/job');
    final job = json['job'];
    return job is Map<String, dynamic> ? ClaudeJob.fromJson(job) : null;
  }

  Future<ClaudeJob?> installOrUpdate(String action) async {
    final json = await _request(
      'POST',
      '/cli/$action',
      body: const {},
      timeout: const Duration(seconds: 30),
    );
    if (json['success'] != true) {
      throw ClaudeApiException(json['error'] as String? ?? 'Install failed');
    }
    final job = json['job'];
    return job is Map<String, dynamic> ? ClaudeJob.fromJson(job) : null;
  }

  Future<ClaudeLogin> startLogin(String method) async {
    final json = await _request(
      'POST',
      '/auth/login',
      body: {'method': method},
      timeout: const Duration(seconds: 120),
    );
    return _loginFrom(json);
  }

  Future<ClaudeLogin> loginState(String loginId) async {
    final json = await _request('GET', '/auth/login/$loginId');
    return _loginFrom(json);
  }

  Future<ClaudeLogin> submitCode(String loginId, String code) async {
    final json = await _request(
      'POST',
      '/auth/login/$loginId/code',
      body: {'code': code},
      timeout: const Duration(seconds: 90),
    );
    return _loginFrom(json);
  }

  Future<void> cancelLogin(String loginId) async {
    await _request('DELETE', '/auth/login/$loginId');
  }

  Future<void> logout() async {
    final json = await _request(
      'POST',
      '/auth/logout',
      body: const {},
      timeout: const Duration(seconds: 40),
    );
    if (json['success'] != true) {
      throw ClaudeApiException(json['error'] as String? ?? 'Sign-out failed');
    }
  }

  ClaudeLogin _loginFrom(Map<String, dynamic> json) {
    final login = json['login'];
    if (json['success'] != true || login is! Map<String, dynamic>) {
      throw ClaudeApiException(
        json['error'] as String? ?? 'Claude sign-in failed',
      );
    }
    return ClaudeLogin.fromJson(login);
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
      throw ClaudeApiException('Cannot reach the local bridge: $error');
    }

    final text = response.body.trim();
    final isJson = text.startsWith('{');
    if (response.statusCode == 503) {
      throw ClaudeApiException(
        'The bridge is running with Claude disabled. Restart it from Home.',
      );
    }
    if (response.statusCode == 404 && !isJson) {
      throw ClaudeApiException('This bridge build does not support Claude.');
    }
    if (!isJson) {
      throw ClaudeApiException(
        'HTTP ${response.statusCode}${text.isEmpty ? '' : ': $text'}',
      );
    }

    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw ClaudeApiException('Unexpected bridge response');
    }
    return decoded;
  }
}
