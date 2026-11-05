import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../bridge/data/bridge_channel.dart';
import '../../bridge/presentation/bridge_controller.dart';
import '../data/agy_api.dart';
import '../domain/agy_models.dart';

class AgyState {
  const AgyState({
    this.runtime,
    this.hub,
    this.loginUrl,
    this.loading = false,
    this.installing = false,
    this.error,
  });

  final AgyRuntimeStatus? runtime;
  final AgyHubStatus? hub;
  final AgyLoginUrl? loginUrl;
  final bool loading;
  final bool installing;
  final String? error;

  bool get installed => runtime?.installed == true;
  bool get hubOnline => hub?.online == true;
  bool get busy => loading || installing;

  AgyState copyWith({
    AgyRuntimeStatus? runtime,
    AgyHubStatus? hub,
    AgyLoginUrl? loginUrl,
    bool? loading,
    bool? installing,
    String? error,
    bool clearError = false,
  }) {
    return AgyState(
      runtime: runtime ?? this.runtime,
      hub: hub ?? this.hub,
      loginUrl: loginUrl ?? this.loginUrl,
      loading: loading ?? this.loading,
      installing: installing ?? this.installing,
      error: clearError ? null : error ?? this.error,
    );
  }
}

final agyApiProvider = Provider<AgyApi>(
  (ref) => AgyApi(bridge: ref.watch(bridgeServiceProvider)),
);

class AgyController extends Notifier<AgyState> {
  late final AgyApi _api = ref.read(agyApiProvider);
  final BridgeChannel _channel = BridgeChannel();

  @override
  AgyState build() {
    ref.onDispose(() {});
    Future.microtask(() => refresh());
    return const AgyState();
  }

  Future<void> refresh() async {
    if (state.loading) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final runtime = await _api.runtime();
      AgyHubStatus? hub;
      try {
        hub = await _api.hubStatus();
      } catch (_) {
        hub = null;
      }
      AgyLoginUrl? url;
      try {
        url = await _api.loginUrl();
      } catch (_) {
        url = null;
      }
      state = state.copyWith(
        runtime: runtime,
        hub: hub,
        loginUrl: url,
        loading: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(loading: false, error: error.toString());
    }
  }

  Future<void> install() async {
    if (state.installing) return;
    state = state.copyWith(installing: true, clearError: true);
    try {
      final runtime = await _api.install();
      state = state.copyWith(runtime: runtime, installing: false, clearError: true);
      await refresh();
    } catch (error) {
      state = state.copyWith(installing: false, error: error.toString());
    }
  }

  Future<void> startLogin() async {
    if (state.busy) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      await _api.startLogin();
      for (var attempt = 0; attempt < 15; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final url = await _api.loginUrl();
        state = state.copyWith(loginUrl: url);
        final target = url.url;
        if (target != null && target.isNotEmpty) {
          state = state.copyWith(loading: false, clearError: true);
          await _channel.openUrl(target);
          return;
        }
      }
      state = state.copyWith(
        loading: false,
        error: 'AGY Hub did not provide a sign-in URL. Check bridge logs and retry.',
      );
    } catch (error) {
      state = state.copyWith(loading: false, error: error.toString());
    }
  }

  Future<void> openLoginUrl() async {
    final url = state.loginUrl?.url;
    if (url == null || url.isEmpty) {
      await refresh();
      return;
    }
    try {
      await _channel.openUrl(url);
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }
}

final agyControllerProvider =
    NotifierProvider<AgyController, AgyState>(AgyController.new);
