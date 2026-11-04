import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../bridge/presentation/bridge_controller.dart';
import '../domain/claude_models.dart';
import 'claude_controller.dart';

class ClaudeScreen extends ConsumerStatefulWidget {
  const ClaudeScreen({super.key});

  @override
  ConsumerState<ClaudeScreen> createState() => _ClaudeScreenState();
}

class _ClaudeScreenState extends ConsumerState<ClaudeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(claudeControllerProvider.notifier).refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final claude = ref.watch(claudeControllerProvider);
    final bridge = ref.watch(bridgeControllerProvider);
    final busy = claude.busy || claude.jobRunning || claude.loading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Claude Code'),
        actions: [
          IconButton(
            onPressed: claude.loading
                ? null
                : () => ref.read(claudeControllerProvider.notifier).refresh(),
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          if (!bridge.isRunning)
            _Panel(
              color: AppTheme.accentAlt.withValues(alpha: 0.10),
              borderColor: AppTheme.accentAlt.withValues(alpha: 0.25),
              child: Row(
                children: [
                  const Icon(Icons.hub_outlined, color: AppTheme.accentAlt),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'The local bridge is offline. Start it from Home first.',
                      style: TextStyle(fontSize: 13, height: 1.4),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(bridgeControllerProvider.notifier).toggle(),
                    child: const Text('Start'),
                  ),
                ],
              ),
            ),
          if (!bridge.isRunning) const SizedBox(height: 16),

          _CliPanel(claude: claude, enabled: bridge.isRunning && !busy),
          const SizedBox(height: 16),
          _AccountPanel(claude: claude, enabled: bridge.isRunning && !busy),

          if (claude.error != null) ...[
            const SizedBox(height: 16),
            _Panel(
              color: Theme.of(context).colorScheme.error
                  .withValues(alpha: 0.10),
              borderColor: Theme.of(context).colorScheme.error
                  .withValues(alpha: 0.25),
              child: Text(
                claude.error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
          ],

          if (claude.job != null) ...[
            const SizedBox(height: 16),
            _JobPanel(job: claude.job!),
          ],

          const SizedBox(height: 20),
          const Text(
            'Claude Code runs locally through the embedded Go bridge. '
            'The official CLI is started with the bundled glibc loader.',
            style: TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _CliPanel extends ConsumerWidget {
  const _CliPanel({required this.claude, required this.enabled});

  final ClaudeState claude;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = claude.status;
    final installed = status?.installed == true;
    final version = status?.version;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal, color: AppTheme.accent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'CLI runtime',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              if (claude.loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                _Pill(
                  text: installed ? 'Installed' : 'Not installed',
                  color: installed ? AppTheme.accent : AppTheme.muted,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            installed
                ? '${version ?? 'Claude Code'} • native binary'
                : status?.error ?? 'Install Claude Code to start chatting.',
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          if (status?.authError != null) ...[
            const SizedBox(height: 8),
            Text(
              status!.authError!,
              style: const TextStyle(color: AppTheme.muted, fontSize: 11),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: enabled
                  ? () {
                      final controller = ref.read(
                        claudeControllerProvider.notifier,
                      );
                      installed ? controller.update() : controller.install();
                    }
                  : null,
              icon: Icon(
                installed ? Icons.system_update_alt : Icons.download,
                size: 18,
              ),
              label: Text(installed ? 'Update CLI' : 'Install CLI'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountPanel extends ConsumerWidget {
  const _AccountPanel({required this.claude, required this.enabled});

  final ClaudeState claude;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = claude.status?.auth;
    final loggedIn = auth?.loggedIn == true;
    final plan = auth?.subscriptionType;
    final email = auth?.email;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.person_outline, color: AppTheme.accentAlt),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Account',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              _Pill(
                text: loggedIn ? 'Signed in' : 'Signed out',
                color: loggedIn ? AppTheme.accent : AppTheme.muted,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            loggedIn
                ? [
                    email,
                    plan,
                  ].whereType<String>().where((v) => v.isNotEmpty).join(' • ')
                : 'Sign in with a Claude subscription or Anthropic Console billing.',
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          if (loggedIn) ...[
            const SizedBox(height: 8),
            if (auth?.authMethod != null)
              Text(
                'Method: ${auth!.authMethod}',
                style: const TextStyle(color: AppTheme.muted, fontSize: 11),
              ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: loggedIn
                ? OutlinedButton.icon(
                    onPressed: enabled
                        ? () => ref
                              .read(claudeControllerProvider.notifier)
                              .logout()
                        : null,
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Sign out'),
                  )
                : FilledButton.icon(
                    onPressed: enabled
                        ? () => showModalBottomSheet<void>(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: AppTheme.surface,
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(24),
                              ),
                            ),
                            builder: (_) => const _LoginSheet(),
                          )
                        : null,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('Sign in to Claude'),
                  ),
          ),
        ],
      ),
    );
  }
}

class _JobPanel extends StatelessWidget {
  const _JobPanel({required this.job});

  final ClaudeJob job;

  @override
  Widget build(BuildContext context) {
    final failed = job.exitCode != null && job.exitCode != 0;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.downloading,
                color: failed
                    ? Theme.of(context).colorScheme.error
                    : AppTheme.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'CLI ${job.kind}${job.running ? ' running' : ' finished'}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (job.exitCode != null)
                _Pill(
                  text: 'exit ${job.exitCode}',
                  color: failed
                      ? Theme.of(context).colorScheme.error
                      : AppTheme.accent,
                ),
            ],
          ),
          if (job.running) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 3),
          ],
          if (job.log.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                _tail(job.log, 6000),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10.5,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _tail(String text, int max) {
    if (text.length <= max) {
      return text;
    }
    return '…${text.substring(text.length - max)}';
  }
}

class _LoginSheet extends ConsumerStatefulWidget {
  const _LoginSheet();

  @override
  ConsumerState<_LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends ConsumerState<_LoginSheet> {
  final TextEditingController _code = TextEditingController();
  bool _useCode = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<ClaudeState>(claudeControllerProvider, (previous, next) {
      if (previous?.login != null &&
          next.login == null &&
          next.error == null &&
          !next.busy) {
        Navigator.of(context).pop();
      }
    });

    final claude = ref.watch(claudeControllerProvider);
    final login = claude.login;
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 20 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Sign in to Claude Code',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: () {
                  ref.read(claudeControllerProvider.notifier).cancelLogin();
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (login == null) ...[
            const Text(
              'Choose how you pay for Claude. The browser opens after you continue.',
              style: TextStyle(
                color: AppTheme.muted,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: claude.busy
                    ? null
                    : () => ref
                          .read(claudeControllerProvider.notifier)
                          .startLogin('claudeai'),
                icon: const Icon(Icons.workspace_premium_outlined, size: 18),
                label: const Text('Claude subscription (Pro / Max)'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: claude.busy
                    ? null
                    : () => ref
                          .read(claudeControllerProvider.notifier)
                          .startLogin('console'),
                icon: const Icon(Icons.key_outlined, size: 18),
                label: const Text('Anthropic Console (API billing)'),
              ),
            ),
            if (claude.busy) ...[
              const SizedBox(height: 16),
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('Starting sign-in…', style: TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ] else ...[
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Waiting for approval in the browser…',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: login.automaticUrl == null
                    ? null
                    : () => ref
                          .read(claudeControllerProvider.notifier)
                          .openUrl(login.automaticUrl!),
                icon: const Icon(Icons.open_in_browser, size: 18),
                label: const Text('Open sign-in page again'),
              ),
            ),
            const SizedBox(height: 8),
            if (!_useCode)
              TextButton(
                onPressed: () => setState(() => _useCode = true),
                child: const Text('Browser cannot return? Sign in with a code'),
              )
            else ...[
              const Text(
                'After approving, Claude shows a code. Paste it here:',
                style: TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _code,
                maxLines: 1,
                decoration: const InputDecoration(
                  hintText: 'code#state',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  if (login.manualUrl != null)
                    TextButton(
                      onPressed: () => ref
                          .read(claudeControllerProvider.notifier)
                          .openUrl(login.manualUrl!),
                      child: const Text('Open code page'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: claude.busy
                        ? null
                        : () => ref
                              .read(claudeControllerProvider.notifier)
                              .submitCode(_code.text),
                    child: const Text('Submit code'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                ref.read(claudeControllerProvider.notifier).cancelLogin();
                Navigator.of(context).pop();
              },
              child: const Text('Cancel sign-in'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.color, this.borderColor});

  final Widget child;
  final Color? color;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color ?? AppTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: borderColor ?? Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: child,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
