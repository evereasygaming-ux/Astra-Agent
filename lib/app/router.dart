import 'package:go_router/go_router.dart';

import '../features/agy/presentation/agy_screen.dart';
import '../features/claude/presentation/claude_screen.dart';
import '../features/home/home_screen.dart';
import '../features/settings/settings_screen.dart';

final GoRouter appRouter = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(path: '/claude', builder: (context, state) => const ClaudeScreen()),
    GoRoute(path: '/agy', builder: (context, state) => const AgyScreen()),
  ],
);
