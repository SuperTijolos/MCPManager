import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

Future<void> _withServers(WidgetTester tester, Size size) async {
  final container = await pumpApp(tester, size: size, server: FakeMcpServer());
  for (final name in ['Alpha', 'Beta', 'Gamma']) {
    await container
        .read(mcpHubProvider.notifier)
        .addServer(name: name, url: 'https://mcp.test/mcp');
  }
  await goTo(tester, '/servers');
}

void main() {
  for (final (size, columns) in [
    (const Size(1724, 1000), 3),
    (const Size(1100, 900), 2),
    (const Size(420, 900), 1),
  ]) {
    testWidgets('Servers use $columns columns at ${size.width} px', (
      tester,
    ) async {
      await _withServers(tester, size);
      final grid = tester.widget<GridView>(
        find.byKey(const ValueKey('server-grid')),
      );
      expect(
        (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
            .crossAxisCount,
        columns,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('connection details open a dedicated diagnostics dialog', (
    tester,
  ) async {
    await _withServers(tester, const Size(1280, 900));
    await tester.tap(find.text('Connection details').first);
    await tester.pumpAndSettle();
    expect(find.text('Connection trace'), findsOneWidget);
    expect(find.text('Copy endpoint'), findsOneWidget);
    expect(find.text('Server software'), findsOneWidget);
    expect(find.text('MCP protocol'), findsOneWidget);
    await tester.tap(find.text('Close').last);
    await tester.pumpAndSettle();
    expect(find.text('Connection trace'), findsNothing);
  });
}
