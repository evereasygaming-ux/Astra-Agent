import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../bridge/domain/bridge_config.dart';
import '../../bridge/presentation/bridge_controller.dart';
import 'agy_controller.dart';

class AgyScreen extends ConsumerStatefulWidget {
  const AgyScreen({super.key});

  @override
  ConsumerState<AgyScreen> createState() => _AgyScreenState();
}

class _AgyScreenState extends ConsumerState<AgyScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(agyControllerProvider.notifier).refresh();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(agyControllerProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final agy = ref.watch(agyControllerProvider);
    final bridge = ref.watch(bridgeControllerProvider);
    final config =
        ref.watch(bridgeConfigProvider).value ?? const BridgeConfig();
    final busy = agy.loading || agy.installing;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AGY'),
        actions: [
          IconButton(
            onPressed: agy.loading
                ? null
                : () => ref.read(agyControllerProvider.notifier).refresh(),
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
          if (config.isExternal)
            _TermuxPanel(config: config)
          else
            const _TermuxRequiredPanel(),
          const SizedBox(height: 16),
          _HubPanel(agy: agy, enabled: bridge.isRunning && !busy),
          if (agy.error != null) ...[
            const SizedBox(height: 16),
            _Panel(
              color: Theme.of(context).colorScheme.error
                  .withValues(alpha: 0.10),
              borderColor: Theme.of(context).colorScheme.error
                  .withValues(alpha: 0.25),
              child: Text(
                agy.error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ),
          ],
          const SizedBox(height: 20),
          const Text(
            'AGY is the Antigravity (Gemini) agent. In Termux mode it runs '
            'inside your Termux environment and Astra Code Agent talks to the '
            'bridge over localhost.',
            style: TextStyle(color: AppTheme.muted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _TermuxPanel extends StatelessWidget {
  const _TermuxPanel({required this.config});

  final BridgeConfig config;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.terminal, color: AppTheme.accent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Termux runtime',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              _Pill(text: 'Linked', color: AppTheme.accent),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'AGY is managed by Termux. Astra Code Agent only connects to the bridge '
            'at ${config.trimmedUrl}; sign-in and updates happen inside Debian proot.',
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          const _SetupSteps(),
        ],
      ),
    );
  }
}

class _TermuxRequiredPanel extends StatelessWidget {
  const _TermuxRequiredPanel();

  @override
  Widget build(BuildContext context) {
    return _Panel(
      color: AppTheme.accentAlt.withValues(alpha: 0.10),
      borderColor: AppTheme.accentAlt.withValues(alpha: 0.25),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.link_off, color: AppTheme.accentAlt),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Termux mode required',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'AGY cannot run inside the Astra Code Agent sandbox without a Linux '
            'environment. Switch Settings -> Bridge -> Mode to Termux and run '
            'the bridge from Termux.',
            style: TextStyle(fontSize: 12, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _SetupSteps extends StatelessWidget {
  const _SetupSteps();

  @override
  Widget build(BuildContext context) {
    const steps = [
      'Install Termux from F-Droid (not the Play Store build).',
      'Astra Code Agent -> Home -> Set up & launch.',
      'Allow the Termux run-command permission and "Allow external apps".',
      'Wait until the bridge shows Online, then sign in with Google.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Termux quick start',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        for (final step in steps)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SelectableText(
              '• $step',
              style: const TextStyle(
                color: AppTheme.muted,
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ),
      ],
    );
  }
}

class _HubPanel extends ConsumerWidget {
  const _HubPanel({required this.agy, required this.enabled});

  final AgyState agy;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hub = agy.hub;
    final online = hub?.online == true;
    final status = hub?.status ?? (agy.loading ? 'checking' : 'unavailable');

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_circle_outlined, color: AppTheme.accent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Account & hub',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              if (agy.loading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                _Pill(
                  text: online ? 'Online' : status,
                  color: online
                      ? AppTheme.accent
                      : status == 'unavailable'
                      ? Theme.of(context).colorScheme.error
                      : AppTheme.muted,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            online
                ? 'Hub is online. Sign-in is managed by Google.'
                : status == 'unavailable'
                ? 'Could not read the Hub status from the Debian bridge.'
                : 'The hub is $status. Start the bridge in Termux, then sign in.',
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          if (hub?.error != null && hub!.error!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              hub.error!,
              style: const TextStyle(color: AppTheme.muted, fontSize: 11),
            ),
          ],
          const SizedBox(height: 14),
          if (agy.loginUrl?.url != null && agy.loginUrl!.url!.isNotEmpty)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: enabled
                    ? () => ref
                          .read(agyControllerProvider.notifier)
                          .openLoginUrl()
                    : null,
                icon: const Icon(Icons.open_in_browser, size: 18),
                label: const Text('Open sign-in page'),
              ),
            ),
          if (agy.loginUrl?.url != null && agy.loginUrl!.url!.isNotEmpty)
            const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: enabled
                  ? () => ref.read(agyControllerProvider.notifier).startLogin()
                  : null,
              icon: const Icon(Icons.login, size: 18),
              label: const Text('Sign in with Google'),
            ),
          ),
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
