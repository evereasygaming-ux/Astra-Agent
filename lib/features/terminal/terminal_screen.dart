import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../app/theme/app_theme.dart';
import '../bridge/presentation/bridge_controller.dart';

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final _command = TextEditingController();
  final _scroll = ScrollController();
  final _output = StringBuffer();
  List<_Workspace> _workspaces = [];
  String? _workspace;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  String _status = 'Choose a workspace to connect';
  String? _error;
  bool _loading = true;
  bool _connected = false;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadWorkspaces());
  }

  @override
  void dispose() {
    unawaited(_closeTerminal());
    _command.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadWorkspaces() async {
    try {
      final bridge = ref.read(bridgeServiceProvider);
      final response = await http
          .get(
            await bridge.resolve('/api/projects'),
            headers: await bridge.authHeaders(),
          )
          .timeout(const Duration(seconds: 12));
      final body = response.body;
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}: $body');
      }
      final decoded = jsonDecode(body);
      final raw = decoded is List
          ? decoded
          : decoded is Map<String, dynamic>
          ? decoded['projects'] as List? ?? const []
          : const [];
      final items = raw.whereType<Map>().map(_Workspace.fromJson).toList();
      if (items.isEmpty) throw const FormatException('No workspaces found');
      if (!mounted) return;
      setState(() {
        _workspaces = items;
        _workspace = items.first.path;
        _loading = false;
      });
      await _connect();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load workspaces: $error';
        });
      }
    }
  }

  Future<void> _connect() async {
    final workspace = _workspace;
    if (workspace == null || _connecting) return;
    setState(() {
      _connecting = true;
      _connected = false;
      _error = null;
      _status = 'Connecting…';
    });
    try {
      await _closeTerminal();
      final bridge = ref.read(bridgeServiceProvider);
      final baseUri = await bridge.resolve('/terminal-ws');
      final uri = baseUri.replace(
        scheme: baseUri.scheme == 'https' ? 'wss' : 'ws',
      );
      final socket = await WebSocket.connect(
        uri.toString(),
        headers: await bridge.authHeaders(),
      ).timeout(const Duration(seconds: 20));
      _socket = socket;
      _subscription = socket.listen(
        _onFrame,
        onError: (Object error) {
          if (mounted) {
            setState(() {
              _connected = false;
              _error = 'Terminal connection failed: $error';
            });
          }
        },
        onDone: () {
          if (mounted) {
            setState(() {
              _connected = false;
              _status = 'Disconnected';
            });
          }
        },
      );
      socket.add(
        jsonEncode({'type': 'terminal_create', 'workspaceDir': workspace}),
      );
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not connect: $error');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _onFrame(dynamic frame) {
    try {
      final message = jsonDecode(frame as String);
      if (message is! Map<String, dynamic>) return;
      switch (message['type']) {
        case 'terminal_created':
          final terminal = message['terminal'];
          if (mounted) {
            setState(() {
              _connected = true;
              _status = terminal is Map
                  ? (terminal['title']?.toString() ?? 'Connected')
                  : 'Connected';
              _error = null;
            });
          }
          break;
        case 'terminal_output':
          final data = message['data'];
          if (data is Map && data['output'] is String) {
            final bytes = base64Decode(data['output'] as String);
            _output.write(utf8.decode(bytes, allowMalformed: true));
            if (mounted) {
              setState(() {});
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scroll.hasClients) {
                  _scroll.jumpTo(_scroll.position.maxScrollExtent);
                }
              });
            }
            final code = data['exitCode'];
            if (code is num && code != 0 && mounted) {
              setState(() => _status = 'Process exited ($code)');
            }
          }
          break;
        case 'terminal_error':
          if (mounted) {
            setState(
              () => _error = message['error']?.toString() ?? 'Terminal error',
            );
          }
          break;
        case 'terminal_exit':
          if (mounted) {
            setState(() {
              _connected = false;
              _status = 'Shell exited';
            });
          }
          break;
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Invalid terminal response: $error');
    }
  }

  void _sendCommand(String value) {
    final command = value.trimRight();
    if (!_connected || command.isEmpty) return;
    _socket?.add(jsonEncode({'type': 'terminal_input', 'input': '$command\n'}));
    _command.clear();
  }

  Future<void> _closeTerminal() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        socket.add(jsonEncode({'type': 'terminal_close'}));
      } catch (_) {}
    }
    await _subscription?.cancel();
    _subscription = null;
    await socket?.close();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal'),
        actions: [
          IconButton(
            tooltip: 'Reconnect',
            onPressed: _connecting || _loading ? null : _connect,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: _workspace,
                decoration: const InputDecoration(labelText: 'Workspace'),
                items: _workspaces
                    .map(
                      (item) => DropdownMenuItem(
                        value: item.path,
                        child: Text(item.name, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: _loading || _connecting
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _workspace = value);
                        unawaited(_connect());
                      },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    _connected ? Icons.circle : Icons.circle_outlined,
                    size: 12,
                    color: _connected ? AppTheme.accent : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _loading ? 'Loading workspaces…' : _status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xff101318),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: SelectableText(
                      _output.isEmpty
                          ? 'Terminal output will appear here.'
                          : _output.toString(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        color: Color(0xffd7e1ec),
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _command,
                      enabled: _connected,
                      onSubmitted: _sendCommand,
                      textInputAction: TextInputAction.send,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        hintText: 'Enter a shell command',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _connected
                        ? () => _sendCommand(_command.text)
                        : null,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Workspace {
  const _Workspace(this.name, this.path);

  final String name;
  final String path;

  factory _Workspace.fromJson(Map value) => _Workspace(
    value['name']?.toString() ?? 'Workspace',
    value['path']?.toString() ?? '',
  );
}
