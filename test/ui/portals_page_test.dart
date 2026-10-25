import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/mcp/mcp_auto_connection.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';
import 'package:mcp_manager/engine/portal/portal_controller.dart';
import 'package:mcp_manager/engine/portal/portal_models.dart';
import 'package:mcp_portal_server/mcp_portal_server.dart' show hashSecret;

import '../support/app_harness.dart';
import '../support/fakes.dart';
import '../support/gateway_harness.dart';

final _tools = [
  {
    'name': 'lookup',
    'description': 'Look something up',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'q': {'type': 'string'},
      },
    },
    'annotations': {'readOnlyHint': true},
  },
  {
    'name': 'wipe',
    'description': 'Destroys',
    'inputSchema': {'type': 'object'},
  },
];

Finder _field(String key) => find.byKey(ValueKey(key));

void main() {
  late TestGateway gw;
  late FakeMcpServer upstream;

  /// Starts the gateway inside the test, not in setUp: its futures must be
  /// created in the test's own (fake-async) zone to be driven by pumping.
  Future<void> startGateway({bool upstreamDown = false}) async {
    upstream = FakeMcpServer(
      tools: _tools,
      handlers: {'lookup': (a) => textResult('found ${a['q']}')},
    );
    gw = await TestGateway.start(
      upstream: upstream,
      upstreamClient: upstreamDown
          ? () => MockClient(
              (_) async => throw http.ClientException('connection refused'),
            )
          : null,
    );
    // Nothing to await: an in-memory gateway holds no sockets, and awaiting in
    // a tear-down would wait on fake-async futures that never run again.
    addTearDown(gw.client.close);
  }

  Future<ProviderContainer> open(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
    http.Client? reach,
    bool upstreamDown = false,
  }) async {
    await startGateway(upstreamDown: upstreamDown);
    final c = await pumpApp(
      tester,
      gateway: gw,
      size: size,
      reach: reach,
      defaultProvider: reach == null,
    );
    await goTo(tester, '/portals');
    return c;
  }

  Future<void> tab(WidgetTester tester, String name) async {
    await tester.tap(find.widgetWithText(Tab, name));
    await tester.pumpAndSettle();
  }

  /// Adds a "Docs" server and returns its id.
  Future<String> publishDocs(ProviderContainer c) async {
    final runtime = await c
        .read(mcpHubProvider.notifier)
        .addServer(name: 'Docs', url: 'https://docs.test/mcp');
    await c.read(portalControllerProvider.notifier).refresh();
    return runtime.config.id;
  }

  group('opening the page', () {
    testWidgets('shows the server and what it holds', (tester) async {
      final c = await open(tester);
      expect(c.read(portalControllerProvider).connected, isTrue);
      for (final name in ['Portals', 'Access']) {
        expect(find.widgetWithText(Tab, name), findsOneWidget);
      }
      expect(find.widgetWithText(Tab, 'Servers'), findsNothing);
      expect(find.widgetWithText(Tab, 'Activity'), findsNothing);
      expect(
        find.textContaining('Server $gatewayUrl · v1.0.0'),
        findsOneWidget,
      );
      expect(find.text('No portals yet'), findsOneWidget);
    });

    testWidgets('a server that does not answer offers a retry', (tester) async {
      final down = MockClient(
        (_) async => throw http.ClientException('connection refused'),
      );
      await open(tester, reach: down);
      expect(find.text('Server not reachable'), findsOneWidget);
      expect(find.textContaining('Could not reach'), findsOneWidget);
      expect(_field('gateway-retry'), findsOneWidget);
    });

    testWidgets('servers added on the Servers page can go in a portal', (
      tester,
    ) async {
      final c = await open(tester);
      expect(find.text('No portals yet'), findsOneWidget);
      expect(find.textContaining('Add some MCP servers first'), findsOneWidget);
      await publishDocs(c);
      await tester.pumpAndSettle();
      expect(find.textContaining('Add some MCP servers first'), findsNothing);
    });

    testWidgets('a server that needs OAuth can be in a portal', (tester) async {
      final c = await open(tester);
      final runtime = await c
          .read(mcpHubProvider.notifier)
          .addServer(
            name: 'Protected',
            url: 'https://mcp.test/mcp',
            oauth: true,
          );
      await c.read(portalControllerProvider.notifier).refresh();
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(
            name: 'Dev',
            slug: 'dev',
            servers: [GatewayPortalServer(runtime.config.id)],
          );
      await tester.pumpAndSettle();
      expect(
        gw.state.portals.single.servers.single.serverId,
        runtime.config.id,
      );
      expect(find.text('Dev'), findsOneWidget);
    });
  });

  group('portals', () {
    testWidgets('are created from the servers on the gateway', (tester) async {
      final c = await open(tester);
      final id = await publishDocs(c);
      await tester.pumpAndSettle();

      await tester.tap(_field('new-portal'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('portal-name'), 'Dev Tools');
      await tester.pump();
      expect(
        tester.widget<TextField>(_field('portal-slug')).controller!.text,
        'dev-tools',
        reason: 'the address follows the name until you edit it',
      );
      await tester.tap(_field('portal-server-$id'));
      await tester.pump();
      await tester.tap(_field('portal-save'));
      await tester.pumpAndSettle();

      expect(find.text('Dev Tools'), findsOneWidget);
      expect(find.text('$gatewayUrl/mcp/dev-tools'), findsOneWidget);
      expect(find.text('Live'), findsWidgets);
      final portal = gw.state.portals.single;
      expect(portal.slug, 'dev-tools');
      expect(portal.servers.map((s) => s.serverId), [id]);
    });

    testWidgets('a taken address is explained', (tester) async {
      final c = await open(tester);
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(name: 'Dev', slug: 'dev');
      await tester.pumpAndSettle();

      await tester.tap(_field('new-portal'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('portal-name'), 'Another');
      await tester.enterText(_field('portal-slug'), 'dev');
      await tester.tap(_field('portal-save'));
      await tester.pumpAndSettle();

      expect(
        find.text('Another portal already uses that address.'),
        findsOneWidget,
      );
      expect(
        find.text('New portal'),
        findsWidgets,
        reason: 'the dialog stays open',
      );
    });

    testWidgets('need a name and a tidy address', (tester) async {
      await open(tester);
      await tester.tap(_field('new-portal'));
      await tester.pumpAndSettle();
      await tester.tap(_field('portal-save'));
      await tester.pumpAndSettle();
      expect(find.text('Give the portal a name.'), findsOneWidget);

      await tester.enterText(_field('portal-name'), 'X');
      await tester.enterText(_field('portal-slug'), 'Not Tidy!');
      await tester.tap(_field('portal-save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('lowercase letters'), findsOneWidget);
    });

    testWidgets('can be edited, switched off and deleted', (tester) async {
      final c = await open(tester);
      final id = await publishDocs(c);
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(
            name: 'Dev',
            slug: 'dev',
            servers: [GatewayPortalServer(id)],
          );
      await tester.pumpAndSettle();

      await tester.tap(_field('portal-switch-dev'));
      await tester.pumpAndSettle();
      expect(gw.state.portals.single.enabled, isFalse);
      expect(find.text('Off'), findsOneWidget);

      await tester.tap(_field('portal-edit-dev'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('portal-description'), 'For developers');
      await tester.tap(_field('portal-save'));
      await tester.pumpAndSettle();
      expect(gw.state.portals.single.description, 'For developers');
      expect(
        gw.state.portals.single.enabled,
        isFalse,
        reason: 'editing keeps it off',
      );

      await tester.tap(_field('portal-delete-dev'));
      await tester.pumpAndSettle();
      await tester.tap(_field('confirm-delete'));
      await tester.pumpAndSettle();
      expect(gw.state.portals, isEmpty);
      expect(find.text('No portals yet'), findsOneWidget);
    });

    testWidgets('show the tools they expose and can leave some out', (
      tester,
    ) async {
      final c = await open(tester);
      final id = await publishDocs(c);
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(
            name: 'Dev',
            slug: 'dev',
            servers: [GatewayPortalServer(id)],
          );
      await tester.pumpAndSettle();

      await tester.tap(_field('portal-tools-dev'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tool-docs__lookup')), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-docs__wipe')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tool-docs__wipe')));
      await tester.pumpAndSettle();
      expect(gw.state.portals.single.excludedTools, ['$id/wipe']);

      // Reopening shows it switched off rather than missing.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 tool left out'), findsOneWidget);
      await tester.tap(_field('portal-tools-dev'));
      await tester.pumpAndSettle();
      final wipe = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('tool-docs__wipe')),
      );
      expect(wipe.value, isFalse);
    });

    testWidgets(
      'a server that cannot be reached is reported in the tool list',
      (tester) async {
        final c = await open(tester, upstreamDown: true);
        final id = await publishDocs(c);
        await c
            .read(portalControllerProvider.notifier)
            .savePortal(
              name: 'Dev',
              slug: 'dev',
              servers: [GatewayPortalServer(id)],
            );
        await tester.pumpAndSettle();

        await tester.tap(_field('portal-tools-dev'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Docs could not be reached'),
          findsOneWidget,
        );
        expect(find.text('This portal exposes no tools yet.'), findsOneWidget);
      },
    );

    testWidgets('tell a client how to connect, and warn about plain HTTP', (
      tester,
    ) async {
      final c = await open(tester);
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(name: 'Dev', slug: 'dev');
      await tester.pumpAndSettle();

      await tester.tap(_field('portal-connect-dev'));
      await tester.pumpAndSettle();

      expect(find.text('Connect to Dev'), findsOneWidget);
      expect(find.text('$gatewayUrl/mcp/dev'), findsWidgets);
      expect(
        find.textContaining(
          'claude mcp add --transport http dev $gatewayUrl/mcp/dev',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('"mcpServers"'), findsOneWidget);
      expect(find.textContaining('not HTTPS'), findsOneWidget);
    });
  });

  group('access tokens', () {
    testWidgets('are created, shown once, and work against the gateway', (
      tester,
    ) async {
      final c = await open(tester);
      final id = await publishDocs(c);
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(
            name: 'Dev',
            slug: 'dev',
            servers: [GatewayPortalServer(id)],
          );
      await tab(tester, 'Access');
      expect(find.text('No tokens yet.'), findsOneWidget);

      await tester.tap(_field('new-token'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('token-name'), 'Claude Code');
      await tester.tap(_field('token-portal-dev'));
      await tester.pump();
      await tester.tap(_field('token-create'));
      await tester.pumpAndSettle();

      final secret = tester
          .widget<SelectableText>(_field('token-secret'))
          .data!;
      expect(secret, startsWith('mcp_'));
      expect(gw.state.tokens.single.hash, hashSecret(secret));
      await tester.tap(_field('token-done'));
      await tester.pumpAndSettle();

      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.textContaining('Dev'), findsWidgets);
      expect(find.textContaining('never used'), findsOneWidget);
      expect(
        find.textContaining(secret),
        findsNothing,
        reason: 'the secret is not kept on screen',
      );

      final connection = createMcpConnection(
        McpServerConfig(
          id: 'p',
          name: 'p',
          url: '$gatewayUrl/mcp/dev',
          headers: {'Authorization': 'Bearer $secret'},
          transport: McpTransport.streamableHttp,
        ),
        httpClient: gw.client,
      );
      await connection.connect();
      expect((await connection.listTools()).map((t) => t.name), [
        'docs__lookup',
        'docs__wipe',
      ]);
    });

    testWidgets('need a name', (tester) async {
      await open(tester);
      await tab(tester, 'Access');
      await tester.tap(_field('new-token'));
      await tester.pumpAndSettle();
      await tester.tap(_field('token-create'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Give the token a name'), findsOneWidget);
      expect(gw.state.tokens, isEmpty);
    });

    testWidgets('can be revoked', (tester) async {
      final c = await open(tester);
      final created = await c
          .read(portalControllerProvider.notifier)
          .createToken(name: 'Old client');
      await tab(tester, 'Access');

      await tester.tap(_field('revoke-${created.token.id}'));
      await tester.pumpAndSettle();
      expect(find.textContaining('stop working right away'), findsOneWidget);
      await tester.tap(_field('confirm-revoke'));
      await tester.pumpAndSettle();

      expect(find.text('Revoked'), findsOneWidget);
      expect(find.text('Active'), findsNothing);
      expect(gw.state.tokens.single.revokedAt, isNotNull);
      expect(_field('revoke-${created.token.id}'), findsNothing);
    });
  });

  group('what clients do', () {
    testWidgets('shows on the Audit page as coming through a portal', (
      tester,
    ) async {
      final c = await open(tester);
      final id = await publishDocs(c);
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(
            name: 'Dev',
            slug: 'dev',
            servers: [GatewayPortalServer(id)],
          );
      final secret =
          (await c
                  .read(portalControllerProvider.notifier)
                  .createToken(name: 'client'))
              .secret;
      final connection = createMcpConnection(
        McpServerConfig(
          id: 'p',
          name: 'p',
          url: '$gatewayUrl/mcp/dev',
          headers: {'Authorization': 'Bearer $secret'},
          transport: McpTransport.streamableHttp,
        ),
        httpClient: gw.client,
      );
      await connection.connect();
      await connection.callTool('docs__lookup', {'q': 'report'});

      await goTo(tester, '/audit');
      await c.read(auditLogProvider.notifier).reload();
      await tester.pumpAndSettle();
      expect(find.text('Docs · lookup'), findsOneWidget);
      expect(find.textContaining('client'), findsWidgets);
      expect(find.textContaining('Portal'), findsWidgets);
    });

    testWidgets('the page fits a phone', (tester) async {
      final c = await open(tester, size: const Size(390, 800));
      final id = await publishDocs(c);
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(
            name: 'A rather long portal name for a phone',
            slug: 'long',
            servers: [GatewayPortalServer(id)],
          );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tab(tester, 'Access');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the route is /portals', (tester) async {
      await open(tester);
      final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
      expect(router.routeInformationProvider.value.uri.path, '/portals');
    });
  });
}
