import 'dart:async';

import 'package:flutter/material.dart';

import '../core/constants/app_info.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class AstraAgentApp extends StatelessWidget {
  const AstraAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Astra Code Agent',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      builder: (context, child) => _StartupBrandOverlay(child: child),
      routerConfig: appRouter,
    );
  }
}

class _StartupBrandOverlay extends StatefulWidget {
  const _StartupBrandOverlay({required this.child});

  final Widget? child;

  @override
  State<_StartupBrandOverlay> createState() => _StartupBrandOverlayState();
}

class _StartupBrandOverlayState extends State<_StartupBrandOverlay> {
  bool _showSplash = true;
  bool _removeSplash = false;
  Timer? _dismissTimer;
  Timer? _removeTimer;

  @override
  void initState() {
    super.initState();
    _dismissTimer = Timer(const Duration(milliseconds: 850), () {
      if (!mounted) return;
      setState(() => _showSplash = false);
      _removeTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _removeSplash = true);
      });
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _removeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.child != null) widget.child!,
        if (!_removeSplash)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_showSplash,
              child: AnimatedOpacity(
                opacity: _showSplash ? 1 : 0,
                duration: const Duration(milliseconds: 300),
                child: const _BrandLoadingScreen(),
              ),
            ),
          ),
      ],
    );
  }
}

class _BrandLoadingScreen extends StatelessWidget {
  const _BrandLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.2),
            radius: 1.05,
            colors: [Color(0xFF171426), AppTheme.background],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 132,
                height: 132,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(34),
                  border: Border.all(color: AppTheme.outline),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.accent.withValues(alpha: 0.2),
                      blurRadius: 42,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: AppTheme.accentAlt.withValues(alpha: 0.16),
                      blurRadius: 54,
                      offset: const Offset(12, 14),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(
                  'assets/branding/astra_code_icon.png',
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                AppInfo.name,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                AppInfo.tagline,
                style: TextStyle(
                  color: AppTheme.muted,
                  fontSize: 12,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 38),
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppTheme.cyan,
                  backgroundColor: AppTheme.outline,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Preparing your workspace',
                style: TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
