import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/data/bridge_channel.dart';

Future<void> showLinuxTestDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _LinuxTestDialog(),
  );
}

class _LinuxTestDialog extends StatefulWidget {
  const _LinuxTestDialog();

  @override
  State<_LinuxTestDialog> createState() => _LinuxTestDialogState();
}

class _LinuxTestDialogState extends State<_LinuxTestDialog> {
  final _channel = BridgeChannel();
  Timer? _timer;
  Map<String, Object?> _status = const {};
  String _output = '';
  String _action = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_busy) {
        _refresh();
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final status = await _channel.linuxStatus();
      if (!mounted) {
        return;
      }
      setState(() {
        _status = status;
        if (!_busy && _output.isEmpty) {
          _output = (status['log'] as String?) ?? '';
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output = error.toString();
      });
    }
  }

  Future<void> _run(
    String label,
    Future<Map<String, Object?>> Function() action,
  ) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _action = label;
      _output = '';
    });
    try {
      final result = await action();
      if (!mounted) {
        return;
      }
      final output = result['output'] as String?;
      setState(() {
        _output = output != null && output.trim().isNotEmpty
            ? output
            : (result['log'] as String?) ?? '';
      });
      await _refresh();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output = '${error.toString()}\n\n${_status['log'] ?? ''}';
      });
      await _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _action = '';
        });
      }
    }
  }

  Future<void> _installLinux() {
    return _run('Installing Debian rootfs', _channel.linuxInstall);
  }

  Future<void> _installAgy() {
    return _run('Installing AGY CLI', _channel.linuxInstallAgy);
  }

  Future<void> _diagnostics() {
    return _run('Running diagnostics', () async {
      return _channel.linuxRun(
        'echo "--- system ---"; uname -a; '
        'cat /etc/os-release | head -4; '
        'echo "--- user ---"; id; '
        'echo "--- agy ---"; '
        'if [ -x /root/.local/bin/agy ]; then '
        '/root/.local/bin/agy --version; '
        'else echo "AGY is not installed"; fi',
        timeoutSeconds: 120,
      );
    });
  }

  Future<void> _startBridge() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _action = 'Starting Linux bridge';
      _output = '';
    });
    try {
      await _channel.stop();
      final token = await _channel.token();
      if (token.isEmpty) {
        throw StateError('Bridge token is unavailable');
      }
      final result = await _channel.linuxStartBridge(
        token: token,
        port: 1234,
        hubPort: 1235,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _output = (result['bridgeLog'] as String?) ??
            (result['log'] as String?) ??
            '';
      });
      await _refresh();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output = '${error.toString()}\n\n${_status['log'] ?? ''}';
      });
      await _refresh();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _action = '';
        });
      }
    }
  }

  Future<void> _stopBridge() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _action = 'Stopping Linux bridge';
    });
    try {
      await _channel.linuxStopBridge();
      await _refresh();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _output = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _action = '';
        });
      }
    }
  }

  String _text(String key) => _status[key]?.toString() ?? '';

  bool _flag(String key) => _status[key] == true;

  int _number(String key) {
    final value = _status[key];
    if (value is int) {
      return value;
    }
    return int.tryParse('$value') ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final installed = _flag('installed');
    final agyInstalled = _flag('agyInstalled');
    final bridgeRunning = _flag('bridgeRunning');
    final progress = _number('progress');
    final total = _number('total');
    final freeBytes = _number('freeBytes');
    final agySize = _number('agySize');
    final freeGb = freeBytes / (1024 * 1024 * 1024);
    final hasSpace = freeBytes > 1200 * 1024 * 1024;

    return AlertDialog(
      title: const Text('In-app Linux test'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Phase 0 validates proot, Debian, AGY, and the bridge inside '
                'Astra Code Agent. Keep the app open while installing.',
                style: TextStyle(fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 12),
              _StatusRow(
                label: 'Linux runtime',
                value: installed ? 'Ready' : 'Not installed',
                ok: installed,
              ),
              _StatusRow(
                label: 'AGY CLI',
                value: agyInstalled
                    ? '${_text('agyVersion')} • '
                          '${(agySize / (1024 * 1024)).round()} MB'
                    : 'Not installed',
                ok: agyInstalled,
              ),
              _StatusRow(
                label: 'Linux bridge',
                value: bridgeRunning
                    ? 'Running (pid ${_text('bridgePid')})'
                    : 'Stopped',
                ok: bridgeRunning,
              ),
              _StatusRow(
                label: 'Free space',
                value: '${freeGb.toStringAsFixed(1)} GB',
                ok: hasSpace,
              ),
              if (_busy) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: total > 0 ? (progress / total).clamp(0.0, 1.0) : null,
                ),
                const SizedBox(height: 4),
                Text(
                  '$_action...',
                  style: const TextStyle(fontSize: 11),
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: _busy ? null : _installLinux,
                    child: const Text('Install Linux'),
                  ),
                  FilledButton.tonal(
                    onPressed: _busy || !installed ? null : _installAgy,
                    child: const Text('Install AGY'),
                  ),
                  OutlinedButton(
                    onPressed: _busy || !installed ? null : _diagnostics,
                    child: const Text('Diagnostics'),
                  ),
                  OutlinedButton(
                    onPressed: _busy || !installed || !agyInstalled
                        ? null
                        : _startBridge,
                    child: const Text('Start Linux bridge'),
                  ),
                  OutlinedButton(
                    onPressed: _busy || !bridgeRunning ? null : _stopBridge,
                    child: const Text('Stop bridge'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Logs',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _output.isEmpty ? 'No logs yet.' : _output,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
    required this.ok,
  });

  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.radio_button_unchecked,
            size: 16,
            color: ok ? Colors.greenAccent : Colors.white54,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
