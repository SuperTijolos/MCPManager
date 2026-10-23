import 'dart:async';

import 'package:test/test.dart';

import 'support/fake_github.dart';
import 'support/fake_upstream.dart';
import 'support/harness.dart';
import 'support/sse.dart';

void main() {
  late Harness gw;
  late FakeUpstream upstream;

  setUp(() async {
    gw = await Harness.start(eventHeartbeat: const Duration(milliseconds: 80));
    upstream = await FakeUpstream.start(
      tools: [tool('lookup')],
      handlers: {'lookup': (_) => textResult('found')},
    );
  });

  tearDown(() async {
    await gw.close();
    await upstream.close();
  });

  Future<SseReader> open({String? token = adminToken}) async {
    final r = await SseReader.open(
      '${gw.base}/api/events',
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    );
    addTearDown(r.close);
    return r;
  }

  test('needs a credential', () async {
    final r = await open(token: null);
    expect(r.status, 401);
    final wrong = await open(token: 'wrong-wrong-wrong-wrong');
    expect(wrong.status, 401);
  });

  test('opens as an event stream and says it is ready', () async {
    final r = await open();
    expect(r.status, 200);
    expect(r.headers['content-type'], startsWith('text/event-stream'));
    expect(r.headers['cache-control'], contains('no-cache'));
    expect((await r.next()).event, 'ready');
  });

  test('announces a stored call as it is recorded', () async {
    await gw.addServer('Docs', upstream.url, id: 'srv');
    await gw.addPortal('Docs', ['srv'], slug: 'docs');
    final token = await gw.addToken('c');
    final r = await open();
    await r.nextOf('ready');

    await gw.callTool('docs', token, 'docs__lookup');
    final e = await r.nextOf('audit');
    expect(e.data['exposedName'], 'docs__lookup');
    expect(e.data['status'], 'success');
    expect(e.data['result'], 'found');
    expect(e.data['portalSlug'], 'docs');
  });

  test('announces which stored things changed', () async {
    final r = await open();
    await r.nextOf('ready');

    await gw.addServer('Docs', upstream.url, id: 'srv');
    expect((await r.nextOf('changed')).data['collections'], ['servers']);

    await gw.addPortal('Docs', ['srv'], slug: 'docs');
    expect((await r.nextOf('changed')).data['collections'], ['portals']);

    await gw.addToken('c');
    expect((await r.nextOf('changed')).data['collections'], ['tokens']);

    await gw.adminJson('PUT', '/api/rules', {
      'rules': [],
      'overrides': {
        'srv/x': {'hidden': true},
      },
    });
    expect((await r.nextOf('changed')).data['collections'], ['overrides']);
  });

  test('says nothing when nothing changed', () async {
    await gw.addServer('Docs', upstream.url, id: 'srv');
    final r = await open();
    await r.nextOf('ready');
    await gw.adminJson('PUT', '/api/servers/srv', {
      'name': 'Docs',
      'url': upstream.url,
      'transport': 'streamable-http',
    });
    expect(await r.quietFor(), isTrue, reason: '${r.messages}');
  });

  test('reaches every open dashboard', () async {
    final a = await open();
    final b = await open();
    await a.nextOf('ready');
    await b.nextOf('ready');
    await gw.addServer('Docs', upstream.url, id: 'srv');
    expect((await a.nextOf('changed')).data['collections'], ['servers']);
    expect((await b.nextOf('changed')).data['collections'], ['servers']);
  });

  test('keeps an idle stream alive', () async {
    final r = await open();
    await r.nextOf('ready');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(r.comments, isNotEmpty);
  });

  test('stops sending to a dashboard that left', () async {
    final r = await open();
    await r.nextOf('ready');
    expect(gw.gateway.bus.hasListeners, isTrue);
    await r.close();
    for (var i = 0; i < 20 && gw.gateway.bus.hasListeners; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(gw.gateway.bus.hasListeners, isFalse);
  });

  test('ends when the server shuts down', () async {
    final r = await open();
    await r.nextOf('ready');
    await gw.gateway.close();
    for (var i = 0; i < 40 && !r.done; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(r.done, isTrue);
  });

  test('a signed-in member can listen too', () async {
    final github = await FakeGitHub.start();
    addTearDown(github.close);
    await gw.close();
    gw = await Harness.start(github: github, githubOrgs: ['acme']);
    final code = github.codeFor(GhUser(1, 'ada', orgs: ['acme']));
    final start = await gw.rawGet('/auth/github');
    final state = Uri.parse(
      start.headers['location']!,
    ).queryParameters['state']!;
    final done = await gw.rawGet(
      '/auth/github/callback?code=$code&state=$state',
      {'cookie': 'mcp_login=$state'},
    );
    final session = RegExp(
      'mcp_session=([^;,]+)',
    ).firstMatch(done.headers['set-cookie']!)!.group(1)!;

    final r = await open(token: session);
    expect(r.status, 200);
    expect((await r.next()).event, 'ready');
  });
}
