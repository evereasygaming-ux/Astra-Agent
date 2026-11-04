class ClaudeAuthStatus {
  const ClaudeAuthStatus({
    this.loggedIn = false,
    this.authMethod,
    this.email,
    this.subscriptionType,
  });

  final bool loggedIn;
  final String? authMethod;
  final String? email;
  final String? subscriptionType;

  factory ClaudeAuthStatus.fromJson(Map<String, dynamic> json) {
    return ClaudeAuthStatus(
      loggedIn: json['loggedIn'] == true,
      authMethod: json['authMethod'] as String?,
      email: json['email'] as String?,
      subscriptionType: json['subscriptionType'] as String?,
    );
  }
}

class ClaudeCliStatus {
  const ClaudeCliStatus({
    this.success = false,
    this.installed = false,
    this.version,
    this.binPath,
    this.auth,
    this.authError,
    this.error,
  });

  final bool success;
  final bool installed;
  final String? version;
  final String? binPath;
  final ClaudeAuthStatus? auth;
  final String? authError;
  final String? error;

  bool get loggedIn => auth?.loggedIn == true;

  factory ClaudeCliStatus.fromJson(Map<String, dynamic> json) {
    final auth = json['auth'];
    return ClaudeCliStatus(
      success: json['success'] == true,
      installed: json['installed'] == true,
      version: json['version'] as String?,
      binPath: json['bin_path'] as String?,
      auth: auth is Map<String, dynamic>
          ? ClaudeAuthStatus.fromJson(auth)
          : null,
      authError: json['auth_error'] as String?,
      error: json['error'] as String?,
    );
  }
}

class ClaudeJob {
  const ClaudeJob({
    required this.kind,
    required this.running,
    required this.log,
    this.exitCode,
  });

  final String kind;
  final bool running;
  final String log;
  final int? exitCode;

  factory ClaudeJob.fromJson(Map<String, dynamic> json) {
    return ClaudeJob(
      kind: json['kind'] as String? ?? '',
      running: json['running'] == true,
      log: json['log'] as String? ?? '',
      exitCode: (json['exit_code'] as num?)?.toInt(),
    );
  }
}

class ClaudeLogin {
  const ClaudeLogin({
    required this.loginId,
    required this.method,
    required this.state,
    this.error,
    this.manualUrl,
    this.automaticUrl,
  });

  final String loginId;
  final String method;
  final String state;
  final String? error;
  final String? manualUrl;
  final String? automaticUrl;

  bool get pending => state == 'pending';

  factory ClaudeLogin.fromJson(Map<String, dynamic> json) {
    return ClaudeLogin(
      loginId: json['login_id'] as String? ?? '',
      method: json['method'] as String? ?? '',
      state: json['state'] as String? ?? '',
      error: json['error'] as String?,
      manualUrl: json['manual_url'] as String?,
      automaticUrl: json['automatic_url'] as String?,
    );
  }
}
