import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/server/session.dart';

import '../support/app_harness.dart';
import '../support/gateway_harness.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  testWidgets('a signed-out dashboard opens on the sign-in page', (
    tester,
  ) async {
    await pumpApp(tester, signedIn: false);
    expect(
      find.text(
        'Sign in to your server. Servers, tools, audit and chats live there; this page is the dashboard.',
      ),
      findsOneWidget,
    );
    expect(_key('sign-in-github'), findsOneWidget);
    expect(_key('admin-token'), findsNothing, reason: 'hidden until asked for');
    expect(
      find.text('Overview'),
      findsNothing,
      reason: 'no dashboard behind it',
    );
  });

  testWidgets('the admin token signs in and opens the dashboard', (
    tester,
  ) async {
    final c = await pumpApp(tester, signedIn: false);
    await tester.enterText(_key('server-url'), gatewayUrl);
    await tester.tap(_key('sign-in-use-token'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('admin-token'), gatewayAdminToken);
    await tester.tap(_key('sign-in-token'));
    await tester.pumpAndSettle();

    expect(c.read(sessionProvider).signedIn, isTrue);
    expect(_key('sign-in-github'), findsNothing);
    expect(find.text('Overview'), findsWidgets);
    final saved = jsonDecode(
      c.read(sharedPreferencesProvider).getString('mcpm.session.v1')!,
    ) as Map;
    expect(saved['token'], gatewayAdminToken);
  });

  testWidgets('a wrong token says so and stays on the page', (tester) async {
    final c = await pumpApp(tester, signedIn: false);
    await tester.enterText(_key('server-url'), gatewayUrl);
    await tester.tap(_key('sign-in-use-token'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('admin-token'), 'wrong-wrong-wrong-wrong');
    await tester.tap(_key('sign-in-token'));
    await tester.pumpAndSettle();

    expect(find.text('That token is not accepted.'), findsOneWidget);
    expect(c.read(sessionProvider).signedIn, isFalse);
    expect(_key('sign-in-token'), findsOneWidget);
  });

  testWidgets('GitHub says when the server has none set up', (tester) async {
    await pumpApp(tester, signedIn: false);
    await tester.enterText(_key('server-url'), gatewayUrl);
    await tester.tap(_key('sign-in-github'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no GitHub sign-in set up'), findsOneWidget);
  });

  testWidgets('a session that ended says why', (tester) async {
    await pumpApp(
      tester,
      signedIn: false,
      prefs: {
        'mcpm.session.v1': jsonEncode({
          'url': gatewayUrl,
          'token': 'revoked-revoked-revoked',
        }),
      },
    );
    expect(find.textContaining('Your session has ended'), findsOneWidget);
    expect(
      tester.widget<TextField>(_key('server-url')).controller!.text,
      gatewayUrl,
      reason: 'the address is remembered',
    );
  });

  testWidgets('it fits a phone', (tester) async {
    await pumpApp(tester, signedIn: false, size: const Size(360, 640));
    await tester.tap(_key('sign-in-use-token'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('signing out from Settings returns to the sign-in page', (
    tester,
  ) async {
    await pumpApp(tester);
    await goTo(tester, '/settings');
    await tester.tap(find.widgetWithText(ListTile, 'Account & data'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(_key('sign-in-github'), findsOneWidget);
  });
}
