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
      port: _parseInt(json['port']),
      error: json['error'] as String?,
      logs: logsRaw is List
          ? logsRaw.map((e) => e.toString()).toList()
          : const [],
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
      size: _parseInt(json['size']) ?? 0,
      wrapper: json['wrapper'] == true,
    );
  }
}

int? _parseInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
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

class AgyQuotaSummary {
  const AgyQuotaSummary({this.description = '', this.groups = const []});

  final String description;
  final List<AgyQuotaGroup> groups;

  factory AgyQuotaSummary.fromJson(Map<String, dynamic> json) {
    final rawGroups = json['groups'];
    final rawBuckets = json['buckets'];
    final groups = rawGroups is List
        ? rawGroups
              .whereType<Map>()
              .map(
                (item) => AgyQuotaGroup.fromJson(item.cast<String, dynamic>()),
              )
              .where((group) => group.buckets.isNotEmpty)
              .toList()
        : <AgyQuotaGroup>[];
    if (groups.isEmpty && rawBuckets is List) {
      final buckets = rawBuckets
          .whereType<Map>()
          .map((item) => AgyQuotaBucket.fromJson(item.cast<String, dynamic>()))
          .toList();
      if (buckets.isNotEmpty) {
        groups.add(AgyQuotaGroup(name: 'Antigravity usage', buckets: buckets));
      }
    }
    return AgyQuotaSummary(
      description: json['description']?.toString() ?? '',
      groups: groups,
    );
  }
}

class AgyQuotaGroup {
  const AgyQuotaGroup({
    required this.name,
    this.description = '',
    this.buckets = const [],
  });

  final String name;
  final String description;
  final List<AgyQuotaBucket> buckets;

  factory AgyQuotaGroup.fromJson(Map<String, dynamic> json) {
    final rawBuckets = json['buckets'];
    return AgyQuotaGroup(
      name: json['displayName']?.toString() ?? 'Usage',
      description: json['description']?.toString() ?? '',
      buckets: rawBuckets is List
          ? rawBuckets
                .whereType<Map>()
                .map(
                  (item) =>
                      AgyQuotaBucket.fromJson(item.cast<String, dynamic>()),
                )
                .where((bucket) => !bucket.disabled)
                .toList()
          : const [],
    );
  }
}

class AgyQuotaBucket {
  const AgyQuotaBucket({
    required this.name,
    required this.remainingFraction,
    this.window = '',
    this.remainingAmount,
    this.resetAt,
    this.description = '',
    this.disabled = false,
  });

  final String name;
  final String window;
  final double remainingFraction;
  final int? remainingAmount;
  final DateTime? resetAt;
  final String description;
  final bool disabled;

  factory AgyQuotaBucket.fromJson(Map<String, dynamic> json) {
    final rawFraction = json['remainingFraction'];
    final fraction = rawFraction is num
        ? rawFraction.toDouble()
        : double.tryParse(rawFraction?.toString() ?? '') ?? 0;
    final rawReset = json['resetTime'];
    DateTime? resetAt;
    if (rawReset is Map) {
      final seconds = _parseInt(rawReset['seconds']);
      if (seconds != null && seconds > 0) {
        resetAt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
      }
    } else if (rawReset is String) {
      resetAt = DateTime.tryParse(rawReset)?.toLocal();
    }
    return AgyQuotaBucket(
      name:
          json['displayName']?.toString() ??
          json['window']?.toString() ??
          'Usage',
      window: json['window']?.toString() ?? '',
      remainingFraction: fraction.clamp(0, 1).toDouble(),
      remainingAmount: _parseInt(json['remainingAmount']),
      resetAt: resetAt,
      description: json['description']?.toString() ?? '',
      disabled: json['disabled'] == true,
    );
  }
}
