import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/bridge_service.dart';
import '../domain/bridge_status.dart';

final bridgeServiceProvider = Provider<BridgeService>((ref) => BridgeService());

class BridgeController extends Notifier<BridgeStatus> {
  late final BridgeService _service = ref.read(bridgeServiceProvider);

  @override
  BridgeStatus build() => const BridgeStatus();

  Future<void> start() async {
    if (state.isBusy || state.isRunning) {
      return;
    }
    state = state.copyWith(phase: BridgePhase.starting, clearError: true);
    try {
      state = await _service.start();
    } catch (error) {
      state = state.copyWith(phase: BridgePhase.error, error: error.toString());
    }
  }

  Future<void> stop() async {
    if (!state.isRunning && !state.isBusy) {
      return;
    }
    try {
      state = await _service.stop();
    } catch (error) {
      state = state.copyWith(phase: BridgePhase.error, error: error.toString());
    }
  }

  Future<void> toggle() async {
    if (state.isRunning) {
      await stop();
    } else {
      await start();
    }
  }

  Future<void> refresh() async {
    try {
      final status = await _service.status();
      state = status.copyWith(log: await _service.logs());
    } catch (error) {
      state = state.copyWith(phase: BridgePhase.error, error: error.toString());
    }
  }

  Future<void> clearLogs() async {
    try {
      await _service.clearLogs();
      state = state.copyWith(log: '');
    } catch (error) {
      state = state.copyWith(phase: BridgePhase.error, error: error.toString());
    }
  }
}

final bridgeControllerProvider =
    NotifierProvider<BridgeController, BridgeStatus>(BridgeController.new);
