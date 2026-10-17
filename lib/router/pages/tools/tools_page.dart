import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/audit/audit_models.dart';
import '../../../engine/core/json.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/mcp/mcp_models.dart';
import '../../../engine/mcp/schema.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({super.key});

  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  String _query = '';
  String? _serverId;
  ({String serverId, String tool})? _selected;

  @override
  Widget build(BuildContext context) {
    final hub = ref.watch(mcpHubProvider);
    final all = hub.availableTools;
    final tools = [
      for (final t in all)
        if ((_serverId == null || t.server.id == _serverId) &&
            (_query.isEmpty ||
                t.tool.name.toLowerCase().contains(_query) ||
                (t.tool.description ?? '').toLowerCase().contains(_query)))
          t,
    ];

    ToolRef? selected;
    if (_selected != null) {
      for (final t in all) {
        if (t.server.id == _selected!.serverId &&
            t.tool.name == _selected!.tool) {
          selected = t;
        }
      }
    }

    return PageScaffold(
      title: 'Tools',
      subtitle: 'Inspect and test the tools exposed by your servers',
      child: all.isEmpty
          ? EmptyState(
              icon: Icons.build_outlined,
              title: 'No tools available',
              message: 'Connect an MCP server to discover its tools.',
              action: FilledButton(
                onPressed: () => context.go('/servers'),
                child: const Text('Open Servers'),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 820;
                final list = _ToolList(
                  tools: tools,
                  servers: hub.servers
                      .where((s) => s.tools.isNotEmpty)
                      .toList(),
                  serverId: _serverId,
                  selected: selected,
                  onQuery: (v) =>
                      setState(() => _query = v.trim().toLowerCase()),
                  onServer: (v) => setState(() => _serverId = v),
                  onSelect: (t) {
                    if (wide) {
                      setState(
                        () => _selected = (
                          serverId: t.server.id,
                          tool: t.tool.name,
                        ),
                      );
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => Scaffold(
                            appBar: AppBar(title: Text(t.tool.name)),
                            body: Padding(
                              padding: const EdgeInsets.all(kPagePadding),
                              child: ToolWorkbench(
                                key: ValueKey('${t.server.id}/${t.tool.name}'),
                                toolRef: t,
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                  },
                );
                if (!wide) return list;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 340, child: list),
                    const SizedBox(width: 16),
                    Expanded(
                      child: selected == null
                          ? const EmptyState(
                              icon: Icons.touch_app_outlined,
                              title: 'Select a tool',
                              message:
                                  'Its schema and a test bench appear here.',
                            )
                          : ToolWorkbench(
                              key: ValueKey(
                                '${selected.server.id}/${selected.tool.name}',
                              ),
                              toolRef: selected,
                            ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _ToolList extends StatelessWidget {
  const _ToolList({
    required this.tools,
    required this.servers,
    required this.serverId,
    required this.selected,
    required this.onQuery,
    required this.onServer,
    required this.onSelect,
  });

  final List<ToolRef> tools;
  final List<ServerRuntime> servers;
  final String? serverId;
  final ToolRef? selected;
  final ValueChanged<String> onQuery;
  final ValueChanged<String?> onServer;
  final ValueChanged<ToolRef> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search tools',
          ),
          onChanged: onQuery,
        ),
        if (servers.length > 1) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: serverId == null,
                  onSelected: (_) => onServer(null),
                ),
                for (final s in servers) ...[
                  const SizedBox(width: 6),
                  ChoiceChip(
                    label: Text(s.config.name),
                    selected: serverId == s.config.id,
                    onSelected: (_) => onServer(s.config.id),
                  ),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: 8),
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
                    final isSelected =
                        selected != null &&
                        selected!.server.id == t.server.id &&
                        selected!.tool.name == t.tool.name;
                    return ListTile(
                      dense: true,
                      selected: isSelected,
                      selectedTileColor: Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0.12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      title: Text(t.tool.name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${t.server.name}${t.tool.description == null ? '' : ' · ${t.tool.description}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: t.tool.isReadOnly
                          ? const Icon(
                              Icons.visibility_outlined,
                              size: 16,
                              color: StatusColors.ok,
                            )
                          : null,
                      onTap: () => onSelect(t),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class ToolWorkbench extends ConsumerStatefulWidget {
  const ToolWorkbench({super.key, required this.toolRef});

  final ToolRef toolRef;

  @override
  ConsumerState<ToolWorkbench> createState() => _ToolWorkbenchState();
}

class _ToolWorkbenchState extends ConsumerState<ToolWorkbench> {
  late final TextEditingController _args;
  McpToolResult? _result;
  int? _durationMs;
  String? _argsError;
  bool _running = false;

  McpTool get _tool => widget.toolRef.tool;

  @override
  void initState() {
    super.initState();
    _args = TextEditingController(
      text: prettyJson(skeletonFromSchema(_tool.inputSchema)),
    );
  }

  @override
  void dispose() {
    _args.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final parsed = tryDecodeObject(
      _args.text.trim().isEmpty ? '{}' : _args.text,
    );
    if (parsed == null) {
      setState(() => _argsError = 'Arguments must be a valid JSON object.');
      return;
    }
    setState(() {
      _argsError = null;
      _running = true;
      _result = null;
    });
    final watch = Stopwatch()..start();
    final result = await ref
        .read(mcpHubProvider.notifier)
        .callTool(
          serverId: widget.toolRef.server.id,
          toolName: _tool.name,
          args: parsed,
          source: AuditSource.workbench,
          actor: 'user',
        );
    watch.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
      _durationMs = watch.elapsedMilliseconds;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tool = _tool;
    final result = _result;
    String output = result?.text ?? '';
    final asJson = result == null ? null : tryDecodeJson(output);
    if (asJson != null) output = prettyJson(asJson);

    return ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(tool.displayName, style: theme.textTheme.titleLarge),
            ),
            if (tool.isReadOnly)
              const StatusChip(
                'read-only',
                StatusColors.ok,
                icon: Icons.visibility_outlined,
              )
            else if (tool.isDestructive)
              const StatusChip(
                'may modify data',
                StatusColors.warn,
                icon: Icons.warning_amber_rounded,
              ),
          ],
        ),
        Text(
          '${widget.toolRef.server.name} · ${tool.name}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (tool.description != null) ...[
          const SizedBox(height: 10),
          SelectableText(tool.description!),
        ],
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Input schema'),
          children: [JsonBlock(tool.inputSchema)],
        ),
        const SizedBox(height: 8),
        Text('Arguments (JSON)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        TextField(
          controller: _args,
          minLines: 4,
          maxLines: 12,
          style: const TextStyle(fontFamilyFallback: monoFonts, fontSize: 13),
          decoration: InputDecoration(errorText: _argsError),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: _running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('Run'),
            ),
            const SizedBox(width: 12),
            if (result != null) ...[
              StatusChip(
                result.isError ? 'error' : 'ok',
                result.isError ? StatusColors.bad : StatusColors.ok,
              ),
              const SizedBox(width: 8),
              Text('$_durationMs ms', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
        if (result != null) ...[
          const SizedBox(height: 12),
          CodeBlock(output, maxHeight: 360),
        ],
      ],
    );
  }
}
