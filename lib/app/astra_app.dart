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
      routerConfig: appRouter,
    );
  }
}
