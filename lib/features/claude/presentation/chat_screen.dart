import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/app_panel.dart';
import '../../../app/theme/code_syntax.dart';
import '../../bridge/data/bridge_channel.dart';
import '../../bridge/presentation/bridge_controller.dart';
import '../../editor/workspace_folder_picker.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  final _prompt = TextEditingController();
  final _scroll = ScrollController();
  final List<_ChatMessage> _messages = [];
  final Map<int, _AgyInteraction> _agyInteractions = {};
  final List<_SavedConversation> _history = [];
  final BridgeChannel _historyChannel = BridgeChannel();
  late Future<void> _historyReady;
  List<_Workspace> _workspaces = [];
  List<_AgentModel> _models = [];
  final Map<int, String> _agyTextByStep = {};
  String? _workspace;
  String _agent = 'Antigravity';
  String? _selectedModel;
  String? _sessionId;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _historySaveTimer;
  Timer? _progressTimer;
  DateTime? _turnStartedAt;
  String _agentProgress = 'Starting Antigravity…';
  Duration _turnElapsed = Duration.zero;
  bool _loadingWorkspaces = true;
  bool _sending = false;
  bool _sawStreamText = false;
  bool _agyStarted = false;
  bool _loadingModels = false;
  int? _assistantDraftIndex;
  final Map<String, int> _toolMessageIndices = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadWorkspaces());
    _historyReady = _loadHistory();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    unawaited(_socket?.close());
    _historySaveTimer?.cancel();
    _progressTimer?.cancel();
    unawaited(_persistCurrentConversation());
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _flushHistorySave();
    }
  }

  Future<void> _loadWorkspaces() async {
    try {
      final bridge = ref.read(bridgeServiceProvider);
      final headers = await bridge.authHeaders();
      final response = await http
          .get(await bridge.resolve('/api/projects'), headers: headers)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
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
        final currentWorkspace = _workspace;
        _workspaces = found;
        if (currentWorkspace != null &&
            !found.any((item) => item.path == currentWorkspace)) {
          _workspaces.add(
            _Workspace(
              name: currentWorkspace.split('/').last,
              path: currentWorkspace,
            ),
          );
        }
        _workspace =
            currentWorkspace ?? (found.isEmpty ? null : found.first.path);
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

  Future<void> _rememberWorkspace(String path) async {
    try {
      final bridge = ref.read(bridgeServiceProvider);
      final existing = _workspaces.where((workspace) => workspace.path == path);
      final name = existing.isEmpty ? null : existing.first.name;
      final response = await http
          .post(
            await bridge.resolve('/api/projects/add'),
            headers: {
              ...await bridge.authHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'name':
                  name ?? path.split('/').where((part) => part.isNotEmpty).last,
              'path': path,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Workspace choice was not saved: $error');
      }
    }
  }

  Future<void> _addWorkspace() async {
    final bridge = ref.read(bridgeServiceProvider);
    final path = await showDialog<String>(
      context: context,
      builder: (context) =>
          WorkspaceFolderPicker(bridge: bridge, initialPath: _workspace),
    );
    if (path == null || !mounted) return;
    final name = path.split('/').where((part) => part.isNotEmpty).last;
    try {
      final response = await http
          .post(
            await bridge.resolve('/api/projects/add'),
            headers: {
              ...await bridge.authHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'name': name, 'path': path}),
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        final body = jsonDecode(response.body);
        final detail = body is Map ? body['error']?.toString() : null;
        throw HttpException(detail ?? 'HTTP ${response.statusCode}');
      }
      final body = jsonDecode(response.body);
      final resolvedPath = body is Map
          ? body['path']?.toString() ?? path
          : path;
      final resolvedName = body is Map
          ? body['name']?.toString() ?? name
          : name;
      final resolvedWorkspace = _Workspace(
        name: resolvedName,
        path: resolvedPath,
      );
      setState(() {
        _workspaces = [
          resolvedWorkspace,
          ..._workspaces.where((item) => item.path != resolvedPath),
        ];
        _workspace = resolvedPath;
        _error = null;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Workspace could not be added: $error');
      }
    }
  }

  Future<void> _openSetup() async {
    if (_sending || _sessionId != null) return;
    var selectedAgent = _agent;
    var selectedWorkspace = _workspace;
    var selectedModel = _selectedModel;
    var loadingModels = _loadingModels;

    final selection = await showModalBottomSheet<_ChatSetupSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> loadModels() async {
            if (loadingModels) return;
            setSheetState(() => loadingModels = true);
            await _loadModels();
            if (!sheetContext.mounted) return;
            setSheetState(() {
              loadingModels = false;
              selectedModel = _selectedModel;
            });
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              8,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Chat setup',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Choose the agent and workspace for this conversation.',
                    style: TextStyle(color: AppTheme.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: selectedAgent,
                    decoration: const InputDecoration(
                      labelText: 'Agent',
                      prefixIcon: Icon(Icons.auto_awesome_outlined),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'Claude Code',
                        child: Text('Claude Code'),
                      ),
                      DropdownMenuItem(
                        value: 'Antigravity',
                        child: Text('Antigravity'),
                      ),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      setSheetState(() {
                        selectedAgent = value;
                        selectedModel = value == 'Antigravity'
                            ? _selectedModel
                            : null;
                      });
                      if (value == 'Antigravity' && _models.isEmpty) {
                        await loadModels();
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  _loadingWorkspaces
                      ? const LinearProgressIndicator()
                      : DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: selectedWorkspace,
                          decoration: InputDecoration(
                            labelText: 'Workspace',
                            prefixIcon: const Icon(Icons.folder_open_outlined),
                            suffixIcon: IconButton(
                              tooltip: 'Add workspace folder',
                              onPressed: () async {
                                await _addWorkspace();
                                if (!sheetContext.mounted) return;
                                setSheetState(
                                  () => selectedWorkspace = _workspace,
                                );
                              },
                              icon: const Icon(
                                Icons.create_new_folder_outlined,
                              ),
                            ),
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
                          onChanged: (value) =>
                              setSheetState(() => selectedWorkspace = value),
                        ),
                  if (selectedAgent == 'Antigravity') ...[
                    const SizedBox(height: 12),
                    if (loadingModels || _loadingModels)
                      const LinearProgressIndicator()
                    else if (_models.isEmpty)
                      OutlinedButton.icon(
                        onPressed: loadModels,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Load Antigravity models'),
                      )
                    else
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue:
                            _models.any((model) => model.id == selectedModel)
                            ? selectedModel
                            : _models.first.id,
                        decoration: const InputDecoration(
                          labelText: 'Antigravity model',
                          prefixIcon: Icon(Icons.memory_outlined),
                        ),
                        items: _models
                            .map(
                              (model) => DropdownMenuItem(
                                value: model.id,
                                child: Text(
                                  model.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            setSheetState(() => selectedModel = value),
                      ),
                  ],
                  if (!ref.read(bridgeControllerProvider).isRunning) ...[
                    const SizedBox(height: 10),
                    const Text(
                      'Start the bridge from Home before chatting.',
                      style: TextStyle(color: AppTheme.muted, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed:
                          selectedWorkspace == null ||
                              (selectedAgent == 'Antigravity' &&
                                  selectedModel == null)
                          ? null
                          : () => Navigator.pop(
                              context,
                              _ChatSetupSelection(
                                agent: selectedAgent,
                                workspace: selectedWorkspace!,
                                model: selectedAgent == 'Antigravity'
                                    ? selectedModel
                                    : null,
                              ),
                            ),
                      icon: const Icon(Icons.check),
                      label: const Text('Apply setup'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (selection == null || !mounted) return;

    setState(() {
      _agent = selection.agent;
      _workspace = selection.workspace;
      _selectedModel = selection.model;
      if (selection.agent != 'Antigravity') _models = [];
      _error = null;
    });
    if (_agent == 'Antigravity' && _models.isEmpty) {
      unawaited(_loadModels());
    }
    await _rememberWorkspace(selection.workspace);
  }

  Future<void> _loadHistory() async {
    try {
      final decoded = jsonDecode(await _historyChannel.chatHistory());
      if (decoded is! List) return;
      final history =
          decoded
              .whereType<Map>()
              .map(
                (item) =>
                    _SavedConversation.fromMap(Map<String, dynamic>.from(item)),
              )
              .where(
                (item) =>
                    item.id.isNotEmpty &&
                    item.workspace.isNotEmpty &&
                    item.messages.isNotEmpty,
              )
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (!mounted) return;
      setState(() {
        _history
          ..clear()
          ..addAll(history);
      });
      if (history.isNotEmpty) {
        await _restoreConversation(history.first);
      } else if (_agent == 'Antigravity') {
        unawaited(_loadModels());
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Chat history could not load: $error');
      }
      if (_agent == 'Antigravity') unawaited(_loadModels());
    }
  }

  void _scheduleHistorySave() {
    if (_sessionId == null || _messages.isEmpty || _workspace == null) return;
    _historySaveTimer?.cancel();
    _historySaveTimer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_persistCurrentConversation()),
    );
  }

  void _flushHistorySave() {
    _historySaveTimer?.cancel();
    unawaited(_persistCurrentConversation());
  }

  Future<void> _persistCurrentConversation() async {
    await _historyReady;
    final id = _sessionId;
    if (id == null || _messages.isEmpty || _workspace == null) return;
    final firstPrompt = _messages.firstWhere(
      (message) => message.isUser,
      orElse: () => const _ChatMessage(text: 'New chat', isUser: true),
    );
    final rawTitle = firstPrompt.text.trim().replaceAll('\n', ' ');
    final item = _SavedConversation(
      id: id,
      title: String.fromCharCodes(rawTitle.runes.take(72)),
      agent: _agent,
      model: _selectedModel,
      workspace: _workspace!,
      updatedAt: DateTime.now(),
      messages: List<_ChatMessage>.unmodifiable(_messages),
    );
    final next = <_SavedConversation>[
      item,
      ..._history.where((saved) => saved.id != id),
    ];
    if (next.length > 50) next.removeRange(50, next.length);
    try {
      await _historyChannel.saveChatHistory(
        jsonEncode(next.map((conversation) => conversation.toMap()).toList()),
      );
      if (!mounted) return;
      setState(() {
        _history
          ..clear()
          ..addAll(next);
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Chat history could not be saved: $error');
      }
    }
  }

  Future<void> _showHistory() async {
    await _persistCurrentConversation();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.65,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Chat history',
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Saved on this device · tap a conversation to resume it',
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _history.isEmpty
                    ? const Center(child: Text('No saved conversations yet.'))
                    : ListView.builder(
                        itemCount: _history.length,
                        itemBuilder: (context, index) {
                          final item = _history[index];
                          return ListTile(
                            leading: const Icon(Icons.chat_bubble_outline),
                            title: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${item.agent} · ${item.messages.length} messages\n${_historyPreview(item)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              unawaited(_restoreConversation(item));
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

  String _historyPreview(_SavedConversation item) {
    final last = item.messages.last.text.trim().replaceAll('\n', ' ');
    return last.isEmpty ? item.workspace : last;
  }

  Future<void> _restoreConversation(_SavedConversation item) async {
    _historySaveTimer?.cancel();
    await _subscription?.cancel();
    await _socket?.close();
    if (!mounted) return;
    setState(() {
      _subscription = null;
      _socket = null;
      _sessionId = item.id;
      _agent = item.agent;
      _workspace = item.workspace;
      if (!_workspaces.any((workspace) => workspace.path == item.workspace)) {
        _workspaces = [
          ..._workspaces,
          _Workspace(
            name: item.workspace.split('/').last,
            path: item.workspace,
          ),
        ];
      }
      _models = [];
      _selectedModel = null;
      _messages
        ..clear()
        ..addAll(item.messages);
      _agyInteractions.clear();
      _agyTextByStep.clear();
      _agyStarted = item.agent == 'Antigravity';
      _sending = false;
      _error = null;
    });
    if (item.agent == 'Antigravity') {
      await _loadModels();
      if (!mounted) return;
      if (_models.any((model) => model.id == item.model)) {
        setState(() => _selectedModel = item.model);
      }
    }
    _scrollToBottom();
  }

  Future<void> _loadModels() async {
    while (_loadingModels && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    if (!mounted) return;
    setState(() => _loadingModels = true);
    try {
      final bridge = ref.read(bridgeServiceProvider);
      final response = await http
          .get(
            await bridge.resolve('/api/models?agent=agy'),
            headers: await bridge.authHeaders(),
          )
          .timeout(const Duration(seconds: 25));
      final body = jsonDecode(response.body);
      if (response.statusCode != 200 || body is! Map<String, dynamic>) {
        final error = body is Map ? body['error']?.toString() : null;
        throw HttpException(error ?? 'HTTP ${response.statusCode}');
      }
      final available = (body['models'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (item) => _AgentModel(
              id: item['id']?.toString() ?? '',
              key: item['key']?.toString() ?? '',
              name:
                  item['displayName']?.toString() ??
                  item['id']?.toString() ??
                  '',
            ),
          )
          .where((model) => model.id.isNotEmpty && model.name.isNotEmpty)
          .toList();
      final defaultModel = body['defaultModel']?.toString();
      final defaults = available
          .where(
            (model) => model.id == defaultModel || model.key == defaultModel,
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _models = available;
        _selectedModel = defaults.isNotEmpty
            ? defaults.first.id
            : available.isNotEmpty
            ? available.first.id
            : null;
        _loadingModels = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        _error = 'Could not load Antigravity models: $error';
      });
    }
  }

  Future<void> _send() async {
    final text = _prompt.text.trim();
    if (text.isEmpty || _sending) return;
    if (_workspace == null) {
      setState(() => _error = 'Choose a workspace first.');
      return;
    }
    if (_agent == 'Antigravity' && _selectedModel == null) {
      setState(
        () => _error =
            'Antigravity models are not loaded. Refresh them and try again.',
      );
      return;
    }

    setState(() {
      _error = null;
      _sending = true;
      _sawStreamText = false;
      _agyTextByStep.clear();
      _messages.add(_ChatMessage(text: text, isUser: true));
      _messages.add(_ChatMessage(text: '', isUser: false));
      _assistantDraftIndex = _messages.length - 1;
      _toolMessageIndices.clear();
      _prompt.clear();
    });
    _agentProgress = 'Starting $_agent…';
    _startProgressTimer();
    _scrollToBottom();

    try {
      if (_socket == null) await _connect();
      final message = _agent == 'Claude Code'
          ? {
              'type': 'user',
              'message': {'role': 'user', 'content': text},
              'parent_tool_use_id': null,
              'session_id': _sessionId,
            }
          : {
              'type': 'send_prompt',
              'conversationId': _sessionId,
              'model': _selectedModel,
              'prompt': text,
              'workspaceDir': _workspace,
              'isNew': !_agyStarted,
            };
      _socket!.add(jsonEncode(message));
      _scheduleHistorySave();
    } catch (error) {
      _stopProgressTimer();
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Could not start $_agent session: $error';
        if (_messages.isNotEmpty &&
            !_messages.last.isUser &&
            _messages.last.text.isEmpty) {
          _messages.removeLast();
        }
      });
      _scheduleHistorySave();
    }
  }

  Future<void> _connect() async {
    final id = _sessionId ?? _newId();
    final bridge = ref.read(bridgeServiceProvider);
    final isClaude = _agent == 'Claude Code';
    final uri = await bridge
        .resolve(isClaude ? '/api/claude/session' : '/ws')
        .then(
          (value) => value.replace(
            scheme: value.scheme == 'https' ? 'wss' : 'ws',
            queryParameters: isClaude
                ? {'id': id, 'cwd': _workspace!, 'permission_mode': 'default'}
                : null,
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
        _stopProgressTimer();
        if (mounted) {
          setState(() {
            _sending = false;
            _error = 'Agent connection failed: $error';
          });
        }
        _socket = null;
      },
      onDone: () {
        _stopProgressTimer();
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
      if (data['type'] == 'error' || data['type'] == 'bridge_error') {
        setState(() {
          _sending = false;
          _error = data['error']?.toString();
        });
        _stopProgressTimer();
        _flushHistorySave();
        return;
      }
      if (data['type'] == 'done') {
        setState(() {
          _sending = false;
          _assistantDraftIndex = null;
        });
        _stopProgressTimer();
        _flushHistorySave();
        return;
      }
      if (data['type'] == 'interaction_resolved') {
        final index = (data['stepIndex'] as num?)?.toInt();
        if (index != null) setState(() => _agyInteractions.remove(index));
        return;
      }
      if (data['type'] == 'session_attached' && _agent == 'Antigravity') {
        _agyStarted = true;
        return;
      }
      if (data['type'] == 'agy_event') {
        _consumeAgyUpdate(data['data']);
        return;
      }
      if (data['type'] == 'bridge_state') {
        if (_sending && data['event'] == 'exit') {
          setState(() => _sending = false);
          _stopProgressTimer();
        }
        return;
      }
      if (data['type'] != 'bridge_line' ||
          data['data'] is! Map<String, dynamic>) {
        return;
      }
      final event = data['data'] as Map<String, dynamic>;
      final eventType = event['type']?.toString();
      if (eventType == 'assistant') _recordClaudeToolUses(event);
      if (eventType == 'user') _recordClaudeToolResults(event);
      final addition = _assistantText(event);
      if (eventType == 'result') {
        setState(() {
          _sending = false;
          final draftIndex = _assistantDraftIndex;
          if (!_sawStreamText &&
              addition.isNotEmpty &&
              draftIndex != null &&
              draftIndex < _messages.length) {
            _messages[draftIndex] = _messages[draftIndex].copyWith(
              text: addition,
            );
          }
          _assistantDraftIndex = null;
        });
        _stopProgressTimer();
        _flushHistorySave();
        _scrollToBottom();
        return;
      }
      if (addition.isEmpty) {
        if (eventType == 'assistant' || eventType == 'user') {
          _scheduleHistorySave();
          _scrollToBottom();
        }
        return;
      }
      setState(() {
        _agentProgress = 'Receiving response…';
        final draftIndex = _assistantDraftIndex;
        if (draftIndex != null && draftIndex < _messages.length) {
          if (eventType == 'stream_event') _sawStreamText = true;
          if (eventType == 'assistant' && _sawStreamText) return;
          _messages[draftIndex] = _messages[draftIndex].copyWith(
            text: _messages[draftIndex].text + addition,
          );
        }
      });
      _scheduleHistorySave();
      _scrollToBottom();
    } catch (_) {
      // Ignore non-JSON frames; the bridge protocol is newline-delimited JSON.
    }
  }

  void _startProgressTimer() {
    _progressTimer?.cancel();
    _turnStartedAt = DateTime.now();
    _turnElapsed = Duration.zero;
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_sending || _turnStartedAt == null) return;
      setState(() => _turnElapsed = DateTime.now().difference(_turnStartedAt!));
    });
  }

  void _stopProgressTimer() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _turnStartedAt = null;
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

  void _recordClaudeToolUses(Map<String, dynamic> event) {
    final message = event['message'];
    final content = message is Map ? message['content'] : null;
    if (content is! List) return;
    var changed = false;
    for (final part in content.whereType<Map>()) {
      if (part['type'] != 'tool_use') continue;
      final id = part['id']?.toString();
      if (id == null || _toolMessageIndices.containsKey(id)) continue;
      final input = part['input'];
      final inputMap = input is Map ? input : const {};
      final command =
          inputMap['command']?.toString() ??
          inputMap['cmd']?.toString() ??
          (input is String
              ? input
              : input == null
              ? ''
              : const JsonEncoder.withIndent('  ').convert(input));
      final index = _messages.length;
      _toolMessageIndices[id] = index;
      _messages.add(
        _ChatMessage(
          text: '',
          isUser: false,
          isTool: true,
          toolName: part['name']?.toString() ?? 'Tool',
          command: command,
          toolRunning: true,
        ),
      );
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  void _recordClaudeToolResults(Map<String, dynamic> event) {
    final message = event['message'];
    final content = message is Map ? message['content'] : null;
    if (content is! List) return;
    var changed = false;
    for (final part in content.whereType<Map>()) {
      if (part['type'] != 'tool_result') continue;
      final index = _toolMessageIndices[part['tool_use_id']?.toString()];
      if (index == null || index >= _messages.length) continue;
      final raw = part['content'];
      final output = raw is String
          ? raw
          : raw is List
          ? raw
                .whereType<Map>()
                .map((item) => item['text']?.toString() ?? '')
                .where((s) => s.isNotEmpty)
                .join('\n')
          : raw?.toString() ?? '';
      _messages[index] = _messages[index].copyWith(
        text: output,
        toolRunning: false,
        toolFailed: part['is_error'] == true,
      );
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  void _consumeAgyUpdate(Object? raw) {
    if (raw is! Map<String, dynamic>) return;
    final update = raw['update'];
    if (update is! Map<String, dynamic>) return;
    final trajectory = update['mainTrajectoryUpdate'];
    if (trajectory is! Map<String, dynamic>) return;
    final stepsUpdate = trajectory['stepsUpdate'];
    if (stepsUpdate is! Map<String, dynamic>) return;
    final steps = stepsUpdate['steps'];
    if (steps is! List) return;
    final indices = stepsUpdate['indices'];
    var interactionAdded = false;
    var progressChanged = false;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      if (step is! Map) continue;
      final metadata = step['metadata'];
      final source = metadata is Map
          ? metadata['sourceTrajectoryStepInfo']
          : null;
      final rawIndex = source is Map ? source['stepIndex'] : null;
      final index = rawIndex is num
          ? rawIndex.toInt()
          : indices is List && i < indices.length && indices[i] is num
          ? (indices[i] as num).toInt()
          : i;
      final requested = step['requestedInteraction'];
      if (requested is Map) {
        final type = requested['askQuestion'] is Map
            ? 'askQuestion'
            : requested['runCommand'] is Map
            ? 'runCommand'
            : requested['permission'] is Map
            ? 'permission'
            : requested['filePermission'] is Map
            ? 'filePermission'
            : requested['mcp'] is Map
            ? 'mcp'
            : requested['approvalInteraction'] is Map
            ? 'approvalInteraction'
            : requested['readUrlContent'] is Map
            ? 'readUrlContent'
            : requested['browserAction'] is Map
            ? 'browserAction'
            : null;
        final nextProgress = type == 'askQuestion'
            ? 'Waiting for your answer'
            : type != null
            ? 'Waiting for your approval'
            : null;
        if (nextProgress != null && nextProgress != _agentProgress) {
          _agentProgress = nextProgress;
          progressChanged = true;
        }
        if (type != null && !_agyInteractions.containsKey(index)) {
          final spec = requested[type];
          final questions = type == 'askQuestion' && spec is Map
              ? (spec['questions'] as List? ?? const [])
                    .whereType<Map>()
                    .map((q) => Map<String, dynamic>.from(q))
                    .toList()
              : const <Map<String, dynamic>>[];
          final trajectoryId = source is Map
              ? source['trajectoryId']?.toString() ?? ''
              : '';
          final label = type == 'askQuestion'
              ? 'Antigravity has a question'
              : _agyActionDescription(spec, type);
          _agyInteractions[index] = _AgyInteraction(
            stepIndex: index,
            trajectoryId: trajectoryId,
            type: type,
            label: label,
            target: spec is Map
                ? spec['absolutePathUri']?.toString() ?? ''
                : '',
            questions: questions,
          );
          interactionAdded = true;
        }
      } else {
        final nextProgress = _agyProgressForStep(step);
        if (nextProgress != null && nextProgress != _agentProgress) {
          _agentProgress = nextProgress;
          progressChanged = true;
        }
      }
      final planner = step['plannerResponse'];
      if (planner is Map) {
        final response = planner['response']?.toString() ?? '';
        if (response.isNotEmpty) _agyTextByStep[index] = response;
      }
      final activity = _agyStepOutput(step);
      if (activity != null) _agyTextByStep[index] = activity;
      final stepError = step['errorMessage'];
      if (stepError is Map) {
        final message = stepError['message']?.toString() ?? '';
        if (message.isNotEmpty) _agyTextByStep[index] = '⚠️ $message';
      }
    }
    final response = _agyTextByStep.keys.toList()..sort();
    final text = response.map((index) => _agyTextByStep[index]!).join('\n\n');
    if (text.isEmpty) {
      if (interactionAdded || progressChanged) setState(() {});
      return;
    }
    setState(() {
      final draftIndex = _assistantDraftIndex;
      if (draftIndex != null && draftIndex < _messages.length) {
        _messages[draftIndex] = _messages[draftIndex].copyWith(text: text);
      }
    });
    _scheduleHistorySave();
    _scrollToBottom();
  }

  String? _agyStepOutput(Map step) {
    String textValue(Object? value) => value?.toString().trim() ?? '';
    String? outputText(Map? value, Iterable<String> keys) {
      if (value == null) return null;
      for (final key in keys) {
        final text = textValue(value[key]);
        if (text.isNotEmpty) return text;
      }
      return null;
    }

    final commandStatus = step['commandStatus'];
    if (commandStatus is Map) {
      final output = outputText(commandStatus, [
        'combined',
        'stdout',
        'stderr',
        'delta',
      ]);
      if (output != null) {
        final status = textValue(commandStatus['status']);
        return 'Command output${status.isEmpty ? '' : ' · $status'}:\n${_limitAgyOutput(output)}';
      }
    }

    final runCommand = step['runCommand'];
    if (runCommand is Map) {
      final combined =
          runCommand['combinedOutput'] ?? runCommand['combinedOutputSnapshot'];
      final stdout = runCommand['stdoutOutput'] ?? runCommand['stdout'];
      final stderr = runCommand['stderrOutput'] ?? runCommand['stderr'];
      final stdoutText =
          outputText(stdout is Map ? stdout : null, ['full', 'truncated']) ??
          textValue(stdout);
      final stderrText =
          outputText(stderr is Map ? stderr : null, ['full', 'truncated']) ??
          textValue(stderr);
      final streamOutput = [
        stdoutText,
        stderrText,
      ].where((part) => part.isNotEmpty).join('\n');
      final output =
          outputText(combined is Map ? combined : null, [
            'full',
            'truncated',
          ]) ??
          (streamOutput.isEmpty ? null : streamOutput) ??
          outputText(runCommand, ['rawDebugOutput', 'sandboxErrors']);
      final command = textValue(
        runCommand['commandLine'] ?? runCommand['proposedCommandLine'],
      );
      if (output != null || command.isNotEmpty) {
        return [
          if (command.isNotEmpty) 'Command: $command',
          if (output != null) 'Output:\n${_limitAgyOutput(output)}',
        ].join('\n');
      }
    }

    final shellExec = step['shellExec'];
    if (shellExec is Map) {
      final command = textValue(shellExec['command']);
      final output = textValue(shellExec['output']);
      final error = textValue(shellExec['errorMessage']);
      if (command.isNotEmpty || output.isNotEmpty || error.isNotEmpty) {
        return [
          if (command.isNotEmpty) 'Command: $command',
          if (output.isNotEmpty) 'Output:\n${_limitAgyOutput(output)}',
          if (error.isNotEmpty) 'Error: $error',
        ].join('\n');
      }
    }

    final finish = step['finish'];
    if (finish is Map) {
      final output = textValue(finish['outputString']);
      if (output.isNotEmpty) return output;
    }

    final systemMessage = step['systemMessage'];
    if (systemMessage is Map) {
      final message = textValue(systemMessage['message']);
      if (message.isNotEmpty) return message;
    }

    final write = step['writeToFile'];
    if (write is Map) {
      final path = textValue(write['targetFileUri']);
      if (path.isNotEmpty) {
        return '${write['fileCreated'] == true ? 'Created' : 'Updated'} file: $path';
      }
    }
    final fileChange = step['fileChange'];
    if (fileChange is Map) {
      final path = textValue(fileChange['absolutePathUri']);
      if (path.isNotEmpty) return 'Changed file: $path';
    }
    return null;
  }

  String _limitAgyOutput(String output) {
    const maxChars = 4000;
    return output.length <= maxChars
        ? output
        : '${output.substring(0, maxChars)}\n… output shortened …';
  }

  String? _agyProgressForStep(Map step) {
    final type = step['type']?.toString() ?? '';
    if (type.contains('PLAN_INPUT')) return 'Planning the work…';
    if (type.contains('RUN_COMMAND') || type.contains('SHELL_EXEC')) {
      return 'Running a command…';
    }
    if (type.contains('WRITE_TO_FILE') ||
        type.contains('FILE_CHANGE') ||
        type.contains('CODE_ACTION')) {
      return 'Creating project files…';
    }
    if (type.contains('COMPILE')) return 'Building the project…';
    if (type.contains('GREP_SEARCH') ||
        type.contains('CODE_SEARCH') ||
        type.contains('SEARCH_WEB') ||
        type.contains('FIND')) {
      return 'Searching for information…';
    }
    if (type.contains('LIST_DIRECTORY') ||
        type.contains('VIEW_FILE') ||
        type.contains('READ_TERMINAL')) {
      return 'Inspecting the workspace…';
    }
    if (type.contains('PLANNER_RESPONSE')) return 'Writing a response…';
    if (type.contains('USER_INPUT')) return 'Planning the work…';
    return null;
  }

  String _elapsedLabel() {
    final seconds = _turnElapsed.inSeconds;
    if (seconds < 60) return '${seconds}s';
    return '${seconds ~/ 60}m ${seconds % 60}s';
  }

  String _agyActionDescription(Object? spec, String type) {
    if (spec is Map) {
      final resource = spec['resource'];
      final action = resource is Map ? resource['action']?.toString() : null;
      final target = resource is Map ? resource['target']?.toString() : null;
      final description = spec['actionDescription']?.toString();
      if (description != null && description.isNotEmpty) return description;
      final command = spec['proposedCommandLine']?.toString();
      if (command != null && command.isNotEmpty) return 'Run command: $command';
      final path = spec['absolutePathUri']?.toString();
      if (path != null && path.isNotEmpty) return 'Allow file access: $path';
      if (action != null && action.isNotEmpty) {
        return target == null || target.isEmpty ? action : '$action: $target';
      }
    }
    return 'Antigravity requests permission to continue ($type).';
  }

  void _resolveAgyInteraction(
    _AgyInteraction interaction, {
    required bool allow,
    List<Map<String, dynamic>> responses = const [],
  }) {
    final socket = _socket;
    if (socket == null) {
      setState(() => _error = 'Antigravity connection is not available.');
      return;
    }
    socket.add(
      jsonEncode({
        'type': 'resolve_interaction',
        'conversationId': _sessionId,
        'trajectoryId': interaction.trajectoryId,
        'stepIndex': interaction.stepIndex,
        'interactionType': interaction.type,
        'target': interaction.target,
        'allow': allow,
        'responses': responses,
      }),
    );
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
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _newChat() async {
    _historySaveTimer?.cancel();
    await _persistCurrentConversation();
    await _subscription?.cancel();
    await _socket?.close();
    if (!mounted) return;
    setState(() {
      _subscription = null;
      _socket = null;
      _sessionId = null;
      _messages.clear();
      _agyInteractions.clear();
      _agyTextByStep.clear();
      _agyStarted = false;
      _sending = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bridge = ref.watch(bridgeControllerProvider);
    return PopScope<Object?>(
      canPop: !_sending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sending) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Wait for the agent task to finish before leaving chat.',
              ),
            ),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Agent chat'),
          actions: [
            IconButton(
              tooltip: 'Chat history',
              onPressed: _sending ? null : _showHistory,
              icon: const Icon(Icons.history),
            ),
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
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: _ChatSetupCard(
                agent: _agent,
                workspace: _workspaces
                    .where((workspace) => workspace.path == _workspace)
                    .map((workspace) => workspace.name)
                    .firstOrNull,
                model: _models
                    .where((model) => model.id == _selectedModel)
                    .map((model) => model.name)
                    .firstOrNull,
                loading: _loadingWorkspaces || _loadingModels,
                locked: _sending || _sessionId != null,
                bridgeOnline: bridge.isRunning,
                onTap: _sending || _sessionId != null ? null : _openSetup,
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
              child: Column(
                children: [
                  Expanded(
                    child: _messages.isEmpty
                        ? const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.auto_awesome,
                                  size: 34,
                                  color: AppTheme.accentAlt,
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'Your next idea starts here',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                SizedBox(height: 5),
                                Text(
                                  'Choose a workspace and send your first prompt.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: AppTheme.muted),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(16),
                            itemCount:
                                _messages.length + _agyInteractions.length,
                            itemBuilder: (context, index) {
                              if (index < _messages.length) {
                                return _MessageBubble(
                                  message: _messages[index],
                                  agentName: _agent,
                                );
                              }
                              final interaction = _agyInteractions.values
                                  .elementAt(index - _messages.length);
                              return _AgyInteractionCard(
                                key: ValueKey(interaction.stepIndex),
                                interaction: interaction,
                                onApprove: (responses) =>
                                    _resolveAgyInteraction(
                                      interaction,
                                      allow: true,
                                      responses: responses,
                                    ),
                                onDeny: () => _resolveAgyInteraction(
                                  interaction,
                                  allow: false,
                                ),
                              );
                            },
                          ),
                  ),
                  if (_sending)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.surface,
                          border: Border.all(color: AppTheme.outline),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.auto_awesome,
                                  size: 16,
                                  color: AppTheme.accent,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _agentProgress,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.muted,
                                    ),
                                  ),
                                ),
                                Text(
                                  _elapsedLabel(),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.muted,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: const LinearProgressIndicator(
                                minHeight: 3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Container(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 6),
                decoration: const BoxDecoration(
                  color: AppTheme.surface,
                  border: Border(top: BorderSide(color: AppTheme.outline)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _prompt,
                        minLines: 1,
                        maxLines: MediaQuery.viewInsetsOf(context).bottom > 0
                            ? 3
                            : 5,
                        decoration: InputDecoration(
                          hintText: _agent == 'Antigravity'
                              ? 'Message Antigravity about this workspace'
                              : 'Ask Claude Code to work in this workspace',
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
      ),
    );
  }
}

class _ChatSetupCard extends StatelessWidget {
  const _ChatSetupCard({
    required this.agent,
    required this.workspace,
    required this.model,
    required this.loading,
    required this.locked,
    required this.bridgeOnline,
    required this.onTap,
  });

  final String agent;
  final String? workspace;
  final String? model;
  final bool loading;
  final bool locked;
  final bool bridgeOnline;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.accentAlt.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    agent == 'Antigravity'
                        ? Icons.auto_awesome
                        : Icons.terminal,
                    color: AppTheme.cyan,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$agent  ·  ${workspace ?? 'Choose workspace'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        loading
                            ? 'Loading setup…'
                            : !bridgeOnline
                            ? 'Bridge offline · start from Home'
                            : agent == 'Antigravity'
                            ? model ?? 'Choose an Antigravity model'
                            : locked
                            ? 'Active conversation'
                            : 'Tap to change agent, workspace, or model',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: !bridgeOnline
                              ? AppTheme.accent
                              : AppTheme.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  locked ? Icons.lock_outline : Icons.tune_rounded,
                  color: AppTheme.muted,
                  size: 19,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatSetupSelection {
  const _ChatSetupSelection({
    required this.agent,
    required this.workspace,
    this.model,
  });

  final String agent;
  final String workspace;
  final String? model;
}

class _Workspace {
  const _Workspace({required this.name, required this.path});
  final String name;
  final String path;
}

class _AgentModel {
  const _AgentModel({required this.id, required this.key, required this.name});
  final String id;
  final String key;
  final String name;
}

class _AgyInteraction {
  const _AgyInteraction({
    required this.stepIndex,
    required this.trajectoryId,
    required this.type,
    required this.label,
    required this.target,
    required this.questions,
  });

  final int stepIndex;
  final String trajectoryId;
  final String type;
  final String label;
  final String target;
  final List<Map<String, dynamic>> questions;
}

class _AgyInteractionCard extends StatefulWidget {
  const _AgyInteractionCard({
    super.key,
    required this.interaction,
    required this.onApprove,
    required this.onDeny,
  });

  final _AgyInteraction interaction;
  final ValueChanged<List<Map<String, dynamic>>> onApprove;
  final VoidCallback onDeny;

  @override
  State<_AgyInteractionCard> createState() => _AgyInteractionCardState();
}

class _AgyInteractionCardState extends State<_AgyInteractionCard> {
  late final List<TextEditingController> _answers;
  late final List<Set<String>> _selectedOptions;

  @override
  void initState() {
    super.initState();
    _answers = List.generate(
      widget.interaction.questions.length,
      (_) => TextEditingController(),
    );
    _selectedOptions = List.generate(
      widget.interaction.questions.length,
      (_) => <String>{},
    );
  }

  @override
  void dispose() {
    for (final controller in _answers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isQuestion = widget.interaction.type == 'askQuestion';
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.interaction.label, style: theme.textTheme.titleSmall),
            if (isQuestion && widget.interaction.questions.isNotEmpty) ...[
              const SizedBox(height: 10),
              for (var i = 0; i < widget.interaction.questions.length; i++) ...[
                Text(
                  widget.interaction.questions[i]['question']?.toString() ??
                      'Your answer',
                ),
                if (widget.interaction.questions[i]['options'] is List)
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final option
                          in widget.interaction.questions[i]['options'] as List)
                        if (option is Map && option['id'] != null)
                          FilterChip(
                            label: Text(
                              option['text']?.toString() ??
                                  option['id'].toString(),
                            ),
                            selected: _selectedOptions[i].contains(
                              option['id'].toString(),
                            ),
                            onSelected: (selected) => setState(() {
                              final id = option['id'].toString();
                              if (selected) {
                                if (widget
                                        .interaction
                                        .questions[i]['isMultiSelect'] !=
                                    true) {
                                  _selectedOptions[i].clear();
                                }
                                _selectedOptions[i].add(id);
                              } else {
                                _selectedOptions[i].remove(id);
                              }
                            }),
                          ),
                    ],
                  ),
                const SizedBox(height: 6),
                TextField(
                  controller: _answers[i],
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'Type your answer',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: widget.onDeny,
                  child: Text(isQuestion ? 'Skip' : 'Deny'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final responses = <Map<String, dynamic>>[];
                    for (
                      var i = 0;
                      i < widget.interaction.questions.length;
                      i++
                    ) {
                      final question = widget.interaction.questions[i];
                      responses.add({
                        'question': question['question']?.toString() ?? '',
                        'options': question['options'] is List
                            ? question['options']
                            : const [],
                        'isMultiSelect': question['isMultiSelect'] == true,
                        'selectedOptionIds': _selectedOptions[i].toList(),
                        'writeInResponse': _answers[i].text.trim(),
                      });
                    }
                    widget.onApprove(responses);
                  },
                  child: Text(isQuestion ? 'Send answer' : 'Approve once'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMessage {
  const _ChatMessage({
    required this.text,
    required this.isUser,
    this.isTool = false,
    this.toolName,
    this.command,
    this.toolRunning = false,
    this.toolFailed = false,
  });
  final String text;
  final bool isUser;
  final bool isTool;
  final String? toolName;
  final String? command;
  final bool toolRunning;
  final bool toolFailed;
  _ChatMessage copyWith({String? text, bool? toolRunning, bool? toolFailed}) =>
      _ChatMessage(
        text: text ?? this.text,
        isUser: isUser,
        isTool: isTool,
        toolName: toolName,
        command: command,
        toolRunning: toolRunning ?? this.toolRunning,
        toolFailed: toolFailed ?? this.toolFailed,
      );
}

class _SavedConversation {
  const _SavedConversation({
    required this.id,
    required this.title,
    required this.agent,
    required this.model,
    required this.workspace,
    required this.updatedAt,
    required this.messages,
  });

  final String id;
  final String title;
  final String agent;
  final String? model;
  final String workspace;
  final DateTime updatedAt;
  final List<_ChatMessage> messages;

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'agent': agent,
    'model': model,
    'workspace': workspace,
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages
        .map(
          (message) => {
            'text': message.text,
            'isUser': message.isUser,
            'isTool': message.isTool,
            'toolName': message.toolName,
            'command': message.command,
            'toolRunning': message.toolRunning,
            'toolFailed': message.toolFailed,
          },
        )
        .toList(),
  };

  factory _SavedConversation.fromMap(Map<String, dynamic> map) {
    final rawMessages = map['messages'];
    final messages = rawMessages is List
        ? rawMessages
              .whereType<Map>()
              .map(
                (message) => _ChatMessage(
                  text: message['text']?.toString() ?? '',
                  isUser: message['isUser'] == true,
                  isTool: message['isTool'] == true,
                  toolName: message['toolName']?.toString(),
                  command: message['command']?.toString(),
                  toolRunning: message['toolRunning'] == true,
                  toolFailed: message['toolFailed'] == true,
                ),
              )
              .toList()
        : <_ChatMessage>[];
    final rawUpdatedAt = DateTime.tryParse(map['updatedAt']?.toString() ?? '');
    return _SavedConversation(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? 'Saved chat',
      agent: map['agent']?.toString() ?? 'Claude Code',
      model: map['model']?.toString(),
      workspace: map['workspace']?.toString() ?? '',
      updatedAt: rawUpdatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      messages: messages,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.agentName});
  final _ChatMessage message;
  final String agentName;

  @override
  Widget build(BuildContext context) {
    if (!message.isUser && !message.isTool && message.text.isEmpty) {
      return const SizedBox.shrink();
    }
    if (message.isTool) return _ToolActivityCard(message: message);
    final isUser = message.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.9,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? AppTheme.accent.withValues(alpha: 0.12)
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          border: Border.all(
            color: (isUser ? AppTheme.accent : AppTheme.outline).withValues(
              alpha: isUser ? 0.27 : 1,
            ),
          ),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isUser
                      ? Icons.person_outline
                      : agentName == 'Antigravity'
                      ? Icons.auto_awesome
                      : Icons.code,
                  size: 15,
                  color: isUser ? AppTheme.accent : AppTheme.accentAlt,
                ),
                const SizedBox(width: 6),
                Text(
                  isUser ? 'You' : agentName,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            _AssistantBody(text: message.text),
          ],
        ),
      ),
    );
  }
}

class _ToolActivityCard extends StatelessWidget {
  const _ToolActivityCard({required this.message});
  final _ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final statusColor = message.toolFailed
        ? Colors.redAccent
        : message.toolRunning
        ? AppTheme.cyan
        : Colors.greenAccent;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: statusColor.withValues(alpha: .42)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal, size: 16, color: statusColor),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  message.toolName ?? 'Tool',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
              if (message.toolRunning)
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.7,
                    color: statusColor,
                  ),
                )
              else
                Icon(
                  message.toolFailed
                      ? Icons.error_outline
                      : Icons.check_circle_outline,
                  size: 15,
                  color: statusColor,
                ),
              const SizedBox(width: 5),
              Text(
                message.toolRunning
                    ? 'RUNNING'
                    : message.toolFailed
                    ? 'FAILED'
                    : 'DONE',
                style: TextStyle(
                  color: statusColor,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .5,
                ),
              ),
            ],
          ),
          if ((message.command ?? '').isNotEmpty) ...[
            const SizedBox(height: 9),
            _CodeBlock(code: message.command!, language: 'shell'),
          ],
          if (message.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            _CodeBlock(code: message.text, language: 'plain'),
          ],
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.language});
  final String code;
  final String language;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: const Color(0xFF10121A),
      borderRadius: BorderRadius.circular(9),
    ),
    child: SelectableText.rich(
      TextSpan(
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.5,
          color: CodeSyntax.foreground,
        ),
        children: CodeSyntax.spans(code, language: language),
      ),
    ),
  );
}

class _AssistantBody extends StatelessWidget {
  const _AssistantBody({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final matches = RegExp(
      r'(?:^|\n\n)Command: ([^\n]+)(?:\nOutput:\n([\s\S]*?))?(?=\n\nCommand: |$)',
    ).allMatches(text).toList();
    if (matches.isEmpty) return SelectableText(text);
    final children = <Widget>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        final prose = text.substring(cursor, match.start).trim();
        if (prose.isNotEmpty) {
          children.add(SelectableText(prose));
          children.add(const SizedBox(height: 8));
        }
      }
      children.add(_CodeBlock(code: match.group(1)!, language: 'shell'));
      final output = match.group(2)?.trim();
      if (output != null && output.isNotEmpty) {
        children.add(const SizedBox(height: 7));
        children.add(_CodeBlock(code: output, language: 'plain'));
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      final prose = text.substring(cursor).trim();
      if (prose.isNotEmpty) children.add(SelectableText(prose));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
