import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/agent/chat_controller.dart';
import 'package:mcp_manager/engine/agent/chat_store.dart';
import 'package:mcp_manager/engine/server/session.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/llm/provider_config.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/settings/app_settings.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';
import '../support/gateway_harness.dart';

class _BrokenModels implements LlmProvider {
  @override
  Future<List<LlmModel>> listModels() async =>
      throw LlmException('connection refused');
  @override
  Stream<LlmEvent> chat({
    required String model,
    required List<LlmMessage> messages,
    List<LlmToolSpec> tools = const [],
  }) => const Stream.empty();
  @override
  void close() {}
}

Future<ProviderContainer> _open(
  WidgetTester tester, {
  LlmProvider? llm,
  Size size = const Size(1400, 900),
  Map<String, Object> prefs = const {},
  Future<void> Function(TestGateway gateway)? setup,
}) async {
  final c = await pumpApp(
    tester,
    llm: llm ?? ScriptedLlm(const []),
    server: FakeMcpServer(),
    size: size,
    prefs: prefs,
    setup: setup,
  );
  await goTo(tester, '/settings');
  return c;
}

/// Opens a Settings section from Settings' own list (wide) or chips (phone),
/// not from the app's navigation rail, which has similar labels.
Future<void> _section(WidgetTester tester, String label) async {
  final tile = find.widgetWithText(ListTile, label);
  final chip = find.widgetWithText(ChoiceChip, label);
  await tester.tap(tile.evaluate().isNotEmpty ? tile.first : chip.first);
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

// Built in memory so GitHub does not mistake a test fixture for a real key.
final _openRouterSyntheticKey =
    'sk-or-v1-${List.filled(4, '0123456789abcdef').join()}';

void main() {
  group('navigation', () {
    testWidgets('three sections, Models first', (tester) async {
      await _open(tester);
      expect(
        find.text('Providers and the model the Operator runs on'),
        findsOneWidget,
      );
      for (final s in ['Models', 'Operator', 'Account & data']) {
        expect(find.text(s), findsWidgets);
      }
      await _section(tester, 'Operator');
      expect(
        find.text('Limits, approvals and your instructions'),
        findsOneWidget,
      );
      await _section(tester, 'Account & data');
      expect(
        find.text('Who is signed in, where data lives, clean-up'),
        findsOneWidget,
      );
    });

    testWidgets('on a phone the sections are chips', (tester) async {
      await _open(tester, size: const Size(400, 800));
      for (final label in ['Models', 'Operator', 'Account & data']) {
        expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
      }
      await tester.tap(find.widgetWithText(ChoiceChip, 'Operator'));
      await tester.pumpAndSettle();
      expect(find.text('Tool steps per request'), findsOneWidget);
    });
  });

  group('models', () {
    testWidgets('the provider card shows what is configured', (tester) async {
      await _open(tester);
      expect(find.text('Ollama'), findsOneWidget);
      expect(find.text('no API key'), findsOneWidget);
      expect(find.text('context $defaultOllamaContext'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'gemma4'), findsOneWidget);
      expect(find.text('active'), findsOneWidget);
    });

    testWidgets('Check reports reachability, missing models, and errors', (
      tester,
    ) async {
      await _open(tester, llm: ScriptedLlm(const []));
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.text('Reachable · 1 model'), findsOneWidget);
    });

    testWidgets('Check names models that are enabled but not installed', (
      tester,
    ) async {
      final c = await _open(tester);
      final p = c.read(llmSettingsProvider).providers.single;
      await c
          .read(llmSettingsProvider.notifier)
          .upsert(p.copyWith(models: ['gemma4', 'missing-model']));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('not installed: missing-model'),
        findsOneWidget,
      );
    });

    testWidgets('Check shows the error when the provider is down', (
      tester,
    ) async {
      await _open(tester, llm: _BrokenModels());
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.textContaining('connection refused'), findsOneWidget);
    });

    testWidgets('adding from a preset prefills the form', (tester) async {
      final c = await _open(tester);
      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      expect(find.text('LM Studio'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();

      expect(find.text('Add OpenRouter'), findsOneWidget);
      expect(
        find.widgetWithText(TextFormField, 'https://openrouter.ai/api/v1'),
        findsOneWidget,
      );
      // Hosted services need a key.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('This service needs a key'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API key'),
        _openRouterSyntheticKey,
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final added = c.read(llmSettingsProvider).providers.last;
      expect(added.name, 'OpenRouter');
      expect(added.baseUrl, 'https://openrouter.ai/api/v1');
      expect(added.apiKey, isNull, reason: 'the dashboard does not keep it');
      expect(added.hasKey, isTrue);
      expect(
        gatewayOf(c).state.llmProviders.last.apiKey,
        _openRouterSyntheticKey,
        reason: 'the server holds it',
      );
      expect(find.text('API key set'), findsOneWidget);
    });

    testWidgets('OpenRouter rejects a key from the wrong service', (
      tester,
    ) async {
      final c = await _open(tester);
      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API key'),
        'sk-test-from-another-provider',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('OpenRouter keys start with'), findsOneWidget);
      expect(c.read(llmSettingsProvider).providers.length, 1);
    });

    testWidgets('the server refuses a truncated OpenRouter key and says why', (
      tester,
    ) async {
      final c = await _open(tester);
      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      // Long enough for the form, short enough for the server to refuse.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API key'),
        'sk-or-v1-${'0' * 20}',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Invalid OpenRouter API key'), findsWidgets);
      expect(c.read(llmSettingsProvider).providers.length, 1);
      expect(gatewayOf(c).state.llmProviders.length, 1);
    });

    testWidgets('a stored key is kept unless replaced or removed', (
      tester,
    ) async {
      final c = await _open(tester);
      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'API key'),
        'Bearer $_openRouterSyntheticKey',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        gatewayOf(c).state.llmProviders.last.apiKey,
        _openRouterSyntheticKey,
        reason: 'a pasted Bearer prefix is dropped',
      );

      // Editing without touching the key keeps it, and it is not asked for.
      await tester.tap(find.byTooltip('Edit').last);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('A key is stored on the server'),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'OR 2',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(gatewayOf(c).state.llmProviders.last.name, 'OR 2');
      expect(
        gatewayOf(c).state.llmProviders.last.apiKey,
        _openRouterSyntheticKey,
      );

      // Removing it from a service that needs one is refused.
      await tester.tap(find.byTooltip('Edit').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('This service needs a key'), findsOneWidget);
      expect(
        gatewayOf(c).state.llmProviders.last.apiKey,
        _openRouterSyntheticKey,
      );
    });

    testWidgets('a key can be removed from a service that does not need one', (
      tester,
    ) async {
      final c = await _open(tester);
      await c
          .read(llmSettingsProvider.notifier)
          .upsert(
            const ProviderConfig(
              id: 'lm',
              name: 'LM Studio',
              kind: ProviderKind.openaiCompatible,
              baseUrl: 'http://localhost:1234/v1',
              apiKey: 'lm-key-12345678',
            ),
          );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('remove-key')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(gatewayOf(c).state.llmProviders.last.apiKey, isNull);
      expect(c.read(llmSettingsProvider).providers.last.hasKey, isFalse);
    });

    testWidgets('a local Ollama preset needs no key and brings gemma4', (
      tester,
    ) async {
      final c = await _open(tester);
      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ollama on another machine'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'http://100.x.y.z:11434'),
        '100.64.0.5:11434',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      final p = c.read(llmSettingsProvider).providers.last;
      expect(p.baseUrl, 'http://100.64.0.5:11434');
      expect(p.models, ['gemma4']);
      expect(gatewayOf(c).state.llmProviders.last.baseUrl, p.baseUrl);
    });

    testWidgets('editing and removing a provider', (tester) async {
      final c = await _open(tester);
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'),
        'Home Ollama',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(c.read(llmSettingsProvider).providers.single.name, 'Home Ollama');

      await tester.tap(find.byTooltip('Remove'));
      await tester.pumpAndSettle();
      expect(find.textContaining('API key are deleted'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(c.read(llmSettingsProvider).providers, isEmpty);
      expect(find.text('No providers'), findsOneWidget);
    });

    testWidgets('Manage models: discover, enable, add by name', (tester) async {
      final c = await _open(tester);
      await tester.tap(find.text('Manage models'));
      await tester.pumpAndSettle();
      expect(find.text('gemma4'), findsWidgets);
      expect(find.byTooltip('Supports tools'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Add a model by name'),
        'gemma4:e4b',
      );
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      expect(find.text('2 enabled · 2 shown'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(c.read(llmSettingsProvider).providers.single.models, [
        'gemma4',
        'gemma4:e4b',
      ]);
      expect(gatewayOf(c).state.llmProviders.single.models, [
        'gemma4',
        'gemma4:e4b',
      ]);
    });
  });

  group('operator', () {
    testWidgets('steps, read-only confirmation and instructions are saved', (
      tester,
    ) async {
      final c = await _open(tester);
      await _section(tester, 'Operator');

      await tester.drag(find.byType(Slider), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(c.read(appSettingsProvider).maxSteps, lessThan(12));

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(c.read(appSettingsProvider).confirmReadOnly, isTrue);

      final save = find.widgetWithText(FilledButton, 'Save');
      expect(
        tester.widget<FilledButton>(save).onPressed,
        isNull,
        reason: 'nothing to save yet',
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Our project lives in /srv/app.',
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(
        c.read(appSettingsProvider).extraInstructions,
        'Our project lives in /srv/app.',
      );
      expect(find.text('Instructions saved'), findsOneWidget);
    });

    testWidgets('saved instructions reach the model on the next message', (
      tester,
    ) async {
      final llm = ScriptedLlm([
        [const LlmTextDelta('ok'), const LlmDone()],
      ]);
      final c = await _open(tester, llm: llm);
      c
          .read(appSettingsProvider.notifier)
          .update(
            (s) => s.copyWith(extraInstructions: 'Answer in Portuguese.'),
          );
      await c.read(chatControllerProvider.notifier).send('hello');
      final system = llm.received.first.first.content;
      expect(system, contains('Answer in Portuguese.'));
      expect(system, contains('cannot override'));
    });

    testWidgets('the built-in prompt can be read, and rules/history link out', (
      tester,
    ) async {
      await _open(tester);
      await _section(tester, 'Operator');
      await tester.scrollUntilVisible(
        find.text('The built-in system prompt'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await _tapVisible(tester, find.text('The built-in system prompt'));
      expect(
        find.textContaining('You are the Operator of MCP Manager'),
        findsOneWidget,
      );
      expect(find.text('Tool rules'), findsOneWidget);
      expect(find.text('Conversation history'), findsOneWidget);
    });
  });

  group('account & data', () {
    Future<ProviderContainer> data(
      WidgetTester tester, {
      Size size = const Size(1400, 900),
      Future<void> Function(TestGateway gateway)? setup,
    }) async {
      final c = await _open(tester, size: size, setup: setup);
      await c
          .read(mcpHubProvider.notifier)
          .addServer(name: 'Docs', url: 'https://mcp.test/mcp');
      await c
          .read(auditLogProvider.notifier)
          .record(
            kind: AuditKind.toolCall,
            status: AuditStatus.success,
            source: AuditSource.workbench,
            actor: 'user',
          );
      await _section(tester, 'Account & data');
      return c;
    }

    testWidgets('says where the server is and who is signed in', (
      tester,
    ) async {
      await data(tester);
      expect(find.text('This dashboard'), findsOneWidget);
      expect(find.text(gatewayUrl), findsOneWidget);
      expect(find.text('The admin token'), findsOneWidget);
      expect(find.textContaining('in its database'), findsOneWidget);
    });

    testWidgets('signing out forgets the session here and nothing else', (
      tester,
    ) async {
      final c = await data(tester);
      await _tapVisible(tester, find.text('Sign out'));
      expect(
        c.read(sessionProvider).status,
        SessionStatus.signedOut,
        reason: 'this browser lets go of the session',
      );
      expect(
        c.read(sharedPreferencesProvider).getString('mcpm.session.v1'),
        isNot(contains('token')),
      );
      expect(gatewayOf(c).state.servers, hasLength(1));
    });

    testWidgets(
      'clearing the audit log asks first and clears it on the server',
      (tester) async {
        final c = await data(tester);
        expect(c.read(auditLogProvider), isNotEmpty);
        await _tapVisible(tester, find.widgetWithText(OutlinedButton, 'Clear'));
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(c.read(auditLogProvider), isNotEmpty);

        await tester.tap(find.widgetWithText(OutlinedButton, 'Clear'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
        await tester.pumpAndSettle();
        expect(c.read(auditLogProvider), isEmpty);
        expect(await gatewayOf(c).server.audit.recent(), isEmpty);
      },
    );

    testWidgets('deleting all conversations removes them from the server', (
      tester,
    ) async {
      final c = await data(
        tester,
        setup: (gateway) => gateway.server.chats.save(
          'chat_old',
          'admin',
          DateTime.now(),
          title: 'Old',
        ),
      );
      expect(c.read(chatControllerProvider).conversations, hasLength(1));
      await _tapVisible(tester, find.widgetWithText(OutlinedButton, 'Delete'));
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      await c.read(chatStoreProvider).flushed;
      expect(await gatewayOf(c).server.chats.list('admin'), isEmpty);
    });
  });

  group('phone width', () {
    testWidgets('every section fits', (tester) async {
      await _open(tester, size: const Size(400, 800));
      for (final label in ['Models', 'Operator', 'Account & data']) {
        await tester.ensureVisible(find.widgetWithText(ChoiceChip, label));
        await tester.tap(find.widgetWithText(ChoiceChip, label));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: label);
      }
    });
  });
}
