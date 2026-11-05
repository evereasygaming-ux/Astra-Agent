import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:astra_agent/app/astra_app.dart';

void main() {
  testWidgets('home screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: AstraAgentApp()));
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Astra Code Agent'), findsOneWidget);

    final homeList = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Chat'),
      300,
      scrollable: homeList,
    );
    await tester.scrollUntilVisible(
      find.text('Terminal'),
      300,
      scrollable: homeList,
    );

    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
  });

  testWidgets('settings opens from home', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: AstraAgentApp()));
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('AGENTS'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
  });
}
