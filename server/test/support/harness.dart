import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mcp_portal_server/mcp_portal_server.dart';

import 'fake_github.dart';

const adminToken = 'admin-token-for-tests-1234';

String hashOf(String secret) => hashSecret(secret);

/// A running gateway plus a client for it.
class Harness {
  Harness._(this.gateway, this.base, this.clock);

  final GatewayServer gateway;
  final String base;
  final Clock clock;
  final client = http.Client();

  /// Starts a gateway on a free port. Everything stays in memory unless
  /// [databaseUrl] is given (see [TestDatabase]).
  static Future<Harness> start({
    String? databaseUrl,
    String? token = adminToken,
    List<String> allowedOrigins = const [],
    String? publicUrl,
    FakeGitHub? github,
    List<String> githubOrgs = const [],
    List<String> githubUsers = const [],
    Duration? eventHeartbeat,
    Duration healthInterval = Duration.zero,
    int maxChatsPerOwner = 200,
  }) async {
    final clock = Clock();
    final gateway = await GatewayServer.create(
      GatewayConfig(
        host: '127.0.0.1',
        port: 0,
        databaseUrl: databaseUrl,
        adminToken: token,
        allowedOrigins: allowedOrigins,
        publicBaseUrl: publicUrl,
        githubClientId: github == null ? null : 'gh-client',
        githubClientSecret: github == null ? null : 'gh-secret',
        githubOrgs: githubOrgs,
        githubUsers: githubUsers,
        eventHeartbeat: eventHeartbeat ?? const Duration(seconds: 25),
        healthInterval: healthInterval,
        maxChatsPerOwner: maxChatsPerOwner,
        githubUrl: github?.url ?? 'https://github.com',
        githubApiUrl: github?.url ?? 'https://api.github.com',
      ),
      clock: clock.call,
      inMemory: databaseUrl == null,
    );
    final server = await gateway.start();
    return Harness._(gateway, 'http://127.0.0.1:${server.port}', clock);
  }

  Future<void> close() async {
    client.close();
    await gateway.close();
  }

  // ---------------------------------------------------------------- helpers

  /// A GET that does not follow redirects.
  Future<http.Response> rawGet(
    String path, [
    Map<String, String>? headers,
  ]) async {
    final request = http.Request('GET', Uri.parse('$base$path'))
      ..followRedirects = false
      ..headers.addAll(headers ?? {});
    return http.Response.fromStream(await client.send(request));
  }

  Map<String, String> adminHeaders([String token = adminToken]) => {
    'authorization': 'Bearer $token',
    'content-type': 'application/json',
  };

  Future<http.Response> admin(
    String method,
    String path, [
    Object? body,
    Map<String, String>? headers,
  ]) {
    final request = http.Request(method, Uri.parse('$base$path'))
      ..headers.addAll(headers ?? adminHeaders());
    if (body != null) request.body = jsonEncode(body);
    return client.send(request).then(http.Response.fromStream);
  }

  Future<Map<String, dynamic>> adminJson(
    String method,
    String path, [
    Object? body,
  ]) async {
    final response = await admin(method, path, body);
    if (response.statusCode >= 300) {
      throw StateError(
        '$method $path → ${response.statusCode}: ${response.body}',
      );
    }
    final decoded = jsonDecode(response.body);
    return decoded is Map
        ? decoded.cast<String, dynamic>()
        : {'value': decoded};
  }

  /// Registers an upstream; returns its id.
  Future<String> addServer(
    String name,
    String url, {
    Map<String, String>? headers,
    String? id,
  }) async {
    final body = {
      'name': name,
      'url': url,
      'transport': 'streamable-http',
      'headers': ?headers,
    };
    final json = id == null
        ? await adminJson('POST', '/api/servers', body)
        : await adminJson('PUT', '/api/servers/$id', body);
    return json['id'] as String;
  }

  /// Creates a portal over [serverIds]; returns its id.
  Future<String> addPortal(
    String name,
    List<String> serverIds, {
    String? slug,
    Map<String, dynamic> extra = const {},
  }) async {
    final json = await adminJson('POST', '/api/portals', {
      'name': name,
      'slug': ?slug,
      'servers': serverIds,
      ...extra,
    });
    return json['id'] as String;
  }

  /// Creates an access token; returns its secret.
  Future<String> addToken(
    String name, {
    List<String> portalIds = const [],
    int? days,
  }) async {
    final json = await adminJson('POST', '/api/tokens', {
      'name': name,
      'portalIds': portalIds,
      'expiresInDays': ?days,
    });
    return json['secret'] as String;
  }

  /// One JSON-RPC request to a portal.
  Future<Map<String, dynamic>> rpc(
    String slug,
    String method, {
    Map<String, dynamic>? params,
    String? token,
    int id = 1,
  }) async {
    final response = await post(slug, {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    }, token: token);
    return (jsonDecode(response.body) as Map).cast<String, dynamic>();
  }

  Future<http.Response> post(
    String slug,
    Object body, {
    String? token,
    Map<String, String>? headers,
  }) => client.post(
    Uri.parse('$base/mcp/$slug'),
    headers: {
      'content-type': 'application/json',
      'accept': 'application/json, text/event-stream',
      if (token != null) 'authorization': 'Bearer $token',
      ...?headers,
    },
    body: body is String ? body : jsonEncode(body),
  );

  Future<Map<String, dynamic>> callTool(
    String slug,
    String token,
    String name, [
    Map<String, dynamic> args = const {},
  ]) => rpc(
    slug,
    'tools/call',
    token: token,
    params: {'name': name, 'arguments': args},
  );

  Future<List<String>> toolNames(String slug, String token) async {
    final reply = await rpc(slug, 'tools/list', token: token);
    return [
      for (final t in (reply['result']['tools'] as List))
        (t as Map)['name'] as String,
    ];
  }

  String textOf(Map<String, dynamic> reply) =>
      ((reply['result']['content'] as List).first as Map)['text'] as String;
}

/// A clock the tests can move.
class Clock {
  DateTime _now = DateTime.now();
  DateTime call() => _now;
  void advance(Duration d) => _now = _now.add(d);
}

/// A bare request, for the cases the helpers above do not cover.
http.Request rawRequest(
  String method,
  String url,
  Map<String, String> headers,
) => http.Request(method, Uri.parse(url))..headers.addAll(headers);
