import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/core/prefs.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/resizable_split.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'rules_tab.dart';
import 'tool_detail.dart';
import 'tool_list.dart';

const _listWidthKey = 'mcpm.ui.toolsListWidth';
const _defaultListWidth = 380.0;

class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({super.key});

  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  String _query = '';
  String? _serverId;
  String? _focusedKey;
  bool _selectMode = false;
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final hub = ref.watch(mcpHubProvider);
    final ruleCount = ref.watch(toolRulesProvider).rules.length;
    final all = hub.availableTools;
    final tools = [
      for (final t in all)
        if ((_serverId == null || t.server.id == _serverId) &&
            (_query.isEmpty ||
                t.tool.name.toLowerCase().contains(_query) ||
                (t.tool.description ?? '').toLowerCase().contains(_query)))
          t,
    ];
    ToolRef? focused;
    for (final t in all) {
      if (ToolList.keyOf(t) == _focusedKey) focused = t;
    }

    return PageScaffold(
      title: 'Tools',
      subtitle: 'Inspect and test tools, and shape what the Operator sees',
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
          onPressed: () => context.go('/servers'),
          child: const Text('Open Servers'),
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
              setState(() => _focusedKey = ToolList.keyOf(t));
            } else {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(t.tool.name)),
                    body: Padding(
                      padding: const EdgeInsets.all(kPagePadding),
                      child: ToolDetail(toolRef: t),
                    ),
                  ),
                ),
              );
            }
          },
        );
        if (!wide) return list;

        final prefs = ref.read(sharedPreferencesProvider);
        return ResizableSplit(
          initialWidth: prefs.getDouble(_listWidthKey) ?? _defaultListWidth,
          onChanged: (w) => prefs.setDouble(_listWidthKey, w),
          semanticLabel: 'Resize the tool list',
          left: list,
          right: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: focused == null
                ? const EmptyState(
                    icon: Icons.touch_app_outlined,
                    title: 'Select a tool',
                    message: 'Test it, compare its schema, and see what the Operator gets.',
                  )
                : ToolDetail(
                    key: ValueKey(ToolList.keyOf(focused)),
                    toolRef: focused,
                  ),
          ),
        );
      },
    );
  }
}
