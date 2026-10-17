import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/rules/tool_rules.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'rule_dialog.dart';

/// All rules, highest priority first. Rules at the top win when two of them
/// define the same argument.
class RulesTab extends ConsumerWidget {
  const RulesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(toolRulesProvider);
    final hub = ref.watch(mcpHubProvider);
    final store = ref.read(toolRulesProvider.notifier);

    if (state.rules.isEmpty) {
      return EmptyState(
        icon: Icons.rule_folder_outlined,
        title: 'No rules yet',
        message:
            'Rules add arguments such as "reason" or "expected result" to many tools at once, '
            'record them in the audit log, and can inject fixed values the model never sees.',
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final p in rulePresets.take(4))
                  ActionChip(
                    avatar: const Icon(Icons.auto_awesome, size: 16),
                    label: Text(p.name),
                    onPressed: () => showRuleDialog(context, preset: p),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => showRuleDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('Create a rule'),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: () => showRuleDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('New rule'),
            ),
            PopupMenuButton<RulePreset>(
              tooltip: 'Start from a preset',
              onSelected: (p) => showRuleDialog(context, preset: p),
              itemBuilder: (_) => [
                for (final p in rulePresets)
                  PopupMenuItem(
                    value: p,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name),
                        Text(
                          p.description,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
              ],
              child: const Chip(
                avatar: Icon(Icons.auto_awesome, size: 16),
                label: Text('From a preset'),
              ),
            ),
            Text(
              'Drag to reorder · the rule at the top wins on conflicts',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ReorderableListView.builder(
            buildDefaultDragHandles: false,
            itemCount: state.rules.length,
            onReorderItem: store.move,
            proxyDecorator: (child, _, _) =>
                Material(color: Colors.transparent, child: child),
            itemBuilder: (context, i) {
              final rule = state.rules[i];
              final matched = [
                for (final t in hub.availableTools)
                  if (rule.matches(t.server, t.tool)) t,
              ];
              return Padding(
                key: ValueKey(rule.id),
                padding: const EdgeInsets.only(bottom: 10),
                child: _RuleCard(
                  rule: rule,
                  index: i,
                  matched: matched,
                  hubServers: hub.servers,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _RuleCard extends ConsumerWidget {
  const _RuleCard({
    required this.rule,
    required this.index,
    required this.matched,
    required this.hubServers,
  });

  final ToolRule rule;
  final int index;
  final List<ToolRef> matched;
  final List<ServerRuntime> hubServers;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final store = ref.read(toolRulesProvider.notifier);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Opacity(
      opacity: rule.enabled ? 1 : 0.55,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ReorderableDragStartListener(
                    index: index,
                    child: const MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.drag_indicator, size: 20),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(rule.name, style: theme.textTheme.titleMedium),
                        Text(
                          '#${index + 1} · ${rule.scopeSummary}',
                          style: muted,
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: rule.enabled,
                    onChanged: (v) => store.setEnabled(rule.id, v),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Rule actions',
                    onSelected: (v) {
                      switch (v) {
                        case 'edit':
                          showRuleDialog(context, existing: rule);
                        case 'copy':
                          store.upsert(
                            ToolRule(
                              id: store.newRuleId(),
                              name: '${rule.name} (copy)',
                              description: rule.description,
                              enabled: rule.enabled,
                              scope: rule.scope,
                              serverIds: rule.serverIds,
                              toolKeys: rule.toolKeys,
                              conditions: rule.conditions,
                              matchMode: rule.matchMode,
                              args: rule.args,
                              instructions: rule.instructions,
                            ),
                          );
                        case 'delete':
                          _confirmDelete(context, store);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'copy', child: Text('Duplicate')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (rule.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(rule.description, style: muted),
                      ),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final a in rule.args) _ArgChip(a),
                        if (rule.instructions.isNotEmpty)
                          const StatusChip(
                            'instructions',
                            StatusColors.muted,
                            icon: Icons.notes,
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Theme(
                      data: theme.copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(
                          matched.isEmpty
                              ? 'Matches no connected tools'
                              : 'Applies to ${matched.length} connected tool${matched.length == 1 ? '' : 's'}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: matched.isEmpty ? StatusColors.warn : null,
                          ),
                        ),
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final t in matched)
                                  Chip(
                                    visualDensity: VisualDensity.compact,
                                    label: Text(
                                      '${t.server.name} · ${t.tool.name}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ToolRulesNotifier store,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${rule.name}"?'),
        content: const Text(
          'The Operator goes back to seeing the affected tools as the servers define them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) store.remove(rule.id);
  }
}

/// One argument of a rule, with an icon for what happens to it.
class _ArgChip extends StatelessWidget {
  const _ArgChip(this.arg);
  final RuleArg arg;

  @override
  Widget build(BuildContext context) {
    final (icon, color, hint) = switch (arg.source) {
      ArgSource.hardcoded => (
        Icons.lock_outline,
        StatusColors.warn,
        'fixed, hidden from the model',
      ),
      ArgSource.custom when arg.forward => (
        Icons.send_outlined,
        StatusColors.info,
        'asked of the model, sent to the server',
      ),
      ArgSource.custom => (
        Icons.receipt_long_outlined,
        StatusColors.ok,
        'asked of the model, audit only',
      ),
    };
    return Tooltip(
      message: '${arg.required ? 'required · ' : ''}$hint',
      child: StatusChip(
        arg.source == ArgSource.hardcoded
            ? '${arg.name} = ${arg.fixedValue}'
            : '${arg.name}${arg.required ? '*' : ''}',
        color,
        icon: icon,
      ),
    );
  }
}
