import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/rules/tool_rules.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'rule_dialog.dart';

/// Tool safety filters are intentionally conservative: an MCP tool without
/// an explicit read-only annotation is classified as potentially modifying.
enum ToolListFilter { all, readOnly, mayModify, hidden }

/// Search, server and safety filters, plus (in select mode) bulk actions.
class ToolList extends ConsumerWidget {
  const ToolList({
    super.key,
    required this.tools,
    required this.servers,
    required this.serverId,
    required this.focusedKey,
    required this.selectMode,
    required this.selected,
    required this.onQuery,
    required this.onServer,
    required this.onOpen,
    required this.onSelectMode,
    required this.onToggle,
    required this.onSelectAll,
    required this.filter,
    required this.onFilter,
    required this.totalCount,
  });

  final List<ToolRef> tools;
  final List<ServerRuntime> servers;
  final String? serverId;
  final String? focusedKey;
  final bool selectMode;
  final Set<String> selected;
  final ValueChanged<String> onQuery;
  final ValueChanged<String?> onServer;
  final ValueChanged<ToolRef> onOpen;
  final ValueChanged<bool> onSelectMode;
  final ValueChanged<String> onToggle;
  final ValueChanged<bool> onSelectAll;
  final ToolListFilter filter;
  final ValueChanged<ToolListFilter> onFilter;
  final int totalCount;

  static String keyOf(ToolRef t) => toolKey(t.server.id, t.tool.name);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ref.watch(toolRulesProvider);
    final shownKeys = [for (final t in tools) keyOf(t)];
    final allShown = shownKeys.isNotEmpty && shownKeys.every(selected.contains);
    final someShown = shownKeys.any(selected.contains);

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search tools',
                ),
                onChanged: onQuery,
              ),
            ),
            const SizedBox(width: 8),
            selectMode
                ? FilledButton.tonalIcon(
                    onPressed: () => onSelectMode(false),
                    icon: const Icon(Icons.done, size: 18),
                    label: const Text('Done'),
                  )
                : OutlinedButton.icon(
                    onPressed: () => onSelectMode(true),
                    icon: const Icon(Icons.checklist, size: 18),
                    label: const Text('Select'),
                  ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final value in ToolListFilter.values)
              FilterChip(
                key: ValueKey('tool-filter-${value.name}'),
                label: Text(switch (value) {
                  ToolListFilter.all => 'All',
                  ToolListFilter.readOnly => 'Read-only',
                  ToolListFilter.mayModify => 'May modify',
                  ToolListFilter.hidden => 'Hidden',
                }),
                visualDensity: VisualDensity.compact,
                selected: filter == value,
                showCheckmark: false,
                onSelected: (_) => onFilter(value),
              ),
          ],
        ),
        if (servers.length > 1) ...[
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => DropdownMenu<String>(
              key: ValueKey('mcp-server-picker-${serverId ?? 'all'}'),
              width: constraints.maxWidth,
              menuHeight: 280,
              requestFocusOnTap: true,
              enableFilter: true,
              enableSearch: true,
              initialSelection: serverId ?? '',
              leadingIcon: const Icon(Icons.dns_outlined, size: 20),
              label: const Text('MCP server'),
              trailingIcon: const Icon(Icons.keyboard_arrow_down),
              selectedTrailingIcon: const Icon(Icons.keyboard_arrow_up),
              dropdownMenuEntries: [
                const DropdownMenuEntry<String>(
                  value: '',
                  label: 'All MCP servers',
                  leadingIcon: Icon(Icons.all_inclusive),
                ),
                for (final server in servers)
                  DropdownMenuEntry<String>(
                    value: server.config.id,
                    label: server.config.name,
                    leadingIcon: const Icon(Icons.dns_outlined),
                  ),
              ],
              onSelected: (id) =>
                  onServer(id == null || id.isEmpty ? null : id),
            ),
          ),
        ],
        if (selectMode) ...[
          const SizedBox(height: 8),
          _BulkBar(
            allShown: allShown,
            someShown: someShown,
            shownCount: shownKeys.length,
            selected: selected,
            onSelectAll: onSelectAll,
            allTools: tools,
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${tools.length} of $totalCount tools',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Expanded(
          child: tools.isEmpty
              ? const EmptyState(
                  icon: Icons.search_off,
                  title: 'No matching tools',
                )
              : ListView.builder(
                  itemCount: tools.length,
                  itemBuilder: (context, i) {
                    final t = tools[i];
                    final key = keyOf(t);
                    final isFocused = focusedKey == key;
                    final isChecked = selected.contains(key);
                    final ruleCount = [
                      for (final r in rules.rules)
                        if (r.enabled && r.matches(t.server, t.tool)) r,
                    ].length;
                    final hidden = rules.overrides[key]?.hidden == true;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Material(
                        color: isFocused || (selectMode && isChecked)
                            ? Theme.of(context).colorScheme.primary
                                  .withValues(alpha: 0.09)
                            : Theme.of(context).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          key: ValueKey('tool-row-$key'),
                          dense: false,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          selected: selectMode ? isChecked : isFocused,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: isFocused
                                  ? Theme.of(context).colorScheme.primary
                                        .withValues(alpha: 0.5)
                                  : Theme.of(context).colorScheme.outlineVariant
                                        .withValues(alpha: 0.4),
                            ),
                          ),
                          leading: selectMode
                              ? Checkbox(
                                  value: isChecked,
                                  onChanged: (_) => onToggle(key),
                                )
                              : null,
                          title: Text(
                            t.tool.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 3),
                              Text(
                                t.server.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    ),
                              ),
                              if (t.tool.description?.isNotEmpty == true) ...[
                                const SizedBox(height: 3),
                                Text(
                                  t.tool.description!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (hidden)
                                const Tooltip(
                                  message: 'Hidden from the Operator',
                                  child: Icon(
                                    Icons.visibility_off_outlined,
                                    size: 16,
                                    color: StatusColors.muted,
                                  ),
                                ),
                              if (ruleCount > 0)
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: Tooltip(
                                    message:
                                        '$ruleCount rule${ruleCount == 1 ? '' : 's'} apply',
                                    child: StatusChip(
                                      '$ruleCount',
                                      StatusColors.info,
                                      icon: Icons.rule,
                                    ),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Tooltip(
                                  message: t.tool.isReadOnly
                                      ? 'Read-only'
                                      : 'May modify data',
                                  child: Icon(
                                    t.tool.isReadOnly
                                        ? Icons.visibility_outlined
                                        : Icons.edit_note_outlined,
                                    size: 16,
                                    color: t.tool.isReadOnly
                                        ? StatusColors.ok
                                        : StatusColors.warn,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          onTap: () => selectMode ? onToggle(key) : onOpen(t),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _BulkBar extends ConsumerWidget {
  const _BulkBar({
    required this.allShown,
    required this.someShown,
    required this.shownCount,
    required this.selected,
    required this.onSelectAll,
    required this.allTools,
  });

  final bool allShown;
  final bool someShown;
  final int shownCount;
  final Set<String> selected;
  final ValueChanged<bool> onSelectAll;
  final List<ToolRef> allTools;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final store = ref.read(toolRulesProvider.notifier);
    final overrides = ref.watch(toolRulesProvider).overrides;
    final anyVisible = selected.any((k) => overrides[k]?.hidden != true);
    final count = selected.length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                tristate: true,
                value: allShown ? true : (someShown ? null : false),
                onChanged: (_) => onSelectAll(!allShown),
              ),
              Expanded(
                child: Text(
                  count == 0
                      ? 'Select tools · all $shownCount shown'
                      : '$count selected',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonalIcon(
                onPressed: count == 0
                    ? null
                    : () =>
                          showRuleDialog(context, toolKeys: selected.toList()),
                icon: const Icon(Icons.playlist_add, size: 18),
                label: const Text('Add argument…'),
              ),
              OutlinedButton.icon(
                onPressed: count == 0
                    ? null
                    : () => store.setHidden(selected, anyVisible),
                icon: Icon(
                  anyVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
                label: Text(
                  anyVisible ? 'Hide from Operator' : 'Show to Operator',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
