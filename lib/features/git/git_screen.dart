import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../app/theme/app_theme.dart';
import '../bridge/data/bridge_channel.dart';
import '../bridge/presentation/bridge_controller.dart';

const _githubOAuthClientId = String.fromEnvironment('GITHUB_OAUTH_CLIENT_ID');

class GitScreen extends ConsumerStatefulWidget {
  const GitScreen({super.key});

  @override
  ConsumerState<GitScreen> createState() => _GitScreenState();
}

class _GitScreenState extends ConsumerState<GitScreen> {
  List<_Project> _projects = [];
  List<_GitBranch> _branches = [];
  List<_GitCommit> _commits = [];
  String? _projectPath;
  _GitStatus? _status;
  String _remoteUrl = '';
  _GitHubAccount? _githubAccount;
  String? _error;
  String? _githubError;
  bool _loading = true;
  bool _loadingGithub = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProjects());
    unawaited(_loadGithubAccount());
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool allowList = false,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final bridge = ref.read(bridgeServiceProvider);
    final uri = (await bridge.resolve(path)).replace(queryParameters: query);
    final headers = await bridge.authHeaders();
    headers['Content-Type'] = 'application/json';
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final streamed = await request.send().timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      decoded = null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map
          ? decoded['error'] ?? decoded['message']
          : null;
      throw _GitException(
        message?.toString() ?? 'Bridge returned HTTP ${response.statusCode}',
      );
    }
    if (decoded is List && allowList) return {'_items': decoded};
    if (decoded is! Map) throw const _GitException('Invalid bridge response.');
    return decoded.cast<String, dynamic>();
  }

  Future<void> _loadProjects() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _request('GET', '/api/projects', allowList: true);
      final raw = result['_items'] is List
          ? result['_items'] as List
          : const <dynamic>[];
      final projects = raw
          .whereType<Map>()
          .map(_Project.fromJson)
          .where((project) => project.path.isNotEmpty)
          .toList();
      if (projects.isEmpty) throw const _GitException('No workspaces found.');
      final selected = projects.any((p) => p.path == _projectPath)
          ? _projectPath!
          : projects.first.path;
      if (!mounted) return;
      setState(() {
        _projects = projects;
        _projectPath = selected;
      });
      await _loadStatus();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _loadStatus({bool showLoading = true}) async {
    final project = _projectPath;
    if (project == null) return;
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final responses = await Future.wait([
        _request('GET', '/api/git/status', query: {'project': project}),
        _request('GET', '/api/git/config', query: {'project': project}),
        _request('GET', '/api/git/branches', query: {'project': project}),
        _request(
          'GET',
          '/api/git/log',
          query: {'project': project, 'limit': '12'},
        ),
      ]);
      final json = responses[0];
      final config = responses[1];
      final branches = responses[2];
      final history = responses[3];
      if (!mounted) return;
      setState(() {
        _status = _GitStatus.fromJson(json);
        _remoteUrl = config['remoteUrl']?.toString() ?? '';
        _branches = _items(branches['branches'])
            .map(_GitBranch.fromJson)
            .toList();
        _commits = _items(history['commits']).map(_GitCommit.fromJson).toList();
        _loading = false;
        _error = json['error']?.toString();
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _selectProject(String? path) async {
    if (path == null || path == _projectPath) return;
    setState(() {
      _projectPath = path;
      _status = null;
      _remoteUrl = '';
      _branches = [];
      _commits = [];
    });
    await _loadStatus();
  }

  Future<void> _loadGithubAccount() async {
    try {
      final result = await _request('GET', '/api/git/github/auth');
      if (!mounted) return;
      setState(() {
        _githubAccount = result['connected'] == true
            ? _GitHubAccount(result['login']?.toString() ?? '')
            : null;
        _githubError = result['error']?.toString();
        _loadingGithub = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _githubError = error.toString();
          _loadingGithub = false;
        });
      }
    }
  }

  Future<_GitHubDeviceCode> _requestGithubDeviceCode() async {
    if (_githubOAuthClientId.isEmpty) {
      throw const _GitException(
        'GitHub OAuth is not configured. Add GITHUB_OAUTH_CLIENT_ID to the '
        'build settings after registering an OAuth App with Device Flow enabled.',
      );
    }
    final response = await http
        .post(
          Uri.https('github.com', '/login/device/code', {
            'client_id': _githubOAuthClientId,
            'scope': 'repo read:user',
          }),
          headers: const {'Accept': 'application/json'},
        )
        .timeout(const Duration(seconds: 15));
    final decoded = _decodeOAuthResponse(response);
    if (response.statusCode != 200 || decoded['device_code'] == null) {
      throw _GitException(
        decoded['error_description']?.toString() ??
            'GitHub could not start sign-in (HTTP ${response.statusCode}).',
      );
    }
    return _GitHubDeviceCode.fromJson(decoded);
  }

  Future<void> _connectGithub() async {
    setState(() {
      _busy = true;
      _githubError = null;
    });
    try {
      final deviceCode = await _requestGithubDeviceCode();
      if (!mounted) return;
      final accessToken = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _GitHubDeviceDialog(
          clientId: _githubOAuthClientId,
          deviceCode: deviceCode,
        ),
      );
      if (accessToken == null || !mounted) return;
      final result = await _request(
        'POST',
        '/api/git/github/auth',
        body: {'accessToken': accessToken},
      );
      if (!mounted) return;
      final account = _GitHubAccount(result['login']?.toString() ?? '');
      setState(() => _githubAccount = account);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to GitHub as @${account.login}')),
      );
    } catch (error) {
      if (mounted) setState(() => _githubError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnectGithub() async {
    setState(() {
      _busy = true;
      _githubError = null;
    });
    try {
      await _request('DELETE', '/api/git/github/auth');
      if (mounted) setState(() => _githubAccount = null);
    } catch (error) {
      if (mounted) setState(() => _githubError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _perform(
    String label,
    String path, {
    Object? body,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final project = _projectPath;
    if (project == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payload = <String, dynamic>{'project': project};
      if (body is Map<String, dynamic>) payload.addAll(body);
      final result = await _request(
        'POST',
        path,
        body: payload,
        timeout: timeout,
      );
      if (result['success'] == false) {
        throw _GitException(result['error']?.toString() ?? '$label failed.');
      }
      await _loadStatus(showLoading: false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$label complete')));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _initRepository() =>
      _perform('Git repository initialized', '/api/git/init');

  bool get _remoteUsesGitHubHttps => _isGitHubHttpsRemote(_remoteUrl);

  bool _hasLocalChanges(_GitStatus status) =>
      status.staged.isNotEmpty ||
      status.unstaged.isNotEmpty ||
      status.untracked.isNotEmpty;

  Future<void> _editRemote() async {
    final remote = await showDialog<String>(
      context: context,
      builder: (context) => _RemoteDialog(initialValue: _remoteUrl),
    );
    if (remote == null || !mounted) return;
    if (!_isGitHubHttpsRemote(remote)) {
      setState(() => _error = 'Enter an HTTPS URL from github.com.');
      return;
    }
    await _perform(
      'Save origin remote',
      '/api/git/config',
      body: {'remoteUrl': remote.trim()},
    );
  }

  Future<void> _push() async {
    final status = _status;
    if (status == null || status.unpushedCount == 0) return;
    await _perform(
      'Push',
      '/api/git/push',
      timeout: const Duration(minutes: 3),
    );
  }

  Future<void> _pull() async {
    final status = _status;
    if (status == null || _hasLocalChanges(status)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pull from GitHub?'),
        content: Text(
          'Pull changes from origin into ${status.branch}. '
          'The workspace is clean, so Git can update its files safely.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Pull'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _perform(
        'Pull',
        '/api/git/pull',
        timeout: const Duration(minutes: 3),
      );
    }
  }

  Future<void> _openPullRequests() async {
    final project = _projectPath;
    if (project == null || !_remoteUsesGitHubHttps || _githubAccount == null) {
      return;
    }
    try {
      final result = await _request(
        'GET',
        '/api/git/github/pulls',
        query: {'project': project},
      );
      final pullRequests = _items(result['pullRequests'])
          .map(_GitHubPullRequest.fromJson)
          .toList();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _PullRequestsSheet(
          pullRequests: pullRequests,
          defaultBranch: result['defaultBranch']?.toString() ?? '',
          currentBranch: result['headBranch']?.toString() ?? '',
          canCreate:
              _status != null &&
              !_hasLocalChanges(_status!) &&
              _status!.tracking.isNotEmpty &&
              _status!.unpushedCount == 0,
          onCreate: (base) => _createPullRequest(base),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _createPullRequest(String defaultBranch) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) =>
          _CreatePullRequestDialog(defaultBranch: defaultBranch),
    );
    final project = _projectPath;
    if (values == null || project == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final pull = await _request(
        'POST',
        '/api/git/github/pulls',
        body: {
          'project': project,
          'title': values['title'],
          'body': values['body'],
          'base': values['base'],
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pull request #${pull['number']} created')),
      );
      await _loadStatus(showLoading: false);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkoutBranch(String? branch) async {
    final status = _status;
    if (branch == null ||
        status == null ||
        branch == status.branch ||
        _hasLocalChanges(status)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Switch branch?'),
        content: Text('Switch from ${status.branch} to $branch?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _perform(
        'Switch branch',
        '/api/git/checkout',
        body: {'branch': branch},
      );
    }
  }

  Future<void> _createBranch() async {
    final status = _status;
    if (status == null || _hasLocalChanges(status)) return;
    final branch = await showDialog<String>(
      context: context,
      builder: (context) => const _GitBranchDialog(),
    );
    if (branch == null || branch.trim().isEmpty || !mounted) return;
    await _perform(
      'Create branch',
      '/api/git/branch/create',
      body: {'branch': branch.trim(), 'create': true},
    );
  }

  Future<void> _showCommitDetails(_GitCommit commit) async {
    try {
      final details = await _request(
        'GET',
        '/api/git/commit/details',
        query: {'project': _projectPath ?? '', 'hash': commit.hash},
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _CommitDetailsSheet(
          commit: _GitCommitDetails.fromJson(details),
          onFileTap: (file) => _showCommitDiff(commit.hash, file),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _showCommitDiff(String hash, _GitCommitFile file) async {
    try {
      final result = await _request(
        'GET',
        '/api/git/commit/diff',
        query: {'project': _projectPath ?? '', 'hash': hash, 'file': file.path},
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _CommitDiffSheet(
          file: file,
          diff: result['diff']?.toString() ?? '',
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _stageAll() => _perform('Stage all changes', '/api/git/stage');

  Future<void> _stage(_GitFile file) => _perform(
    'Stage ${file.path}',
    '/api/git/stage',
    body: {
      'paths': [file.path],
    },
  );

  Future<void> _unstage(_GitFile file) => _perform(
    'Unstage ${file.path}',
    '/api/git/unstage',
    body: {
      'paths': [file.path],
    },
  );

  Future<void> _commit() async {
    final message = await showDialog<String>(
      context: context,
      builder: (context) => const _CommitDialog(),
    );
    if (message == null || message.trim().isEmpty) return;
    await _perform(
      'Commit created',
      '/api/git/commit',
      body: {'message': message.trim()},
    );
  }

  Future<void> _showDiff(_GitFile file) async {
    try {
      final json = await _request(
        'GET',
        '/api/git/diff',
        query: {
          'project': _projectPath ?? '',
          'file': file.path,
          'staged': file.staged.toString(),
        },
      );
      if (!mounted) return;
      final diff = _GitDiff.fromJson(json);
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (context) => _DiffSheet(file: file, diff: diff),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = _projectPath;
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Git'),
        actions: [
          IconButton(
            tooltip: 'Refresh status',
            onPressed: _loading || _busy ? null : () => _loadStatus(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: _projects.isEmpty && _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: project,
                    decoration: const InputDecoration(labelText: 'Workspace'),
                    items: _projects
                        .map(
                          (item) => DropdownMenuItem(
                            value: item.path,
                            child: Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: _busy ? null : _selectProject,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    MaterialBanner(
                      content: Text(_error!),
                      actions: [
                        TextButton(
                          onPressed: _loadProjects,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 8),
                  _GitHubCard(
                    account: _githubAccount,
                    loading: _loadingGithub,
                    busy: _busy,
                    error: _githubError,
                    oauthReady: _githubOAuthClientId.isNotEmpty,
                    onConnect: _connectGithub,
                    onDisconnect: _disconnectGithub,
                  ),
                  const SizedBox(height: 16),
                  if (_loading)
                    const LinearProgressIndicator()
                  else if (status == null)
                    const Center(child: Text('Git status unavailable.'))
                  else if (!status.isGitRepo)
                    _NotRepository(onInit: _busy ? null : _initRepository)
                  else ...[
                    _BranchCard(
                      status: status,
                      branches: _branches,
                      canChange: !_busy && !_hasLocalChanges(status),
                      onSelect: _checkoutBranch,
                      onCreate: _createBranch,
                    ),
                    const SizedBox(height: 8),
                    _RemoteCard(
                      remoteUrl: _remoteUrl,
                      supportsGitHubAuth: _remoteUsesGitHubHttps,
                      onEdit: _busy ? null : _editRemote,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed:
                                _busy ||
                                    !_remoteUsesGitHubHttps ||
                                    _githubAccount == null ||
                                    _hasLocalChanges(status)
                                ? null
                                : _pull,
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('Pull'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed:
                                _busy ||
                                    !_remoteUsesGitHubHttps ||
                                    _githubAccount == null ||
                                    status.unpushedCount == 0
                                ? null
                                : _push,
                            icon: const Icon(Icons.upload_outlined),
                            label: Text(
                              status.unpushedCount == 0
                                  ? 'Push'
                                  : 'Push ${status.unpushedCount}',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed:
                          _busy ||
                              !_remoteUsesGitHubHttps ||
                              _githubAccount == null
                          ? null
                          : _openPullRequests,
                      icon: const Icon(Icons.merge_type),
                      label: const Text('Pull requests'),
                    ),
                    if (_remoteUrl.isEmpty || !_remoteUsesGitHubHttps)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Set an HTTPS github.com origin to sync.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.muted, fontSize: 12),
                        ),
                      )
                    else if (_githubAccount == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Connect GitHub above to enable remote sync.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.muted, fontSize: 12),
                        ),
                      )
                    else if (_hasLocalChanges(status))
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Commit or stash local changes before pulling.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.muted, fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Changes',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _busy || status.unstaged.isEmpty
                              ? null
                              : _stageAll,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Stage all'),
                        ),
                      ],
                    ),
                    _FileSection(
                      title: 'Staged',
                      files: status.staged,
                      emptyText: 'No staged changes',
                      onFileTap: _showDiff,
                      onAction: _busy ? null : _unstage,
                      actionIcon: Icons.remove_circle_outline,
                      actionLabel: 'Unstage',
                    ),
                    _FileSection(
                      title: 'Unstaged',
                      files: [...status.unstaged, ...status.untracked],
                      emptyText: 'No unstaged changes',
                      onFileTap: _showDiff,
                      onAction: _busy ? null : _stage,
                      actionIcon: Icons.add_circle_outline,
                      actionLabel: 'Stage',
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy || status.staged.isEmpty
                          ? null
                          : _commit,
                      icon: const Icon(Icons.check),
                      label: Text(
                        _busy
                            ? 'Working…'
                            : 'Commit ${status.staged.length} staged',
                      ),
                    ),
                    if (status.staged.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text(
                        'Only staged files will be included.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.muted, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _HistorySection(
                      commits: _commits,
                      onCommitTap: _showCommitDetails,
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _PullRequestsSheet extends StatelessWidget {
  const _PullRequestsSheet({
    required this.pullRequests,
    required this.defaultBranch,
    required this.currentBranch,
    required this.canCreate,
    required this.onCreate,
  });

  final List<_GitHubPullRequest> pullRequests;
  final String defaultBranch;
  final String currentBranch;
  final bool canCreate;
  final ValueChanged<String> onCreate;

  @override
  Widget build(BuildContext context) {
    final branchReady =
        canCreate && currentBranch.isNotEmpty && currentBranch != defaultBranch;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Open pull requests',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            if (pullRequests.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text('No open pull requests.'),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: pullRequests.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final pull = pullRequests[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.merge_type),
                      title: Text('#${pull.number} ${pull.title}'),
                      subtitle: SelectableText(
                        '${pull.head} → ${pull.base}\n${pull.url}',
                        maxLines: 3,
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: branchReady ? () => onCreate(defaultBranch) : null,
              icon: const Icon(Icons.add),
              label: const Text('Create pull request'),
            ),
            if (!branchReady)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Use a clean, pushed branch with an upstream, different from the default branch.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CreatePullRequestDialog extends StatefulWidget {
  const _CreatePullRequestDialog({required this.defaultBranch});

  final String defaultBranch;

  @override
  State<_CreatePullRequestDialog> createState() =>
      _CreatePullRequestDialogState();
}

class _CreatePullRequestDialogState extends State<_CreatePullRequestDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late final TextEditingController _baseController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _bodyController = TextEditingController();
    _baseController = TextEditingController(text: widget.defaultBranch);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _baseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create pull request'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _titleController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseController,
            decoration: const InputDecoration(labelText: 'Base branch'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _bodyController,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(labelText: 'Description'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final title = _titleController.text.trim();
          final base = _baseController.text.trim();
          if (title.isEmpty || base.isEmpty) return;
          Navigator.pop(context, {
            'title': title,
            'body': _bodyController.text.trim(),
            'base': base,
          });
        },
        child: const Text('Create'),
      ),
    ],
  );
}

class _NotRepository extends StatelessWidget {
  const _NotRepository({required this.onInit});

  final VoidCallback? onInit;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Icon(Icons.folder_open_outlined, size: 36),
          const SizedBox(height: 12),
          const Text('This workspace is not a Git repository.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onInit,
            icon: const Icon(Icons.add),
            label: const Text('Initialize Git repository'),
          ),
        ],
      ),
    ),
  );
}

class _GitHubCard extends StatelessWidget {
  const _GitHubCard({
    required this.account,
    required this.loading,
    required this.busy,
    required this.error,
    required this.oauthReady,
    required this.onConnect,
    required this.onDisconnect,
  });

  final _GitHubAccount? account;
  final bool loading;
  final bool busy;
  final String? error;
  final bool oauthReady;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.code, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account == null ? 'GitHub account' : '@${account!.login}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      loading
                          ? 'Checking connection…'
                          : account == null
                          ? oauthReady
                                ? 'Connect to use GitHub HTTPS remotes'
                                : 'GitHub OAuth Client ID is not configured'
                          : 'Connected',
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (account == null)
                OutlinedButton(
                  onPressed: busy || !oauthReady ? null : onConnect,
                  child: const Text('Connect'),
                )
              else
                IconButton(
                  tooltip: 'Disconnect GitHub',
                  onPressed: busy ? null : onDisconnect,
                  icon: const Icon(Icons.logout),
                ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _GitHubDeviceCode {
  const _GitHubDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresIn;
  final int interval;

  factory _GitHubDeviceCode.fromJson(Map<String, dynamic> json) =>
      _GitHubDeviceCode(
        deviceCode: json['device_code'].toString(),
        userCode: json['user_code'].toString(),
        verificationUri: json['verification_uri'].toString(),
        expiresIn: _intValue(json['expires_in']),
        interval: _intValue(json['interval']) == 0
            ? 5
            : _intValue(json['interval']),
      );
}

class _GitHubDeviceDialog extends StatefulWidget {
  const _GitHubDeviceDialog({required this.clientId, required this.deviceCode});

  final String clientId;
  final _GitHubDeviceCode deviceCode;

  @override
  State<_GitHubDeviceDialog> createState() => _GitHubDeviceDialogState();
}

class _GitHubDeviceDialogState extends State<_GitHubDeviceDialog> {
  String? _error;
  String _status = 'Waiting for approval…';
  late int _interval;
  late final DateTime _expiresAt;

  @override
  void initState() {
    super.initState();
    _interval = widget.deviceCode.interval;
    _expiresAt = DateTime.now().add(
      Duration(seconds: widget.deviceCode.expiresIn),
    );
    unawaited(_pollForAccessToken());
  }

  Future<void> _pollForAccessToken() async {
    var networkFailures = 0;
    while (mounted && DateTime.now().isBefore(_expiresAt)) {
      await Future<void>.delayed(Duration(seconds: _interval));
      if (!mounted) return;
      try {
        final response = await http
            .post(
              Uri.https('github.com', '/login/oauth/access_token', {
                'client_id': widget.clientId,
                'device_code': widget.deviceCode.deviceCode,
                'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
              }),
              headers: const {'Accept': 'application/json'},
            )
            .timeout(const Duration(seconds: 15));
        final decoded = _decodeOAuthResponse(response);
        final accessToken = decoded['access_token']?.toString();
        if (response.statusCode == 200 && accessToken?.isNotEmpty == true) {
          if (mounted) Navigator.pop(context, accessToken);
          return;
        }
        networkFailures = 0;
        switch (decoded['error']) {
          case 'authorization_pending':
            if (mounted && _status != 'Waiting for approval…') {
              setState(() => _status = 'Waiting for approval…');
            }
            continue;
          case 'slow_down':
            final newInterval = _intValue(decoded['interval']);
            _interval = newInterval > _interval ? newInterval : _interval + 5;
            continue;
          case 'access_denied':
            _setError('GitHub sign-in was denied.');
            return;
          case 'expired_token':
          case 'token_expired':
            _setError('The device code expired. Start sign-in again.');
            return;
          default:
            _setError(
              decoded['error_description']?.toString() ??
                  'GitHub sign-in failed (HTTP ${response.statusCode}).',
            );
            return;
        }
      } catch (error) {
        networkFailures++;
        if (networkFailures >= 5) {
          _setError('Could not reach GitHub after several retries: $error');
          return;
        }
        if (mounted) {
          setState(
            () => _status =
                'Connection interrupted; retrying ($networkFailures/5)…',
          );
        }
      }
    }
    _setError('The device code expired. Start sign-in again.');
  }

  void _setError(String message) {
    if (mounted) setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Sign in to GitHub'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Open GitHub and enter this one-time code:'),
        const SizedBox(height: 12),
        Center(
          child: SelectableText(
            widget.deviceCode.userCode,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () =>
              BridgeChannel().openUrl(widget.deviceCode.verificationUri),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('Open GitHub verification'),
        ),
        if (_error == null)
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              Expanded(child: Text(_status)),
            ],
          )
        else
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
    ],
  );
}

Map<String, dynamic> _decodeOAuthResponse(http.Response response) {
  final decoded = jsonDecode(response.body);
  if (decoded is! Map) throw const _GitException('Invalid GitHub response.');
  return decoded.cast<String, dynamic>();
}

class _BranchCard extends StatelessWidget {
  const _BranchCard({
    required this.status,
    required this.branches,
    required this.canChange,
    required this.onSelect,
    required this.onCreate,
  });

  final _GitStatus status;
  final List<_GitBranch> branches;
  final bool canChange;
  final ValueChanged<String?> onSelect;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final localBranches = branches.where((branch) => !branch.isRemote).toList();
    final currentBranch =
        localBranches.any((branch) => branch.name == status.branch)
        ? status.branch
        : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.account_tree_outlined, color: AppTheme.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String>(
                    value: currentBranch,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    hint: Text(status.branch),
                    items: localBranches
                        .map(
                          (branch) => DropdownMenuItem(
                            value: branch.name,
                            child: Text(
                              branch.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: canChange ? onSelect : null,
                  ),
                ),
                IconButton(
                  tooltip: 'Create branch',
                  onPressed: canChange ? onCreate : null,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 34, bottom: 4),
              child: Text(
                status.tracking.isNotEmpty
                    ? '${status.tracking}  •  ${status.ahead} ahead, ${status.behind} behind'
                    : canChange
                    ? 'Local branch'
                    : 'Commit or stash changes before switching branches',
                style: const TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistorySection extends StatelessWidget {
  const _HistorySection({required this.commits, required this.onCommitTap});

  final List<_GitCommit> commits;
  final ValueChanged<_GitCommit> onCommitTap;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            'History (${commits.length})',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        if (commits.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'No commits yet.',
              style: TextStyle(color: AppTheme.muted),
            ),
          )
        else
          ...commits.map(
            (commit) => ListTile(
              dense: true,
              leading: Icon(
                commit.isUnpushed ? Icons.upload_outlined : Icons.commit,
                color: commit.isUnpushed ? AppTheme.accent : AppTheme.muted,
              ),
              title: Text(
                commit.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${commit.shortHash} • ${commit.author} • ${commit.date}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => onCommitTap(commit),
            ),
          ),
      ],
    ),
  );
}

class _CommitDetailsSheet extends StatelessWidget {
  const _CommitDetailsSheet({required this.commit, required this.onFileTap});

  final _GitCommitDetails commit;
  final ValueChanged<_GitCommitFile> onFileTap;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .78,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    commit.subject,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '${commit.shortHash} • ${commit.author} • ${commit.date}',
              style: const TextStyle(color: AppTheme.muted, fontSize: 12),
            ),
          ),
          if (commit.body.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(commit.body),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Text(
              'Changed files (${commit.files.length})',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: commit.files.isEmpty
                ? const Center(child: Text('No file changes recorded.'))
                : ListView.builder(
                    itemCount: commit.files.length,
                    itemBuilder: (context, index) {
                      final file = commit.files[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(
                          file.path,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(file.status),
                        onTap: () => onFileTap(file),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

class _CommitDiffSheet extends StatelessWidget {
  const _CommitDiffSheet({required this.file, required this.diff});

  final _GitCommitFile file;
  final String diff;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .82,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    file.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: diff.isEmpty
                ? const Center(child: Text('No text diff available.'))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      diff,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}

class _RemoteCard extends StatelessWidget {
  const _RemoteCard({
    required this.remoteUrl,
    required this.supportsGitHubAuth,
    required this.onEdit,
  });

  final String remoteUrl;
  final bool supportsGitHubAuth;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: const Icon(Icons.cloud_outlined),
      title: const Text('Origin'),
      subtitle: Text(
        remoteUrl.isEmpty
            ? 'No remote configured'
            : supportsGitHubAuth
            ? remoteUrl
            : '$remoteUrl\nUse an HTTPS github.com origin for app sign-in',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: remoteUrl.isEmpty ? 'Set origin' : 'Edit origin',
        onPressed: onEdit,
        icon: const Icon(Icons.edit_outlined),
      ),
    ),
  );
}

class _RemoteDialog extends StatefulWidget {
  const _RemoteDialog({required this.initialValue});

  final String initialValue;

  @override
  State<_RemoteDialog> createState() => _RemoteDialogState();
}

class _RemoteDialogState extends State<_RemoteDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('GitHub origin'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      autocorrect: false,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(
        labelText: 'HTTPS repository URL',
        hintText: 'https://github.com/owner/repository.git',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: const Text('Save'),
      ),
    ],
  );
}

class _FileSection extends StatelessWidget {
  const _FileSection({
    required this.title,
    required this.files,
    required this.emptyText,
    required this.onFileTap,
    required this.onAction,
    required this.actionIcon,
    required this.actionLabel,
  });

  final String title;
  final List<_GitFile> files;
  final String emptyText;
  final ValueChanged<_GitFile> onFileTap;
  final Future<void> Function(_GitFile)? onAction;
  final IconData actionIcon;
  final String actionLabel;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            '$title (${files.length})',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        if (files.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              emptyText,
              style: const TextStyle(color: AppTheme.muted),
            ),
          )
        else
          ...files.map(
            (file) => ListTile(
              dense: true,
              title: Text(
                file.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(file.status),
              onTap: () => onFileTap(file),
              trailing: IconButton(
                tooltip: actionLabel,
                onPressed: onAction == null ? null : () => onAction!(file),
                icon: Icon(actionIcon),
              ),
            ),
          ),
      ],
    ),
  );
}

class _DiffSheet extends StatelessWidget {
  const _DiffSheet({required this.file, required this.diff});

  final _GitFile file;
  final _GitDiff diff;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .82,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    file.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '+${diff.additions}  −${diff.deletions}',
              style: const TextStyle(color: AppTheme.accent),
            ),
          ),
          const Divider(),
          Expanded(
            child: diff.text.isEmpty
                ? const Center(
                    child: Text('No text diff available for this file.'),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      diff.text,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.45,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}

class _GitBranchDialog extends StatefulWidget {
  const _GitBranchDialog();

  @override
  State<_GitBranchDialog> createState() => _GitBranchDialogState();
}

class _GitBranchDialogState extends State<_GitBranchDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Create branch'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      autocorrect: false,
      decoration: const InputDecoration(labelText: 'Branch name'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Create'),
      ),
    ],
  );
}

class _CommitDialog extends StatefulWidget {
  const _CommitDialog();

  @override
  State<_CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends State<_CommitDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Commit staged changes'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLines: 3,
      decoration: const InputDecoration(
        labelText: 'Commit message',
        hintText: 'Describe your changes',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Commit'),
      ),
    ],
  );
}

class _Project {
  const _Project({required this.name, required this.path});
  final String name;
  final String path;

  factory _Project.fromJson(Map<dynamic, dynamic> json) => _Project(
    name: (json['name'] ?? '').toString(),
    path: (json['path'] ?? '').toString(),
  );
}

class _GitHubAccount {
  const _GitHubAccount(this.login);
  final String login;
}

class _GitHubPullRequest {
  const _GitHubPullRequest({
    required this.number,
    required this.title,
    required this.url,
    required this.head,
    required this.base,
  });

  final int number;
  final String title;
  final String url;
  final String head;
  final String base;

  factory _GitHubPullRequest.fromJson(Map<dynamic, dynamic> json) =>
      _GitHubPullRequest(
        number: (json['number'] as num?)?.toInt() ?? 0,
        title: json['title']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
        head: json['head']?.toString() ?? '',
        base: json['base']?.toString() ?? '',
      );
}

class _GitBranch {
  const _GitBranch({
    required this.name,
    required this.isCurrent,
    required this.isRemote,
  });

  final String name;
  final bool isCurrent;
  final bool isRemote;

  factory _GitBranch.fromJson(Map<dynamic, dynamic> json) => _GitBranch(
    name: (json['name'] ?? '').toString(),
    isCurrent: json['isCurrent'] == true,
    isRemote: json['isRemote'] == true,
  );
}

class _GitCommit {
  const _GitCommit({
    required this.hash,
    required this.shortHash,
    required this.author,
    required this.date,
    required this.message,
    required this.isUnpushed,
  });

  final String hash;
  final String shortHash;
  final String author;
  final String date;
  final String message;
  final bool isUnpushed;

  factory _GitCommit.fromJson(Map<dynamic, dynamic> json) => _GitCommit(
    hash: (json['hash'] ?? '').toString(),
    shortHash: (json['shortHash'] ?? '').toString(),
    author: (json['author'] ?? '').toString(),
    date: (json['date'] ?? '').toString(),
    message: (json['message'] ?? '').toString(),
    isUnpushed: json['isUnpushed'] == true,
  );
}

class _GitCommitFile {
  const _GitCommitFile({required this.path, required this.status});
  final String path;
  final String status;

  factory _GitCommitFile.fromJson(Map<dynamic, dynamic> json) => _GitCommitFile(
    path: (json['path'] ?? '').toString(),
    status: (json['status'] ?? '').toString(),
  );
}

class _GitCommitDetails {
  const _GitCommitDetails({
    required this.shortHash,
    required this.author,
    required this.date,
    required this.subject,
    required this.body,
    required this.files,
  });

  final String shortHash;
  final String author;
  final String date;
  final String subject;
  final String body;
  final List<_GitCommitFile> files;

  factory _GitCommitDetails.fromJson(Map<String, dynamic> json) =>
      _GitCommitDetails(
        shortHash: (json['shortHash'] ?? '').toString(),
        author: (json['author'] ?? '').toString(),
        date: (json['date'] ?? '').toString(),
        subject: (json['subject'] ?? '').toString(),
        body: (json['body'] ?? '').toString(),
        files: _items(json['changedFiles'])
            .map(_GitCommitFile.fromJson)
            .toList(),
      );
}

class _GitFile {
  const _GitFile({
    required this.path,
    required this.status,
    required this.staged,
  });
  final String path;
  final String status;
  final bool staged;

  factory _GitFile.fromJson(
    Map<dynamic, dynamic> json, {
    bool staged = false,
  }) => _GitFile(
    path: (json['path'] ?? '').toString(),
    status: (json['status'] ?? '?').toString(),
    staged: json['staged'] == true || staged,
  );
}

class _GitStatus {
  const _GitStatus({
    required this.isGitRepo,
    required this.branch,
    required this.tracking,
    required this.ahead,
    required this.behind,
    required this.unpushedCount,
    required this.staged,
    required this.unstaged,
    required this.untracked,
  });

  final bool isGitRepo;
  final String branch;
  final String tracking;
  final int ahead;
  final int behind;
  final int unpushedCount;
  final List<_GitFile> staged;
  final List<_GitFile> unstaged;
  final List<_GitFile> untracked;

  factory _GitStatus.fromJson(Map<String, dynamic> json) => _GitStatus(
    isGitRepo: json['isGitRepo'] == true,
    branch: json['branch']?.toString() ?? 'HEAD',
    tracking: json['tracking']?.toString() ?? '',
    ahead: _intValue(json['ahead']),
    behind: _intValue(json['behind']),
    unpushedCount: _intValue(json['unpushedCount']),
    staged: _files(json['stagedFiles'], staged: true),
    unstaged: _files(json['unstagedFiles']),
    untracked: _files(json['untrackedFiles']),
  );
}

class _GitDiff {
  const _GitDiff(this.text, this.additions, this.deletions);
  final String text;
  final int additions;
  final int deletions;

  factory _GitDiff.fromJson(Map<String, dynamic> json) => _GitDiff(
    json['diff']?.toString() ?? '',
    _intValue(json['additions']),
    _intValue(json['deletions']),
  );
}

List<Map<dynamic, dynamic>> _items(Object? value) =>
    value is List ? value.whereType<Map>().toList() : const [];

List<_GitFile> _files(Object? value, {bool staged = false}) => value is List
    ? value
          .whereType<Map>()
          .map((json) => _GitFile.fromJson(json, staged: staged))
          .toList()
    : const [];

int _intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

bool _isGitHubHttpsRemote(String remote) {
  final uri = Uri.tryParse(remote.trim());
  return uri != null &&
      uri.scheme.toLowerCase() == 'https' &&
      uri.host.toLowerCase() == 'github.com' &&
      uri.pathSegments.length >= 2;
}

class _GitException implements Exception {
  const _GitException(this.message);
  final String message;
  @override
  String toString() => message;
}
