import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/rules/tool_rules.dart';
import 'package:mcp_manager/engine/rules/tool_rules_store.dart';

import 'package:mcp_manager/router/pages/tools/rule_dialog.dart';
import 'package:mcp_manager/router/pages/tools/tool_list.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

/// An action chip by its exact label ("Reason" must not also match
/// "Reason & expected result").
Finder chip(String label) => find.descendant(
  of: find.byType(RuleDialog),
  matching: find.byWidgetPredicate(
    (w) =>
        w is ActionChip && w.label is Text && (w.label as Text).data == label,
  ),
);

Map<String, dynamic> _tool(
  String name, {
  bool readOnly = false,
  Map<String, dynamic> props = const {},
}) => {
  'name': name,
  'description': 'Does $name.',
  'inputSchema': {'type': 'object', 'properties': props},
  if (readOnly) 'annotations': {'readOnlyHint': true},
};

FakeMcpServer _server() => FakeMcpServer(
  tools: [
    _tool(
      'read_file',
      readOnly: true,
      props: {
        'path': {'type': 'string'},
      },
    ),
    _tool(
      'write_file',
      props: {
        'path': {'type': 'string'},
        'content': {'type': 'string'},
      },
    ),
    _tool(
      'delete_file',
      props: {
        'path': {'type': 'string'},
      },
    ),
    _tool(
      'list_dir',
      readOnly: true,
      props: {
        'path': {'type': 'string'},
      },
    ),
  ],
  handlers: {'read_file': (args) => textResult('contents of ${args['path']}')},
);

Future<ProviderContainer> _open(
  WidgetTester tester, {
  Size size = const Size(1280, 900),
  Map<String, Object> prefs = const {},
}) async {
  final c = await pumpApp(tester, server: _server(), size: size, prefs: prefs);
  await c
      .read(mcpHubProvider.notifier)
      .addServer(name: 'Files', url: 'https://f.test/mcp');
  await goTo(tester, '/tools');
  return c;
}

List<ToolRule> _rules(ProviderContainer c) => c.read(toolRulesProvider).rules;

Future<void> _pickTool(WidgetTester tester, String name) async {
  await tester.tap(find.widgetWithText(ListTile, name));
  await tester.pumpAndSettle();
}

void main() {
  group('list and detail', () {
    testWidgets(
      'lists the tools, with counts on the tabs, and filters by search',
      (tester) async {
        await _open(tester);
        expect(find.text('Tools (4)'), findsOneWidget);
        expect(find.text('Rules (0)'), findsOneWidget);
        for (final t in [
          'read_file',
          'write_file',
          'delete_file',
          'list_dir',
        ]) {
          expect(find.widgetWithText(ListTile, t), findsOneWidget);
        }
        await tester.enterText(
          find.widgetWithText(TextField, 'Search tools'),
          'file',
        );
        await tester.pumpAndSettle();
        expect(find.widgetWithText(ListTile, 'list_dir'), findsNothing);
        expect(find.widgetWithText(ListTile, 'write_file'), findsOneWidget);
      },
    );

    testWidgets(
      'selecting a tool shows its detail with Test, Schema and Operator view',
      (tester) async {
        await _open(tester);
        expect(find.text('Select a tool'), findsOneWidget);
        await _pickTool(tester, 'read_file');
        expect(find.text('read-only'), findsOneWidget);
        for (final tab in ['Test', 'Schema', 'Operator view']) {
          expect(find.widgetWithText(Tab, tab), findsOneWidget);
        }
        await tester.enterText(
          find.byType(TextField).last,
          '{"path": "/a.txt"}',
        );
        await tester.tap(find.text('Run'));
        await tester.pumpAndSettle();
        expect(find.text('contents of /a.txt'), findsOneWidget);
      },
    );

    testWidgets(
      'Schema: original, what the Operator sees, and the diff once a rule applies',
      (tester) async {
        final c = await _open(tester);
        await _pickTool(tester, 'read_file');
        await tester.tap(find.widgetWithText(Tab, 'Schema'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Diff (none)'), findsOneWidget);

        c
            .read(toolRulesProvider.notifier)
            .upsert(
              const ToolRule(
                id: 'r',
                name: 'Reason',
                args: [
                  RuleArg(name: 'reason', description: 'Why.', required: true),
                ],
              ),
            );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Diff'));
        await tester.pumpAndSettle();
        expect(find.textContaining('+ '), findsWidgets);
        expect(find.textContaining('"reason"'), findsWidgets);

        await tester.tap(find.text('Operator sees'));
        await tester.pumpAndSettle();
        expect(find.textContaining('"reason"'), findsWidgets);
        await tester.tap(find.text('Original'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('"reason"'),
          findsNothing,
          reason: 'the original is never changed',
        );
      },
    );

    testWidgets(
      'Operator view: hide the tool, add instructions, see where each argument comes from',
      (tester) async {
        final c = await _open(tester);
        c
            .read(toolRulesProvider.notifier)
            .upsert(
              const ToolRule(
                id: 'r',
                name: 'Reason',
                args: [
                  RuleArg(name: 'reason', required: true),
                  RuleArg(
                    name: 'workspace',
                    source: ArgSource.hardcoded,
                    fixedValue: 'dev',
                  ),
                ],
              ),
            );
        await _pickTool(tester, 'read_file');
        await tester.tap(find.widgetWithText(Tab, 'Operator view'));
        await tester.pumpAndSettle();

        expect(find.text('Reason · audit only'), findsOneWidget);
        expect(find.textContaining('fixed to dev'), findsOneWidget);
        expect(find.text('server'), findsOneWidget);

        await tester.tap(find.byType(Switch).first);
        await tester.pumpAndSettle();
        final key =
            '${c.read(mcpHubProvider).servers.single.config.id}/read_file';
        expect(c.read(toolRulesProvider).overrides[key]!.hidden, isTrue);
        expect(find.text('hidden from Operator'), findsOneWidget);

        await tester.enterText(
          find.widgetWithText(TextField, 'Extra instructions for this tool'),
          'Never use on /etc.',
        );
        await tester.pump(const Duration(milliseconds: 600));
        expect(
          c.read(toolRulesProvider).overrides[key]!.instructions,
          'Never use on /etc.',
        );
      },
    );
  });

  group('select several tools and add the same argument', () {
    testWidgets(
      'bulk: choose a preset, create the rule for exactly the chosen tools',
      (tester) async {
        final c = await _open(tester);
        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(ListTile, 'write_file'));
        await tester.tap(find.widgetWithText(ListTile, 'delete_file'));
        await tester.pumpAndSettle();
        expect(find.text('2 selected'), findsOneWidget);

        await tester.tap(find.text('Add argument…'));
        await tester.pumpAndSettle();
        expect(find.text('New rule'), findsOneWidget);
        expect(
          find.widgetWithText(InputChip, 'Files · write_file'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(InputChip, 'Files · delete_file'),
          findsOneWidget,
        );

        await tester.tap(chip('Reason & expected result'));
        await tester.pumpAndSettle();
        expect(find.text('2 of 4 tools'), findsOneWidget);

        await tester.tap(find.text('Create rule'));
        await tester.pumpAndSettle();

        final rule = _rules(c).single;
        expect(rule.name, 'Reason & expected result');
        expect(rule.scope, RuleScope.tools);
        expect(
          rule.toolKeys.map((k) => k.split('/').last),
          unorderedEquals(['write_file', 'delete_file']),
        );
        expect(rule.args.map((a) => a.name), ['reason', 'expected_result']);
        expect(
          rule.args.every((a) => a.required && !a.forward),
          isTrue,
          reason: 'audit only by default',
        );
        expect(
          find.textContaining('applies to 2 tools right now'),
          findsOneWidget,
        );

        // Only those two rows carry the rules badge.
        expect(find.byTooltip('1 rule apply'), findsNWidgets(2));
      },
    );

    testWidgets(
      'select all shown, then hide them from the Operator and show them again',
      (tester) async {
        final c = await _open(tester);
        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Checkbox).first);
        await tester.pumpAndSettle();
        expect(find.text('4 selected'), findsOneWidget);

        await tester.tap(find.text('Hide from Operator'));
        await tester.pumpAndSettle();
        expect(
          c.read(toolRulesProvider).overrides.values.where((o) => o.hidden),
          hasLength(4),
        );
        expect(find.text('Show to Operator'), findsOneWidget);

        await tester.tap(find.text('Show to Operator'));
        await tester.pumpAndSettle();
        expect(c.read(toolRulesProvider).overrides, isEmpty);
      },
    );

    testWidgets(
      'actions are disabled until something is selected, and Done leaves select mode',
      (tester) async {
        await _open(tester);
        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();
        final add = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Add argument…'),
        );
        expect(add.onPressed, isNull);
        expect(find.textContaining('all 4 shown'), findsOneWidget);

        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.byType(Checkbox), findsNothing);
      },
    );
  });

  group('rule dialog', () {
    Future<void> openNew(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(Tab, 'Rules (0)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a rule'));
      await tester.pumpAndSettle();
    }

    testWidgets('validation messages', (tester) async {
      await _open(tester);
      await openNew(tester);

      await tester.tap(find.text('Create rule'));
      await tester.pumpAndSettle();
      expect(find.text('Give the rule a name.'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Mine');
      await tester.tap(find.text('Create rule'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Add at least one argument'), findsOneWidget);

      await tester.tap(find.text('Add argument'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Name').last,
        '1bad name',
      );
      await tester.tap(find.text('Create rule'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Argument names use letters'), findsOneWidget);
    });

    testWidgets(
      'a fixed value needs a value; the arg is then hidden from the model',
      (tester) async {
        final c = await _open(tester);
        await openNew(tester);
        await tester.enterText(
          find.widgetWithText(TextField, 'Name').first,
          'Pin workspace',
        );
        await tester.tap(find.text('Add argument'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Name').last,
          'workspace',
        );
        await tester.tap(find.text('Ask the model · audit only'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Fixed value · hidden from the model').last);
        await tester.pumpAndSettle();

        await tester.tap(find.text('Create rule'));
        await tester.pumpAndSettle();
        expect(find.textContaining('fixed value'), findsWidgets);

        await tester.enterText(find.widgetWithText(TextField, 'Value'), 'dev');
        await tester.tap(find.text('Create rule'));
        await tester.pumpAndSettle();
        final arg = _rules(c).single.args.single;
        expect(arg.source, ArgSource.hardcoded);
        expect(arg.fixedValue, 'dev');
        expect(arg.required, isFalse);
      },
    );

    testWidgets('"tools matching…" with a glob previews which tools it hits', (
      tester,
    ) async {
      final c = await _open(tester);
      await openNew(tester);
      await tester.tap(chip('Reason'));
      await tester.pumpAndSettle();
      expect(find.text('4 of 4 tools'), findsOneWidget);

      await tester.ensureVisible(find.text('Narrow down by name…'));
      await tester.tap(find.text('Narrow down by name…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('contains').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('matches glob').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'e.g. write_*'),
        'write_*',
      );
      await tester.pumpAndSettle();
      expect(find.text('1 of 4 tools'), findsOneWidget);

      await tester.tap(find.text('Create rule'));
      await tester.pumpAndSettle();
      final rule = _rules(c).single;
      expect(rule.conditions.single.op, ConditionOp.glob);
      expect(rule.conditions.single.value, 'write_*');
      expect(rule.scope, RuleScope.all);
    });

    testWidgets('a rule that matches nothing says so', (tester) async {
      await _open(tester);
      await openNew(tester);
      await tester.tap(chip('Reason'));
      await tester.ensureVisible(find.text('Narrow down by name…'));
      await tester.tap(find.text('Narrow down by name…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'text'),
        'zzz-nothing',
      );
      await tester.pumpAndSettle();
      expect(find.text('0 of 4 tools'), findsOneWidget);
    });
  });

  group('rules tab', () {
    ToolRule rule(String name, {bool enabled = true}) => ToolRule(
      id: name,
      name: name,
      enabled: enabled,
      args: const [RuleArg(name: 'reason', required: true)],
    );

    testWidgets('empty state offers presets', (tester) async {
      await _open(tester);
      await tester.tap(find.widgetWithText(Tab, 'Rules (0)'));
      await tester.pumpAndSettle();
      expect(find.text('No rules yet'), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is ActionChip &&
              w.label is Text &&
              (w.label as Text).data == 'Require explanation',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('New rule'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'explanation'),
        findsOneWidget,
        reason: 'the preset argument is filled in',
      );
    });

    testWidgets('priorities are shown, rules toggle, duplicate and delete', (
      tester,
    ) async {
      final c = await _open(tester);
      final store = c.read(toolRulesProvider.notifier);
      store.upsert(rule('First'));
      store.upsert(rule('Second'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Rules (2)'));
      await tester.pumpAndSettle();

      expect(find.textContaining('#1 · All servers'), findsOneWidget);
      expect(find.textContaining('#2 · All servers'), findsOneWidget);
      expect(
        find.textContaining('Applies to 4 connected tools'),
        findsNWidgets(2),
      );

      store.move(1, 0);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Second')).dy,
        lessThan(tester.getTopLeft(find.text('First')).dy),
      );

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(_rules(c).first.enabled, isFalse);

      await tester.tap(find.byTooltip('Rule actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(_rules(c).map((r) => r.name), contains('Second (copy)'));

      await tester.tap(find.byTooltip('Rule actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(_rules(c).map((r) => r.name), isNot(contains('Second')));
    });
  });

  group('resizable list', () {
    double listWidth(WidgetTester tester) =>
        tester.getSize(find.byType(ToolList)).width;

    testWidgets(
      'dragging the divider resizes the list and remembers the width',
      (tester) async {
        final c = await _open(tester);
        final before = listWidth(tester);

        await tester.drag(
          find.bySemanticsLabel('Resize the tool list'),
          const Offset(120, 0),
        );
        await tester.pumpAndSettle();
        final after = listWidth(tester);
        expect(after, greaterThan(before + 80));
        expect(
          c.read(sharedPreferencesProvider).getDouble('mcpm.ui.toolsListWidth'),
          isNotNull,
        );

        await tester.drag(
          find.bySemanticsLabel('Resize the tool list'),
          const Offset(-2000, 0),
        );
        await tester.pumpAndSettle();
        expect(
          listWidth(tester),
          greaterThanOrEqualTo(150),
          reason: 'never collapses below its minimum',
        );
      },
    );

    testWidgets('the list cannot squeeze the detail pane below its minimum', (
      tester,
    ) async {
      await _open(tester);
      await tester.drag(
        find.bySemanticsLabel('Resize the tool list'),
        const Offset(5000, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final total = tester.getSize(find.byType(Scaffold).first).width;
      expect(listWidth(tester), lessThan(total - 360));
    });

    testWidgets('a saved width is restored', (tester) async {
      await _open(tester, prefs: {'mcpm.ui.toolsListWidth': 520.0});
      expect(listWidth(tester), greaterThan(400));
    });

    testWidgets('double-tapping the divider resets the width', (tester) async {
      await _open(tester);
      final original = listWidth(tester);
      await tester.drag(
        find.bySemanticsLabel('Resize the tool list'),
        const Offset(150, 0),
      );
      await tester.pumpAndSettle();
      expect(listWidth(tester), isNot(closeTo(original, 5)));
      final handle = find.bySemanticsLabel('Resize the tool list');
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(listWidth(tester), closeTo(original, 5));
    });
  });

  group('phone width', () {
    testWidgets('the list opens a tool as its own page', (tester) async {
      await _open(tester, size: const Size(400, 800));
      await tester.tap(find.widgetWithText(ListTile, 'read_file'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(Tab, 'Operator view'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('select mode, the rules tab and the rule dialog all fit', (
      tester,
    ) async {
      final c = await _open(tester, size: const Size(400, 800));
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'read_file'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Add argument…'));
      await tester.pumpAndSettle();
      await tester.tap(chip('Reason & expected result'));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'the dialog is full-screen on a phone',
      );
      await tester.tap(find.text('Create rule'));
      await tester.pumpAndSettle();

      expect(_rules(c), hasLength(1));
      await tester.tap(find.widgetWithText(Tab, 'Rules (1)'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Reason & expected result'), findsOneWidget);
    });
  });
}
