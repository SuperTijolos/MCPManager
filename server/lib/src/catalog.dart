import 'package:mcp_core/mcp_core.dart';

import 'models.dart';
import 'state.dart';
import 'upstream.dart';

/// One tool as a portal client sees it.
class ExposedTool {
  const ExposedTool({
    required this.server,
    required this.tool,
    required this.exposedName,
    required this.effective,
    this.excluded = false,
  });

  final UpstreamServer server;
  final McpTool tool;

  /// `<server slug>__<tool>`: unique inside the portal.
  final String exposedName;

  /// The description and schema after rules and overrides.
  final EffectiveTool effective;

  /// Left out of this portal by its settings. Only present in admin previews.
  final bool excluded;

  /// What `tools/list` returns for it.
  Json toMcpJson() => {
    'name': exposedName,
    if (tool.title != null) 'title': tool.title,
    'description': '[${server.name}] ${effective.description}',
    'inputSchema': effective.inputSchema,
    if (tool.annotations.isNotEmpty) 'annotations': tool.annotations,
  };
}

/// The tools of one portal, and the servers that could not be listed.
class PortalCatalog {
  PortalCatalog(this.tools, this.problems);

  final List<ExposedTool> tools;

  /// Server id → why its tools are missing.
  final Map<String, String> problems;

  ExposedTool? find(String exposedName) =>
      tools.where((t) => t.exposedName == exposedName).firstOrNull;
}

String _slug(String input) => input
    .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

String _uniqueName(String base, Set<String> used) {
  var name = base.length > 64 ? base.substring(0, 64) : base;
  var n = 2;
  while (used.contains(name)) {
    final suffix = '_$n';
    final cut = (64 - suffix.length).clamp(0, base.length);
    name = '${base.substring(0, cut)}$suffix';
    n++;
  }
  return name;
}

/// Builds what [portal] exposes: its enabled servers' tools, minus the ones it
/// excludes or hides, reshaped by the rules and overrides.
///
/// With [includeHidden] the hidden and excluded tools are kept too (marked
/// by `effective.visible == false` and [ExposedTool.excluded]), for the admin
/// preview.
Future<PortalCatalog> buildCatalog(
  Portal portal,
  PortalState state,
  UpstreamPool pool, {
  bool includeHidden = false,
  bool refresh = false,
}) async {
  final tools = <ExposedTool>[];
  final problems = <String, String>{};
  final used = <String>{};

  final live = [
    for (final ref in portal.servers)
      if (ref.enabled)
        if (state.server(ref.serverId) case final server?)
          if (server.enabled) server,
  ];
  final catalogs = await Future.wait([
    for (final server in live) pool.catalog(server, refresh: refresh),
  ]);

  for (var i = 0; i < live.length; i++) {
    final server = live[i];
    final catalog = catalogs[i];
    if (catalog.error != null) problems[server.id] = catalog.error!;
    for (final tool in catalog.tools) {
      final key = toolKey(server.id, tool.name);
      final excluded = portal.excludedTools.contains(key);
      if (excluded && !includeHidden) continue;
      final effective = computeEffective(
        server.toConfig(),
        tool,
        state.rules,
        state.overrides[key],
      );
      if (!effective.visible && !includeHidden) continue;
      final name = _uniqueName(
        '${_slug(server.slug)}__${_slug(tool.name)}',
        used,
      );
      used.add(name);
      tools.add(
        ExposedTool(
          server: server,
          tool: tool,
          exposedName: name,
          effective: effective,
          excluded: excluded,
        ),
      );
    }
  }
  return PortalCatalog(tools, problems);
}
