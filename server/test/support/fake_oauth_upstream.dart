import 'dart:convert';
import 'dart:io';

import 'package:mcp_portal_server/mcp_portal_server.dart';

/// An MCP server behind OAuth, with its own authorization server: discovery,
/// dynamic registration, PKCE and rotating refresh tokens.
class FakeOAuthUpstream {
  FakeOAuthUpstream._(this._server);

  final HttpServer _server;

  /// Seconds an access token lasts.
  int expiresIn = 3600;

  /// Make refresh requests fail like a revoked grant.
  bool rejectRefresh = false;

  /// Client ids that exist without registering (pre-registered clients).
  final presetClients = <String>{};

  final registrations = <Map<String, dynamic>>[];
  final authorizeRequests = <Uri>[];
  final tokenRequests = <Map<String, String>>[];
  final mcpRequests = <String>[]; // the bearer of each MCP request
  var _n = 0;

  final _codes = <String, Map<String, String>>{};
  final _accessTokens = <String>{};
  final _refreshTokens = <String>{};

  String get origin => 'http://127.0.0.1:${_server.port}';
  String get url => '$origin/mcp';

  int get refreshCount =>
      tokenRequests.where((r) => r['grant_type'] == 'refresh_token').length;

  static Future<FakeOAuthUpstream> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeOAuthUpstream._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  /// Drops every access token, as a server revoking them would.
  void revokeAccessTokens() => _accessTokens.clear();

  /// What the user's approval would do: checks the request the gateway built
  /// and returns the address the browser is sent back to.
  Uri approve(Uri authorizeUrl, {String? error}) {
    final q = authorizeUrl.queryParameters;
    final redirect = Uri.parse(q['redirect_uri']!);
    if (error != null) {
      return redirect.replace(
        queryParameters: {'error': error, 'state': q['state']!},
      );
    }
    final code = 'code-${_n++}';
    _codes[code] = q;
    return redirect.replace(
      queryParameters: {'code': code, 'state': q['state']!},
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final path = request.uri.path;

    void json(
      int status,
      Object data, {
      Map<String, String> headers = const {},
    }) {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json;
      headers.forEach(request.response.headers.set);
      request.response.write(jsonEncode(data));
      request.response.close();
    }

    switch (path) {
      case '/.well-known/oauth-protected-resource/mcp':
        return json(200, {
          'resource': url,
          'authorization_servers': [origin],
        });
      case '/.well-known/oauth-authorization-server':
        return json(200, {
          'issuer': origin,
          'authorization_endpoint': '$origin/authorize',
          'token_endpoint': '$origin/token',
          'registration_endpoint': '$origin/register',
        });
      case '/register':
        final doc = (jsonDecode(body) as Map).cast<String, dynamic>();
        registrations.add(doc);
        return json(201, {'client_id': 'client-${registrations.length}'});
      case '/authorize':
        authorizeRequests.add(request.uri);
        return json(200, {'note': 'the test approves this itself'});
      case '/token':
        return _token(Uri.splitQueryString(body), json);
      case '/mcp':
        return _mcp(request, body, json);
    }
    json(404, {'error': 'not found'});
  }

  void _token(
    Map<String, String> form,
    void Function(int, Object, {Map<String, String> headers}) json,
  ) {
    tokenRequests.add(form);
    Object issue() {
      final at = 'at-${_n++}';
      final rt = 'rt-${_n++}';
      _accessTokens.add(at);
      _refreshTokens.add(rt);
      return {
        'access_token': at,
        'refresh_token': rt,
        'token_type': 'Bearer',
        'expires_in': expiresIn,
        'scope': 'read',
      };
    }

    if (form['grant_type'] == 'authorization_code') {
      final q = _codes.remove(form['code']);
      if (q == null) {
        return json(400, {
          'error': 'invalid_grant',
          'error_description': 'bad code',
        });
      }
      final okPkce =
          pkceS256(form['code_verifier'] ?? '') == q['code_challenge'];
      final okClient = form['client_id'] == q['client_id'];
      final okRedirect = form['redirect_uri'] == q['redirect_uri'];
      if (!okPkce || !okClient || !okRedirect) {
        return json(400, {
          'error': 'invalid_grant',
          'error_description': 'mismatch',
        });
      }
      return json(200, issue());
    }
    if (form['grant_type'] == 'refresh_token') {
      if (rejectRefresh || !_refreshTokens.remove(form['refresh_token'])) {
        return json(400, {
          'error': 'invalid_grant',
          'error_description': 'revoked',
        });
      }
      return json(200, issue());
    }
    json(400, {'error': 'unsupported_grant_type'});
  }

  void _mcp(
    HttpRequest request,
    String body,
    void Function(int, Object, {Map<String, String> headers}) json,
  ) {
    final auth = request.headers.value('authorization') ?? '';
    final bearer = auth.replaceFirst('Bearer ', '');
    mcpRequests.add(auth.startsWith('Bearer ') ? bearer : '');
    if (!_accessTokens.contains(bearer)) {
      return json(
        401,
        {'error': 'unauthorized'},
        headers: {
          'www-authenticate':
              'Bearer resource_metadata="$origin/.well-known/oauth-protected-resource/mcp", scope="read"',
        },
      );
    }
    final rpc = (jsonDecode(body) as Map).cast<String, dynamic>();
    final id = rpc['id'];
    Object? result;
    switch (rpc['method']) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'oauth-upstream', 'version': '1'},
        };
      case 'tools/list':
        result = {
          'tools': [
            {
              'name': 'whoami',
              'description': 'Says which token called.',
              'inputSchema': {'type': 'object', 'properties': {}},
            },
          ],
        };
      case 'tools/call':
        result = {
          'content': [
            {'type': 'text', 'text': 'token:$bearer'},
          ],
        };
      case 'ping':
        result = {};
      default:
        // Notifications and anything else: accepted, no body.
        request.response.statusCode = 202;
        request.response.close();
        return;
    }
    json(200, {'jsonrpc': '2.0', 'id': id, 'result': result});
  }
}
