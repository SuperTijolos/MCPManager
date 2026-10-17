import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/rules/tool_rules.dart';
import 'package:mcp_manager/engine/rules/tool_rules_store.dart';
import 'package:mcp_manager/engine/settings/app_settings.dart';
import 'package:mcp_manager/engine/settings/backup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// A container holding a bit of everything, written through the real stores.
Future<(dynamic, SharedPreferences)> _populated() async {
  final llm = ScriptedLlm([
    for (var i = 0; i < 4; i++) [LlmTextDelta('reply $i'), const LlmDone()],
  ]);
  final c = await makeContainer(server: FakeMcpServer(), llm: llm);
  addTearDown(c.dispose);
  await c
      .read(mcpHubProvider.notifier)
      .addServer(
        name: 'Docs',
        url: 'https://mcp.test/mcp',
        headers: {'Authorization': 'Bearer secret-token-1', 'X-Team': 'blue'},
      );
  c
      .read(llmSettingsProvider.notifier)
      .upsert(
        c
            .read(llmSettingsProvider)
            .providers
            .first
            .copyWith(
              apiKey: 'sk-provider-key',
              models: ['gemma4', 'gemma4:e4b'],
            ),
      );
  c
      .read(toolRulesProvider.notifier)
      .upsert(
        const ToolRule(
          id: 'r1',
          name: 'Reason',
          args: [RuleArg(name: 'reason', required: true)],
        ),
      );
  c
      .read(appSettingsProvider.notifier)
      .update((s) => s.copyWith(maxSteps: 9, extraInstructions: 'Be brief.'));
  c
      .read(auditLogProvider.notifier)
      .record(
        kind: AuditKind.toolCall,
        status: AuditStatus.success,
        source: AuditSource.workbench,
        actor: 'user',
        toolName: 't',
      );
  final chat = c.read(chatControllerProvider.notifier);
  await chat.send('first');
  chat.newConversation();
  await chat.send('second');
  return (c, c.read(sharedPreferencesProvider));
}

void main() {
  test('a backup contains settings but no credentials by default', () async {
    final (_, prefs) = await _populated();
    final backup = buildBackup(prefs);
    final text = jsonEncode(backup);

    expect(backup['format'], backupFormat);
    expect(backup['includesCredentials'], isFalse);
    expect(text, isNot(contains('secret-token-1')));
    expect(text, isNot(contains('sk-provider-key')));
    final server = (backup['servers'] as List).single as Map;
    expect(server['headers'], {
      'X-Team': 'blue',
    }, reason: 'only the secret header is stripped');
    expect(backup.containsKey('oauth'), isFalse);
    expect(backup.containsKey('audit'), isFalse);
    expect(backup.containsKey('chats'), isFalse);
    expect((backup['toolRules'] as Map)['rules'], hasLength(1));
    expect((backup['settings'] as Map)['maxSteps'], 9);
    expect(((backup['llm'] as Map)['providers'] as List).single['models'], [
      'gemma4',
      'gemma4:e4b',
    ]);
  });

  test(
    'credentials, conversations and the audit log are included only when asked',
    () async {
      final (_, prefs) = await _populated();
      final backup = buildBackup(
        prefs,
        includeCredentials: true,
        includeChats: true,
        includeAudit: true,
      );
      final text = jsonEncode(backup);
      expect(backup['includesCredentials'], isTrue);
      expect(text, contains('secret-token-1'));
      expect(text, contains('sk-provider-key'));
      expect(backup['audit'], isNotEmpty);
      final chats = backup['chats'] as Map;
      expect(chats['index'], hasLength(2));
      expect(chats['bodies'], hasLength(2));
    },
  );

  test(
    'export then import into a fresh browser restores the configuration',
    () async {
      final (_, source) = await _populated();
      final text = jsonEncode(
        buildBackup(
          source,
          includeChats: true,
          includeAudit: true,
          includeCredentials: true,
        ),
      );

      SharedPreferences.setMockInitialValues({});
      final fresh = await SharedPreferences.getInstance();
      final parsed = parseBackup(text);
      expect(parsed.error, isNull);
      final result = await restoreBackup(fresh, parsed.data!);
      expect(result.ok, isTrue);
      expect(
        result.restored,
        containsAll([
          'servers (1)',
          'tool rules (1)',
          'operator settings',
          'audit log (2)',
          'conversations (2)',
        ]),
      );

      // A new app on that storage sees all of it.
      final c = await makeContainer(
        prefs: {for (final k in fresh.getKeys()) k: fresh.get(k)!},
        server: FakeMcpServer(),
      );
      addTearDown(c.dispose);
      expect(
        c.read(mcpHubProvider).servers.single.config.headers['Authorization'],
        'Bearer secret-token-1',
      );
      expect(c.read(toolRulesProvider).rules.single.name, 'Reason');
      expect(c.read(appSettingsProvider).maxSteps, 9);
      expect(c.read(appSettingsProvider).extraInstructions, 'Be brief.');
      expect(
        c.read(llmSettingsProvider).providers.single.apiKey,
        'sk-provider-key',
      );
      expect(c.read(auditLogProvider), hasLength(2));
      expect(
        c.read(chatControllerProvider).conversations.map((m) => m.title),
        containsAll(['first', 'second']),
      );
    },
  );

  test('restoring a credential-free backup keeps the API keys already on this machine', () async {
    final (_, prefs) = await _populated();
    final backup = buildBackup(prefs); // no credentials
    final result = await restoreBackup(prefs, backup);
    expect(result.ok, isTrue);
    final llm = jsonDecode(prefs.getString('mcpm.llm.v1')!) as Map;
    expect((llm['providers'] as List).single['apiKey'], 'sk-provider-key');
  });

  test('only the sections in a backup are replaced', () async {
    final (_, prefs) = await _populated();
    final before = prefs.getString('mcpm.servers.v1');
    final result = await restoreBackup(prefs, {
      'format': backupFormat,
      'version': 1,
      'settings': {
        'maxSteps': 4,
        'extraInstructions': '',
        'confirmReadOnly': true,
      },
    });
    expect(result.restored, ['operator settings']);
    expect(prefs.getString('mcpm.servers.v1'), before);
    expect(
      (jsonDecode(prefs.getString('mcpm.settings.v1')!) as Map)['maxSteps'],
      4,
    );
  });

  group('parseBackup', () {
    test('rejects things that are not backups, clearly', () {
      expect(parseBackup('nope{').error, 'That is not valid JSON.');
      expect(parseBackup('[]').error, 'That is not an MCP Manager backup.');
      expect(
        parseBackup('{"format":"other"}').error,
        'That is not an MCP Manager backup.',
      );
      expect(
        parseBackup('{"format":"$backupFormat","version":99}').error,
        contains('newer version'),
      );
      expect(
        parseBackup(
          '{"format":"$backupFormat","version":1,"servers":[{"id":1}]}',
        ).error,
        contains('servers section'),
      );
    });

    test(
      'accepts a minimal backup, and an empty one restores nothing',
      () async {
        final parsed = parseBackup('{"format":"$backupFormat","version":1}');
        expect(parsed.error, isNull);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final r = await restoreBackup(prefs, parsed.data!);
        expect(r.ok, isFalse);
        expect(r.problems.single, contains('nothing to restore'));
      },
    );
  });

  group('storage', () {
    test('the report counts what is there', () async {
      final (_, prefs) = await _populated();
      final report = {for (final e in storageReport(prefs)) e.label: e};
      expect(report['Servers']!.detail, '1 configured');
      expect(
        report['Audit log']!.detail,
        '2 events',
        reason: 'the connection and the manual one',
      );
      expect(report['Conversations']!.detail, '2 saved');
      expect(report['Tool rules']!.detail, '1 rules · 0 overrides');
      expect(report['Providers & models']!.detail, '1 providers');
      expect(report.values.every((e) => e.bytes >= 0), isTrue);
      expect(
        report['Conversations']!.bytes,
        greaterThan(report['Servers']!.bytes ~/ 4),
      );
    });

    test('an empty profile reports zeros without crashing', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(storageReport(prefs).every((e) => e.bytes == 0), isTrue);
    });

    test('deleting conversations leaves everything else', () async {
      final (_, prefs) = await _populated();
      await removeConversations(prefs);
      expect(prefs.getKeys().where((k) => k.startsWith('mcpm.chat')), isEmpty);
      expect(prefs.getString('mcpm.servers.v1'), isNotNull);
    });

    test('reset removes only this app\'s data', () async {
      final (_, prefs) = await _populated();
      await prefs.setString('someone.else', 'keep me');
      final removed = await resetAll(prefs);
      expect(removed, greaterThan(5));
      expect(prefs.getKeys(), {'someone.else'});
    });

    test('byte formatting', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(3 * 1024 * 1024), '3.00 MB');
    });
  });
}
