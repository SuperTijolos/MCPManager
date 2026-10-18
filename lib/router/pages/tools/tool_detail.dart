import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/rules/tool_rules.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'tool_operator_tab.dart';
import 'tool_schema_tab.dart';
import 'tool_test_tab.dart';

/// One tool: description, badges, and the Test / Schema / Operator tabs.
class ToolDetail extends ConsumerWidget {
  const ToolDetail({super.key, required this.toolRef});

  final ToolRef toolRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tool = toolRef.tool;
    final rules = ref.watch(toolRulesProvider);
    final effective = rules.effective(toolRef.server, tool);
    final safety = rules.safety(toolRef.server, tool);

    return DefaultTabController(
      length: 3,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tool.displayName,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              Wrap(
                spacing: 6,
                children: [
                  switch (safety) {
                    ToolSafety.readOnly => const StatusChip(
                      'read-only',
                      StatusColors.ok,
                      icon: Icons.visibility_outlined,
                    ),
                    ToolSafety.readOnlyByUser => const StatusChip(
                      'read-only (marked by you)',
                      StatusColors.ok,
                      icon: Icons.visibility_outlined,
                    ),
                    ToolSafety.mayModify => const StatusChip(
                      'may modify data',
                      StatusColors.warn,
                      icon: Icons.warning_amber_rounded,
                    ),
                    ToolSafety.unmarked => const StatusChip(
                      'not marked read-only',
                      StatusColors.warn,
                      icon: Icons.help_outline,
                    ),
                  },
                  if (!effective.visible)
                    const StatusChip(
                      'hidden from Operator',
                      StatusColors.muted,
                      icon: Icons.visibility_off_outlined,
                    ),
                  if (effective.rules.isNotEmpty)
                    StatusChip(
                      '${effective.rules.length} rule${effective.rules.length == 1 ? '' : 's'}',
                      StatusColors.info,
                      icon: Icons.rule,
                    ),
                ],
              ),
            ],
          ),
          Text(
            '${toolRef.server.name} · ${tool.name}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (tool.description != null) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 110),
              child: SingleChildScrollView(
                child: SelectableText(tool.description!),
              ),
            ),
          ],
          const SizedBox(height: 8),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Test'),
              Tab(text: 'Schema'),
              Tab(text: 'Operator view'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ToolTestTab(toolRef: toolRef),
                ToolSchemaTab(toolRef: toolRef),
                ToolOperatorTab(toolRef: toolRef),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
