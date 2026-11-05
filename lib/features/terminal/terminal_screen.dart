import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:xterm/xterm.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/app_panel.dart';
import '../bridge/presentation/bridge_controller.dart';

const _astraTerminalTheme = TerminalTheme(
  cursor: AppTheme.cyan,
  selection: Color(0x88586BFF),
  foreground: Color(0xFFE2E4F0),
  background: Color(0xFF090A12),
  black: Color(0xFF090A12),
  red: Color(0xFFFF657A),
  green: Color(0xFF47D7A1),
  yellow: Color(0xFFFFD166),
  blue: Color(0xFF6D8BFF),
  magenta: Color(0xFFF12DFF),
  cyan: Color(0xFF20DFFF),
  white: Color(0xFFE2E4F0),
  brightBlack: Color(0xFF77788D),
  brightRed: Color(0xFFFF8292),
  brightGreen: Color(0xFF74E7B8),
  brightYellow: Color(0xFFFFDE91),
  brightBlue: Color(0xFF8BA2FF),
  brightMagenta: Color(0xFFF66BFF),
  brightCyan: Color(0xFF62E8FF),
  brightWhite: Colors.white,
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Colors.black,
);

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key, this.initialWorkspace, this.initialCommand});

  final String? initialWorkspace;
  final String? initialCommand;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  final _terminal = Terminal(maxLines: 10000);
  final _terminalController = TerminalController();
  List<_Workspace> _workspaces = [];
  String? _workspace;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  String _status = 'Choose a workspace to connect';
  String? _error;
  bool _loading = true;
  bool _connected = false;
  bool _connecting = false;
  bool _controlModifier = false;
  bool _startupPending = false;
  int _terminalColumns = 80;
  int _terminalRows = 24;
  Timer? _resizeTimer;

  @override
  void initState() {
    super.initState();
    _startupPending = widget.initialCommand != null;
    _terminal.onOutput = _sendInput;
    _terminal.onResize = (columns, rows, _, _) {
      _terminalColumns = columns;
      _terminalRows = rows;
      _resizeTimer?.cancel();
      _resizeTimer = Timer(const Duration(milliseconds: 100), _sendResize);
    };
    unawaited(_loadWorkspaces());
  }

  @override
  void dispose() {
    _resizeTimer?.cancel();
    unawaited(_closeTerminal());
    _terminalController.dispose();
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
      final preferred = widget.initialWorkspace;
      final selectedWorkspace = items.any((item) => item.path == preferred)
          ? preferred
          : items.first.path;
      setState(() {
        _workspaces = items;
        _workspace = selectedWorkspace;
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
          _sendResize();
          final startupCommand = widget.initialCommand;
          if (_startupPending && startupCommand != null) {
            _startupPending = false;
            _sendInput('$startupCommand\r');
          }
          break;
        case 'terminal_output':
          final data = message['data'];
          if (data is Map && data['output'] is String) {
            final bytes = base64Decode(data['output'] as String);
            _terminal.write(utf8.decode(bytes, allowMalformed: true));
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

  void _sendInput(String input) {
    if (!_connected || input.isEmpty) return;
    _socket?.add(jsonEncode({'type': 'terminal_input', 'input': input}));
  }

  void _sendResize() {
    if (!_connected || _terminalColumns < 1 || _terminalRows < 1) return;
    _socket?.add(
      jsonEncode({
        'type': 'terminal_resize',
        'cols': _terminalColumns,
        'rows': _terminalRows,
      }),
    );
  }

  void _sendKey(TerminalKey key, {bool ctrl = false}) {
    if (!_connected) return;
    _terminal.keyInput(key, ctrl: ctrl || _controlModifier);
    if (_controlModifier) setState(() => _controlModifier = false);
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
            tooltip: 'Open browser preview',
            onPressed: () => context.push('/browser'),
            icon: const Icon(Icons.public),
          ),
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
              AppPanel(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _workspace,
                      decoration: const InputDecoration(
                        labelText: 'Workspace',
                        prefixIcon: Icon(Icons.folder_open_outlined),
                      ),
                      items: _workspaces
                          .map(
                            (item) => DropdownMenuItem(
                              value: item.path,
                              child: Text(
                                item.name,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          _connected
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          size: 16,
                          color: _connected ? AppTheme.cyan : AppTheme.muted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _loading ? 'Loading workspaces…' : _status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Text(
                          _connected ? 'LIVE' : 'PTY',
                          style: TextStyle(
                            color: _connected
                                ? AppTheme.cyan
                                : AppTheme.accentAlt,
                            fontSize: 10,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
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
              SizedBox(
                height: 38,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _terminalKeyButton('Esc', TerminalKey.escape),
                      _terminalKeyButton('Tab', TerminalKey.tab),
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: OutlinedButton(
                          onPressed: _connected
                              ? () => setState(
                                  () => _controlModifier = !_controlModifier,
                                )
                              : null,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 34),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            backgroundColor: _controlModifier
                                ? AppTheme.accent.withValues(alpha: 0.2)
                                : null,
                          ),
                          child: const Text('Ctrl'),
                        ),
                      ),
                      _terminalKeyButton('↑', TerminalKey.arrowUp),
                      _terminalKeyButton('↓', TerminalKey.arrowDown),
                      _terminalKeyButton('←', TerminalKey.arrowLeft),
                      _terminalKeyButton('→', TerminalKey.arrowRight),
                      _terminalKeyButton('Enter', TerminalKey.enter),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF090A12),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppTheme.outline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      Container(
                        height: 38,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: const BoxDecoration(
                          color: AppTheme.surface,
                          border: Border(
                            bottom: BorderSide(color: AppTheme.outline),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.terminal,
                              size: 17,
                              color: AppTheme.cyan,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'TERMINAL',
                              style: TextStyle(
                                fontSize: 10,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '$_terminalColumns×$_terminalRows',
                              style: const TextStyle(
                                color: AppTheme.muted,
                                fontFamily: 'monospace',
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TerminalView(
                          _terminal,
                          controller: _terminalController,
                          autofocus: true,
                          theme: _astraTerminalTheme,
                          textStyle: const TerminalStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                          padding: const EdgeInsets.all(12),
                          keyboardAppearance: Brightness.dark,
                          onSecondaryTapDown: (details, offset) async {
                            final selection = _terminalController.selection;
                            if (selection != null) {
                              final text = _terminal.buffer.getText(selection);
                              _terminalController.clearSelection();
                              await Clipboard.setData(
                                ClipboardData(text: text),
                              );
                            } else {
                              final data = await Clipboard.getData(
                                'text/plain',
                              );
                              final text = data?.text;
                              if (text != null) _terminal.paste(text);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _terminalKeyButton(String label, TerminalKey key) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: OutlinedButton(
      onPressed: _connected ? () => _sendKey(key) : null,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(42, 34),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Text(label),
    ),
  );
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
