import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/rules/tool_rules_store.dart';

import '../support/fakes.dart';
import '../support/gateway_harness.dart';

/// What someone else (another browser, a script) does to the same server.
Future<http.Response> _elsewhere(
  TestGateway gw,
  String method,
  String path, [
  Object? body,
]) async {
  final request = http.Request(method, Uri.parse('$gatewayUrl$path'))
    ..headers['authorization'] = 'Bearer $gatewayAdminToken'
    ..headers['content-type'] = 'application/json';
  if (body != null) request.body = jsonEncode(body);
  return http.Response.fromStream(await gw.client.send(request));
}

/// Polls until [done] holds (the event stream delivers in the background).
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late TestGateway gw;

  Future<ProviderContainer> live({bool realAuditLog = false}) async {
    gw = await TestGateway.start(
      upstream: FakeMcpServer(
        tools: [
          {
            'name': 'lookup',
            'description': 'Look',
            'inputSchema': {'type': 'object'},
          },
        ],
        handlers: {'lookup': (_) => textResult('found')},
      ),
    );
    final c = await makeContainer(
      gateway: gw,
      liveEvents: true,
      realAuditLog: realAuditLog,
      defaultProvider: false,
    );
    addTearDown(c.dispose);
    await c.read(mcpHubProvider.notifier).loaded;
    await c.read(auditLogProvider.notifier).loaded;
    await c.read(toolRulesProvider.notifier).loaded;
    await c.read(llmSettingsProvider.notifier).loaded;
    await c.read(chatControllerProvider.notifier).loaded;
    return c;
  }

  test(
    'a server added elsewhere appears, connected, without a refresh',
    () async {
      final c = await live();
      await _elsewhere(gw, 'POST', '/api/servers', {
        'name': 'Docs',
        'url': 'https://docs.test/mcp',
      });
      await _until(
        () =>
            c.read(mcpHubProvider).servers.isNotEmpty &&
            c.read(mcpHubProvider).servers.single.status ==
                ServerStatus.connected,
      );
      final runtime = c.read(mcpHubProvider).servers.single;
      expect(runtime.config.name, 'Docs');
      expect(runtime.status, ServerStatus.connected);
      expect(runtime.tools.map((t) => t.name), ['lookup']);
    },
  );

  test('a call made elsewhere shows in the audit log as it happens', () async {
    final c = await live();
    final created = jsonDecode(
      (await _elsewhere(gw, 'POST', '/api/servers', {
        'name': 'Docs',
        'url': 'https://docs.test/mcp',
      })).body,
    ) as Map;
    await _elsewhere(gw, 'POST', '/api/servers/${created['id']}/call', {
      'tool': 'lookup',
      'arguments': {},
    });
    await _until(
      () => c.read(auditLogProvider).any((e) => e.kind == AuditKind.toolCall),
    );
    final call = c
        .read(auditLogProvider)
        .firstWhere((e) => e.kind == AuditKind.toolCall);
    expect(call.toolName, 'lookup');
    expect(call.source, AuditSource.workbench);
  });

  test('rules changed elsewhere arrive', () async {
    final c = await live();
    await _elsewhere(gw, 'PUT', '/api/rules', {
      'rules': [
        {'id': 'r', 'name': 'From elsewhere', 'scope': 'all', 'args': []},
      ],
      'overrides': {},
    });
    await _until(() => c.read(toolRulesProvider).rules.isNotEmpty);
    expect(c.read(toolRulesProvider).rules.single.name, 'From elsewhere');
  });

  test('providers changed elsewhere arrive, without their keys', () async {
    final c = await live();
    await _elsewhere(gw, 'PUT', '/api/llm/providers/p1', {
      'name': 'Cloud',
      'kind': 'openaiCompatible',
      'baseUrl': 'https://api.example.com/v1',
      'apiKey': 'sk-test-key-0123456789',
      'models': ['m1'],
    });
    await _until(() => c.read(llmSettingsProvider).providers.isNotEmpty);
    final p = c.read(llmSettingsProvider).providers.single;
    expect(p.name, 'Cloud');
    expect(p.hasKey, isTrue);
    expect(p.apiKey, isNull);
  });

  test('conversations saved from another device are listed', () async {
    final c = await live();
    await gw.server.chats.save(
      'other',
      'admin',
      DateTime.now(),
      title: 'From my laptop',
    );
    await _elsewhere(gw, 'PUT', '/api/chats/other', {
      'title': 'From my laptop',
    });
    await _until(() => c.read(chatControllerProvider).conversations.isNotEmpty);
    expect(
      c.read(chatControllerProvider).conversations.single.title,
      'From my laptop',
    );
  });

  test(
    'the dashboard\'s own record of an action goes through the server',
    () async {
      final c = await live(realAuditLog: true);
      await c
          .read(auditLogProvider.notifier)
          .record(
            kind: AuditKind.manage,
            status: AuditStatus.success,
            source: AuditSource.operator,
            actor: 'operator:gemma4',
            toolName: 'add_server',
            serverName: 'Docs',
            approval: 'user',
            args: '{"password":"hunter2hunter2"}',
          );
      final stored = await gw.server.audit.recent();
      expect(stored.single.kind, 'manage');
      expect(stored.single.source, 'chat');
      expect(stored.single.actor, 'operator:gemma4');
      expect(stored.single.approval, 'user');
      expect(c.read(auditLogProvider).single.toolName, 'add_server');
    },
  );
}
