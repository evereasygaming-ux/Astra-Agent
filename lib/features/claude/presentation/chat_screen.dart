import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../app/theme/app_theme.dart';
import '../../bridge/data/bridge_service.dart';
import '../../bridge/presentation/bridge_controller.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _prompt = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatMessage> _messages = [];
  List<_Workspace> _workspaces = [];
  String? _workspace;
  String _agent = 'Claude Code';
  String? _sessionId;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  bool _loadingWorkspaces = true;
  bool _sending = false;
  bool _sawStreamText = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadWorkspaces());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_socket?.close());
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadWorkspaces() async {
    try {
      final bridge = ref.read(bridgeServiceProvider);
      final headers = await bridge.authHeaders();
      final response = await http
          .get(await bridge.resolve('/api/projects'), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200)
        throw HttpException('HTTP ${response.statusCode}');
      final decoded = jsonDecode(response.body);
      final raw = decoded is List
          ? decoded
          : decoded is Map<String, dynamic>
          ? decoded['projects'] as List? ?? const []
          : const [];
      final found = raw
          .whereType<Map>()
          .map((item) {
            final path = item['path']?.toString() ?? '';
            final name = item['name']?.toString() ?? path;
            return _Workspace(name: name, path: path);
          })
          .where((item) => item.path.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _workspaces = found;
        _workspace = found.isEmpty ? null : found.first.path;
        _loadingWorkspaces = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingWorkspaces = false;
        _error = 'Workspace list could not load: $error';
      });
    }
  }

  Future<void> _send() async {
    final text = _prompt.text.trim();
    if (text.isEmpty || _sending) return;
    if (_agent != 'Claude Code') {
      setState(
        () => _error =
            'Antigravity chat is not connected in this bridge build yet.',
      );
      return;
    }
    if (_workspace == null) {
      setState(() => _error = 'Choose a workspace first.');
      return;
    }

    setState(() {
      _error = null;
      _sending = true;
      _sawStreamText = false;
      _messages.add(_ChatMessage(text: text, isUser: true));
      _messages.add(_ChatMessage(text: '', isUser: false));
      _prompt.clear();
    });
    _scrollToBottom();

    try {
      if (_socket == null) await _connect();
      final message = {
        'type': 'user',
        'message': {'role': 'user', 'content': text},
        'parent_tool_use_id': null,
        'session_id': _sessionId,
      };
      _socket!.add(jsonEncode(message));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Could not start Claude session: $error';
        if (_messages.isNotEmpty &&
            !_messages.last.isUser &&
            _messages.last.text.isEmpty) {
          _messages.removeLast();
        }
      });
    }
  }

  Future<void> _connect() async {
    final id = _sessionId ?? _newId();
    final bridge = ref.read(bridgeServiceProvider);
    final uri = await bridge
        .resolve('/api/claude/session')
        .then(
          (value) => value.replace(
            scheme: value.scheme == 'https' ? 'wss' : 'ws',
            queryParameters: {
              'id': id,
              'cwd': _workspace!,
              'permission_mode': 'default',
            },
          ),
        );
    final socket = await WebSocket.connect(
      uri.toString(),
      headers: await bridge.authHeaders(),
    );
    _sessionId = id;
    _socket = socket;
    _subscription = socket.listen(
      _onFrame,
      onError: (Object error) {
        if (mounted)
          setState(() {
            _sending = false;
            _error = 'Claude connection failed: $error';
          });
        _socket = null;
      },
      onDone: () {
        if (mounted) setState(() => _sending = false);
        _socket = null;
      },
    );
  }

  void _onFrame(dynamic frame) {
    if (!mounted) return;
    try {
      final data = jsonDecode(frame as String);
      if (data is! Map<String, dynamic>) return;
      if (data['type'] == 'bridge_error') {
        setState(() {
          _sending = false;
          _error = data['error']?.toString();
        });
        return;
      }
      if (data['type'] == 'bridge_state') {
        if (_sending && data['event'] == 'exit') {
          setState(() => _sending = false);
        }
        return;
      }
      if (data['type'] != 'bridge_line' ||
          data['data'] is! Map<String, dynamic>)
        return;
      final event = data['data'] as Map<String, dynamic>;
      final eventType = event['type']?.toString();
      final addition = _assistantText(event);
      if (eventType == 'result') {
        setState(() {
          _sending = false;
          if (!_sawStreamText &&
              _messages.isNotEmpty &&
              !_messages.last.isUser &&
              _messages.last.text.isEmpty) {
            _messages[_messages.length - 1] = _messages.last.copyWith(
              text: addition,
            );
          }
        });
        _scrollToBottom();
        return;
      }
      if (addition.isEmpty) return;
      setState(() {
        if (_messages.isNotEmpty && !_messages.last.isUser) {
          if (eventType == 'stream_event') _sawStreamText = true;
          if (eventType == 'assistant' && _sawStreamText) return;
          _messages[_messages.length - 1] = _messages.last.copyWith(
            text: _messages.last.text + addition,
          );
        }
      });
      _scrollToBottom();
    } catch (_) {
      // Ignore non-JSON frames; the bridge protocol is newline-delimited JSON.
    }
  }

  String _assistantText(Map<String, dynamic> event) {
    final type = event['type']?.toString();
    if (type == 'assistant') {
      final message = event['message'];
      final content = message is Map ? message['content'] : null;
      if (content is List) {
        return content
            .whereType<Map>()
            .where((part) => part['type'] == 'text')
            .map((part) => part['text']?.toString() ?? '')
            .join();
      }
    }
    if (type == 'stream_event') {
      final inner = event['event'];
      if (inner is Map && inner['type'] == 'content_block_delta') {
        final delta = inner['delta'];
        return delta is Map && delta['type'] == 'text_delta'
            ? delta['text']?.toString() ?? ''
            : '';
      }
    }
    if (type == 'result') return event['result']?.toString() ?? '';
    return '';
  }

  String _newId() {
    final random = Random.secure();
    String part(int count) => List.generate(
      count,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    return '${part(8)}-${part(4)}-4${part(3)}-${(8 + random.nextInt(4)).toRadixString(16)}${part(3)}-${part(12)}';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients)
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
    });
  }

  Future<void> _newChat() async {
    await _subscription?.cancel();
    await _socket?.close();
    if (!mounted) return;
    setState(() {
      _subscription = null;
      _socket = null;
      _sessionId = null;
      _messages.clear();
      _sending = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bridge = ref.watch(bridgeControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent chat'),
        actions: [
          IconButton(
            tooltip: 'New chat',
            onPressed: _sessionId == null || _sending ? null : _newChat,
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _agent,
                        decoration: const InputDecoration(
                          labelText: 'Agent',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'Claude Code',
                            child: Text('Claude Code'),
                          ),
                          DropdownMenuItem(
                            value: 'Antigravity',
                            child: Text('Antigravity · unavailable'),
                          ),
                        ],
                        onChanged: _sending || _sessionId != null
                            ? null
                            : (value) => setState(() {
                                _agent = value ?? 'Claude Code';
                                _error = null;
                              }),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _loadingWorkspaces
                          ? const LinearProgressIndicator()
                          : DropdownButtonFormField<String>(
                              value: _workspace,
                              decoration: const InputDecoration(
                                labelText: 'Workspace',
                                border: OutlineInputBorder(),
                                isDense: true,
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
                              onChanged: _sending || _sessionId != null
                                  ? null
                                  : (value) =>
                                        setState(() => _workspace = value),
                            ),
                    ),
                  ],
                ),
                if (!bridge.isRunning || _agent == 'Antigravity')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _agent == 'Antigravity'
                          ? 'AGY Hub is online, but prompt sending is not implemented in the bridge yet.'
                          : 'Start the bridge from Home before chatting.',
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Choose a workspace and send your first prompt.',
                      style: TextStyle(color: AppTheme.muted),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) =>
                        _MessageBubble(message: _messages[index]),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _prompt,
                      minLines: 1,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        hintText: 'Ask Claude to work in this workspace',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending || !bridge.isRunning ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Workspace {
  const _Workspace({required this.name, required this.path});
  final String name;
  final String path;
}

class _ChatMessage {
  const _ChatMessage({required this.text, required this.isUser});
  final String text;
  final bool isUser;
  _ChatMessage copyWith({String? text}) =>
      _ChatMessage(text: text ?? this.text, isUser: isUser);
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message});
  final _ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final color = message.isUser
        ? AppTheme.accent.withValues(alpha: 0.15)
        : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.88,
        ),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
        ),
        child: message.text.isEmpty && !message.isUser
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : SelectableText(message.text),
      ),
    );
  }
}
