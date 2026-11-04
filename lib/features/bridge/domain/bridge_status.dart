import '../../../core/constants/app_info.dart';

enum BridgePhase { stopped, starting, running, error }

class BridgeStatus {
  const BridgeStatus({
    this.phase = BridgePhase.stopped,
    this.pid = 0,
    this.port = AppInfo.bridgePort,
    this.error,
    this.healthVersion,
    this.log = '',
  });

  final BridgePhase phase;
  final int pid;
  final int port;
  final String? error;
  final String? healthVersion;
  final String log;

  bool get isRunning => phase == BridgePhase.running;

  bool get isBusy => phase == BridgePhase.starting;

  String get label => switch (phase) {
    BridgePhase.stopped => 'Offline',
    BridgePhase.starting => 'Starting…',
    BridgePhase.running => 'Running',
    BridgePhase.error => 'Error',
  };

  BridgeStatus copyWith({
    BridgePhase? phase,
    int? pid,
    int? port,
    String? error,
    String? healthVersion,
    String? log,
    bool clearError = false,
  }) {
    return BridgeStatus(
      phase: phase ?? this.phase,
      pid: pid ?? this.pid,
      port: port ?? this.port,
      error: clearError ? null : error ?? this.error,
      healthVersion: healthVersion ?? this.healthVersion,
      log: log ?? this.log,
    );
  }
}
