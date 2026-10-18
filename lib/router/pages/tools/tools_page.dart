import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/core/json.dart';
import '../../../engine/core/prefs.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/resizable_split.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'rules_tab.dart';
import 'tool_detail.dart';
import 'tool_focus.dart';
import 'tool_list.dart';

const _listWidthKey = 'mcpm.ui.toolsListWidth';
const _defaultListWidth = 380.0;

class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({super.key, this.focus});

  /// Open this tool on arrival (a link from the audit log).
  final ToolFocus? focus;

  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  String _query = '';
  String? _serverId;
  ToolListFilter _filter = ToolListFilter.all;
  String? _focusedKey;
  bool _selectMode = false;
  final Set<String> _selected = {};

  /// A tool to open once the layout is known, and the arguments to start with.
  ToolFocus? _pendingFocus;
  Json? _testArgs;
  int _focusCount = 0;

  @override
  void initState() {
    super.initState();
    _applyFocus(widget.focus);
  }

  @override
  void didUpdateWidget(ToolsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focus != oldWidget.focus) _applyFocus(widget.focus);
  }

  void _applyFocus(ToolFocus? focus) {
    if (focus == null) return;
    // Clear anything that could hide the tool being opened.
    _query = '';
    _serverId = null;
    _filter = ToolListFilter.all;
    _focusedKey = focus.key;
    _testArgs = focus.args;
    _pendingFocus = focus;
    _focusCount++;
  }

  @override
  Widget build(BuildContext context) {
    final hub = ref.watch(mcpHubProvider);
    final rules = ref.watch(toolRulesProvider);
    final ruleCount = rules.rules.length;
    final all = hub.availableTools;
    final tools = [
      for (final t in all)
        if ((_serverId == null || t.server.id == _serverId) &&
            (_query.isEmpty ||
                t.tool.name.toLowerCase().contains(_query) ||
                (t.tool.description ?? '').toLowerCase().contains(_query) ||
                t.tool.displayName.toLowerCase().contains(_query)) &&
            switch (_filter) {
              ToolListFilter.all => true,
              ToolListFilter.readOnly => rules.isReadOnly(t.server, t.tool),
              ToolListFilter.notReadOnly => !rules.isReadOnly(t.server, t.tool),
              ToolListFilter.hidden =>
                rules.overrides[ToolList.keyOf(t)]?.hidden == true,
            })
          t,
    ];
    ToolRef? focused;
    for (final t in all) {
      if (ToolList.keyOf(t) == _focusedKey) focused = t;
    }

    return PageScaffold(
      title: 'MCP Tools',
      subtitle: 'Inspect and test tools, and shape what the Operator sees',
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ToolSummary(
              tools: all,
              readOnly: all
                  .where((t) => rules.isReadOnly(t.server, t.tool))
                  .length,
              servers: hub.connectedCount,
            ),
            const SizedBox(height: 12),
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Tools (${all.length})'),
                Tab(text: 'Rules ($ruleCount)'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                children: [
                  _toolsTab(context, hub, all, tools, focused),
                  const RulesTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openNarrow(BuildContext context, ToolRef t, {Json? args}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(t.tool.name)),
          body: Padding(
            padding: const EdgeInsets.all(kPagePadding),
            child: ToolDetail(toolRef: t, initialArgs: args),
          ),
        ),
      ),
    );
  }

  Widget _toolsTab(
    BuildContext context,
    McpHubState hub,
    List<ToolRef> all,
    List<ToolRef> tools,
    ToolRef? focused,
  ) {
    if (all.isEmpty) {
      return EmptyState(
        icon: Icons.build_outlined,
        title: 'No tools available',
        message: 'Connect an MCP server to discover its tools.',
        action: FilledButton(
          onPressed: () => context.go('/mcp-servers'),
          child: const Text('Open MCP Servers'),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 820;
        final list = ToolList(
          tools: tools,
          servers: hub.servers.where((s) => s.tools.isNotEmpty).toList(),
          serverId: _serverId,
          focusedKey: _focusedKey,
          selectMode: _selectMode,
          selected: _selected,
          filter: _filter,
          totalCount: all.length,
          onFilter: (value) => setState(() => _filter = value),
          onQuery: (v) => setState(() => _query = v.trim().toLowerCase()),
          onServer: (v) => setState(() => _serverId = v),
          onSelectMode: (on) => setState(() {
            _selectMode = on;
            if (!on) _selected.clear();
          }),
          onToggle: (key) => setState(
            () => _selected.contains(key)
                ? _selected.remove(key)
                : _selected.add(key),
          ),
          onSelectAll: (on) => setState(() {
            final keys = [for (final t in tools) ToolList.keyOf(t)];
            on ? _selected.addAll(keys) : _selected.removeAll(keys);
          }),
          onOpen: (t) {
            if (wide) {
              setState(() {
                _focusedKey = ToolList.keyOf(t);
                _testArgs = null;
              });
            } else {
              _openNarrow(context, t);
            }
          },
        );
        // A link from elsewhere: on a phone the tool opens as its own page.
        if (_pendingFocus != null) {
          _pendingFocus = null;
          final target = focused;
          if (!wide && target != null) {
            final args = _testArgs;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _openNarrow(context, target, args: args);
            });
          }
        }
        if (!wide) return list;

        final prefs = ref.read(sharedPreferencesProvider);
        return ResizableSplit(
          initialWidth: prefs.getDouble(_listWidthKey) ?? _defaultListWidth,
          onChanged: (w) => prefs.setDouble(_listWidthKey, w),
          semanticLabel: 'Resize the tool list',
          left: list,
          right: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: focused == null
                    ? _ToolExplorer(
                        tools: all,
                        onOpen: (tool) =>
                            setState(() => _focusedKey = ToolList.keyOf(tool)),
                      )
                    : ToolDetail(
                        key: ValueKey(
                          '${ToolList.keyOf(focused)}#$_focusCount',
                        ),
                        toolRef: focused,
                        initialArgs: _testArgs,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Small overview to replace the otherwise unused detail pane before a tool
/// is selected. Counts are derived from live MCP annotations, never guessed.
class _ToolSummary extends StatelessWidget {
  const _ToolSummary({
    required this.tools,
    required this.readOnly,
    required this.servers,
  });
  final List<ToolRef> tools;

  /// Declared by the server or vouched for by the user.
  final int readOnly;
  final int servers;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Wrap(
      key: const ValueKey('mcp-tool-summary'),
      spacing: 22,
      runSpacing: 8,
      children: [
        _SummaryItem(Icons.build_outlined, '${tools.length} discovered', color),
        _SummaryItem(Icons.dns_outlined, '$servers connected', color),
        _SummaryItem(
          Icons.visibility_outlined,
          '$readOnly read-only',
          StatusColors.ok,
        ),
        _SummaryItem(
          Icons.edit_note_outlined,
          '${tools.length - readOnly} not marked read-only',
          StatusColors.warn,
        ),
      ],
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem(this.icon, this.label, this.color);
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _ToolExplorer extends StatelessWidget {
  const _ToolExplorer({required this.tools, required this.onOpen});
  final List<ToolRef> tools;
  final ValueChanged<ToolRef> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final servers = <String, int>{};
    for (final t in tools) {
      servers[t.server.name] = (servers[t.server.name] ?? 0) + 1;
    }
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 34,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  'Explore your MCP tools',
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Choose a tool to inspect its inputs, run a test call, and see exactly what the Operator can access.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'CONNECTED COLLECTIONS',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                for (final entry in servers.entries.take(5))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        Icon(
                          Icons.dns_outlined,
                          size: 17,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            entry.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${entry.value} tools',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 18),
                const Divider(),
                const SizedBox(height: 14),
                for (final guide in [
                  (
                    Icons.play_circle_outline,
                    'Test',
                    'Run tools with editable JSON arguments.',
                  ),
                  (
                    Icons.data_object_outlined,
                    'Schema',
                    'Compare the original schema with rule changes.',
                  ),
                  (
                    Icons.smart_toy_outlined,
                    'Operator view',
                    'Review visibility, rules and instructions.',
                  ),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          guide.$1,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${guide.$2}  ',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                TextSpan(text: guide.$3),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (tools.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    key: const ValueKey('open-first-tool'),
                    onPressed: () => onOpen(tools.first),
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: const Text('Inspect first tool'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
