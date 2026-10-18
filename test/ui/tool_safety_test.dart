import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';
import 'package:mcp_manager/engine/rules/tool_rules.dart';
import 'package:mcp_manager/engine/rules/tool_rules_store.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

McpTool _mcpTool(String name, [Map<String, dynamic> annotations = const {}]) =>
    McpTool.fromJson({
      'name': name,
      'inputSchema': {'type': 'object'},
      'annotations': annotations,
    });

final _server = McpServerConfig(id: 's', name: 'Srv', url: 'https://x.test');

ToolRulesState _marked(String tool) => ToolRulesState(
  overrides: {toolKey('s', tool): const ToolOverride(readOnly: true)},
);

Map<String, dynamic> _wire(String name, [Map<String, dynamic>? annotations]) =>
    {
      'name': name,
      'description': 'Does $name.',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
      'annotations': ?annotations,
    };

void main() {
  group('ToolSafety', () {
    test('a tool the server is silent about needs approval', () {
      final state = const ToolRulesState();
      expect(state.safety(_server, _mcpTool('a')), ToolSafety.unmarked);
      expect(state.isReadOnly(_server, _mcpTool('a')), isFalse);
      expect(state.effective(_server, _mcpTool('a')).readOnly, isFalse);
    });

    test('the user can vouch for a silent tool', () {
      final state = _marked('a');
      expect(state.safety(_server, _mcpTool('a')), ToolSafety.readOnlyByUser);
      expect(state.isReadOnly(_server, _mcpTool('a')), isTrue);
      final effective = state.effective(_server, _mcpTool('a'));
      expect(effective.readOnly, isTrue);
      expect(effective.readOnlyByUser, isTrue);
    });

    test('the mark is ignored when the server says the tool writes', () {
      for (final hint in [
        {'destructiveHint': true},
        {'readOnlyHint': false},
      ]) {
        final tool = _mcpTool('a', hint);
        final state = _marked('a');
        expect(
          state.safety(_server, tool),
          ToolSafety.mayModify,
          reason: '$hint',
        );
        expect(state.isReadOnly(_server, tool), isFalse);
        expect(state.effective(_server, tool).readOnly, isFalse);
      }
    });

    test('a server-declared read-only tool stays read-only', () {
      final tool = _mcpTool('a', {'readOnlyHint': true});
      expect(const ToolRulesState().safety(_server, tool), ToolSafety.readOnly);
      expect(_marked('a').effective(_server, tool).readOnlyByUser, isFalse);
    });

    test('the override survives a JSON round trip and is not empty', () {
      const o = ToolOverride(readOnly: true);
      expect(o.isEmpty, isFalse);
      expect(ToolOverride.fromJson(o.toJson()).readOnly, isTrue);
      expect(const ToolOverride().toJson().containsKey('readOnly'), isFalse);
    });
  });

  group('MCP Tools page', () {
    late FakeMcpServer server;

    Future<ProviderContainer> open(WidgetTester tester) async {
      server = FakeMcpServer(
        tools: [
          _wire('read_file', {'readOnlyHint': true}),
          _wire('write_file'),
          _wire('rm', {'destructiveHint': true}),
        ],
        handlers: {'write_file': (_) => textResult('written')},
      );
      final c = await pumpApp(tester, server: server);
      await c
          .read(mcpHubProvider.notifier)
          .addServer(name: 'Files', url: 'https://f.test/mcp');
      await goTo(tester, '/mcp-tools');
      return c;
    }

    int calls() =>
        server.bodies.where((b) => b['method'] == 'tools/call').length;

    Future<void> pick(WidgetTester tester, String name) async {
      await tester.tap(find.widgetWithText(ListTile, name));
      await tester.pumpAndSettle();
    }

    testWidgets('unmarked tools are described honestly, not as dangerous', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('1 read-only'), findsOneWidget);
      expect(find.text('2 not marked read-only'), findsOneWidget);
      expect(find.textContaining('may modify'), findsNothing);

      await pick(tester, 'write_file');
      expect(find.text('not marked read-only'), findsOneWidget);
      await pick(tester, 'rm');
      expect(find.text('may modify data'), findsOneWidget);
    });

    testWidgets('marking a tool read-only updates the badge and the counts', (
      tester,
    ) async {
      final c = await open(tester);
      await pick(tester, 'write_file');
      await tester.tap(find.widgetWithText(Tab, 'Operator view'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tool-read-only-switch')));
      await tester.pumpAndSettle();

      expect(find.text('read-only (marked by you)'), findsOneWidget);
      expect(find.text('2 read-only'), findsOneWidget);
      expect(c.read(toolRulesProvider).overrides.length, 1);

      await tester.tap(find.byKey(const ValueKey('tool-read-only-switch')));
      await tester.pumpAndSettle();
      expect(c.read(toolRulesProvider).overrides, isEmpty);
    });

    testWidgets('the switch is not offered for tools that declare a write', (
      tester,
    ) async {
      await open(tester);
      await pick(tester, 'rm');
      await tester.tap(find.widgetWithText(Tab, 'Operator view'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tool-read-only-switch')), findsNothing);

      await pick(tester, 'read_file');
      await tester.tap(find.widgetWithText(Tab, 'Operator view'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tool-read-only-switch')), findsNothing);
    });

    testWidgets(
      'bulk select can mark tools, skipping ones that declare a write',
      (tester) async {
        final c = await open(tester);
        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Checkbox).first); // select all shown
        await tester.pumpAndSettle();
        await tester.tap(find.text('Treat as read-only'));
        await tester.pumpAndSettle();

        expect(c.read(toolRulesProvider).overrides.keys, [
          toolKey(
            c.read(mcpHubProvider).servers.single.config.id,
            'write_file',
          ),
        ], reason: 'read_file already is, rm says it writes');
        expect(find.text('Remove read-only mark'), findsOneWidget);
      },
    );

    testWidgets('the Test tab asks before running an unmarked tool, once', (
      tester,
    ) async {
      await open(tester);
      await pick(tester, 'write_file');

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.text('Run write_file?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls(), 0, reason: 'cancelled before reaching the server');

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Run'),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls(), 1);
      expect(find.text('written'), findsOneWidget);

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.text('Run write_file?'), findsNothing);
      expect(calls(), 2, reason: 'already confirmed for this tool');
    });

    testWidgets('the Test tab runs read-only tools straight away', (
      tester,
    ) async {
      await open(tester);
      await pick(tester, 'read_file');
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Run read_file?'), findsNothing);
      expect(calls(), 1);
    });

    testWidgets('a declared write says so in the confirmation', (tester) async {
      await open(tester);
      await pick(tester, 'rm');
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(
        find.text('The server says this tool may modify data.'),
        findsOneWidget,
      );
    });
  });
}
