import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../app/theme/app_theme.dart';
import '../bridge/data/bridge_service.dart';
import '../bridge/presentation/bridge_controller.dart';

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  List<_Project> _projects = [];
  List<_FileEntry> _entries = [];
  String? _projectPath;
  String? _currentPath;
  String? _error;
  bool _loadingProjects = true;
  bool _loadingDirectory = false;
  int _directoryRequest = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProjects());
  }

  Future<void> _loadProjects() async {
    try {
      final bridge = ref.read(bridgeServiceProvider);
      final response = await http
          .get(
            await bridge.resolve('/api/projects'),
            headers: await bridge.authHeaders(),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw _EditorException(_responseError(response));
      }
      final decoded = jsonDecode(response.body);
      final raw = decoded is List
          ? decoded
          : decoded is Map<String, dynamic>
          ? decoded['projects'] as List? ?? const []
          : const [];
      final projects = raw
          .whereType<Map>()
          .map(_Project.fromJson)
          .where((project) => project.path.isNotEmpty)
          .toList();
      if (projects.isEmpty) {
        throw const _EditorException('No workspaces found on the bridge.');
      }
      if (!mounted) return;
      setState(() {
        _projects = projects;
        _projectPath = projects.first.path;
        _currentPath = projects.first.path;
        _loadingProjects = false;
      });
      await _loadDirectory(projects.first.path);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadingProjects = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _loadDirectory(String path) async {
    final request = ++_directoryRequest;
    setState(() {
      _currentPath = path;
      _loadingDirectory = true;
      _error = null;
    });
    try {
      final bridge = ref.read(bridgeServiceProvider);
      final uri = (await bridge.resolve('/api/fs/browse'))
          .replace(queryParameters: {'dir': path});
      final response = await http
          .get(uri, headers: await bridge.authHeaders())
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw _EditorException(_responseError(response));
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const _EditorException(
          'The bridge returned an invalid directory.',
        );
      }
      final items = (decoded['items'] as List? ?? const [])
          .whereType<Map>()
          .map(_FileEntry.fromJson)
          .toList();
      if (!mounted || request != _directoryRequest) return;
      setState(() {
        _entries = items;
        _currentPath = decoded['currentPath']?.toString() ?? path;
        _loadingDirectory = false;
      });
    } catch (error) {
      if (mounted && request == _directoryRequest) {
        setState(() {
          _loadingDirectory = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _selectProject(String? path) async {
    if (path == null) return;
    setState(() {
      _projectPath = path;
      _entries = [];
    });
    await _loadDirectory(path);
  }

  Future<void> _openFile(_FileEntry entry) async {
    final bridge = ref.read(bridgeServiceProvider);
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _TextFileEditor(
          bridge: bridge,
          path: entry.path,
          name: entry.name,
          fileSize: entry.size,
        ),
      ),
    );
    if (mounted) unawaited(_loadDirectory(_currentPath ?? _projectPath!));
  }

  String _responseError(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final message = decoded['error'] ?? decoded['message'];
        if (message != null) return 'HTTP ${response.statusCode}: $message';
      }
    } catch (_) {
      // Use the status code for non-JSON bridge responses.
    }
    return 'HTTP ${response.statusCode}';
  }

  @override
  Widget build(BuildContext context) {
    final projectPath = _projectPath;
    final currentPath = _currentPath;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Editor'),
        actions: [
          IconButton(
            tooltip: 'Refresh files',
            onPressed: currentPath == null || _loadingDirectory
                ? null
                : () => _loadDirectory(currentPath),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: projectPath,
                decoration: const InputDecoration(labelText: 'Workspace'),
                items: _projects
                    .map(
                      (project) => DropdownMenuItem(
                        value: project.path,
                        child: Text(
                          project.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _loadingProjects || _loadingDirectory
                    ? null
                    : _selectProject,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    tooltip: 'Up one folder',
                    onPressed:
                        currentPath == null ||
                            projectPath == null ||
                            currentPath == projectPath ||
                            _loadingDirectory
                        ? null
                        : () {
                            final parent = Uri.file(currentPath)
                                .resolve('..')
                                .toFilePath();
                            if (_isWithinProject(parent, projectPath)) {
                              unawaited(_loadDirectory(parent));
                            }
                          },
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  Expanded(
                    child: Text(
                      currentPath ?? 'Select a workspace',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.muted),
                    ),
                  ),
                ],
              ),
              if (_error != null)
                MaterialBanner(
                  content: Text(_error!),
                  actions: [
                    TextButton(
                      onPressed: currentPath == null
                          ? _loadProjects
                          : () => _loadDirectory(currentPath),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              const SizedBox(height: 4),
              Expanded(
                child: _loadingProjects || _loadingDirectory
                    ? const Center(child: CircularProgressIndicator())
                    : _entries.isEmpty
                    ? const Center(child: Text('This folder is empty.'))
                    : ListView.separated(
                        itemCount: _entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return ListTile(
                            leading: Icon(
                              entry.isDirectory
                                  ? Icons.folder_outlined
                                  : _fileIcon(entry.name),
                              color: entry.isDirectory ? AppTheme.accent : null,
                            ),
                            title: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: entry.isDirectory
                                ? null
                                : Text(_formatSize(entry.size)),
                            trailing: entry.isDirectory
                                ? const Icon(Icons.chevron_right)
                                : null,
                            onTap: () {
                              if (entry.isDirectory) {
                                unawaited(_loadDirectory(entry.path));
                              } else {
                                unawaited(_openFile(entry));
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isWithinProject(String path, String project) {
    final normalizedProject = project.endsWith('/')
        ? project.substring(0, project.length - 1)
        : project;
    return path == normalizedProject || path.startsWith('$normalizedProject/');
  }

  IconData _fileIcon(String name) {
    final extension = name.split('.').last.toLowerCase();
    return switch (extension) {
      'dart' ||
      'go' ||
      'java' ||
      'kt' ||
      'js' ||
      'ts' ||
      'py' ||
      'rs' ||
      'c' ||
      'h' => Icons.code,
      'md' ||
      'txt' ||
      'yaml' ||
      'yml' ||
      'json' ||
      'toml' ||
      'xml' => Icons.description_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  String _formatSize(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _TextFileEditor extends StatefulWidget {
  const _TextFileEditor({
    required this.bridge,
    required this.path,
    required this.name,
    required this.fileSize,
  });

  final BridgeService bridge;
  final String path;
  final String name;
  final int fileSize;

  @override
  State<_TextFileEditor> createState() => _TextFileEditorState();
}

class _TextFileEditorState extends State<_TextFileEditor> {
  static const _maxFileBytes = 2 * 1024 * 1024;
  final _controller = TextEditingController();
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  Future<void> _load() async {
    try {
      if (widget.fileSize > _maxFileBytes) {
        throw const _EditorException(
          'This MVP supports text files up to 2 MB.',
        );
      }
      final uri = (await widget.bridge.resolve('/api/file/read'))
          .replace(queryParameters: {'path': widget.path});
      final response = await http
          .get(uri, headers: await widget.bridge.authHeaders())
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw _EditorException(_responseError(response));
      }
      if (response.bodyBytes.length > _maxFileBytes) {
        throw const _EditorException(
          'This file is larger than the 2 MB limit.',
        );
      }
      if (response.headers['x-file-category'] == 'binary') {
        throw const _EditorException('Binary files cannot be edited as text.');
      }
      final content = utf8.decode(response.bodyBytes);
      if (!mounted) return;
      _controller.text = content;
      setState(() {
        _loading = false;
        _dirty = false;
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

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final response = await http
          .post(
            await widget.bridge.resolve('/api/file/save'),
            headers: {
              ...await widget.bridge.authHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'path': widget.path,
              'content': _controller.text,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw _EditorException(_responseError(response));
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
        throw const _EditorException('The bridge did not confirm the save.');
      }
      if (mounted) {
        setState(() {
          _dirty = false;
          _saving = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('File saved')));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard unsaved edits?'),
        content: const Text('Your changes have not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _dirty = false);
      Navigator.of(context).pop();
    }
  }

  String _responseError(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final message = decoded['error'] ?? decoded['message'];
        if (message != null) return 'HTTP ${response.statusCode}: $message';
      }
    } catch (_) {
      // Use the status code for non-JSON bridge responses.
    }
    return 'HTTP ${response.statusCode}';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _dirty) unawaited(_confirmDiscard());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                _dirty ? 'Unsaved changes' : widget.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: _dirty ? AppTheme.accent : AppTheme.muted,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Save file',
              onPressed: !_dirty || _saving || _loading ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _controller.text.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    if (_error != null)
                      MaterialBanner(
                        content: Text(_error!),
                        actions: [
                          TextButton(
                            onPressed: () => setState(() => _error = null),
                            child: const Text('Dismiss'),
                          ),
                        ],
                      ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        expands: true,
                        minLines: null,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        textAlignVertical: TextAlignVertical.top,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                          height: 1.45,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(16),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Project {
  const _Project(this.name, this.path);

  final String name;
  final String path;

  factory _Project.fromJson(Map value) => _Project(
    value['name']?.toString() ?? 'Workspace',
    value['path']?.toString() ?? '',
  );
}

class _FileEntry {
  const _FileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;

  factory _FileEntry.fromJson(Map value) => _FileEntry(
    name: value['name']?.toString() ?? '',
    path: value['path']?.toString() ?? '',
    isDirectory: value['isDir'] == true,
    size: int.tryParse(value['size']?.toString() ?? '') ?? 0,
  );
}

class _EditorException implements Exception {
  const _EditorException(this.message);

  final String message;

  @override
  String toString() => message;
}
