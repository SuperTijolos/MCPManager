import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audit/audit_models.dart';
import '../core/json.dart';
import '../mcp/mcp_hub.dart';
import '../mcp/mcp_models.dart';
import 'agent_tool.dart';
import 'platform_tools.dart';

const maxToolOutputChars = 12000;

/// Builds the tool list for one operator run: built-in platform tools plus
/// every tool of every connected server. Names are made unique and valid for
/// function calling.
List<AgentTool> buildToolbox(Ref ref) {
  final tools = <AgentTool>[...platformTools(ref)];
  final used = tools.map((t) => t.name).toSet();

  for (final entry in ref.read(mcpHubProvider).availableTools) {
    final name = _uniqueName(
      '${_slug(entry.server.name)}__${_slug(entry.tool.name)}',
      used,
    );
    used.add(name);
    tools.add(_McpAgentTool(ref, name, entry.server, entry.tool));
  }
  return tools;
}

String _slug(String input) => input
    .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

String _uniqueName(String base, Set<String> used) {
  var name = base.length > 64 ? base.substring(0, 64) : base;
  var n = 2;
  while (used.contains(name)) {
    final suffix = '_$n';
    name =
        '${base.substring(0, (64 - suffix.length).clamp(0, base.length))}$suffix';
    n++;
  }
  return name;
}

class _McpAgentTool extends AgentTool {
  _McpAgentTool(this._ref, this.name, this._server, this._tool);

  final Ref _ref;
  final McpServerConfig _server;
  final McpTool _tool;

  @override
  final String name;

  @override
  String get description =>
      '[${_server.name}] ${_tool.description ?? _tool.displayName}';

  @override
  Json get parameters => _tool.inputSchema;

  @override
  String get label => '${_server.name} · ${_tool.name}';

  @override
  bool get requiresApproval => !_tool.isReadOnly;

  @override
  Future<AgentToolResult> run(Json args, ToolRunContext context) async {
    final result = await _ref
        .read(mcpHubProvider.notifier)
        .callTool(
          serverId: _server.id,
          toolName: _tool.name,
          args: args,
          source: AuditSource.operator,
          actor: context.actor,
          approval: context.approval,
        );
    return AgentToolResult(result.text, isError: result.isError);
  }

  @override
  void onDenied(Json args, ToolRunContext context) {
    _ref
        .read(mcpHubProvider.notifier)
        .recordDenied(
          serverId: _server.id,
          toolName: _tool.name,
          args: args,
          actor: context.actor,
        );
  }
}

/// Wraps tool output so the model treats it as untrusted data.
String wrapToolOutput(String toolName, String output) {
  final text = truncate(output, maxToolOutputChars);
  return '<tool_output name="$toolName">\n$text\n</tool_output>';
}
