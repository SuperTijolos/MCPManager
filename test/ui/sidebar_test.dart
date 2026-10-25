import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('desktop rail collapses to icons and expands on demand', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1440, 900));

    NavigationRail rail() =>
        tester.widget<NavigationRail>(find.byType(NavigationRail));

    expect(rail().extended, isTrue);
    final railFinder = find.byType(NavigationRail);
    final brandText = find.descendant(
      of: railFinder,
      matching: find.text('MCP Manager'),
    );
    expect(brandText, findsOneWidget);
    final dividers = find.descendant(
      of: railFinder,
      matching: find.byType(Divider),
    );
    expect(dividers, findsNWidgets(2));
    final brandIcon = find.descendant(
      of: railFinder,
      matching: find.byKey(const ValueKey('brand-icon')),
    );
    final firstNavigationIcon = find.descendant(
      of: railFinder,
      matching: find.byIcon(Icons.dashboard),
    );
    final separatorTop = tester.getTopLeft(dividers.first).dy;
    expect(separatorTop, greaterThan(tester.getBottomLeft(brandIcon).dy));
    expect(separatorTop, lessThan(tester.getTopLeft(firstNavigationIcon).dy));
    expect(find.byTooltip('Collapse sidebar'), findsOneWidget);
    final wideWidth = tester.getSize(find.byType(NavigationRail)).width;
    expect(wideWidth, 256, reason: 'The bottom toggle must not widen the rail');
    final railBottom = tester.getBottomLeft(find.byType(NavigationRail)).dy;
    final toggleBottom = tester
        .getBottomLeft(find.byTooltip('Collapse sidebar'))
        .dy;
    expect(
      railBottom - toggleBottom,
      lessThan(45),
      reason: 'The arrow belongs in the bottom footer',
    );

    await tester.tap(find.byTooltip('Collapse sidebar'));
    await tester.pumpAndSettle();
    expect(rail().extended, isFalse);
    expect(brandText, findsNothing);
    expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    expect(tester.getSize(find.byType(NavigationRail)).width, lessThan(100));
    final compactRailBottom = tester
        .getBottomLeft(find.byType(NavigationRail))
        .dy;
    final compactToggleBottom = tester
        .getBottomLeft(find.byTooltip('Expand sidebar'))
        .dy;
    expect(compactRailBottom - compactToggleBottom, lessThan(45));
    expect(
      tester.getSize(find.byType(NavigationRail)).width,
      lessThan(wideWidth),
    );
    // Collapsing labels must not remove the navigation icons.
    expect(
      find.descendant(
        of: railFinder,
        matching: find.byIcon(Icons.dns_outlined),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: railFinder,
        matching: find.byIcon(Icons.dns_outlined),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No servers yet'), findsOneWidget);
    expect(rail().extended, isFalse);
    expect(find.byTooltip('Expand sidebar'), findsOneWidget);

    await tester.tap(find.byTooltip('Expand sidebar'));
    await tester.pumpAndSettle();
    expect(rail().extended, isTrue);
    expect(brandText, findsOneWidget);
    expect(find.byTooltip('Collapse sidebar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet starts compact but arrow can expand the rail', (
    tester,
  ) async {
    await pumpApp(tester, size: const Size(1000, 800));
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isFalse,
    );

    await tester.tap(find.byTooltip('Expand sidebar'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isTrue,
    );
    expect(tester.takeException(), isNull);

    // The phone drawer always takes precedence over a saved desktop preference.
    tester.view.physicalSize = const Size(390, 800);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(Drawer),
        matching: find.text('MCP Servers'),
      ),
    );
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(1000, 800);
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved sidebar preference overrides desktop width default', (
    tester,
  ) async {
    await pumpApp(
      tester,
      size: const Size(1440, 900),
      prefs: const {'mcpm.navigation.rail.expanded.v1': false},
    );
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isFalse,
    );
    expect(find.byTooltip('Expand sidebar'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('MCP Manager'),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
