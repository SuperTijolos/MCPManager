import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/server/access_control.dart';
import 'package:mcp_manager/engine/server/session.dart';
import 'package:mcp_portal_server/mcp_portal_server.dart'
    show DashSession, Member, Role, hashSecret;

import '../support/app_harness.dart';
import '../support/gateway_harness.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

const _viewerToken = 'mcps_viewer-viewer-viewer-viewer-1234';

Future<TestGateway> _gateway({String role = 'viewer'}) async {
  final gw = await TestGateway.start(
    githubClient: () => throw UnimplementedError(),
    githubOrgs: ['acme'],
  );
  await gw.server.store.update((s) {
    s.members.add(
      Member(
        id: 'github:7',
        login: 'vera',
        name: 'Vera',
        orgs: const ['acme'],
        role: role,
        createdAt: DateTime.now(),
      ),
    );
    s.sessions.add(
      DashSession(
        hash: hashSecret(_viewerToken),
        memberId: 'github:7',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 1)),
      ),
    );
  });
  return gw;
}

Map<String, Object> get _asVera => {
  'mcpm.session.v1': jsonEncode({'url': gatewayUrl, 'token': _viewerToken}),
};

Future<void> _openSection(WidgetTester tester, String label) async {
  await goTo(tester, '/settings');
  await tester.tap(find.widgetWithText(ListTile, label));
  await tester.pumpAndSettle();
}

void main() {
  group('as an admin', () {
    testWidgets('Members lists everyone with their role', (tester) async {
      final gw = await _gateway(role: 'operator');
      await pumpApp(tester, gateway: gw);
      await _openSection(tester, 'Members');
      expect(_key('member-github:7'), findsOneWidget);
      expect(find.text('Vera'), findsOneWidget);
      expect(
        find.descendant(
          of: _key('role-github:7'),
          matching: find.text('Operator'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an invitation shows its link once', (tester) async {
      final gw = await _gateway();
      await pumpApp(tester, gateway: gw);
      await _openSection(tester, 'Members');

      await tester.tap(_key('invite-member'));
      await tester.pumpAndSettle();
      await tester.enterText(_key('invite-email'), 'Ann@Example.com');
      await tester.tap(_key('access-role'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Operator').last);
      await tester.pumpAndSettle();
      await tester.tap(_key('access-save'));
      await tester.pumpAndSettle();

      expect(_key('invite-once'), findsOneWidget);
      expect(
        find.textContaining('$gatewayUrl/auth/invite/mcpi_'),
        findsWidgets,
      );
      final invite = gw.state.invites.single;
      expect(invite.email, 'ann@example.com');
      expect(invite.role, 'operator');

      await tester.tap(_key('invite-done'));
      await tester.pumpAndSettle();
      expect(find.textContaining('mcpi_'), findsNothing, reason: 'shown once');
      expect(find.text('ann@example.com'), findsOneWidget);
    });

    testWidgets('an invitation can be revoked', (tester) async {
      final gw = await _gateway();
      await pumpApp(tester, gateway: gw);
      await _openSection(tester, 'Members');
      await tester.tap(_key('invite-member'));
      await tester.pumpAndSettle();
      await tester.tap(_key('access-role'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Viewer').last);
      await tester.pumpAndSettle();
      await tester.tap(_key('access-save'));
      await tester.pumpAndSettle();
      await tester.tap(_key('invite-done'));
      await tester.pumpAndSettle();

      expect(find.text('Anyone with the link'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Revoke'));
      await tester.pumpAndSettle();
      expect(gw.state.invites, isEmpty);
      expect(find.text('No pending invitations.'), findsOneWidget);
    });

    testWidgets('changes a member\'s role and limits them to a server', (
      tester,
    ) async {
      final gw = await _gateway();
      await pumpApp(tester, gateway: gw);
      // A server to limit to.
      await gw.client.post(
        Uri.parse('$gatewayUrl/api/servers'),
        headers: {
          'authorization': 'Bearer $gatewayAdminToken',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'name': 'Docs',
          'url': 'http://docs.test/mcp',
          'transport': 'streamable-http',
        }),
      );
      await tester.pumpAndSettle();
      await _openSection(tester, 'Members');
      await tester.tap(_key('edit-member-github:7'));
      await tester.pumpAndSettle();

      await tester.tap(_key('access-role'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Operator').last);
      await tester.pumpAndSettle();
      await tester.tap(_key('scope-servers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Docs'));
      await tester.pumpAndSettle();
      await tester.tap(_key('access-save'));
      await tester.pumpAndSettle();

      final member = gw.state.members.single;
      expect(member.role, 'operator');
      expect(member.serverIds, hasLength(1));
      expect(member.portalIds, isNull);
    });

    testWidgets('removes a member after asking', (tester) async {
      final gw = await _gateway();
      await pumpApp(tester, gateway: gw);
      await _openSection(tester, 'Members');
      await tester.tap(_key('remove-member-github:7'));
      await tester.pumpAndSettle();
      expect(gw.state.members, hasLength(1), reason: 'not yet');
      await tester.tap(_key('confirm-remove-member'));
      await tester.pumpAndSettle();
      expect(gw.state.members, isEmpty);
      expect(gw.state.sessions, isEmpty);
    });

    testWidgets('Roles lists the built-in roles and makes a new one', (
      tester,
    ) async {
      final gw = await _gateway();
      await pumpApp(tester, gateway: gw, size: const Size(1400, 2400));
      await _openSection(tester, 'Roles');
      for (final name in ['Admin', 'Viewer']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('Operator'), findsWidgets);
      expect(find.text('Built in'), findsNWidgets(3));

      await tester.tap(_key('new-role'));
      await tester.pumpAndSettle();
      await tester.enterText(_key('role-name'), 'Auditor');
      await tester.enterText(_key('role-description'), 'Reads the log');
      await tester.ensureVisible(_key('perm-audit.view'));
      await tester.tap(_key('perm-audit.view'));
      await tester.pumpAndSettle();
      await tester.tap(_key('role-save'));
      await tester.pumpAndSettle();

      final role = gw.state.roles.single;
      expect(role.id, 'auditor');
      expect(role.permissions, {'audit.view'});
      expect(find.text('Auditor'), findsOneWidget);
    });

    testWidgets('a role can be edited and deleted', (tester) async {
      final gw = await _gateway();
      await gw.server.store.update(
        (s) => s.roles.add(
          Role(
            id: 'auditor',
            name: 'Auditor',
            permissions: const {'audit.view'},
            createdAt: DateTime.now(),
          ),
        ),
      );
      await pumpApp(tester, gateway: gw, size: const Size(1400, 2400));
      await _openSection(tester, 'Roles');

      await tester.tap(_key('edit-role-auditor'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(_key('perm-servers.view'));
      await tester.tap(_key('perm-servers.view'));
      await tester.pumpAndSettle();
      await tester.tap(_key('role-save'));
      await tester.pumpAndSettle();
      expect(gw.state.roles.single.permissions, {'audit.view', 'servers.view'});

      await tester.ensureVisible(_key('delete-role-auditor'));
      await tester.tap(_key('delete-role-auditor'));
      await tester.pumpAndSettle();
      expect(gw.state.roles, isEmpty);
    });

    testWidgets('a role in use says it cannot be deleted', (tester) async {
      final gw = await _gateway();
      await gw.server.store.update(
        (s) => s.roles.add(
          Role(
            id: 'auditor',
            name: 'Auditor',
            permissions: const {'audit.view'},
            createdAt: DateTime.now(),
          ),
        ),
      );
      await gw.server.store.update((s) {
        s.members[0] = s.members[0].withAccess(
          role: 'auditor',
          serverIds: null,
          portalIds: null,
        );
      });
      await pumpApp(tester, gateway: gw, size: const Size(1400, 2400));
      await _openSection(tester, 'Roles');
      await tester.ensureVisible(_key('delete-role-auditor'));
      await tester.tap(_key('delete-role-auditor'));
      await tester.pumpAndSettle();
      expect(gw.state.roles, hasLength(1));
      expect(find.textContaining('still use this role'), findsOneWidget);
    });

    testWidgets('a provider has a role for the people on its list', (
      tester,
    ) async {
      final gw = await _gateway();
      await pumpApp(tester, gateway: gw);
      await _openSection(tester, 'Sign-in');
      await tester.tap(_key('add-google'));
      await tester.pumpAndSettle();
      await tester.enterText(_key('provider-client-id'), 'g');
      await tester.enterText(_key('provider-client-secret'), 's');
      await tester.enterText(_key('provider-domains'), 'example.com');
      await tester.ensureVisible(_key('provider-default-role'));
      await tester.tap(_key('provider-default-role'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Operator').last);
      await tester.pumpAndSettle();
      await tester.tap(_key('provider-save'));
      await tester.pumpAndSettle();
      expect(gw.state.authProviders.single.defaultRole, 'operator');
      expect(find.textContaining('They start as: Operator'), findsOneWidget);
    });
  });

  group('as a viewer', () {
    Finder inRail(String label) => find.descendant(
      of: find.byType(NavigationRail),
      matching: find.text(label),
    );

    testWidgets('the navigation offers only what the role allows', (
      tester,
    ) async {
      final gw = await _gateway();
      await pumpApp(
        tester,
        gateway: gw,
        signedIn: false,
        prefs: _asVera,
        defaultProvider: false,
      );
      expect(inRail('MCP Servers'), findsOneWidget);
      expect(inRail('MCP Tools'), findsOneWidget);
      expect(inRail('MCP Portals'), findsOneWidget);
      expect(inRail('Audit'), findsOneWidget);
      expect(inRail('Chat'), findsNothing);
    });

    testWidgets('Settings has no access or sign-in sections', (tester) async {
      final gw = await _gateway();
      await pumpApp(
        tester,
        gateway: gw,
        signedIn: false,
        prefs: _asVera,
        defaultProvider: false,
      );
      await goTo(tester, '/settings');
      expect(find.widgetWithText(ListTile, 'Account & data'), findsOneWidget);
      for (final hidden in ['Members', 'Roles', 'Sign-in']) {
        expect(find.widgetWithText(ListTile, hidden), findsNothing);
      }
    });

    testWidgets('the portals page still loads without access tokens', (
      tester,
    ) async {
      final gw = await _gateway();
      await pumpApp(
        tester,
        gateway: gw,
        signedIn: false,
        prefs: _asVera,
        defaultProvider: false,
      );
      await goTo(tester, '/mcp-portals');
      expect(find.text('MCP Portals'), findsWidgets);
      expect(find.textContaining('did not answer'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a role change reaches the dashboard without signing in again',
      (tester) async {
        final gw = await _gateway();
        final c = await pumpApp(
          tester,
          gateway: gw,
          signedIn: false,
          prefs: _asVera,
          defaultProvider: false,
        );
        expect(inRail('Chat'), findsNothing);

        await gw.server.store.update((s) {
          s.members[0] = s.members[0].withAccess(
            role: 'operator',
            serverIds: null,
            portalIds: null,
          );
        });
        await c.read(sessionProvider.notifier).refreshIdentity();
        await tester.pumpAndSettle();

        expect(inRail('Chat'), findsOneWidget);
        expect(c.read(sessionProvider).identity!.role, 'operator');
        expect(c.read(sessionProvider).signedIn, isTrue);
      },
    );
  });

  test('the dashboard knows the permission catalogue shape', () {
    final p = PermissionInfo.fromJson({
      'id': 'servers.view',
      'group': 'MCP servers',
      'label': 'See servers',
    });
    expect(p.id, 'servers.view');
  });
}
