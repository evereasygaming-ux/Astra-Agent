import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../core/constants/app_info.dart';
import '../agy/presentation/agy_controller.dart';
import '../bridge/domain/bridge_config.dart';
import '../bridge/domain/bridge_status.dart';
import '../bridge/presentation/bridge_controller.dart';
import '../termux/termux_controller.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      final config = await ref.read(bridgeConfigProvider.future);
      if (!mounted) {
        return;
      }
      if (config.isExternal) {
        await ref.read(bridgeControllerProvider.notifier).refresh();
        return;
      }
      final status = ref.read(bridgeControllerProvider);
      if (status.phase == BridgePhase.stopped) {
        ref.read(bridgeControllerProvider.notifier).start();
      }
    });
  }

  void _comingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature is coming in the next phase')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bridge = ref.watch(bridgeControllerProvider);
    final agy = ref.watch(agyControllerProvider);
    final config =
        ref.watch(bridgeConfigProvider).value ?? const BridgeConfig();
    final termux = ref.watch(termuxControllerProvider);
    final bridgeColor = switch (bridge.phase) {
      BridgePhase.running => AppTheme.accent,
      BridgePhase.error => Theme.of(context).colorScheme.error,
      _ => AppTheme.muted,
    };
    final agyValue = agy.hubOnline
        ? 'Online'
        : agy.loading
        ? 'Checking…'
        : agy.hub == null
        ? 'Unavailable'
        : agy.hub!.status;
    final agyColor = agy.hubOnline
        ? AppTheme.accent
        : agy.hub == null && !agy.loading
        ? Theme.of(context).colorScheme.error
        : AppTheme.muted;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            _Header(onSettings: () => context.push('/settings')),
            const SizedBox(height: 24),
            const _HeroCard(),
            if (config.isExternal && !bridge.isRunning) ...[
              const SizedBox(height: 16),
              _TermuxCard(
                termux: termux,
                onSetup: () => ref
                    .read(termuxControllerProvider.notifier)
                    .setupAndLaunch(),
                onLaunch: () =>
                    ref.read(termuxControllerProvider.notifier).launch(),
              ),
            ],
            const SizedBox(height: 24),
            _SectionTitle(title: 'Status'),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _StatusTile(
                    icon: Icons.smart_toy_outlined,
                    label: 'Antigravity',
                    value: agyValue,
                    color: agyColor,
                    onTap: () => context.push('/agy'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatusTile(
                    icon: Icons.hub_outlined,
                    label: config.isExternal ? 'Debian bridge' : 'Bridge',
                    value: bridge.label,
                    color: bridgeColor,
                    onTap: () => config.isExternal
                        ? ref.read(termuxControllerProvider.notifier).launch()
                        : ref.read(bridgeControllerProvider.notifier).toggle(),
                  ),
                ),
              ],
            ),
            if (bridge.error != null) ...[
              const SizedBox(height: 10),
              Text(
                bridge.error!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
            const SizedBox(height: 24),
            const _SectionTitle(title: 'Switch agent'),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.55,
              children: [
                _ActionCard(
                  icon: Icons.terminal,
                  title: 'Claude Code',
                  subtitle: 'CLI setup & account',
                  onTap: () => context.push('/claude'),
                ),
                _ActionCard(
                  icon: Icons.bolt_outlined,
                  title: 'Antigravity',
                  subtitle: agyValue,
                  onTap: () => context.push('/agy'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _SectionTitle(title: 'Workspace'),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.55,
              children: [
                _ActionCard(
                  icon: Icons.chat_bubble_outline,
                  title: 'Chat',
                  subtitle: 'Claude Code / Antigravity',
                  onTap: () => context.push('/chat'),
                ),
                _ActionCard(
                  icon: Icons.terminal,
                  title: 'Terminal',
                  subtitle: 'Antigravity terminal',
                  onTap: () => context.push('/terminal'),
                ),
                _ActionCard(
                  icon: Icons.code,
                  title: 'Editor',
                  subtitle: 'Project files',
                  onTap: () => context.push('/editor'),
                ),
                _ActionCard(
                  icon: Icons.account_tree_outlined,
                  title: 'Git',
                  subtitle: 'Changes & commits',
                  onTap: () => context.push('/git'),
                ),
                _ActionCard(
                  icon: Icons.public,
                  title: 'Browser',
                  subtitle: 'Localhost preview',
                  onTap: () => _comingSoon(context, 'Browser'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _SectionTitle(title: 'Roadmap'),
            const SizedBox(height: 12),
            _RoadmapCard(
              items: const [
                'Browser preview and MCP plugins',
              ],
            ),
            const SizedBox(height: 24),
            Center(
              child: Text(
                '${AppInfo.name} v${AppInfo.version}  •  ${AppInfo.packageId}',
                style: const TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onSettings});

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.accent, AppTheme.accentAlt],
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: const Text(
            'A',
            style: TextStyle(
              color: Color(0xFF07101A),
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppInfo.name,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
              Text(
                AppInfo.tagline,
                style: TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onSettings,
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }
}

class _TermuxCard extends StatelessWidget {
  const _TermuxCard({
    required this.termux,
    required this.onSetup,
    required this.onLaunch,
  });

  final TermuxState termux;
  final VoidCallback onSetup;
  final VoidCallback onLaunch;

  @override
  Widget build(BuildContext context) {
    final message =
        termux.error ??
        termux.message ??
        (termux.installed
            ? 'Debian is ready. Set up the bridge once, then launch it from here.'
            : 'Install Termux and Debian proot first.');
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal, color: AppTheme.accent),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Debian proot',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              if (termux.busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(
                  termux.ready ? 'Online' : 'Offline',
                  style: TextStyle(
                    color: termux.ready ? AppTheme.accent : AppTheme.muted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            message,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.muted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: termux.busy ? null : onSetup,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Set up & launch'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: termux.busy ? null : onLaunch,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Launch'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.accent.withValues(alpha: 0.18),
            AppTheme.accentAlt.withValues(alpha: 0.14),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              'PHASE 1 • BRIDGE',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w700,
                color: AppTheme.accent,
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Agentic coding,\nright on your phone.',
            style: TextStyle(
              fontSize: 26,
              height: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Chat with coding agents, run a real Linux shell, edit files '
            'and preview web apps without leaving Android.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.4,
        color: AppTheme.muted,
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(color: AppTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return tile;
    }
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: tile,
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppTheme.accent, size: 22),
              const Spacer(),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.muted, fontSize: 11),
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

class _RoadmapCard extends StatelessWidget {
  const _RoadmapCard({required this.items});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.accent.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                        color: AppTheme.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      items[i],
                      style: const TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
            if (i != items.length - 1)
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
          ],
        ],
      ),
    );
  }
}
