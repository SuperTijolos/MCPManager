import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
    bool connected = true,
    Size size = const Size(1280, 900),
    http.Client? client,
    bool upstreamDown = false,
  }) async {
    await startGateway(upstreamDown: upstreamDown);
    final prefs = connected
        ? <String, Object>{
            'mcpm.portal.v1':
                '{"url":"$gatewayUrl","token":"$gatewayAdminToken"}',
          }
        : <String, Object>{};
    final c = await pumpApp(
      tester,
      server: upstream,
      size: size,
      prefs: prefs,
      overrides: [
        portalHttpClientProvider.overrideWithValue(client ?? gw.client),
      ],
    );
    await goTo(tester, '/portals');
    return c;
  }

  Future<void> tab(WidgetTester tester, String name) async {
    await tester.tap(find.widgetWithText(Tab, name));
    await tester.pumpAndSettle();
  }

  /// Puts the app's "Docs" server on the gateway and returns its id.
  Future<String> publishDocs(ProviderContainer c) async {
    final runtime = await c
        .read(mcpHubProvider.notifier)
        .addServer(name: 'Docs', url: 'https://docs.test/mcp');
    await c.read(portalControllerProvider.notifier).refresh();
    await c
        .read(portalControllerProvider.notifier)
        .publishServer(runtime.config);
    return runtime.config.id;
  }

  group('before connecting', () {
    testWidgets('Portals is in the navigation and asks for a gateway', (
      tester,
    ) async {
      await open(tester, connected: false);
      expect(find.text('Portals'), findsWidgets);
      expect(find.text('Connect to a gateway'), findsOneWidget);
      expect(
        find.textContaining('dart run bin/mcp_portal.dart'),
        findsOneWidget,
      );
      expect(find.widgetWithText(Tab, 'Servers'), findsNothing);
    });

    testWidgets('a wrong token shows the gateway\'s own message', (
      tester,
    ) async {
      final c = await open(tester, connected: false);
      await tester.enterText(_field('gateway-url'), gatewayUrl);
      await tester.enterText(
        _field('gateway-token'),
        'wrong-wrong-wrong-wrong',
      );
      await tester.tap(_field('gateway-connect'));
      await tester.pumpAndSettle();

      expect(
        find.text('The gateway rejected the admin token.'),
        findsOneWidget,
      );
      expect(c.read(portalControllerProvider).settings.configured, isFalse);
    });

    testWidgets('an address that is not one is refused before any request', (
      tester,
    ) async {
      await open(tester, connected: false);
      await tester.enterText(_field('gateway-url'), 'not a url');
      await tester.enterText(_field('gateway-token'), 'whatever');
      await tester.tap(_field('gateway-connect'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter the gateway address'), findsOneWidget);
    });

    testWidgets('the right token connects and shows the gateway', (
      tester,
    ) async {
      final c = await open(tester, connected: false);
      await tester.enterText(_field('gateway-url'), gatewayUrl);
      await tester.enterText(_field('gateway-token'), gatewayAdminToken);
      await tester.tap(_field('gateway-connect'));
      await tester.pumpAndSettle();

      expect(c.read(portalControllerProvider).connected, isTrue);
      for (final name in ['Portals', 'Servers', 'Access', 'Activity']) {
        expect(find.widgetWithText(Tab, name), findsOneWidget);
      }
      expect(
        find.textContaining('Gateway $gatewayUrl · v1.0.0'),
        findsOneWidget,
      );
      expect(find.text('No portals yet'), findsOneWidget);
    });

    testWidgets('a saved gateway that does not answer offers a retry', (
      tester,
    ) async {
      final down = MockClient(
        (_) async => throw http.ClientException('connection refused'),
      );
      await open(tester, client: down);
      expect(find.text('Gateway not reachable'), findsOneWidget);
      expect(
        find.textContaining('Could not reach the gateway'),
        findsOneWidget,
      );
      expect(_field('gateway-retry'), findsOneWidget);
      expect(_field('gateway-edit'), findsOneWidget);
    });

    testWidgets('a saved gateway that rejects the token says so', (
      tester,
    ) async {
      final c = await pumpApp(
        tester,
        server: upstream,
        prefs: {
          'mcpm.portal.v1':
              '{"url":"$gatewayUrl","token":"revoked-revoked-revoked"}',
        },
        overrides: [portalHttpClientProvider.overrideWithValue(gw.client)],
      );
      await goTo(tester, '/portals');
      expect(
        find.text('The gateway rejected the admin token.'),
        findsOneWidget,
      );
      expect(
        c.read(portalControllerProvider).connection,
        PortalConnection.failed,
      );
    });
  });

  group('servers', () {
    testWidgets('an app server can be put on the gateway', (tester) async {
      final c = await open(tester);
      final hub = c.read(mcpHubProvider.notifier);
      final runtime = await hub.addServer(
        name: 'Docs',
        url: 'https://docs.test/mcp',
        headers: {'Authorization': 'Bearer abc'},
      );
      await tab(tester, 'Servers');

      expect(find.text('Put on gateway'), findsOneWidget);
      await tester.tap(_field('publish-${runtime.config.id}'));
      await tester.pumpAndSettle();

      expect(find.text('On gateway'), findsOneWidget);
      expect(_field('gateway-server-${runtime.config.id}'), findsOneWidget);
      expect(find.textContaining('Tools are named docs__'), findsOneWidget);
      expect(find.textContaining('1 header stored'), findsOneWidget);
      expect(gw.state.servers.single.headers, {'Authorization': 'Bearer abc'});
    });

    testWidgets('a server that needs OAuth cannot be put on a gateway', (
      tester,
    ) async {
      final c = await open(tester);
      await c
          .read(mcpHubProvider.notifier)
          .addServer(
            name: 'Signed in',
            url: 'https://oauth.test/mcp',
            oauth: true,
          );
      await tab(tester, 'Servers');
      expect(find.text('OAuth'), findsOneWidget);
      expect(find.textContaining('A gateway cannot use it'), findsOneWidget);
      expect(find.text('Put on gateway'), findsNothing);
    });

    testWidgets('a gateway server can be tested', (tester) async {
      final c = await open(tester);
      final id = await publishDocs(c);
      await tab(tester, 'Servers');

      await tester.tap(_field('test-$id'));
      await tester.pumpAndSettle();

      expect(
        find.text('2 tools · fake 1.2.3 · streamable-http'),
        findsOneWidget,
      );
    });

    testWidgets('a gateway server that cannot be reached shows why', (
      tester,
    ) async {
      final c = await open(tester, upstreamDown: true);
      final id = await publishDocs(c);
      await tab(tester, 'Servers');

      await tester.tap(_field('test-$id'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not connect:'), findsOneWidget);
      expect(find.textContaining('connection refused'), findsWidgets);
    });

    testWidgets('removing a server names the portals it leaves', (
      tester,
    ) async {
      final c = await open(tester);
      final id = await publishDocs(c);
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(name: 'Dev', servers: [GatewayPortalServer(id)]);
      await tab(tester, 'Servers');

      await tester.tap(_field('remove-$id'));
      await tester.pumpAndSettle();
      expect(find.textContaining('also taken out of Dev'), findsOneWidget);
      await tester.tap(_field('confirm-remove-server'));
      await tester.pumpAndSettle();

      expect(gw.state.servers, isEmpty);
      expect(find.text('The gateway has no servers yet.'), findsOneWidget);
    });

    testWidgets('the app\'s tool rules can be sent', (tester) async {
      await open(tester);
      await tab(tester, 'Servers');
      expect(
        find.textContaining('This app: 0 rules, 0 per-tool settings'),
        findsOneWidget,
      );
      await tester.tap(_field('push-rules'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Sent 0 rules and 0 per-tool settings'),
        findsOneWidget,
      );
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

  group('activity', () {
    testWidgets('lists the calls clients made, with their detail', (
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

      await tab(tester, 'Activity');
      expect(find.text('Docs · lookup'), findsOneWidget);
      expect(find.textContaining('client'), findsWidgets);
      expect(find.text('success'), findsWidgets);

      await tester.tap(find.text('Docs · lookup'));
      await tester.pumpAndSettle();
      expect(find.text('Arguments'), findsOneWidget);
      expect(find.text('Result'), findsOneWidget);
      expect(find.text('access token'), findsOneWidget);
    });

    testWidgets('start empty and say what will appear', (tester) async {
      await open(tester);
      await tab(tester, 'Activity');
      expect(find.text('No calls yet'), findsOneWidget);
    });

    testWidgets('can be narrowed by status', (tester) async {
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
      await connection.callTool('docs__lookup', {'q': 'a'});
      // The client is told, and the gateway records, a call it cannot serve.
      await expectLater(
        connection.callTool('docs__nothing', {}),
        throwsA(isA<McpException>()),
      );

      await tab(tester, 'Activity');
      expect(find.text('Docs · lookup'), findsOneWidget);
      await tester.tap(_field('activity-success'));
      await tester.pumpAndSettle();
      expect(find.text('Docs · lookup'), findsOneWidget);
      await tester.tap(_field('activity-success'));
      await tester.tap(_field('activity-denied'));
      await tester.pumpAndSettle();
      expect(find.text('Docs · lookup'), findsNothing);
    });
  });

  group('the connection', () {
    testWidgets('can be dropped, and the gateway stays as it was', (
      tester,
    ) async {
      final c = await open(tester);
      await c
          .read(portalControllerProvider.notifier)
          .savePortal(name: 'Dev', slug: 'dev');
      await tester.pumpAndSettle();

      await tester.tap(_field('portals-menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      await tester.tap(_field('confirm-disconnect'));
      await tester.pumpAndSettle();

      expect(find.text('Connect to a gateway'), findsOneWidget);
      expect(c.read(portalControllerProvider).settings.configured, isFalse);
      expect(gw.state.portals, hasLength(1));
    });

    testWidgets('can be changed without losing the address', (tester) async {
      await open(tester);
      await tester.tap(_field('portals-menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change address or token'));
      await tester.pumpAndSettle();
      expect(find.text('Connect to a gateway'), findsOneWidget);
      expect(
        tester.widget<TextField>(_field('gateway-url')).controller!.text,
        gatewayUrl,
      );
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
      for (final name in ['Servers', 'Access', 'Activity']) {
        await tab(tester, name);
        expect(tester.takeException(), isNull, reason: name);
      }
    });

    testWidgets('the route is /portals', (tester) async {
      await open(tester);
      final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
      expect(router.routeInformationProvider.value.uri.path, '/portals');
    });
  });
}
