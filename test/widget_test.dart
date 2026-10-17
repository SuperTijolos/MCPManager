import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

Future<void> _pumpApp(
  WidgetTester tester, {
  FakeMcpServer? server,
  ScriptedLlm? llm,
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        if (server != null)
          mcpHttpClientFactoryProvider.overrideWithValue(() => server.client),
        if (llm != null)
          llmProviderFactoryProvider.overrideWithValue((_) => llm),
      ],
      child: const MCPManagerApp(),
    ),
  );
  await tester.pumpAndSettle();
}

final _tools = [
  {
    'name': 'lookup',
    'description': 'Read something',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'q': {'type': 'string'},
      },
    },
    'annotations': {'readOnlyHint': true},
  },
  {
    'name': 'wipe',
    'description': 'Destroys things',
    'inputSchema': {'type': 'object'},
  },
];

Future<void> _addDemoServer(WidgetTester tester) async {
  await tester.tap(find.text('Servers').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Add your first server'));
  await tester.pumpAndSettle();
  await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Demo');
  await tester.enterText(
    find.widgetWithText(TextFormField, 'Endpoint URL'),
    'mcp.test/mcp',
  );
  await tester.tap(find.text('Add & connect'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('boots on the overview with empty-state guidance', (
    tester,
  ) async {
    await _pumpApp(tester);

    expect(find.text('Overview'), findsWidgets);
    expect(find.text('Servers online'), findsOneWidget);
    expect(find.text('0/0'), findsOneWidget);
    expect(
      find.textContaining('No tool calls in the last 24 hours'),
      findsOneWidget,
    );
    // Gemma 4 on Ollama is configured by default.
    expect(find.text('gemma4'), findsOneWidget);
  });

  testWidgets('add-server form validates, then connects and lists the server', (
    tester,
  ) async {
    await _pumpApp(tester, server: FakeMcpServer(tools: _tools));

    await tester.tap(find.text('Servers').first);
    await tester.pumpAndSettle();
    expect(find.text('No servers yet'), findsOneWidget);

    await tester.tap(find.text('Add your first server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add & connect'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    expect(find.text('Enter a valid http(s) URL'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Demo');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Endpoint URL'),
      'mcp.test/mcp',
    );
    await tester.tap(find.text('Add & connect'));
    await tester.pumpAndSettle();

    expect(find.text('Demo'), findsOneWidget);
    expect(
      find.text('http://mcp.test/mcp'),
      findsOneWidget,
      reason: 'scheme added automatically',
    );
    expect(find.text('Connected'), findsOneWidget);
    expect(
      find.textContaining('fake 1.2.3', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('tools workbench runs a tool and shows the result', (
    tester,
  ) async {
    final server = FakeMcpServer(
      tools: _tools,
      handlers: {'lookup': (args) => textResult('found ${args['q']}')},
    );
    await _pumpApp(tester, server: server);
    await _addDemoServer(tester);

    await tester.tap(find.text('Tools').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('lookup'));
    await tester.pumpAndSettle();
    expect(find.text('read-only'), findsOneWidget);

    // The argument template is generated from the schema; edit and run.
    await tester.enterText(find.byType(TextField).last, '{"q": "portimao"}');
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(find.text('found portimao'), findsOneWidget);

    // The call shows up in the audit log.
    await tester.tap(find.text('Audit').first);
    await tester.pumpAndSettle();
    expect(find.text('Demo · lookup'), findsOneWidget);
  });

  testWidgets(
    'operator asks before running a destructive tool, and Deny blocks it',
    (tester) async {
      var wipes = 0;
      final server = FakeMcpServer(
        tools: _tools,
        handlers: {
          'wipe': (_) {
            wipes++;
            return textResult('wiped');
          },
        },
      );
      final llm = ScriptedLlm([
        [
          const LlmToolCallsEvent([LlmToolCall(id: 'c1', name: 'Demo__wipe')]),
        ],
        [const LlmTextDelta('Understood, I left it alone.'), const LlmDone()],
      ]);
      await _pumpApp(tester, server: server, llm: llm);
      await _addDemoServer(tester);

      await tester.tap(find.text('Operator').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'wipe everything');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      expect(find.text('Needs approval'), findsOneWidget);
      expect(find.text('Demo · wipe'), findsOneWidget);
      expect(wipes, 0);

      await tester.tap(find.text('Deny'));
      await tester.pumpAndSettle();

      expect(wipes, 0);
      expect(find.text('Denied'), findsOneWidget);
      expect(find.textContaining('left it alone'), findsOneWidget);
    },
  );

  testWidgets('narrow screens use a drawer instead of the rail', (
    tester,
  ) async {
    await _pumpApp(tester, size: const Size(400, 800));

    expect(find.byType(NavigationRail), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text('Settings')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Model providers for the Operator'), findsOneWidget);
    expect(find.text('Using Ollama from the browser'), findsOneWidget);
  });

  testWidgets(
    'settings lists the default Gemma 4 provider and its enabled model',
    (tester) async {
      await _pumpApp(tester);
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();

      expect(find.text('Ollama'), findsWidgets);
      expect(
        find.text('http://localhost:11434'),
        findsNothing,
        reason: 'shown with the provider kind prefix',
      );
      expect(find.textContaining('http://localhost:11434'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'gemma4'), findsOneWidget);
    },
  );

  testWidgets('every page lays out without overflow at phone width', (
    tester,
  ) async {
    final server = FakeMcpServer(
      tools: _tools,
      handlers: {'lookup': (args) => textResult('found ${args['q']}')},
    );
    await _pumpApp(tester, server: server, size: const Size(360, 740));

    // Seed realistic content: a connected server, an audit event, a chat turn.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MCPManagerApp)),
    );
    await container
        .read(mcpHubProvider.notifier)
        .addServer(name: 'Demo', url: 'https://mcp.test/mcp');
    await container
        .read(mcpHubProvider.notifier)
        .callTool(
          serverId: container.read(mcpHubProvider).servers.single.config.id,
          toolName: 'lookup',
          args: {
            'q': 'a fairly long query string to stress the layout of narrow audit rows',
          },
          source: AuditSource.workbench,
          actor: 'user',
        );
    await tester.pumpAndSettle();

    for (final page in [
      'Overview',
      'Servers',
      'Tools',
      'Operator',
      'Audit',
      'Settings',
      'About',
      'Contributors',
    ]) {
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(Drawer), matching: find.text(page)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'overflow on $page');
    }
  });
}
