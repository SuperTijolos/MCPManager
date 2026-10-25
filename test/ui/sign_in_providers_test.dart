import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/server/session.dart';
import 'package:mcp_portal_server/mcp_portal_server.dart'
    show AuthProviderConfig;

import '../support/app_harness.dart';
import '../support/gateway_harness.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

const _google = AuthProviderConfig(
  id: 'google',
  kind: 'google',
  name: 'Google',
  clientId: 'g-client',
  clientSecret: 'g-secret',
  domains: ['example.com'],
);

const _github = AuthProviderConfig(
  id: 'github',
  kind: 'github',
  name: 'GitHub',
  clientId: 'gh-client',
  clientSecret: 'gh-secret',
  orgs: ['acme'],
);

Future<void> _openSection(WidgetTester tester) async {
  await goTo(tester, '/settings');
  await tester.tap(find.widgetWithText(ListTile, 'Sign-in'));
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String text) =>
    tester.enterText(_key(key), text);

void main() {
  group('the sign-in page', () {
    testWidgets('offers a button for each provider the server has', (
      tester,
    ) async {
      final navigated = <Uri>[];
      await pumpApp(
        tester,
        signedIn: false,
        setup: (gw) => gw.server.store.update((s) {
          s.authProviders
            ..add(_github)
            ..add(_google);
        }),
        overrides: [sessionNavigatorProvider.overrideWithValue(navigated.add)],
      );
      await _enter(tester, 'server-url', gatewayUrl);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('Sign in with GitHub'), findsOneWidget);
      expect(find.text('Sign in with Google'), findsOneWidget);

      await tester.tap(_key('sign-in-google'));
      await tester.pumpAndSettle();
      expect(
        navigated.single.toString(),
        startsWith('$gatewayUrl/auth/google?return_to='),
      );
    });
  });

  group('Settings → Sign-in', () {
    testWidgets('says so when nothing is set up', (tester) async {
      await pumpApp(tester);
      await _openSection(tester);
      expect(find.text('No sign-in set up'), findsOneWidget);
    });

    testWidgets('adds Google and keeps the secret on the server', (
      tester,
    ) async {
      final gw = await TestGateway.start();
      await pumpApp(tester, gateway: gw);
      await _openSection(tester);

      await tester.tap(_key('add-google'));
      await tester.pumpAndSettle();
      await _enter(tester, 'provider-client-id', 'g-client');
      await _enter(tester, 'provider-client-secret', 'g-secret');
      await _enter(tester, 'provider-domains', 'example.com, @other.org');
      await _enter(tester, 'provider-emails', 'ann@gmail.com');
      await tester.tap(_key('provider-save'));
      await tester.pumpAndSettle();

      final saved = gw.state.authProviders.single;
      expect(saved.id, 'google');
      expect(saved.clientSecret, 'g-secret');
      expect(saved.domains, ['example.com', 'other.org']);
      expect(saved.emails, ['ann@gmail.com']);
      expect(saved.enabled, isTrue);

      expect(find.text('Google'), findsWidgets);
      expect(find.textContaining('@example.com'), findsOneWidget);
      expect(find.text('g-secret'), findsNothing);
    });

    testWidgets('shows what the server refused', (tester) async {
      await pumpApp(tester);
      await _openSection(tester);
      await tester.tap(_key('add-google'));
      await tester.pumpAndSettle();
      await _enter(tester, 'provider-client-id', 'g');
      await _enter(tester, 'provider-client-secret', 's');
      await _enter(tester, 'provider-emails', 'not-an-address');
      await tester.tap(_key('provider-save'));
      await tester.pumpAndSettle();
      expect(_key('provider-error'), findsOneWidget);
      expect(find.textContaining('not an email address'), findsOneWidget);
    });

    testWidgets('warns when nobody is on the list', (tester) async {
      await pumpApp(
        tester,
        setup: (gw) => gw.server.store.update(
          (s) => s.authProviders.add(
            const AuthProviderConfig(
              id: 'google',
              kind: 'google',
              name: 'Google',
              clientId: 'c',
              clientSecret: 's',
            ),
          ),
        ),
      );
      await _openSection(tester);
      expect(_key('problem-google'), findsOneWidget);
      expect(find.textContaining('Nobody is on the list'), findsOneWidget);
    });

    testWidgets('editing without a secret keeps the stored one', (
      tester,
    ) async {
      final gw = await TestGateway.start();
      await gw.server.store.update((s) => s.authProviders.add(_google));
      await pumpApp(tester, gateway: gw);
      await _openSection(tester);

      await tester.tap(_key('edit-google'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Leave empty to keep it'), findsOneWidget);
      await _enter(tester, 'provider-domains', 'new.org');
      await tester.tap(_key('provider-save'));
      await tester.pumpAndSettle();

      final saved = gw.state.authProviders.single;
      expect(saved.domains, ['new.org']);
      expect(saved.clientSecret, 'g-secret');
    });

    testWidgets('turns a provider off with its switch', (tester) async {
      final gw = await TestGateway.start();
      await gw.server.store.update((s) => s.authProviders.add(_google));
      await pumpApp(tester, gateway: gw);
      await _openSection(tester);

      await tester.tap(_key('enabled-google'));
      await tester.pumpAndSettle();
      expect(gw.state.authProviders.single.enabled, isFalse);
    });

    testWidgets('removes a provider after asking', (tester) async {
      final gw = await TestGateway.start();
      await gw.server.store.update((s) => s.authProviders.add(_google));
      await pumpApp(tester, gateway: gw);
      await _openSection(tester);

      await tester.tap(_key('remove-google'));
      await tester.pumpAndSettle();
      expect(gw.state.authProviders, hasLength(1), reason: 'not yet');
      await tester.tap(_key('confirm-remove-provider'));
      await tester.pumpAndSettle();
      expect(gw.state.authProviders, isEmpty);
      expect(find.text('No sign-in set up'), findsOneWidget);
    });

    testWidgets('a provider from the environment is read-only', (tester) async {
      final gw = await TestGateway.start(
        githubClient: () => throw UnimplementedError(),
        githubOrgs: ['acme'],
      );
      await pumpApp(tester, gateway: gw);
      await _openSection(tester);
      expect(find.text('Set by the server'), findsOneWidget);
      expect(_key('edit-github'), findsNothing);
      expect(_key('remove-github'), findsNothing);
      expect(tester.widget<Switch>(_key('enabled-github')).onChanged, isNull);
    });

    testWidgets('fits a phone', (tester) async {
      final gw = await TestGateway.start();
      await gw.server.store.update((s) => s.authProviders.add(_google));
      await pumpApp(tester, gateway: gw, size: const Size(360, 700));
      await goTo(tester, '/settings');
      final chip = find.widgetWithText(ChoiceChip, 'Sign-in');
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      await tester.ensureVisible(_key('edit-google'));
      await tester.pumpAndSettle();
      await tester.tap(_key('edit-google'));
      await tester.pumpAndSettle();
      expect(_key('provider-save'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
