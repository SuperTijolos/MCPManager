import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/core/redact.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';

import '../support/fakes.dart';

void main() {
  test('a big JSON tool result is stored as valid, redacted JSON', () async {
    final server = FakeMcpServer(
      tools: [
        {
          'name': 'get_file',
          'description': 'Reads a file',
          'inputSchema': {'type': 'object', 'properties': <String, dynamic>{}},
        },
      ],
      handlers: {
        'get_file': (_) => textResult(
          jsonEncode({
            'path': '/app/main.dart',
            'password': 'hunter2',
            'content': "import 'dart:async';\n${'code line\n' * 2000}",
          }),
        ),
      },
    );
    final c = await makeContainer(server: server);
    addTearDown(c.dispose);
    final hub = c.read(mcpHubProvider.notifier);
    final runtime = await hub.addServer(
      name: 'Files',
      url: 'https://f.test/mcp',
    );
    await c.read(auditLogProvider.notifier).clear();

    await hub.callTool(
      serverId: runtime.config.id,
      toolName: 'get_file',
      args: const {},
      source: AuditSource.workbench,
      actor: 'user',
    );

    final event = c.read(auditLogProvider).single;
    expect(event.result!.length, lessThanOrEqualTo(2000));
    expect(event.result, isNot(contains('hunter2')));
    final stored = jsonDecode(event.result!) as Map;
    expect(stored['path'], '/app/main.dart');
    expect(stored['password'], redacted);
    expect(stored['content'], startsWith("import 'dart:async';"));
    expect(previewWasShortened(event.result!), isTrue);
  });
}
