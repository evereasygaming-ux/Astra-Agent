import 'dart:async';

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
      setState(() => _showSplash = false);
      _removeTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _removeSplash = true);
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
    final splashSize = screen.width * 0.52 < screen.height * 0.34
        ? screen.width * 0.52
        : screen.height * 0.34;
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.16),
            radius: 0.92,
            colors: [Color(0xFF181329), AppTheme.background],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: progress,
                builder: (context, child) => Transform.scale(
                  scale: 0.88 + (progress.value * 0.12),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.accent.withValues(
                            alpha: 0.12 + progress.value * 0.16,
                          ),
                          blurRadius: 18 + progress.value * 18,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Image.asset(
                      'assets/branding/astra_code_splash.png',
                      semanticLabel: 'Astra Code Agent logo',
                      width: splashSize,
                      height: splashSize,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              FadeTransition(
                opacity: progress,
                child: const Text(
                  'Astra Code Agent',
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              FadeTransition(
                opacity: progress,
                child: const Text(
                  'EXPLORE  •  BUILD  •  CREATE',
                  style: TextStyle(
                    color: AppTheme.cyan,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.1,
                  ),
                ),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: splashSize * 1.12,
                child: AnimatedBuilder(
                  animation: progress,
                  builder: (context, _) {
                    final percent = (progress.value * 100).round();
                    return Column(
                      children: [
                        Row(
                          children: [
                            const Text(
                              'LOADING',
                              style: TextStyle(
                                color: AppTheme.muted,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '$percent%',
                              style: const TextStyle(
                                color: AppTheme.cyan,
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 9),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: progress.value,
                            minHeight: 6,
                            backgroundColor: AppTheme.outline,
                            valueColor: const AlwaysStoppedAnimation(
                              AppTheme.cyan,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Preparing your workspace',
                style: TextStyle(color: AppTheme.muted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
