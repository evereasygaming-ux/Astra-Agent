import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../bridge/presentation/bridge_controller.dart';

class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key});

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Plugins & MCP'),
      bottom: TabBar(
        controller: _tabs,
        tabs: const [
          Tab(icon: Icon(Icons.extension_outlined), text: 'Plugins'),
          Tab(icon: Icon(Icons.hub_outlined), text: 'MCP servers'),
        ],
      ),
    ),
    body: TabBarView(
      controller: _tabs,
      children: const [_PluginList(), _McpConfigEditor()],
    ),
  );
}

class _PluginList extends ConsumerStatefulWidget {
  const _PluginList();

  @override
  ConsumerState<_PluginList> createState() => _PluginListState();
}

class _PluginListState extends ConsumerState<_PluginList> {
  List<_Plugin> _plugins = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _request(ref, 'GET', '/api/custom-plugins/');
      final body = _decode(response);
      final rows = body['plugins'];
      if (rows is! List) {
        throw Exception('Bridge returned an invalid plugin list');
      }
      if (!mounted) return;
      setState(() {
        _plugins = rows.whereType<Map>().map(_Plugin.fromJson).toList();
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

  Future<void> _setEnabled(_Plugin plugin, bool enabled) async {
    await _mutate(() async {
      await _request(ref, 'POST', '/api/custom-plugins/set-enabled', {
        'id': plugin.id,
        'enabled': enabled,
      });
    });
  }

  Future<void> _remove(_Plugin plugin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${plugin.name}?'),
        content: const Text('This removes the plugin folder from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _mutate(() async {
      await _request(ref, 'POST', '/api/custom-plugins/remove', {
        'id': plugin.id,
        'delete_data': false,
      });
    });
  }

  Future<void> _installFromGitHub() async {
    final repoController = TextEditingController(
      text: 'evereasygaming-ux/AstraAgent-Plugins',
    );
    final repo = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Install from GitHub'),
        content: TextField(
          controller: repoController,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Repository',
            hintText: 'evereasygaming-ux/AstraAgent-Plugins',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, repoController.text.trim()),
            child: const Text('Find plugins'),
          ),
        ],
      ),
    );
    repoController.dispose();
    if (repo == null || repo.isEmpty || !mounted) return;
    setState(() => _busy = true);
    try {
      final listing = _decode(
        await _request(ref, 'POST', '/api/custom-plugins/repo/list', {
          'repo': repo,
        }),
      );
      final rows = (listing['plugins'] as List? ?? const [])
          .whereType<Map>()
          .map(_RepoPlugin.fromJson)
          .toList();
      if (rows.isEmpty) {
        throw Exception('No installable plugins found in this repository');
      }
      if (!mounted) return;
      final selected = await showDialog<_RepoPlugin>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(listing['title']?.toString() ?? repo),
          children: rows
              .map(
                (item) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, item),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(item.name),
                    subtitle: Text(
                      '${item.description.isEmpty ? item.path : item.description}\n${item.version}',
                    ),
                    isThreeLine: item.description.isNotEmpty,
                  ),
                ),
              )
              .toList(),
        ),
      );
      if (selected == null || !mounted) return;
      final folderController = TextEditingController(
        text: _folderName(selected.name),
      );
      final folder = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Install ${selected.name}'),
          content: TextField(
            controller: folderController,
            decoration: const InputDecoration(labelText: 'Install folder'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, folderController.text.trim()),
              child: const Text('Install'),
            ),
          ],
        ),
      );
      folderController.dispose();
      if (folder == null || folder.isEmpty) return;
      await _request(ref, 'POST', '/api/custom-plugins/repo/install', {
        'repo': repo,
        'path': selected.path,
        'folder': folder,
      }).timeout(const Duration(minutes: 3));
      await _load();
      if (mounted) _message('Installed ${selected.name}');
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _mutate(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${_plugins.length} installed',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            IconButton(
              onPressed: _loading || _busy ? null : _load,
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : _installFromGitHub,
              icon: const Icon(Icons.download),
              label: const Text('GitHub'),
            ),
          ],
        ),
      ),
      if (_busy) const LinearProgressIndicator(),
      if (_loading)
        const Expanded(child: Center(child: CircularProgressIndicator()))
      else if (_error != null)
        Expanded(
          child: _EmptyState(
            message: _error!,
            action: 'Retry',
            onPressed: _load,
          ),
        )
      else if (_plugins.isEmpty)
        const Expanded(
          child: _EmptyState(
            message: 'No plugins installed yet. Install one from a public GitHub repository.',
          ),
        )
      else
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              itemCount: _plugins.length,
              itemBuilder: (context, index) {
                final plugin = _plugins[index];
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Icon(
                        plugin.enabled ? Icons.extension : Icons.extension_off,
                      ),
                    ),
                    title: Text(
                      plugin.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${plugin.id} • v${plugin.version}\n${plugin.toolCount} tools • ${plugin.skillCount} skills',
                    ),
                    isThreeLine: true,
                    trailing: PopupMenuButton<String>(
                      enabled: !_busy,
                      onSelected: (value) {
                        if (value == 'toggle') {
                          _setEnabled(plugin, !plugin.enabled);
                        }
                        if (value == 'remove') {
                          _remove(plugin);
                        }
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'toggle',
                          child: Text(plugin.enabled ? 'Disable' : 'Enable'),
                        ),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
    ],
  );
}

class _McpConfigEditor extends ConsumerStatefulWidget {
  const _McpConfigEditor();

  @override
  ConsumerState<_McpConfigEditor> createState() => _McpConfigEditorState();
}

class _McpConfigEditorState extends ConsumerState<_McpConfigEditor> {
  final _controller = TextEditingController();
  String? _path;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final body = _decode(await _request(ref, 'GET', '/api/mcp/config'));
      if (!mounted) return;
      _controller.text =
          body['content']?.toString() ?? '{\n  "mcpServers": {}\n}';
      setState(() {
        _path = body['path']?.toString();
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

  Future<void> _save() async {
    dynamic parsed;
    try {
      parsed = jsonDecode(_controller.text);
      if (parsed is! Map || parsed['mcpServers'] is! Map) {
        throw const FormatException(
          'Top-level JSON must include an "mcpServers" object.',
        );
      }
    } catch (error) {
      setState(() => _error = 'Invalid MCP config: $error');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final body = _decode(
        await _request(ref, 'POST', '/api/mcp/config', {
          'content': _controller.text,
        }),
      );
      if (!mounted) return;
      setState(() {
        _path = body['path']?.toString() ?? _path;
        _saving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('MCP configuration saved')));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Gemini MCP configuration',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (_path != null) ...[
            const SizedBox(height: 4),
            Text(
              _path!,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: TextField(
              controller: _controller,
              expands: true,
              minLines: null,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
                labelText: 'JSON config',
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _saving ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Reload'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? 'Saving' : 'Save config'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Plugin {
  const _Plugin({
    required this.id,
    required this.name,
    required this.version,
    required this.toolCount,
    required this.skillCount,
    required this.enabled,
  });
  final String id;
  final String name;
  final String version;
  final int toolCount;
  final int skillCount;
  final bool enabled;

  factory _Plugin.fromJson(Map value) => _Plugin(
    id: value['id']?.toString() ?? '',
    name: value['name']?.toString() ?? 'Plugin',
    version: value['version']?.toString() ?? '?',
    toolCount: _asInt(value['toolCount']),
    skillCount: _asInt(value['skillCount']),
    enabled: value['isEnabled'] == true,
  );
}

class _RepoPlugin {
  const _RepoPlugin({
    required this.path,
    required this.name,
    required this.description,
    required this.version,
  });
  final String path;
  final String name;
  final String description;
  final String version;

  factory _RepoPlugin.fromJson(Map value) => _RepoPlugin(
    path: value['path']?.toString() ?? '',
    name: value['name']?.toString() ?? value['id']?.toString() ?? 'Plugin',
    description: value['description']?.toString() ?? '',
    version: value['version']?.toString() ?? '?',
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message, this.action, this.onPressed});
  final String message;
  final String? action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.extension_outlined, size: 42),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onPressed, child: Text(action!)),
          ],
        ],
      ),
    ),
  );
}

Future<http.Response> _request(
  WidgetRef ref,
  String method,
  String path, [
  Map<String, Object?>? body,
]) async {
  final bridge = ref.read(bridgeServiceProvider);
  final uri = await bridge.resolve(path);
  final headers = await bridge.authHeaders();
  if (body != null) headers['content-type'] = 'application/json';
  final response = switch (method) {
    'GET' =>
      await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20)),
    'POST' =>
      await http
          .post(uri, headers: headers, body: jsonEncode(body ?? const {}))
          .timeout(const Duration(minutes: 3)),
    _ => throw StateError('Unsupported request method: $method'),
  };
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(_responseMessage(response));
  }
  return response;
}

Map<String, dynamic> _decode(http.Response response) {
  final decoded = jsonDecode(response.body);
  if (decoded is! Map<String, dynamic>) {
    throw Exception('Bridge returned an invalid response');
  }
  return decoded;
}

String _responseMessage(http.Response response) {
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      return decoded['error']?.toString() ??
          decoded['message']?.toString() ??
          'HTTP ${response.statusCode}';
    }
  } catch (_) {
    // Return status for non-JSON errors.
  }
  return 'Bridge returned HTTP ${response.statusCode}';
}

int _asInt(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

String _folderName(String value) {
  final result = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  return result.isEmpty
      ? 'plugin'
      : result.substring(0, result.length.clamp(0, 64));
}
