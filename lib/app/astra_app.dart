import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

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

class _StartupBrandOverlayState extends State<_StartupBrandOverlay>
    with SingleTickerProviderStateMixin {
  bool _showSplash = true;
  bool _removeSplash = false;
  late final AnimationController _loadingController;
  late final Animation<double> _loadingProgress;
  Timer? _removeTimer;

  @override
  void initState() {
    super.initState();
    _loadingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _loadingProgress = CurvedAnimation(
      parent: _loadingController,
      curve: Curves.easeInOutCubic,
    );
    _loadingController.addStatusListener((status) {
      if (status != AnimationStatus.completed || !mounted) return;
      _removeTimer = Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        setState(() => _showSplash = false);
        _removeTimer = Timer(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _removeSplash = true);
        });
      });
    });
    _loadingController.forward();
  }

  @override
  void dispose() {
    _removeTimer?.cancel();
    _loadingController.dispose();
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
                child: _BrandLoadingScreen(progress: _loadingProgress),
              ),
            ),
          ),
      ],
    );
  }
}

class _BrandLoadingScreen extends StatelessWidget {
  const _BrandLoadingScreen({required this.progress});

  final Animation<double> progress;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    const imageWidth = 941.0;
    const imageHeight = 1672.0;
    final imageScale = math.max(
      screen.width / imageWidth,
      screen.height / imageHeight,
    );
    final renderedWidth = imageWidth * imageScale;
    final renderedHeight = imageHeight * imageScale;
    final cropLeft = (renderedWidth - screen.width) / 2;
    final cropTop = (renderedHeight - screen.height) / 2;
    final progressLeft = 112 * imageScale - cropLeft;
    final progressTop = 1032 * imageScale - cropTop;
    final progressWidth = 718 * imageScale;
    final progressHeight = (70 * imageScale).clamp(38.0, 70.0);
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/branding/astra_code_splash.png',
            semanticLabel: 'Astra Code Agent splash screen',
            fit: BoxFit.cover,
          ),
          Positioned(
            left: progressLeft,
            top: progressTop,
            width: progressWidth,
            child: AnimatedBuilder(
              animation: progress,
              builder: (context, _) {
                final percent = (progress.value * 100).round();
                return Container(
                  height: progressHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xF2050818),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: AppTheme.cyan.withValues(alpha: 0.95),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.cyan.withValues(alpha: 0.28),
                        blurRadius: 16,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: progressHeight - 12,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10152B),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: AppTheme.accent.withValues(alpha: 0.8),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                const ColoredBox(color: Color(0xFF0A1021)),
                                FractionallySizedBox(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: progress.value,
                                  child: const DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          AppTheme.accent,
                                          AppTheme.accentAlt,
                                          AppTheme.cyan,
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 45,
                        child: Text(
                          '$percent%',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
