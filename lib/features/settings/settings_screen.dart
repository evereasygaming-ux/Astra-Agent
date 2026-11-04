import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../core/constants/app_info.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _notReady(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings become editable in Phase 1')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _Section(
            title: 'Agents',
            children: [
              _Tile(
                icon: Icons.smart_toy_outlined,
                title: 'Claude Code',
                subtitle: 'Stream-json agent over the local bridge',
                trailing: 'Not configured',
                onTap: () => _notReady(context),
              ),
              _Tile(
                icon: Icons.bolt_outlined,
                title: 'AGY',
                subtitle: 'gRPC language server agent',
                trailing: 'Not configured',
                onTap: () => _notReady(context),
              ),
            ],
          ),
          _Section(
            title: 'Bridge',
            children: const [
              _Tile(
                icon: Icons.lan_outlined,
                title: 'Host',
                subtitle: AppInfo.bridgeHost,
              ),
              _Tile(
                icon: Icons.settings_ethernet,
                title: 'Ports',
                subtitle:
                    'Bridge ${AppInfo.bridgePort}  •  Hub ${AppInfo.hubPort}',
              ),
              _Tile(
                icon: Icons.key_outlined,
                title: 'Access token',
                subtitle: 'Generated on first launch',
              ),
            ],
          ),
          _Section(
            title: 'Workspace',
            children: const [
              _Tile(
                icon: Icons.folder_outlined,
                title: 'Project root',
                subtitle: 'Not selected',
              ),
              _Tile(
                icon: Icons.storage_outlined,
                title: 'Linux environment',
                subtitle: 'Rootfs install comes in Phase 3',
              ),
            ],
          ),
          _Section(
            title: 'About',
            children: const [
              _Tile(
                icon: Icons.info_outline,
                title: 'Version',
                subtitle: '${AppInfo.version} (build 1)',
              ),
              _Tile(
                icon: Icons.android,
                title: 'Package',
                subtitle: AppInfo.packageId,
              ),
              _Tile(
                icon: Icons.shield_outlined,
                title: 'Android targets',
                subtitle:
                    'minSdk ${AppInfo.minSdk} • targetSdk '
                    '${AppInfo.targetSdk}',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.accentAlt.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppTheme.accentAlt.withValues(alpha: 0.25),
              ),
            ),
            child: const Text(
              'AstraAgent uses its own package id so it installs beside '
              'Termux. Google Play distribution is not planned while '
              'targetSdk stays at 28.',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w700,
                color: AppTheme.muted,
              ),
            ),
          ),
          Material(
            color: AppTheme.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1)
                    Divider(
                      height: 1,
                      indent: 56,
                      color: Colors.white.withValues(alpha: 0.06),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, size: 20),
      title: Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AppTheme.muted, fontSize: 12),
      ),
      trailing: trailing == null
          ? null
          : Text(
              trailing!,
              style: const TextStyle(color: AppTheme.muted, fontSize: 11),
            ),
    );
  }
}
