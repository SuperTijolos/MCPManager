import 'dart:convert';
import 'dart:io';

import 'package:mcp_portal_server/mcp_portal_server.dart';
import 'package:test/test.dart';

import 'support/fake_upstream.dart';
import 'support/harness.dart';

void main() {
  late Directory dir;
  late FakeUpstream upstream;

  setUp(() async {
    dir = await tempDir();
    upstream = await FakeUpstream.start(
      tools: [tool('lookup')],
      handlers: {'lookup': (_) => textResult('found')},
    );
  });

  tearDown(() async {
    await upstream.close();
    await dir.delete(recursive: true);
  });

  test('servers, portals, tokens and rules survive a restart', () async {
    var gw = await Harness.start(dataDir: dir.path);
    await gw.addServer(
      'Docs',
      upstream.url,
      id: 'srv',
      headers: {'X-Key': 'secret'},
    );
    await gw.addPortal('Docs', ['srv'], slug: 'docs');
    final token = await gw.addToken('c');
    await gw.adminJson('PUT', '/api/rules', {
      'rules': [],
      'overrides': {
        'srv/other': {'hidden': true},
      },
    });
    await gw.toolNames('docs', token);
    await gw.close();

    gw = await Harness.start(dataDir: dir.path);
    addTearDown(gw.close);
    expect(await gw.toolNames('docs', token), ['docs__lookup']);
    final server = await gw.adminJson('GET', '/api/servers/srv');
    expect(server['headerNames'], ['X-Key']);
    expect((await gw.adminJson('GET', '/api/rules'))['overrides'], isNotEmpty);
  });

  test('the state file is private and written in one piece', () async {
    final gw = await Harness.start(dataDir: dir.path);
    addTearDown(gw.close);
    await gw.addServer(
      'Docs',
      upstream.url,
      headers: {'Authorization': 'Bearer s'},
    );

    final file = File('${dir.path}/state.json');
    expect(await file.exists(), isTrue);
    expect(File('${dir.path}/state.json.tmp').existsSync(), isFalse);
    if (!Platform.isWindows) {
      final mode = (await file.stat()).mode & 0x1ff;
      expect(mode.toRadixString(8), '600');
    }
    expect(jsonDecode(await file.readAsString()), isA<Map>());
  });

  test('the audit log is appended to a file and read back', () async {
    var gw = await Harness.start(dataDir: dir.path);
    await gw.addServer('Docs', upstream.url, id: 'srv');
    await gw.addPortal('Docs', ['srv'], slug: 'docs');
    final token = await gw.addToken('c');
    await gw.callTool('docs', token, 'docs__lookup');
    await gw.gateway.audit.flush();
    await gw.close();

    final lines = await File('${dir.path}/audit.jsonl').readAsLines();
    expect(lines, hasLength(1));

    gw = await Harness.start(dataDir: dir.path);
    addTearDown(gw.close);
    final events = (await gw.adminJson('GET', '/api/audit'))['events'] as List;
    expect(events, hasLength(1));
    expect((events.single as Map)['exposedName'], 'docs__lookup');
  });

  test('a damaged audit line is skipped, not fatal', () async {
    await File(
      '${dir.path}/audit.jsonl',
    ).writeAsString('not json\n{"also":"wrong"}\n');
    final gw = await Harness.start(dataDir: dir.path);
    addTearDown(gw.close);
    expect((await gw.adminJson('GET', '/api/audit'))['events'], isEmpty);
  });

  group('the admin token', () {
    test(
      'is generated at first start, shown once, and kept as a hash',
      () async {
        var gw = await Harness.start(dataDir: dir.path, token: null);
        final secret = gw.gateway.generatedAdminToken!;
        expect(secret, startsWith('mcpadmin_'));
        expect(
          (await gw.admin(
            'GET',
            '/api/status',
            null,
            gw.adminHeaders(secret),
          )).statusCode,
          200,
        );
        expect(
          await File('${dir.path}/state.json').readAsString(),
          isNot(contains(secret)),
        );
        await gw.close();

        gw = await Harness.start(dataDir: dir.path, token: null);
        addTearDown(gw.close);
        expect(
          gw.gateway.generatedAdminToken,
          isNull,
          reason: 'only the first start shows it',
        );
        expect(
          (await gw.admin(
            'GET',
            '/api/status',
            null,
            gw.adminHeaders(secret),
          )).statusCode,
          200,
        );
        expect(
          (await gw.admin(
            'GET',
            '/api/status',
            null,
            gw.adminHeaders('wrong-wrong-wrong-wrong'),
          )).statusCode,
          401,
        );
      },
    );

    test('a configured token wins and must be long enough', () async {
      expect(
        () => GatewayServer.create(
          GatewayConfig(port: 0, dataDir: dir.path, adminToken: 'short'),
        ),
        throwsA(isA<ArgumentError>()),
      );
      final gw = await Harness.start(
        dataDir: dir.path,
        token: 'a-configured-admin-token-1234',
      );
      addTearDown(gw.close);
      expect(gw.gateway.generatedAdminToken, isNull);
      expect(
        (await gw.admin(
          'GET',
          '/api/status',
          null,
          gw.adminHeaders('a-configured-admin-token-1234'),
        )).statusCode,
        200,
      );
    });
  });
}
