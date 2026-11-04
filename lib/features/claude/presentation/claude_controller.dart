import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../bridge/data/bridge_channel.dart';
import '../data/claude_api.dart';
import '../domain/claude_models.dart';

class ClaudeState {
  const ClaudeState({
    this.status,
    this.loading = false,
    this.busy = false,
    this.error,
    this.job,
    this.login,
  });

  final ClaudeCliStatus? status;
  final bool loading;
  final bool busy;
  final String? error;
  final ClaudeJob? job;
  final ClaudeLogin? login;

  bool get installed => status?.installed == true;

  bool get loggedIn => status?.loggedIn == true;

  bool get jobRunning => job?.running == true;

  ClaudeState copyWith({
    ClaudeCliStatus? status,
    bool? loading,
    bool? busy,
    String? error,
    ClaudeJob? job,
    ClaudeLogin? login,
    bool clearError = false,
    bool clearJob = false,
    bool clearLogin = false,
  }) {
    return ClaudeState(
      status: status ?? this.status,
      loading: loading ?? this.loading,
      busy: busy ?? this.busy,
      error: clearError ? null : error ?? this.error,
      job: clearJob ? null : job ?? this.job,
      login: clearLogin ? null : login ?? this.login,
    );
  }
}

final claudeApiProvider = Provider<ClaudeApi>((ref) => ClaudeApi());

class ClaudeController extends Notifier<ClaudeState> {
  late final ClaudeApi _api = ref.read(claudeApiProvider);
  final BridgeChannel _channel = BridgeChannel();

  Timer? _jobTimer;
  Timer? _loginTimer;
  bool _disposed = false;
  bool _jobPolling = false;
  bool _loginPolling = false;

  @override
  ClaudeState build() {
    ref.onDispose(() {
      _disposed = true;
      _jobTimer?.cancel();
      _loginTimer?.cancel();
    });
    return const ClaudeState();
  }

  Future<void> refresh() async {
    if (state.loading) {
      return;
    }
    state = state.copyWith(loading: true, clearError: true);
    try {
      final status = await _api.status();
      state = state.copyWith(status: status, loading: false, clearError: true);
    } catch (error) {
      state = state.copyWith(loading: false, error: error.toString());
    }
  }

  Future<void> install() => _startJob('install');

  Future<void> update() => _startJob('update');

  Future<void> _startJob(String action) async {
    if (state.busy || state.jobRunning) {
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final job = await _api.installOrUpdate(action);
      state = state.copyWith(busy: false, job: job);
      _watchJob();
    } catch (error) {
      state = state.copyWith(busy: false, error: error.toString());
    }
  }

  void _watchJob() {
    _jobTimer?.cancel();
    _jobTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (_disposed || _jobPolling) {
        return;
      }
      _jobPolling = true;
      try {
        final job = await _api.job();
        if (job == null || _disposed) {
          _jobTimer?.cancel();
          return;
        }
        state = state.copyWith(job: job);
        if (!job.running) {
          _jobTimer?.cancel();
          await refresh();
        }
      } catch (error) {
        _jobTimer?.cancel();
        if (!_disposed) {
          state = state.copyWith(error: error.toString());
        }
      } finally {
        _jobPolling = false;
      }
    });
  }

  Future<void> startLogin(String method) async {
    if (state.busy) {
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final login = await _api.startLogin(method);
      if (_disposed) {
        return;
      }
      state = state.copyWith(login: login, busy: false);
      final url = login.automaticUrl;
      if (url != null && url.isNotEmpty) {
        await _channel.openUrl(url);
      }
      _watchLogin();
    } catch (error) {
      state = state.copyWith(busy: false, error: error.toString());
    }
  }

  void _watchLogin() {
    _loginTimer?.cancel();
    _loginTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      final login = state.login;
      if (_disposed || _loginPolling || login == null) {
        return;
      }
      _loginPolling = true;
      try {
        final next = await _api.loginState(login.loginId);
        if (_disposed) {
          return;
        }
        state = state.copyWith(login: next);
        if (next.state == 'success') {
          _loginTimer?.cancel();
          state = state.copyWith(clearLogin: true, busy: false);
          await refresh();
        } else if (next.state == 'error' || next.state == 'cancelled') {
          _loginTimer?.cancel();
          state = state.copyWith(
            clearLogin: true,
            busy: false,
            error: next.error ?? 'Claude sign-in ${next.state}',
          );
        }
      } catch (error) {
        _loginTimer?.cancel();
        if (!_disposed) {
          state = state.copyWith(error: error.toString());
        }
      } finally {
        _loginPolling = false;
      }
    });
  }

  Future<void> submitCode(String code) async {
    final login = state.login;
    if (login == null || code.trim().isEmpty) {
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final next = await _api.submitCode(login.loginId, code.trim());
      state = state.copyWith(login: next, busy: false);
    } catch (error) {
      state = state.copyWith(busy: false, error: error.toString());
    }
  }

  Future<void> cancelLogin() async {
    final login = state.login;
    _loginTimer?.cancel();
    state = state.copyWith(clearLogin: true, busy: false);
    if (login != null) {
      try {
        await _api.cancelLogin(login.loginId);
      } catch (_) {
        // The login is already gone locally.
      }
    }
  }

  Future<void> logout() async {
    if (state.busy) {
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      await _api.logout();
      state = state.copyWith(busy: false, clearError: true);
      await refresh();
    } catch (error) {
      state = state.copyWith(busy: false, error: error.toString());
    }
  }

  Future<void> openUrl(String url) async {
    try {
      await _channel.openUrl(url);
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }
}

final claudeControllerProvider =
    NotifierProvider<ClaudeController, ClaudeState>(ClaudeController.new);
