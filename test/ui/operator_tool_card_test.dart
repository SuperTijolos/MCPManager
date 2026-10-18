import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/ui/widgets.dart';

import '../support/app_harness.dart';

Map<String, Object> _savedConversation({
  String status = 'done',
  String? result = '{"count": 2, "ok": true}',
  bool assistantReply = false,
}) {
  const id = 'operator-test';
  return {
    'mcpm.chats.active.v1': id,
    'mcpm.chats.index.v1': jsonEncode([
      {
        'id': id,
        'title': 'Inspect MCP tools',
        'createdAt': '2026-10-18T11:00:00.000',
        'updatedAt': '2026-10-18T11:10:00.000',
        'messageCount': 1,
      },
    ]),
    'mcpm.chat.$id.v1': jsonEncode({
      'items': [
        {'type': 'user', 'id': 'request', 'text': 'List the tools'},
        {
          'type': 'tool',
          'id': 'call-1',
          'callId': 'call-id-1',
          'name': 'mcp_list_tools',
          'label': 'MCP Manager · mcp_list_tools',
          'args': {'server': 'MCP GuikiPT - Cloudflare'},
          'status': status,
          'output': result,
        },
        if (assistantReply)
          {
            'type': 'assistant',
            'id': 'assistant-1',
            'text': 'Found two MCP tools.',
            'thinking': 'I should inspect the available MCP tools.',
          },
      ],
      'history': [],
    }),
  };
}

void main() {
  testWidgets(
    'arguments and results collapse separately, with meaningful summaries',
    (tester) async {
      await pumpApp(tester, prefs: _savedConversation());
      await goTo(tester, '/chat');
      expect(find.text('Arguments'), findsOneWidget);
      expect(find.text('1 field'), findsOneWidget);
      expect(find.text('Result'), findsOneWidget);
      expect(find.text('JSON · 24 characters'), findsOneWidget);
      expect(find.byType(CodeBlock), findsNothing);

      await tester.tap(find.text('Arguments'));
      await tester.pumpAndSettle();
      expect(find.byType(JsonBlock), findsOneWidget);
      expect(find.byType(CodeBlock), findsOneWidget);

      await tester.tap(find.text('Arguments'));
      await tester.pumpAndSettle();
      expect(find.byType(JsonBlock), findsNothing);
      expect(find.byType(CodeBlock), findsNothing);

      await tester.tap(find.byKey(const ValueKey('tool-result-call-1')));
      await tester.pumpAndSettle();
      expect(find.byType(CodeBlock), findsOneWidget);
      expect(tester.widget<CodeBlock>(find.byType(CodeBlock)).json, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Operator can hide and restore thinking without hiding answers', (
    tester,
  ) async {
    await pumpApp(tester, prefs: _savedConversation(assistantReply: true));
    await goTo(tester, '/chat');
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('Found two MCP tools.'), findsOneWidget);
    await tester.tap(find.text('Hide thinking'));
    await tester.pumpAndSettle();
    expect(find.text('Thinking'), findsNothing);
    expect(find.text('Found two MCP tools.'), findsOneWidget);
    await tester.tap(find.text('Show thinking'));
    await tester.pumpAndSettle();
    expect(find.text('Thinking'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy response copies the assistant text only', (tester) async {
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
    await pumpApp(tester, prefs: _savedConversation(assistantReply: true));
    await goTo(tester, '/chat');
    await tester.tap(find.byTooltip('Copy response'));
    await tester.pump();
    expect(copied, 'Found two MCP tools.');
    expect(find.text('Response copied'), findsOneWidget);
  });

  testWidgets('failed MCP results remain accessible on small screens', (
    tester,
  ) async {
    await pumpApp(
      tester,
      size: const Size(420, 850),
      prefs: _savedConversation(
        status: 'error',
        result: 'Network disconnected',
      ),
    );
    await goTo(tester, '/chat');
    expect(find.text('Failed'), findsOneWidget);
    expect(find.text('Text · 20 characters'), findsOneWidget);
    expect(find.byType(CodeBlock), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tool-result-call-1')));
    await tester.pumpAndSettle();
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
