import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/server/server_client.dart';
import 'package:mcp_manager/engine/server/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/gateway_harness.dart';

class _Github extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnimplementedError();
}

void main() {
  late TestGateway gw;

  Future<ProviderContainer> start({
    Map<String, Object> prefs = const {},
    http.Client? reach,
    List<Uri>? navigated,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final sp = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sp),
        serverHttpClientProvider.overrideWithValue(() => reach ?? gw.client),
        if (navigated != null)
          sessionNavigatorProvider.overrideWithValue(navigated.add),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  SessionState state(ProviderContainer c) => c.read(sessionProvider);
  SessionNotifier session(ProviderContainer c) =>
      c.read(sessionProvider.notifier);

  Map<String, dynamic> saved(ProviderContainer c) => (jsonDecode(
    c.read(sharedPreferencesProvider).getString('mcpm.session.v1') ?? '{}',
  ) as Map).cast<String, dynamic>();

  group('signing in with the admin token', () {
    setUp(() async => gw = await TestGateway.start());
    tearDown(() => gw.client.close());

    test('starts signed out', () async {
      final c = await start();
      expect(state(c).status, SessionStatus.signedOut);
      expect(state(c).signedIn, isFalse);
    });

    test(
      'a right token signs in, and the address and token are kept',
      () async {
        final c = await start();
        final error = await session(c)
            .signInWithAdminToken('gateway.test', gatewayAdminToken);
        expect(error, isNull);
        expect(state(c).signedIn, isTrue);
        expect(state(c).serverUrl, 'http://gateway.test');
        expect(state(c).identity!.kind, 'admin');
        expect(saved(c), {
          'url': 'http://gateway.test',
          'token': gatewayAdminToken,
        });
      },
    );

    test('a wrong token is refused and nothing is kept', () async {
      final c = await start();
      final error = await session(c)
          .signInWithAdminToken(gatewayUrl, 'wrong-wrong-wrong-wrong');
      expect(error, contains('not accepted'));
      expect(state(c).signedIn, isFalse);
      expect(saved(c), isEmpty);
    });

    test('an empty address or token is refused before any request', () async {
      final c = await start();
      expect(
        await session(c).signInWithAdminToken('', 'x'),
        contains('address'),
      );
      expect(
        await session(c).signInWithAdminToken(gatewayUrl, '  '),
        contains('token'),
      );
    });

    test('a server that cannot be reached says so', () async {
      final c = await start(
        reach: MockClient(
          (_) async => throw http.ClientException('connection refused'),
        ),
      );
      final error = await session(c)
          .signInWithAdminToken(gatewayUrl, gatewayAdminToken);
      expect(error, contains('Could not reach'));
      expect(state(c).signedIn, isFalse);
    });
  });

  group('coming back later', () {
    setUp(() async => gw = await TestGateway.start());
    tearDown(() => gw.client.close());

    test('a saved session is checked, then trusted', () async {
      final c = await start(
        prefs: {
          'mcpm.session.v1': jsonEncode({
            'url': gatewayUrl,
            'token': gatewayAdminToken,
          }),
        },
      );
      expect(state(c).status, SessionStatus.checking);
      for (var i = 0; i < 20 && !state(c).signedIn; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(state(c).signedIn, isTrue);
      expect(c.read(serverClientProvider), isNotNull);
    });

    test('a token the server no longer accepts ends the session', () async {
      final c = await start(
        prefs: {
          'mcpm.session.v1': jsonEncode({
            'url': gatewayUrl,
            'token': 'revoked-revoked-revoked',
          }),
        },
      );
      for (
        var i = 0;
        i < 20 && state(c).status == SessionStatus.checking;
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(state(c).status, SessionStatus.signedOut);
      expect(state(c).error, contains('Sign in again'));
      expect(state(c).serverUrl, gatewayUrl, reason: 'the address is kept');
      expect(saved(c).containsKey('token'), isFalse);
    });

    test('a server that is down keeps the token and lets you retry', () async {
      final down = MockClient(
        (_) async => throw http.ClientException('connection refused'),
      );
      final c = await start(
        reach: down,
        prefs: {
          'mcpm.session.v1': jsonEncode({
            'url': gatewayUrl,
            'token': gatewayAdminToken,
          }),
        },
      );
      for (
        var i = 0;
        i < 20 && state(c).status == SessionStatus.checking;
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(state(c).signedIn, isFalse);
      expect(state(c).token, gatewayAdminToken);
      expect(state(c).error, contains('Could not reach'));
    });

    test('an unauthorized answer later ends the session', () async {
      final c = await start();
      await session(c).signInWithAdminToken(gatewayUrl, gatewayAdminToken);
      session(c).expired();
      expect(state(c).status, SessionStatus.signedOut);
      expect(c.read(serverClientProvider), isNull);
    });

    test('signing out forgets the token here', () async {
      final c = await start();
      await session(c).signInWithAdminToken(gatewayUrl, gatewayAdminToken);
      await session(c).signOut();
      expect(state(c).signedIn, isFalse);
      expect(saved(c).containsKey('token'), isFalse);
      expect(saved(c)['url'], 'http://gateway.test');
    });
  });

  group('GitHub', () {
    test('asks what the server offers', () async {
      gw = await TestGateway.start(
        githubClient: _Github.new,
        githubOrgs: ['acme'],
      );
      addTearDown(gw.client.close);
      final c = await start();
      final options = await session(c).inspect(gatewayUrl);
      expect(options.github, isTrue);
      expect(options.orgs, ['acme']);
    });

    test(
      'sends the window to the server\'s sign-in, remembering the address',
      () async {
        gw = await TestGateway.start(
          githubClient: _Github.new,
          githubOrgs: ['acme'],
        );
        addTearDown(gw.client.close);
        final navigated = <Uri>[];
        final c = await start(navigated: navigated);
        final error = await session(c).beginSignIn('gateway.test');
        expect(error, isNull);
        expect(
          navigated.single.toString(),
          startsWith('http://gateway.test/auth/github?return_to='),
        );
        expect(saved(c)['url'], 'http://gateway.test');
        expect(saved(c).containsKey('token'), isFalse);
      },
    );

    test('says so when the server has no GitHub sign-in', () async {
      gw = await TestGateway.start();
      addTearDown(gw.client.close);
      final navigated = <Uri>[];
      final c = await start(navigated: navigated);
      final error = await session(c).beginSignIn(gatewayUrl);
      expect(error, contains('no sign-in set up'));
      expect(navigated, isEmpty);
    });
  });

  group('the client', () {
    test('turns a refusal into a message and tells the session', () async {
      var told = 0;
      final client = ServerClient(
        baseUrl: 'http://x.test/',
        token: 't',
        httpClient: MockClient(
          (_) async => http.Response('{"error":"unauthorized"}', 401),
        ),
        onUnauthorized: () => told++,
      );
      await expectLater(
        client.send('GET', '/api/me'),
        throwsA(
          isA<ServerException>()
              .having((e) => e.unauthorized, 'unauthorized', isTrue)
              .having((e) => e.code, 'code', 'unauthorized'),
        ),
      );
      expect(told, 1);
    });

    test('normalizes the address people type', () {
      expect(normalizeServerUrl(' localhost:8787/ '), 'http://localhost:8787');
      expect(normalizeServerUrl('https://a.test///'), 'https://a.test');
      expect(normalizeServerUrl(''), '');
    });
  });
}
