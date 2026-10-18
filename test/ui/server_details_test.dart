import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

void main() {
  testWidgets(
    'a server that fails shows the reason and a trace of what was tried',
    (tester) async {
      final server = SessionTroubleServer(hideSessionHeader: true);
      final c = await pumpApp(tester, httpClient: server.client);
      await c
          .read(mcpHubProvider.notifier)
          .addServer(name: 'Cloudflare', url: 'https://cf.test/mcp');
      await goTo(tester, '/mcp-servers');

      expect(find.textContaining('No MCP transport worked'), findsOneWidget);
      expect(
        find.textContaining('could not read the Mcp-Session-Id'),
        findsOneWidget,
      );

      await tester.ensureVisible(find.byTooltip('Connection details'));
      await tester.tap(find.byTooltip('Connection details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('POST initialize → 200'), findsOneWidget);
      expect(
        find.textContaining('Legacy SSE at https://cf.test/sse'),
        findsWidgets,
      );
      expect(
        find.textContaining('Session expired or does not exist'),
        findsWidgets,
      );
    },
  );

  testWidgets('a healthy server keeps a collapsed, harmless trace', (
    tester,
  ) async {
    final c = await pumpApp(tester, server: FakeMcpServer());
    await c
        .read(mcpHubProvider.notifier)
        .addServer(name: 'Modern', url: 'https://mcp.test/mcp');
    await goTo(tester, '/mcp-servers');
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byTooltip('Connection details'), findsOneWidget);
    expect(
      find.textContaining('POST initialize'),
      findsNothing,
      reason: 'collapsed until opened',
    );
  });
}
