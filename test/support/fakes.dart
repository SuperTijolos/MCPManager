import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/core/json.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/oauth/oauth_models.dart';
import 'package:mcp_manager/engine/mcp/oauth/oauth_popup.dart';
import 'package:mcp_manager/engine/mcp/oauth/oauth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeMcpServer {
  FakeMcpServer({
    this.tools = const [],
    this.handlers = const {},
    this.sse = false,
    this.sessionId = 'sess-1',
  });

  final List<Json> tools;

  /// tool name -> handler returning the `result` payload of tools/call.
  final Map<String, Json Function(Json args)> handlers;
  final bool sse;
  final String? sessionId;

  final requests = <http.Request>[];
  final bodies = <Json>[];

  /// Set to make the next request with a session header fail with 404.
  bool expireSession = false;

  http.Client get client => MockClient((request) async {
    requests.add(request);
    if (request.method == 'DELETE') return http.Response('', 200);
    final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
    bodies.add(body);
    final method = body['method'] as String;
    final id = body['id'];

    if (method != 'initialize' &&
        expireSession &&
        request.headers.containsKey('mcp-session-id')) {
      expireSession = false;
      return http.Response('session not found', 404);
    }
    if (id == null) return http.Response('', 202);

    Json result;
    switch (method) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fake', 'version': '1.2.3'},
        };
      case 'tools/list':
        result = {'tools': tools};
      case 'tools/call':
        final params = (body['params'] as Map).cast<String, dynamic>();
        final handler = handlers[params['name']];
        if (handler == null) {
          return _reply({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'Unknown tool'},
          });
        }
        result = handler(
          (params['arguments'] as Map?)?.cast<String, dynamic>() ?? {},
        );
      case 'ping':
        result = {};
      default:
        return _reply({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found'},
        });
    }

    return _reply({
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }, withSession: method == 'initialize');
  });

  http.Response _reply(Json message, {bool withSession = false}) {
    final headers = <String, String>{
      if (withSession && sessionId != null) 'mcp-session-id': sessionId!,
    };
    if (sse) {
      return http.Response(
        ': keep-alive\n\nevent: message\ndata: ${jsonEncode(message)}\n\n',
        200,
        headers: {...headers, 'content-type': 'text/event-stream'},
      );
    }
    return http.Response(
      jsonEncode(message),
      200,
      headers: {...headers, 'content-type': 'application/json'},
    );
  }
}

Json textResult(String text, {bool isError = false}) => {
  'content': [
    {'type': 'text', 'text': text},
  ],
  if (isError) 'isError': true,
};

/// Scripted LLM: each call to [chat] consumes the next list of events.
class ScriptedLlm implements LlmProvider {
  ScriptedLlm(this.turns);

  final List<List<LlmEvent>> turns;
  final received = <List<LlmMessage>>[];
  final toolSpecs = <List<LlmToolSpec>>[];
  var _next = 0;
  bool closed = false;

  @override
  Future<List<LlmModel>> listModels() async => [
    const LlmModel('gemma4', supportsTools: true),
  ];

  @override
  Stream<LlmEvent> chat({
    required String model,
    required List<LlmMessage> messages,
    List<LlmToolSpec> tools = const [],
  }) async* {
    received.add(List.of(messages));
    toolSpecs.add(tools);
    final turn = _next < turns.length
        ? turns[_next]
        : const <LlmEvent>[LlmDone()];
    _next++;
    for (final e in turn) {
      yield e;
    }
  }

  @override
  void close() => closed = true;
}

Future<ProviderContainer> makeContainer({
  FakeMcpServer? server,
  LlmProvider? llm,
  http.Client? httpClient,
  OAuthPopup Function()? popupOpener,
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(sp),
      oauthRedirectUriProvider.overrideWithValue(Uri.parse(oauthRedirect)),
      if (popupOpener != null)
        oauthPopupOpenerProvider.overrideWithValue(popupOpener),
      if (server != null || httpClient != null)
        mcpHttpClientFactoryProvider.overrideWithValue(
          () => httpClient ?? server!.client,
        ),
      if (llm != null) llmProviderFactoryProvider.overrideWithValue((_) => llm),
    ],
  );
  return container;
}

// ---------------------------------------------------------------------------
// OAuth

const oauthMcpUrl = 'https://mcp.test/mcp';
const oauthRedirect = 'https://app.test/oauth_callback.html';

/// An MCP server protected by OAuth, plus its authorization server, behind one
/// mock HTTP client. Mirrors the MCP authorization spec: 401 +
/// `WWW-Authenticate: resource_metadata`, RFC 9728/8414 metadata, RFC 7591
/// dynamic registration, authorization code + PKCE (S256), refresh tokens.
class FakeOAuthWorld {
  FakeOAuthWorld({
    FakeMcpServer? mcp,
    this.withChallengeHeader = true,
    this.withMetadata = true,
    this.supportsRegistration = true,
    this.tokenLifetimeSeconds = 3600,
  }) : mcp = mcp ?? FakeMcpServer();

  final FakeMcpServer mcp;
  final bool withChallengeHeader;
  final bool withMetadata;
  final bool supportsRegistration;
  final int tokenLifetimeSeconds;

  final requested = <String>[]; // "METHOD url" for every request
  final registrations = <Map<String, dynamic>>[];
  final tokenRequests = <Map<String, String>>[];
  final mcpAuthHeaders = <String?>[];

  final _validAccess = <String>{};
  String? _challenge;
  String? _issuedClientId;
  int _tokenCount = 0;
  int _codeCount = 0;
  String? _validCode;
  String _validRefresh = 'rt-1';
  bool refreshFails = false;

  /// Stop honouring [token] so the next MCP call gets a 401.
  void revoke(String token) => _validAccess.remove(token);

  String? get latestAccessToken =>
      _validAccess.isEmpty ? null : _validAccess.last;

  /// The "user agrees in the browser" leg: validates the authorization request
  /// and returns the redirect parameters.
  Map<String, String> authorize(
    Uri url, {
    bool deny = false,
    String? stateOverride,
  }) {
    final q = url.queryParameters;
    expect(url.origin, 'https://auth.test');
    expect(q['response_type'], 'code');
    expect(q['code_challenge_method'], 'S256');
    expect(q['redirect_uri'], oauthRedirect);
    expect(q['resource'], oauthMcpUrl);
    if (_issuedClientId != null) expect(q['client_id'], _issuedClientId);
    _challenge = q['code_challenge'];
    if (deny) {
      return {
        'error': 'access_denied',
        'error_description': 'User said no',
        'state': q['state']!,
      };
    }
    _validCode = 'code-${++_codeCount}';
    return {'code': _validCode!, 'state': stateOverride ?? q['state']!};
  }

  http.Client get client => MockClient((request) async {
    requested.add('${request.method} ${request.url}');
    final url = request.url;

    if (url.host == 'mcp.test') {
      if (url.path.startsWith('/.well-known/oauth-protected-resource')) {
        if (!withMetadata) return http.Response('', 404);
        return _json({
          'resource': oauthMcpUrl,
          'authorization_servers': ['https://auth.test'],
        });
      }
      final auth = request.headers['authorization'];
      mcpAuthHeaders.add(auth);
      final token = auth?.startsWith('Bearer ') == true
          ? auth!.substring(7)
          : null;
      if (token == null || !_validAccess.contains(token)) {
        return http.Response(
          'unauthorized',
          401,
          headers: {
            if (withChallengeHeader) 'www-authenticate': 'Bearer realm="mcp", resource_metadata="https://mcp.test/.well-known/oauth-protected-resource/mcp"',
          },
        );
      }
      return mcp.client.send(_copy(request)).then(http.Response.fromStream);
    }

    if (url.host == 'auth.test') {
      switch (url.path) {
        case '/.well-known/oauth-authorization-server':
          if (!withMetadata) return http.Response('', 404);
          return _json({
            'issuer': 'https://auth.test',
            'authorization_endpoint': 'https://auth.test/authorize',
            'token_endpoint': 'https://auth.test/token',
            if (supportsRegistration)
              'registration_endpoint': 'https://auth.test/register',
            'code_challenge_methods_supported': ['S256'],
          });
        case '/register':
          final body = (jsonDecode(request.body) as Map)
              .cast<String, dynamic>();
          registrations.add(body);
          _issuedClientId = 'client-${registrations.length}';
          return _json({
            'client_id': _issuedClientId,
            'redirect_uris': body['redirect_uris'],
          }, 201);
        case '/token':
          return _token(request.bodyFields);
      }
    }
    return http.Response('not found', 404);
  });

  http.Response _token(Map<String, String> form) {
    tokenRequests.add(form);
    if (form['grant_type'] == 'authorization_code') {
      final verifier = form['code_verifier']!;
      final challenge = base64Url
          .encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');
      if (form['code'] != _validCode || challenge != _challenge) {
        return _json({
          'error': 'invalid_grant',
          'error_description': 'bad code or verifier',
        }, 400);
      }
      _validCode = null;
      return _issue();
    }
    if (form['grant_type'] == 'refresh_token') {
      if (refreshFails || form['refresh_token'] != _validRefresh) {
        return _json({
          'error': 'invalid_grant',
          'error_description': 'refresh token expired',
        }, 400);
      }
      return _issue();
    }
    return _json({'error': 'unsupported_grant_type'}, 400);
  }

  http.Response _issue() {
    _tokenCount++;
    final access = 'at-$_tokenCount';
    _validRefresh = 'rt-$_tokenCount';
    _validAccess.add(access);
    return _json({
      'access_token': access,
      'token_type': 'Bearer',
      'expires_in': tokenLifetimeSeconds,
      'refresh_token': _validRefresh,
    });
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.BaseRequest _copy(http.Request r) => http.Request(r.method, r.url)
    ..headers.addAll(r.headers)
    ..body = r.body;
}

/// A sign-in window driven by the test: records the URL it was sent to and
/// answers like the authorization server's redirect would.
class FakePopup implements OAuthPopup {
  FakePopup(this._respond);

  final Map<String, String> Function(Uri url) _respond;
  final navigated = <Uri>[];
  bool closed = false;
  final _result = Completer<Map<String, String>>();

  /// Approves every request.
  factory FakePopup.approving(FakeOAuthWorld world) =>
      FakePopup(world.authorize);

  factory FakePopup.denying(FakeOAuthWorld world) =>
      FakePopup((u) => world.authorize(u, deny: true));

  factory FakePopup.wrongState(FakeOAuthWorld world) =>
      FakePopup((u) => world.authorize(u, stateOverride: 'forged'));

  /// The user closes the window without finishing.
  factory FakePopup.closedByUser() => FakePopup(
    (_) =>
        throw OAuthException('The sign-in window was closed before finishing.'),
  );

  @override
  void navigate(Uri url) {
    navigated.add(url);
    try {
      _result.complete(_respond(url));
    } on OAuthException catch (e) {
      _result.completeError(e);
    }
  }

  @override
  Future<Map<String, String>> get result => _result.future;

  @override
  void close() => closed = true;
}

// ---------------------------------------------------------------------------
// Legacy HTTP+SSE transport

/// A server speaking the legacy MCP HTTP+SSE transport, with the routing of the
/// real VS Code MCP Bridge extension: `GET /sse` (exact path) opens the event
/// stream and announces `/messages?sessionId=…`; `POST /messages` answers
/// `202 Accepted` and sends the JSON-RPC reply on the stream; every other path
/// is a 404. Optionally demands a bearer token on everything but `/health`.
class FakeSseServer {
  FakeSseServer({
    this.tools = const [],
    this.handlers = const {},
    this.requireToken,
    this.endpointOverride,
    this.chunkSize,
    this.silent = false,
    this.replyDelays = const {},
  });

  final List<Json> tools;
  final Map<String, Json Function(Json args)> handlers;
  final String? requireToken;

  /// Sent instead of the normal `/messages?sessionId=…` endpoint.
  final String? endpointOverride;

  /// Split the stream into chunks of this many bytes (tests incremental parsing).
  final int? chunkSize;

  /// Open the stream but never send the endpoint event.
  final bool silent;

  /// tool name -> delay before its reply is sent.
  final Map<String, Duration> replyDelays;

  final log = <String>[]; // "METHOD path?query"
  final authHeaders = <String?>[];
  final posts = <Json>[];
  int sessions = 0;
  int streamsCancelled = 0;

  StreamController<List<int>>? _stream;
  String? _session;

  void dropStream() => _stream?.close();

  /// Emulate a network error while the long-lived SSE response is being read.
  void failStream(Object error) => _stream?.addError(error);

  void _send(String text) {
    final bytes = utf8.encode(text);
    final c = _stream;
    if (c == null || c.isClosed) return;
    final size = chunkSize;
    if (size == null) {
      c.add(bytes);
      return;
    }
    for (var i = 0; i < bytes.length; i += size) {
      c.add(
        bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
      );
    }
  }

  http.Response _plain(
    int status, [
    String body = '',
    Map<String, String>? headers,
  ]) => http.Response(
    body,
    status,
    headers: {'access-control-allow-origin': '*', ...?headers},
  );

  http.Client get client => MockClient.streaming((request, bodyStream) async {
    final path = request.url.path;
    final query = request.url.hasQuery ? '?${request.url.query}' : '';
    log.add('${request.method} $path$query');

    http.StreamedResponse respond(http.Response r) => http.StreamedResponse(
      Stream.value(r.bodyBytes),
      r.statusCode,
      headers: r.headers,
    );

    if (request.method == 'OPTIONS') return respond(_plain(204));
    if (path == '/health') return respond(_plain(200, '{"status":"ok"}'));

    authHeaders.add(request.headers['authorization']);
    if (requireToken != null &&
        request.headers['authorization'] != 'Bearer $requireToken') {
      return respond(
        _plain(401, '{"error":"Unauthorized"}', {
          'content-type': 'application/json',
        }),
      );
    }

    if (request.method == 'GET' && path == '/sse' && query.isEmpty) {
      sessions++;
      _session = 's$sessions';
      final controller = StreamController<List<int>>(
        onCancel: () => streamsCancelled++,
      );
      _stream = controller;
      if (!silent) {
        final endpoint = endpointOverride ?? '/messages?sessionId=$_session';
        _send('event: endpoint\ndata: $endpoint\n\n');
      }
      return http.StreamedResponse(
        controller.stream,
        200,
        headers: {
          'content-type': 'text/event-stream',
          'access-control-allow-origin': '*',
        },
      );
    }

    if (request.method == 'POST' && path.startsWith('/messages')) {
      if (request.url.queryParameters['sessionId'] != _session) {
        return respond(_plain(404, 'Session not found'));
      }
      final body = (jsonDecode(await bodyStream.bytesToString()) as Map)
          .cast<String, dynamic>();
      posts.add(body);
      final id = body['id'];
      if (id != null) _reply(body, id);
      return respond(_plain(202, 'Accepted'));
    }
    return respond(_plain(404));
  });

  void _reply(Json body, Object id) {
    final method = body['method'] as String;
    Json message;
    var delay = Duration.zero;
    switch (method) {
      case 'initialize':
        message = {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': '2024-11-05',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'vscode-mcp-bridge', 'version': '0.2.5'},
          },
        };
      case 'tools/list':
        message = {
          'jsonrpc': '2.0',
          'id': id,
          'result': {'tools': tools},
        };
      case 'tools/call':
        final params = (body['params'] as Map).cast<String, dynamic>();
        final handler = handlers[params['name']];
        delay = replyDelays[params['name']] ?? Duration.zero;
        message = handler == null
            ? {
                'jsonrpc': '2.0',
                'id': id,
                'error': {'code': -32602, 'message': 'Unknown tool'},
              }
            : {
                'jsonrpc': '2.0',
                'id': id,
                'result': handler(
                  (params['arguments'] as Map?)?.cast<String, dynamic>() ?? {},
                ),
              };
      case 'ping':
        message = {'jsonrpc': '2.0', 'id': id, 'result': {}};
      default:
        message = {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found'},
        };
    }
    final text = 'event: message\ndata: ${jsonEncode(message)}\n\n';
    // Replies come over the stream, after the POST has been acknowledged.
    Future<void>.delayed(delay, () => _send(text));
  }
}

// ---------------------------------------------------------------------------
// Servers with session trouble (the Cloudflare-style failure modes)

/// The body a server sends when it does not know the session.
const sessionGoneBody =
    '{"jsonrpc":"2.0","error":{"code":-32000,"message":"Bad Request: Session expired or does not exist. Please reconnect."},"id":null}';

/// A server at `/mcp` (Streamable HTTP) that misbehaves about sessions, and
/// optionally a legacy SSE server at `/sse` next to it.
///
/// - [hideSessionHeader]: it issues a session but the browser cannot read the
///   `Mcp-Session-Id` header (not listed in Access-Control-Expose-Headers), so
///   the client never learns the id and the next request is "unknown session".
/// - [rejectSession]: it hands out a session id and then refuses to recognise
///   it (state kept per instance, requests landing elsewhere).
/// - [rejectInitialized]: only the `initialized` notification is refused.
class SessionTroubleServer {
  SessionTroubleServer({
    this.hideSessionHeader = false,
    this.rejectSession = false,
    this.badNotification = false,
    this.sse,
    this.tools = const [],
  });

  final bool hideSessionHeader;
  final bool rejectSession;

  /// Answers `initialized` with a plain 400 that does not mention sessions.
  final bool badNotification;
  final FakeSseServer? sse;
  final List<Json> tools;

  final log = <String>[];

  http.Client get client => MockClient.streaming((request, bodyStream) async {
    final path = request.url.path;
    log.add('${request.method} $path');

    // The legacy transport, when present, owns /sse and /messages.
    if (sse != null && (path == '/sse' || path.startsWith('/messages'))) {
      return forwardTo(sse!.client, request, bodyStream);
    }

    http.StreamedResponse reply(
      int status,
      String body, {
      Map<String, String>? headers,
    }) => http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-type': 'application/json', ...?headers},
    );

    if (path != '/mcp' || request.method != 'POST') {
      return reply(404, 'not found');
    }
    final body = (jsonDecode(await bodyStream.bytesToString()) as Map)
        .cast<String, dynamic>();
    final method = body['method'] as String;
    final id = body['id'];

    if (method == 'initialize') {
      return reply(
        200,
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': '2025-06-18',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'edge-server', 'version': '1.0.0'},
          },
        }),
        headers: {if (!hideSessionHeader) 'mcp-session-id': 'sess-abc'},
      );
    }
    if (hideSessionHeader || rejectSession) return reply(404, sessionGoneBody);
    if (badNotification && id == null) return reply(400, 'Bad notification');
    if (id == null) return reply(202, '');
    return reply(
      200,
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': method == 'tools/list' ? {'tools': tools} : {},
      }),
    );
  });
}

/// Re-sends a request received by one fake to another client. A request that
/// has already been sent cannot be reused, so build an equivalent new one.
Future<http.StreamedResponse> forwardTo(
  http.Client target,
  http.BaseRequest request,
  http.ByteStream bodyStream,
) async {
  final copy = http.Request(request.method, request.url)
    ..headers.addAll(request.headers)
    ..bodyBytes = await bodyStream.toBytes();
  return target.send(copy);
}
