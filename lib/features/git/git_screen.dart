import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../app/theme/app_theme.dart';
import '../bridge/data/bridge_channel.dart';
import '../bridge/presentation/bridge_controller.dart';

class GitScreen extends ConsumerStatefulWidget {
  const GitScreen({super.key});

  @override
  ConsumerState<GitScreen> createState() => _GitScreenState();
}

class _GitScreenState extends ConsumerState<GitScreen> {
  List<_Project> _projects = [];
  String? _projectPath;
  _GitStatus? _status;
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
  }) async {
    final bridge = ref.read(bridgeServiceProvider);
    final uri = (await bridge.resolve(path)).replace(queryParameters: query);
    final headers = await bridge.authHeaders();
    headers['Content-Type'] = 'application/json';
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final streamed = await request.send().timeout(const Duration(seconds: 20));
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
      final json = await _request(
        'GET',
        '/api/git/status',
        query: {'project': project},
      );
      if (!mounted) return;
      setState(() {
        _status = _GitStatus.fromJson(json);
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

  Future<void> _connectGithub() async {
    final token = await showDialog<String>(
      context: context,
      builder: (context) => const _GitHubTokenDialog(),
    );
    if (token == null || token.trim().isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _githubError = null;
    });
    try {
      final result = await _request(
        'POST',
        '/api/git/github/auth',
        body: {'token': token.trim()},
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

  Future<void> _perform(String label, String path, {Object? body}) async {
    final project = _projectPath;
    if (project == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final payload = <String, dynamic>{'project': project};
      if (body is Map<String, dynamic>) payload.addAll(body);
      final result = await _request('POST', path, body: payload);
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
                    _BranchCard(status: status),
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
                  ],
                ],
              ),
      ),
    );
  }
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
    required this.onConnect,
    required this.onDisconnect,
  });

  final _GitHubAccount? account;
  final bool loading;
  final bool busy;
  final String? error;
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
                          ? 'Connect to use GitHub HTTPS remotes'
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
                  onPressed: busy ? null : onConnect,
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

class _GitHubTokenDialog extends StatefulWidget {
  const _GitHubTokenDialog();

  @override
  State<_GitHubTokenDialog> createState() => _GitHubTokenDialogState();
}

class _GitHubTokenDialogState extends State<_GitHubTokenDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connect GitHub'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Create a fine-grained personal access token for the repositories '
            'you need. Grant Contents: Read and write, then paste it below. '
            'Use an HTTPS GitHub remote; SSH remotes do not use this token.',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => BridgeChannel().openUrl(
                'https://github.com/settings/personal-access-tokens/new',
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Create token on GitHub'),
            ),
          ),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Personal access token',
              hintText: 'github_pat_…',
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'The token is saved in Debian proot with owner-only file '
            'permissions. It is not added to the remote URL.',
            style: TextStyle(fontSize: 12, color: AppTheme.muted),
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
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('Connect'),
      ),
    ],
  );
}

class _BranchCard extends StatelessWidget {
  const _BranchCard({required this.status});

  final _GitStatus status;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: const Icon(Icons.account_tree_outlined, color: AppTheme.accent),
      title: Text(status.branch),
      subtitle: Text(
        status.tracking.isNotEmpty
            ? '${status.tracking}  •  ${status.ahead} ahead, ${status.behind} behind'
            : 'Current branch',
      ),
    ),
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
    required this.staged,
    required this.unstaged,
    required this.untracked,
  });

  final bool isGitRepo;
  final String branch;
  final String tracking;
  final int ahead;
  final int behind;
  final List<_GitFile> staged;
  final List<_GitFile> unstaged;
  final List<_GitFile> untracked;

  factory _GitStatus.fromJson(Map<String, dynamic> json) => _GitStatus(
    isGitRepo: json['isGitRepo'] == true,
    branch: json['branch']?.toString() ?? 'HEAD',
    tracking: json['tracking']?.toString() ?? '',
    ahead: _intValue(json['ahead']),
    behind: _intValue(json['behind']),
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

List<_GitFile> _files(Object? value, {bool staged = false}) => value is List
    ? value
          .whereType<Map>()
          .map((json) => _GitFile.fromJson(json, staged: staged))
          .toList()
    : const [];

int _intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class _GitException implements Exception {
  const _GitException(this.message);
  final String message;
  @override
  String toString() => message;
}
