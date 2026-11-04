class AgyHubStatus {
  const AgyHubStatus({
    this.active = false,
    this.status = 'stopped',
    this.port,
    this.error,
    this.logs = const [],
  });

  final bool active;
  final String status;
  final int? port;
  final String? error;
  final List<String> logs;

  bool get online => active && status == 'online';

  factory AgyHubStatus.fromJson(Map<String, dynamic> json) {
    final logsRaw = json['logs'];
    return AgyHubStatus(
      active: json['active'] == true,
      status: json['status'] as String? ?? 'stopped',
      port: (json['port'] as num?)?.toInt(),
      error: json['error'] as String?,
      logs: logsRaw is List ? logsRaw.map((e) => e.toString()).toList() : const [],
    );
  }
}

class AgyRuntimeStatus {
  const AgyRuntimeStatus({
    this.installed = false,
    this.path,
    this.size = 0,
    this.wrapper = false,
  });

  final bool installed;
  final String? path;
  final int size;
  final bool wrapper;

  factory AgyRuntimeStatus.fromJson(Map<String, Object?> json) {
    return AgyRuntimeStatus(
      installed: json['installed'] == true,
      path: json['path'] as String?,
      size: (json['size'] as num?)?.toInt() ?? 0,
      wrapper: json['wrapper'] == true,
    );
  }
}

class AgyLoginUrl {
  const AgyLoginUrl({this.url, this.active = false});

  final String? url;
  final bool active;

  factory AgyLoginUrl.fromJson(Map<String, dynamic> json) {
    return AgyLoginUrl(
      url: json['loginUrl'] as String?,
      active: json['active'] == true,
    );
  }
}
