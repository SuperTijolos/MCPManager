import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

Future<void> _withServers(WidgetTester tester, Size size) async {
  final container = await pumpApp(
    tester,
    size: size,
    server: FakeMcpServer(
      tools: [
        {
          'name': 'diagnostics',
          'description': 'Check server status',
          'inputSchema': {'type': 'object'},
        },
      ],
    ),
  );
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
    (const Size(360, 800), 1),
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

  testWidgets('server name sits above a selectable code-style endpoint', (
    tester,
  ) async {
    await _withServers(tester, const Size(1280, 900));
    final firstCard = find.byType(Card).first;
    expect(
      find.descendant(of: firstCard, matching: find.byIcon(Icons.dns_outlined)),
      findsNothing,
      reason: 'the server identity no longer has a decorative icon',
    );
    final endpoint = find.descendant(
      of: firstCard,
      matching: find.byType(SelectableText),
    );
    expect(endpoint, findsOneWidget);
    final text = tester.widget<SelectableText>(endpoint);
    expect(text.data, 'https://mcp.test/mcp');
    expect(text.style?.fontFamily, 'monospace');
    expect(find.byTooltip('Copy endpoint'), findsNWidgets(3));
  });

  testWidgets('the endpoint copy action copies the full URL', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _withServers(tester, const Size(1280, 900));
    await tester.tap(find.byTooltip('Copy endpoint').first);
    await tester.pump();
    expect(copied, 'https://mcp.test/mcp');
    expect(find.text('Endpoint copied'), findsOneWidget);
  });

  testWidgets('connection details open a dedicated diagnostics dialog', (
    tester,
  ) async {
    await _withServers(tester, const Size(1280, 900));
    await tester.tap(find.byTooltip('Connection details').first);
    await tester.pumpAndSettle();
    expect(find.text('Connection trace'), findsOneWidget);
    expect(find.text('Copy endpoint'), findsOneWidget);
    expect(find.text('Server software'), findsOneWidget);
    expect(find.text('MCP protocol'), findsOneWidget);
    await tester.tap(find.text('Close').last);
    await tester.pumpAndSettle();
    expect(find.text('Connection trace'), findsNothing);
  });

  testWidgets('connection details fit on a small screen', (tester) async {
    await _withServers(tester, const Size(360, 760));
    await tester.drag(
      find.byKey(const ValueKey('server-grid')),
      const Offset(0, -130),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Connection details').first);
    await tester.pumpAndSettle();
    expect(find.text('Connection trace'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('info icon sits alongside Tools, Edit and More', (tester) async {
    await _withServers(tester, const Size(1280, 900));
    final info = find.byTooltip('Connection details').first;
    final footer = find.byKey(const ValueKey('server-card-actions')).first;
    expect(find.descendant(of: footer, matching: info), findsOneWidget);
    expect(
      find.descendant(of: footer, matching: find.byTooltip('Tools')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: footer, matching: find.byTooltip('Edit')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: footer,
        matching: find.byTooltip('More server actions'),
      ),
      findsOneWidget,
    );
    expect(
      find.text('Connection details'),
      findsNothing,
      reason: 'details uses an icon instead of a separate card row',
    );
    expect(tester.takeException(), isNull);
  });
}
