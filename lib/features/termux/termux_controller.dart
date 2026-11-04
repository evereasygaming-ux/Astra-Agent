import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../bridge/data/bridge_channel.dart';
import '../bridge/domain/bridge_config.dart';
import '../bridge/presentation/bridge_controller.dart';
import 'termux_setup_script.dart';

class TermuxState {
  const TermuxState({
    this.installed = false,
    this.permission = false,
    this.busy = false,
    this.ready = false,
    this.message,
    this.error,
  });

  final bool installed;
  final bool permission;
  final bool busy;
  final bool ready;
  final String? message;
  final String? error;

  TermuxState copyWith({
    bool? installed,
    bool? permission,
    bool? busy,
    bool? ready,
    String? message,
    String? error,
    bool clearMessage = false,
    bool clearError = false,
  }) {
    return TermuxState(
      installed: installed ?? this.installed,
      permission: permission ?? this.permission,
      busy: busy ?? this.busy,
      ready: ready ?? this.ready,
      message: clearMessage ? null : message ?? this.message,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class TermuxController extends Notifier<TermuxState> {
  final BridgeChannel _channel = BridgeChannel();

  @override
  TermuxState build() {
    Future.microtask(refresh);
    return const TermuxState();
  }

  Future<void> refresh() async {
    try {
      final raw = await _channel.termuxStatus();
      state = state.copyWith(
        installed: raw['installed'] == true,
        permission: raw['permission'] == true,
      );
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }

  Future<void> requestPermission() async {
    try {
      await _channel.termuxRequestPermission();
    } catch (error) {
      state = state.copyWith(error: error.toString());
      return;
    }
    for (var attempt = 0; attempt < 40; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      if (state.permission) {
        state = state.copyWith(clearError: true);
        return;
      }
    }
  }

  Future<void> setupAndLaunch() async {
    if (state.busy) {
      return;
    }
    state = state.copyWith(
      busy: true,
      ready: false,
      message: 'Preparing Termux...',
      clearError: true,
    );
    try {
      await refresh();
      if (!state.installed) {
        throw 'Termux is not installed. Install Termux from F-Droid first.';
      }
      await _ensurePermission();
      if (!state.permission) {
        throw 'Termux run-command permission was not granted. '
            'Allow it, then tap setup again.';
      }

      final store = ref.read(bridgeConfigStoreProvider);
      var config = await store.load(refresh: true);
      final token = BridgeConfig.isValidToken(config.token)
          ? config.token
          : BridgeConfig.generateToken();
      config = await store.save(
        BridgeConfig(
          mode: BridgeMode.external,
          url: config.isExternal ? config.trimmedUrl : 'http://127.0.0.1:1234',
          token: token,
        ),
      );
      ref.invalidate(bridgeConfigProvider);
      await ref.read(bridgeControllerProvider.notifier).refresh();

      final assetPort = await _channel.termuxAssetPort();
      if (assetPort <= 0) {
        throw 'Could not start the local bridge download server.';
      }
      final script = buildSetupScript(
        token: token,
        bridgePort: config.port,
        hubPort: config.port + 1,
        assetPort: assetPort,
      );
      await _channel.termuxRun(script: script, background: false);
      state = state.copyWith(
        message: 'Setup is running in Termux. Waiting for the bridge...',
      );
      await _waitForBridge();
    } on PlatformException catch (error) {
      state = state.copyWith(
        error:
            '${error.message ?? 'Termux command failed'}\n'
            'Enable "Allow external apps" in Termux settings, then retry.',
      );
    } catch (error) {
      state = state.copyWith(error: error.toString());
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> launch() async {
    if (state.busy) {
      return;
    }
    state = state.copyWith(
      busy: true,
      ready: false,
      message: 'Starting bridge in Debian proot...',
      clearError: true,
    );
    try {
      await refresh();
      if (!state.installed) {
        throw 'Termux is not installed. Install Termux from F-Droid first.';
      }
      await _ensurePermission();
      if (!state.permission) {
        throw 'Termux run-command permission was not granted.';
      }
      await _channel.termuxRun(script: buildLaunchScript(), background: true);
      await _waitForBridge(attempts: 20);
    } on PlatformException catch (error) {
      state = state.copyWith(
        error:
            '${error.message ?? 'Termux command failed'}\n'
            'Enable "Allow external apps" in Termux settings, then retry.',
      );
    } catch (error) {
      state = state.copyWith(error: error.toString());
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<bool> applyBridgeConfig(BridgeConfig config) async {
    if (state.busy) {
      return false;
    }
    if (!BridgeConfig.isValidToken(config.token)) {
      state = state.copyWith(
        error: 'Bridge token must contain 12 lowercase letters or digits.',
      );
      return false;
    }
    state = state.copyWith(
      busy: true,
      ready: false,
      message: 'Updating Debian bridge configuration...',
      clearError: true,
    );
    try {
      await refresh();
      if (!state.installed) {
        throw 'Termux is not installed.';
      }
      await _ensurePermission();
      if (!state.permission) {
        throw 'Termux run-command permission was not granted.';
      }
      await _channel.termuxRun(
        script: buildBridgeConfigUpdateScript(
          token: config.token,
          bridgePort: config.port,
          hubPort: config.port + 1,
        ),
        background: true,
      );
      await _waitForBridge(attempts: 20);
      if (!state.ready) {
        return false;
      }
      await ref.read(bridgeServiceProvider).testExternal();
      return state.ready;
    } on PlatformException catch (error) {
      state = state.copyWith(
        error: error.message ?? 'Could not update the Debian bridge.',
      );
      return false;
    } catch (error) {
      state = state.copyWith(
        error:
            '$error\nRun Set up & launch to refresh the Debian proot setup if needed.',
      );
      return false;
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> openTermux() async {
    try {
      await _channel.termuxOpen();
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }

  Future<void> openTermuxSettings() async {
    try {
      await _channel.termuxOpenSettings();
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }

  Future<void> _ensurePermission() async {
    if (state.permission) {
      return;
    }
    await requestPermission();
  }

  Future<void> _waitForBridge({int attempts = 100}) async {
    final service = ref.read(bridgeServiceProvider);
    for (var attempt = 0; attempt < attempts; attempt++) {
      final status = await service.status();
      if (status.isRunning) {
        await ref.read(bridgeControllerProvider.notifier).refresh();
        state = state.copyWith(
          ready: true,
          message: 'Bridge is online at ${status.port}.',
          clearError: true,
        );
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    state = state.copyWith(
      error:
          'Bridge did not come online. Open Debian proot and check '
          '/root/.astra/setup.log, then allow external apps in Termux settings.',
    );
  }
}

final termuxControllerProvider =
    NotifierProvider<TermuxController, TermuxState>(TermuxController.new);
