import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/theme/app_theme.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  static const _startUrl = 'http://127.0.0.1:3000';

  final _address = TextEditingController(text: _startUrl);
  late final WebViewController _controller;
  String? _error;
  int _progress = 0;
  bool _loading = true;
  bool _ready = false;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _startedLoadingPage = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController();
    unawaited(_configureAndLoad());
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _configureAndLoad() async {
    await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
        onPageStarted: (url) {
          if (!mounted) return;
          setState(() {
            _startedLoadingPage = true;
            _loading = true;
            _error = null;
            _progress = 0;
            _address.text = url;
          });
        },
        onPageFinished: (url) {
          if (!mounted) return;
          setState(() {
            _address.text = url;
            _loading = false;
            _progress = 100;
          });
          unawaited(_updateNavigationState());
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == false || !mounted) return;
          setState(() {
            _loading = false;
            _error = error.description;
          });
        },
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
      ),
    );
    if (!mounted) return;
    setState(() => _ready = true);
    await _loadAddress(_startUrl);
  }

  Future<void> _loadAddress([String? rawAddress]) async {
    final raw = (rawAddress ?? _address.text).trim();
    if (raw.isEmpty) return;
    final candidate = raw.contains('://') ? raw : 'http://$raw';
    final uri = Uri.tryParse(candidate);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      setState(() => _error = 'Enter a valid http:// or https:// address.');
      return;
    }
    setState(() {
      _address.text = uri.toString();
      _error = null;
      _loading = true;
      _startedLoadingPage = true;
      _progress = 0;
    });
    try {
      await _controller.loadRequest(uri);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _updateNavigationState() async {
    final back = await _controller.canGoBack();
    final forward = await _controller.canGoForward();
    if (!mounted) return;
    setState(() {
      _canGoBack = back;
      _canGoForward = forward;
    });
  }

  Future<void> _goBack() async {
    if (!_canGoBack) return;
    await _controller.goBack();
    await _updateNavigationState();
  }

  Future<void> _goForward() async {
    if (!_canGoForward) return;
    await _controller.goForward();
    await _updateNavigationState();
  }

  Future<void> _reload() async {
    setState(() {
      _error = null;
      _loading = true;
      _progress = 0;
    });
    try {
      await _controller.reload();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Browser preview'),
      actions: [
        IconButton(
          tooltip: 'Back',
          onPressed: _canGoBack ? _goBack : null,
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          tooltip: 'Forward',
          onPressed: _canGoForward ? _goForward : null,
          icon: const Icon(Icons.arrow_forward),
        ),
        IconButton(
          tooltip: 'Reload',
          onPressed: _ready ? _reload : null,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _address,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      hintText: 'http://127.0.0.1:3000',
                      prefixIcon: Icon(Icons.link),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _loadAddress(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Open address',
                  onPressed: _ready ? () => _loadAddress() : null,
                  icon: const Icon(Icons.public),
                ),
              ],
            ),
          ),
          if (_loading)
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress / 100,
              minHeight: 2,
            )
          else
            const SizedBox(height: 2),
          if (_error != null)
            MaterialBanner(
              content: Text(
                'No web server responded at this address ($_error). Start the project server in Terminal, then reload. For a plain HTML folder, run: python3 -m http.server 3000',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                TextButton(
                  onPressed: () => context.push('/terminal'),
                  child: const Text('Open Terminal'),
                ),
                TextButton(onPressed: _reload, child: const Text('Retry')),
              ],
            ),
          Expanded(
            child: !_ready
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      WebViewWidget(controller: _controller),
                      if (!_startedLoadingPage && _error == null)
                        const Center(
                          child: Text(
                            'Enter a local preview URL above.\nExample: http://127.0.0.1:3000',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.muted),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}
