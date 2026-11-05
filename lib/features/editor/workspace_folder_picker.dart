import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../app/theme/app_theme.dart';
import '../bridge/data/bridge_service.dart';

class WorkspaceFolderPicker extends StatefulWidget {
  const WorkspaceFolderPicker({
    super.key,
    required this.bridge,
    this.initialPath,
  });

  final BridgeService bridge;
  final String? initialPath;

  @override
  State<WorkspaceFolderPicker> createState() => _WorkspaceFolderPickerState();
}

class _WorkspaceFolderPickerState extends State<WorkspaceFolderPicker> {
  String _currentPath = '';
  String _homePath = '';
  List<_DirectoryEntry> _directories = [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPath?.trim() ?? '';
    final start = initial.isEmpty
        ? ''
        : Uri.file(initial).resolve('..').toFilePath();
    _load(start);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = (await widget.bridge.resolve('/api/fs/browse'))
          .replace(queryParameters: path.isEmpty ? null : {'dir': path});
      final response = await http
          .get(uri, headers: await widget.bridge.authHeaders())
          .timeout(const Duration(seconds: 15));
      final decoded = jsonDecode(response.body);
      if (response.statusCode != 200 || decoded is! Map) {
        final detail = decoded is Map ? decoded['error']?.toString() : null;
        throw FormatException(detail ?? 'Could not browse this folder.');
      }
      final directories = (decoded['items'] as List? ?? const [])
          .whereType<Map>()
          .where((item) => item['isDir'] == true)
          .map(_DirectoryEntry.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _currentPath = decoded['currentPath']?.toString() ?? path;
        _homePath = decoded['homePath']?.toString() ?? _homePath;
        _directories = directories;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _goUp() {
    if (_currentPath.isEmpty || _currentPath == _homePath) return;
    final parent = Uri.file(_currentPath).resolve('..').toFilePath();
    unawaited(_load(parent));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Choose workspace folder'),
    content: SizedBox(
      width: 520,
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Parent folder',
                onPressed: _loading || _currentPath == _homePath ? null : _goUp,
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(
                child: Text(
                  _currentPath.isEmpty ? 'Loading home folder…' : _currentPath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppTheme.muted),
                ),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: () => _load(_currentPath),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _directories.isEmpty
                ? const Center(child: Text('No subfolders here.'))
                : ListView.builder(
                    itemCount: _directories.length,
                    itemBuilder: (context, index) {
                      final directory = _directories[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.folder_outlined,
                          color: AppTheme.accent,
                        ),
                        title: Text(
                          directory.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _load(directory.path),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _loading || _currentPath.isEmpty
                ? null
                : () => Navigator.pop(context, _currentPath),
            icon: const Icon(Icons.check),
            label: const Text('Use this folder'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
    ],
  );
}

class _DirectoryEntry {
  const _DirectoryEntry({required this.name, required this.path});

  final String name;
  final String path;

  factory _DirectoryEntry.fromJson(Map value) => _DirectoryEntry(
    name: value['name']?.toString() ?? '',
    path: value['path']?.toString() ?? '',
  );
}
