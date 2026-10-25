import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audit/audit_models.dart';
import '../rules/tool_rules.dart';
import '../rules/tool_rules_store.dart';
import '../settings/app_settings.dart';
import '../core/json.dart';
import '../mcp/mcp_hub.dart';
import '../mcp/mcp_models.dart';
import 'agent_tool.dart';
import 'platform_tools.dart';
import 'tool_insight.dart';

const maxToolOutputChars = 12000;

/// Builds the tool list for one operator run: built-in platform tools plus
/// every tool of every connected server. Names are made unique and valid for
/// function calling.
List<AgentTool> buildToolbox(Ref ref) => buildToolboxWithInsight(ref).tools;

/// The tools for a run plus what we know about them: an index by purpose that
/// powers the capability map, `mcpm_find_tools` and failure hints.
class Toolbox {
  const Toolbox(this.tools, this.index);
  final List<AgentTool> tools;
  final ToolIndex index;
}

Toolbox buildToolboxWithInsight(Ref ref) {
  final tools = <AgentTool>[...platformTools(ref)];
  final used = tools.map((t) => t.name).toSet();
  final insights = <ToolInsight>[];

  final rules = ref.read(toolRulesProvider);
  for (final entry in ref.read(mcpHubProvider).availableTools) {
    final effective = rules.effective(entry.server, entry.tool);
    // Tools hidden from the Operator are simply not offered to it.
    if (!effective.visible) continue;
    final name = _uniqueName(
      '${_slug(entry.server.name)}__${_slug(entry.tool.name)}',
      used,
    );
    used.add(name);
    tools.add(_McpAgentTool(ref, name, effective));
    insights.add(
      ToolInsight.of(
        exposedName: name,
        serverName: entry.server.name,
        tool: entry.tool,
        readOnly: effective.readOnly,
      ),
    );
  }
  final index = ToolIndex(insights);
  tools.add(_FindToolsTool(index));
  return Toolbox(tools, index);
}

/// Lets the model look a tool up by what it wants to do, across every server.
class _FindToolsTool extends AgentTool {
  _FindToolsTool(this._index);

  final ToolIndex _index;

  @override
  String get name => 'mcpm_find_tools';

  @override
  String get description =>
      'Find which tool to use. Describe what you want to do ("open a file", '
      '"run a shell command", "list database tables") and get the best '
      'matching tools from every connected server, with their exact names and '
      'required arguments.';

  @override
  Json get parameters => {
    'type': 'object',
    'properties': {
      'purpose': {
        'type': 'string',
        'description': 'What you want to accomplish, in a few words.',
      },
    },
    'required': ['purpose'],
  };

  @override
  String get label => 'MCP Manager · $name';

  @override
  bool get requiresApproval => false;

  @override
  Future<AgentToolResult> run(Json args, ToolRunContext context) async {
    final purpose = '${args['purpose'] ?? ''}'.trim();
    if (purpose.isEmpty) {
      return const AgentToolResult(
        'Say what you want to do, for example "open a file".',
        isError: true,
      );
    }
    final matches = _index.find(purpose);
    if (matches.isEmpty) {
      return AgentToolResult(
        'No connected tool matches "$purpose". Tools by purpose:\n'
        '${buildCapabilityMap(_index)}',
      );
    }
    return AgentToolResult(
      prettyJson([
        for (final m in matches)
          {
            'tool': m.exposedName,
            'server': m.serverName,
            'for': [for (final c in m.capabilities) c.label],
            'does': m.summary,
            'requires': m.requiredArgs,
            if (m.pathArgs.isNotEmpty) 'locationArguments': m.pathArgs,
            'readOnly': m.readOnly,
          },
      ]),
    );
  }
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
  _McpAgentTool(this._ref, this.name, this._effective);

  final Ref _ref;
  final EffectiveTool _effective;

  McpServerConfig get _server => _effective.server;
  McpTool get _tool => _effective.tool;

  @override
  final String name;

  /// The description and schema are the effective ones: the server's own plus
  /// whatever rules added.
  @override
  String get description => '[${_server.name}] ${_effective.description}';

  @override
  Json get parameters => _effective.inputSchema;

  @override
  String get label => '${_server.name} · ${_tool.name}';

  @override
  bool get requiresApproval =>
      !_effective.readOnly || _ref.read(appSettingsProvider).confirmReadOnly;

  @override
  Future<AgentToolResult> run(Json args, ToolRunContext context) async {
    // The server applies the rules, refuses a call that misses a required
    // argument, and records either outcome.
    final result = await _ref
        .read(mcpHubProvider.notifier)
        .callTool(
          serverId: _server.id,
          toolName: _tool.name,
          args: args,
          clientArgs: args,
          source: AuditSource.operator,
          actor: context.actor,
          approval: context.approval,
          conversationId: context.conversationId,
        );
    return AgentToolResult(result.text, isError: result.isError);
  }

  @override
  Future<void> onDenied(Json args, ToolRunContext context) async {
    await _ref
        .read(mcpHubProvider.notifier)
        .recordDenied(
          serverId: _server.id,
          toolName: _tool.name,
          args: args,
          actor: context.actor,
          conversationId: context.conversationId,
        );
  }
}

/// Wraps tool output so the model treats it as untrusted data.
String wrapToolOutput(String toolName, String output) {
  final text = truncate(output, maxToolOutputChars);
  return '<tool_output name="$toolName">\n$text\n</tool_output>';
}
