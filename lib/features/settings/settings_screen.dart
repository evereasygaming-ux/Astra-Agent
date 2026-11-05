import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/app_theme.dart';
import '../../core/constants/app_info.dart';
import '../bridge/data/bridge_channel.dart';
import '../bridge/domain/bridge_config.dart';
import '../bridge/presentation/bridge_controller.dart';
import '../termux/termux_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _showBridgeLogs(BuildContext context, WidgetRef ref) async {
    await ref.read(bridgeControllerProvider.notifier).refresh();
    if (!context.mounted) {
      return;
    }
    final log = ref.read(bridgeControllerProvider).log;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bridge logs'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: SingleChildScrollView(
            child: SelectableText(
              log.isEmpty ? 'No logs yet.' : log,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveConfig(
    BuildContext context,
    WidgetRef ref,
    BridgeConfig previous,
    BridgeConfig config,
  ) async {
    final service = ref.read(bridgeServiceProvider);
    await service.stop();
    final saved = await ref.read(bridgeConfigStoreProvider).save(config);
    ref.invalidate(bridgeConfigProvider);
    await ref.read(bridgeControllerProvider.notifier).refresh();
    var message = 'Bridge settings saved';
    final shouldRestartTermux =
        previous.isExternal &&
        saved.isExternal &&
        saved.isLoopback &&
        (previous.token != saved.token || previous.port != saved.port);
    if (shouldRestartTermux) {
      final restarted = await ref
          .read(termuxControllerProvider.notifier)
          .applyBridgeConfig(saved);
      if (!restarted) {
        final error = ref.read(termuxControllerProvider).error;
        message =
            'Settings saved, but Debian bridge was not restarted. '
            '${error ?? 'Run Set up & launch in Debian proot automation.'}';
      }
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _editMode(
    BuildContext context,
    WidgetRef ref,
    BridgeConfig config,
  ) async {
    final mode = await showDialog<BridgeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Bridge mode'),
        children: [
          RadioGroup<BridgeMode>(
            groupValue: config.mode,
            onChanged: (value) => Navigator.of(context).pop(value),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                RadioListTile<BridgeMode>(
                  value: BridgeMode.embedded,
                  title: Text('Embedded'),
                  subtitle: Text('Bridge bundled inside Astra Code Agent'),
                ),
                RadioListTile<BridgeMode>(
                  value: BridgeMode.external,
                  title: Text('Debian proot (Termux)'),
                  subtitle: Text('Connect to the Debian bridge on localhost'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (mode == null || mode == config.mode || !context.mounted) {
      return;
    }
    await _saveConfig(context, ref, config, config.copyWith(mode: mode));
  }

  Future<void> _editUrl(
    BuildContext context,
    WidgetRef ref,
    BridgeConfig config,
  ) async {
    final controller = TextEditingController(text: config.trimmedUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bridge URL'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'http://127.0.0.1:1234'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.isEmpty) {
      return;
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.hasScheme) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter a full URL, e.g. http://127.0.0.1:1234'),
          ),
        );
      }
      return;
    }
    if (!context.mounted) {
      return;
    }
    await _saveConfig(context, ref, config, config.copyWith(url: url));
  }

  Future<void> _editToken(
    BuildContext context,
    WidgetRef ref,
    BridgeConfig config,
  ) async {
    final controller = TextEditingController(text: config.token);
    final token = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bridge token'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: '12 lowercase letters or digits',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (token == null) {
      return;
    }
    if (token.isNotEmpty && !BridgeConfig.isValidToken(token)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Token must be 12 lowercase letters or digits'),
          ),
        );
      }
      return;
    }
    if (!context.mounted) {
      return;
    }
    await _saveConfig(context, ref, config, config.copyWith(token: token));
  }

  Future<void> _testExternal(
    BuildContext context,
    WidgetRef ref,
    BridgeConfig config,
  ) async {
    try {
      final version = await ref.read(bridgeServiceProvider).testExternal();
      await ref.read(bridgeControllerProvider.notifier).refresh();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connected to ${config.trimmedUrl} ($version)')),
      );
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bridge = ref.watch(bridgeControllerProvider);
    final config =
        ref.watch(bridgeConfigProvider).value ?? const BridgeConfig();
    final termux = ref.watch(termuxControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          _Section(
            title: 'Agents',
            children: [
              _Tile(
                icon: Icons.extension_outlined,
                title: 'Plugins & MCP servers',
                subtitle: 'Install plugins and edit MCP server configuration',
                trailing: 'Open',
                onTap: () => context.push('/plugins'),
              ),
              _Tile(
                icon: Icons.smart_toy_outlined,
                title: 'Claude Code',
                subtitle: 'CLI runtime, account and sign-in',
                trailing: 'Open',
                onTap: () => context.push('/claude'),
              ),
              _Tile(
                icon: Icons.bolt_outlined,
                title: 'AGY',
                subtitle: 'Antigravity (Gemini) runtime and sign-in',
                trailing: 'Open',
                onTap: () => context.push('/agy'),
              ),
            ],
          ),
          _Section(
            title: 'Bridge',
            children: [
              _Tile(
                icon: Icons.device_hub_outlined,
                title: 'Mode',
                subtitle: config.isExternal
                    ? 'Bridge running in Debian proot'
                    : 'Bridge bundled inside Astra Code Agent',
                trailing: config.isExternal ? 'Debian proot' : 'Embedded',
                onTap: () => _editMode(context, ref, config),
              ),
              if (config.isExternal) ...[
                _Tile(
                  icon: Icons.lan_outlined,
                  title: 'Bridge URL',
                  subtitle: config.trimmedUrl,
                  trailing: 'Edit',
                  onTap: () => _editUrl(context, ref, config),
                ),
                _Tile(
                  icon: Icons.key_outlined,
                  title: 'Access token',
                  subtitle: config.token.isEmpty
                      ? 'Required: same --token as Termux'
                      : '${config.token.substring(0, 3)}•••••••••',
                  trailing: 'Edit',
                  onTap: () => _editToken(context, ref, config),
                ),
                _Tile(
                  icon: Icons.wifi_tethering,
                  title: 'Test connection',
                  subtitle: 'Probe the bridge running in Debian proot',
                  onTap: () => _testExternal(context, ref, config),
                ),
              ],
              _Tile(
                icon: Icons.power_settings_new,
                title: config.isExternal ? 'External bridge' : 'Local bridge',
                subtitle: bridge.isRunning
                    ? '${config.isExternal ? config.trimmedUrl : 'PID ${bridge.pid}'} '
                          '• ${bridge.healthVersion ?? 'healthy'}'
                    : bridge.error ?? 'Tap to connect',
                trailing: bridge.label,
                onTap: () =>
                    ref.read(bridgeControllerProvider.notifier).toggle(),
              ),
              if (!config.isExternal) ...[
                const _Tile(
                  icon: Icons.lan_outlined,
                  title: 'Host',
                  subtitle: AppInfo.bridgeHost,
                ),
                const _Tile(
                  icon: Icons.settings_ethernet,
                  title: 'Ports',
                  subtitle:
                      'Bridge ${AppInfo.bridgePort}  •  Hub ${AppInfo.hubPort}',
                ),
                const _Tile(
                  icon: Icons.key_outlined,
                  title: 'Access token',
                  subtitle: 'Generated on first launch',
                ),
              ],
              _Tile(
                icon: Icons.receipt_long_outlined,
                title: 'View logs',
                subtitle: 'Bridge stdout and stderr',
                onTap: () => _showBridgeLogs(context, ref),
              ),
              _Tile(
                icon: Icons.delete_sweep_outlined,
                title: 'Clear logs',
                subtitle: 'Remove buffered bridge output',
                onTap: () =>
                    ref.read(bridgeControllerProvider.notifier).clearLogs(),
              ),
            ],
          ),
          _Section(
            title: 'Debian proot automation',
            children: [
              _Tile(
                icon: Icons.terminal,
                title: 'Termux',
                subtitle: termux.installed
                    ? termux.permission
                          ? 'Installed • run-command permission granted'
                          : 'Installed • permission not granted'
                    : 'Not installed',
                trailing: termux.installed ? 'Ready' : 'Install',
                onTap: termux.installed
                    ? null
                    : () => BridgeChannel().openUrl(
                        'https://f-droid.org/packages/com.termux/',
                      ),
              ),
              _Tile(
                icon: termux.busy
                    ? Icons.hourglass_top
                    : Icons.rocket_launch_outlined,
                title: 'Set up & launch',
                subtitle: termux.busy ? termux.message ?? 'Working...' : 'Install bridge in Debian; reuse the existing AGY runtime',
                trailing: termux.busy ? 'Busy' : 'Run',
                onTap: termux.busy
                    ? null
                    : () => ref
                          .read(termuxControllerProvider.notifier)
                          .setupAndLaunch(),
              ),
              _Tile(
                icon: Icons.play_circle_outline,
                title: 'Launch bridge',
                subtitle: 'Start an existing Debian bridge setup',
                trailing: 'Start',
                onTap: termux.busy
                    ? null
                    : () =>
                          ref.read(termuxControllerProvider.notifier).launch(),
              ),
              _Tile(
                icon: Icons.settings_suggest_outlined,
                title: 'Termux settings',
                subtitle: 'Enable "Allow external apps" once',
                trailing: 'Open',
                onTap: () => ref
                    .read(termuxControllerProvider.notifier)
                    .openTermuxSettings(),
              ),
              _Tile(
                icon: Icons.open_in_new,
                title: 'Open Termux',
                subtitle: 'View setup and bridge logs',
                trailing: 'Open',
                onTap: () =>
                    ref.read(termuxControllerProvider.notifier).openTermux(),
              ),
              if (termux.error != null)
                _Tile(
                  icon: Icons.error_outline,
                  title: 'Last error',
                  subtitle: termux.error!,
                  trailing: 'Clear',
                  onTap: () =>
                      ref.read(termuxControllerProvider.notifier).refresh(),
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
              'Astra Code Agent uses its own package id so it installs beside '
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
