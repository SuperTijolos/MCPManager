import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/agent_tool.dart';
import 'package:mcp_manager/engine/agent/toolbox.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/rules/tool_rules.dart';
import 'package:mcp_manager/engine/rules/tool_rules_store.dart';

import '../support/fakes.dart';

Map<String, dynamic> _wire(String name, [Map<String, dynamic>? annotations]) =>
    {
      'name': name,
      'description': 'Does $name.',
      'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
      'annotations': ?annotations,
    };

/// A fresh toolbox for the current rules (the toolbox is built once per read).
AgentTool _tool(ProviderContainer c, String name) => c
    .read(Provider((ref) => buildToolbox(ref)))
    .firstWhere((t) => t.name == 'Files__$name');

void main() {
  late ProviderContainer c;
  late String serverId;

  setUp(() async {
    c = await makeContainer(
      server: FakeMcpServer(
        tools: [
          _wire('lookup', {'readOnlyHint': true}),
          _wire('peek'),
          _wire('rm', {'destructiveHint': true}),
        ],
      ),
    );
    addTearDown(c.dispose);
    final runtime = await c
        .read(mcpHubProvider.notifier)
        .addServer(name: 'Files', url: 'https://f.test/mcp');
    serverId = runtime.config.id;
  });

  test('the Operator asks about every tool that is not marked read-only', () {
    expect(_tool(c, 'lookup').requiresApproval, isFalse);
    expect(_tool(c, 'peek').requiresApproval, isTrue);
    expect(_tool(c, 'rm').requiresApproval, isTrue);
  });

  test('a tool the user vouched for runs without asking', () {
    c.read(toolRulesProvider.notifier).setReadOnly([
      toolKey(serverId, 'peek'),
    ], true);
    expect(_tool(c, 'peek').requiresApproval, isFalse);

    c.read(toolRulesProvider.notifier).setReadOnly([
      toolKey(serverId, 'peek'),
    ], false);
    expect(_tool(c, 'peek').requiresApproval, isTrue);
  });

  test('vouching never overrides a server that says the tool writes', () {
    c.read(toolRulesProvider.notifier).setReadOnly([
      toolKey(serverId, 'rm'),
    ], true);
    expect(_tool(c, 'rm').requiresApproval, isTrue);
  });
}
