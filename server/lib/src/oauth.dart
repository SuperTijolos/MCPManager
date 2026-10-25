import 'dart:convert';
import 'dart:io';

import 'package:mcp_core/mcp_core.dart';
import 'package:shelf/shelf.dart';

import 'access.dart';
import 'login.dart';
import 'models.dart';
import 'pages.dart';
import 'security.dart';
import 'state.dart';

const _accessTtl = Duration(hours: 1);
const _refreshTtl = Duration(days: 30);
const _codeTtl = Duration(minutes: 5);
const _maxClients = 200;

class _Code {
  _Code({
    required this.clientId,
    required this.redirectUri,
    required this.challenge,
    required this.expiresAt,
    this.portalId,
  });
  final String clientId;
  final String redirectUri;
  final String challenge;
  final String? portalId;
  final DateTime expiresAt;
}

/// The OAuth 2.1 authorization server MCP clients use to sign in (what web
/// connectors such as ChatGPT or Claude expect): dynamic client registration,
/// authorization code with PKCE, and refresh tokens.
///
/// The gateway has one owner, so "signing in" means giving the admin token on
/// the consent page.
class OAuthServer {
  OAuthServer({
    required this.store,
    required this.auth,
    required this.baseUrl,
    required this.adminEnvToken,
    required this.login,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final StateStore store;
  final PortalAuthenticator auth;
  final String Function(Request request) baseUrl;
  final String? adminEnvToken;
  final LoginService login;
  final DateTime Function() _now;

  final _codes = <String, _Code>{}; // by code hash
  final _failures = <String, List<DateTime>>{};

  Future<Response?> handle(Request request) async {
    final path = '/${request.url.path}';
    final method = request.method;

    if (path == '/.well-known/oauth-authorization-server' && method == 'GET') {
      final base = baseUrl(request);
      return _json(200, {
        'issuer': base,
        'authorization_endpoint': '$base/oauth/authorize',
        'token_endpoint': '$base/oauth/token',
        'registration_endpoint': '$base/oauth/register',
        'response_types_supported': ['code'],
        'grant_types_supported': ['authorization_code', 'refresh_token'],
        'code_challenge_methods_supported': ['S256'],
        'token_endpoint_auth_methods_supported': ['none'],
        'scopes_supported': ['mcp:tools'],
      });
    }
    if (path == '/.well-known/oauth-protected-resource' && method == 'GET') {
      return _json(200, _resourceMetadata(request, ''));
    }
    final resource = RegExp(
      r'^/\.well-known/oauth-protected-resource/mcp/([^/]+)$',
    ).firstMatch(path);
    if (resource != null && method == 'GET') {
      final slug = resource.group(1)!;
      if (store.state.portalBySlug(slug) == null) {
        return _json(404, {'error': 'portal_not_found'});
      }
      return _json(200, _resourceMetadata(request, '/mcp/$slug'));
    }
    if (path == '/oauth/register' && method == 'POST') {
      return _register(request);
    }
    if (path == '/oauth/authorize') {
      if (method == 'GET') return _authorizePage(request);
      if (method == 'POST') return _authorizeSubmit(request);
    }
    if (path == '/oauth/token' && method == 'POST') return _token(request);
    return null;
  }

  Json _resourceMetadata(Request request, String resourcePath) {
    final base = baseUrl(request);
    return {
      'resource': '$base$resourcePath',
      'authorization_servers': [base],
      'bearer_methods_supported': ['header'],
      'scopes_supported': ['mcp:tools'],
    };
  }

  // ------------------------------------------------------------ registration

  bool _acceptableRedirect(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || !parsed.hasScheme || parsed.hasFragment) return false;
    final scheme = parsed.scheme.toLowerCase();
    if (const {
      'javascript',
      'data',
      'file',
      'vbscript',
      'blob',
    }.contains(scheme)) {
      return false;
    }
    if (scheme == 'https') return parsed.host.isNotEmpty;
    if (scheme == 'http') {
      return const {
        'localhost',
        '127.0.0.1',
        '[::1]',
        '::1',
      }.contains(parsed.host);
    }
    return true; // a native app's own scheme
  }

  Future<Response> _register(Request request) async {
    final Json body;
    try {
      body = (jsonDecode(await request.readAsString()) as Map)
          .cast<String, dynamic>();
    } catch (_) {
      return _oauthError(400, 'invalid_client_metadata', 'Send a JSON object');
    }
    final uris = body['redirect_uris'];
    if (uris is! List || uris.isEmpty || uris.length > 10) {
      return _oauthError(
        400,
        'invalid_redirect_uri',
        'redirect_uris is required',
      );
    }
    final redirects = [for (final u in uris) '$u'];
    if (!redirects.every(_acceptableRedirect)) {
      return _oauthError(400, 'invalid_redirect_uri');
    }
    final method = body['token_endpoint_auth_method'];
    if (method != null && method != 'none') {
      return _oauthError(
        400,
        'invalid_client_metadata',
        'Only public PKCE clients are supported',
      );
    }
    final name = '${body['client_name'] ?? 'MCP client'}'.trim();
    final client = OAuthClient(
      clientId: newId('mcpc'),
      clientName: name.isEmpty
          ? 'MCP client'
          : (name.length > 80 ? name.substring(0, 80) : name),
      redirectUris: redirects,
      createdAt: _now(),
    );
    await store.update((s) {
      s.oauthClients.add(client);
      // Registration needs no credential, so it must not grow without bound.
      while (s.oauthClients.length > _maxClients) {
        s.oauthClients.removeAt(0);
      }
    });
    return _json(201, {
      'client_id': client.clientId,
      'client_name': client.clientName,
      'redirect_uris': client.redirectUris,
      'token_endpoint_auth_method': 'none',
      'grant_types': ['authorization_code', 'refresh_token'],
      'response_types': ['code'],
    });
  }

  // --------------------------------------------------------------- authorize

  ({OAuthClient client, String redirectUri, String? portalId})? _checked(
    Map<String, String> q,
    List<String> problem,
  ) {
    final client = store.state.oauthClients
        .where((c) => c.clientId == q['client_id'])
        .firstOrNull;
    if (client == null) {
      problem.add('Unknown client.');
      return null;
    }
    final redirect = q['redirect_uri'];
    if (redirect == null || !client.redirectUris.contains(redirect)) {
      problem.add('The redirect address is not registered for this client.');
      return null;
    }
    if (q['response_type'] != 'code') {
      problem.add('Only the authorization code flow is supported.');
      return null;
    }
    if ((q['code_challenge'] ?? '').isEmpty ||
        q['code_challenge_method'] != 'S256') {
      problem.add('PKCE with S256 is required.');
      return null;
    }
    String? portalId;
    final resource = q['resource'];
    if (resource != null && resource.isNotEmpty) {
      final slug = RegExp(r'/mcp/([^/?#]+)/?$').firstMatch(resource)?.group(1);
      final portal = slug == null ? null : store.state.portalBySlug(slug);
      if (portal == null) {
        problem.add('The requested resource is not a portal of this gateway.');
        return null;
      }
      portalId = portal.id;
    }
    return (client: client, redirectUri: redirect, portalId: portalId);
  }

  Future<Response> _authorizePage(Request request) async {
    final q = request.url.queryParameters;
    final problems = <String>[];
    final checked = _checked(q, problems);
    if (checked == null) {
      return htmlResponse(
        400,
        htmlPage('Cannot sign in', '<p>${escapeHtml(problems.join(' '))}</p>'),
      );
    }
    final token = login.enabled ? login.sessionTokenFromCookie(request) : null;
    final member = token == null ? null : login.memberForToken(token);
    final here =
        '/${request.url.path}${request.url.hasQuery ? '?${request.url.query}' : ''}';
    return htmlResponse(
      200,
      _consent(
        q,
        checked.client,
        checked.portalId,
        null,
        member: member,
        csrf: member == null ? null : login.csrfFor(token!),
        signIn: member == null
            ? {
                for (final p in login.enabledProviders())
                  p.name:
                      '/auth/${p.id}?return_to=${Uri.encodeQueryComponent(here)}',
              }
            : const {},
      ),
      redirect: checked.redirectUri,
    );
  }

  Future<Response> _authorizeSubmit(Request request) async {
    final form = Uri.splitQueryString(await request.readAsString());
    final problems = <String>[];
    final checked = _checked(form, problems);
    if (checked == null) {
      return htmlResponse(
        400,
        htmlPage('Cannot sign in', '<p>${escapeHtml(problems.join(' '))}</p>'),
      );
    }

    Response redirect(Map<String, String> params) {
      final uri = Uri.parse(checked.redirectUri);
      final merged = {
        ...uri.queryParameters,
        ...params,
        if (form['state'] != null) 'state': form['state']!,
      };
      return Response.found(uri.replace(queryParameters: merged).toString());
    }

    if (form['decision'] == 'deny') return redirect({'error': 'access_denied'});

    // Signed in with GitHub: the page carries a value only that browser has.
    final sessionToken = login.enabled
        ? login.sessionTokenFromCookie(request)
        : null;
    final member = sessionToken == null
        ? null
        : login.memberForToken(sessionToken);
    final signedIn =
        member != null &&
        form['csrf'] != null &&
        constantTimeEquals(form['csrf']!, login.csrfFor(sessionToken!));
    final who = _caller(request);
    if (!signedIn && _blocked(who)) {
      return htmlResponse(
        429,
        _consent(
          form,
          checked.client,
          checked.portalId,
          'Too many wrong attempts. Wait a few minutes and try again.',
        ),
        redirect: checked.redirectUri,
      );
    }
    final given = form['password'] ?? '';
    final ok =
        signedIn || auth.isAdmin('Bearer $given', envToken: adminEnvToken);
    if (!ok) {
      _failures.putIfAbsent(who, () => []).add(_now());
      return htmlResponse(
        401,
        _consent(
          form,
          checked.client,
          checked.portalId,
          'That is not the admin token.',
        ),
        redirect: checked.redirectUri,
      );
    }
    _failures.remove(who);

    final code = randomSecret(bytes: 32);
    _codes[hashSecret(code)] = _Code(
      clientId: checked.client.clientId,
      redirectUri: checked.redirectUri,
      challenge: form['code_challenge']!,
      portalId: checked.portalId,
      expiresAt: _now().add(_codeTtl),
    );
    _codes.removeWhere((_, c) => !c.expiresAt.isAfter(_now()));
    return redirect({'code': code});
  }

  String _caller(Request request) {
    final forwarded = request.headers['x-forwarded-for']
        ?.split(',')
        .first
        .trim();
    if (forwarded != null && forwarded.isNotEmpty) return forwarded;
    final info = request.context['shelf.io.connection_info'];
    return info is HttpConnectionInfo ? info.remoteAddress.address : 'unknown';
  }

  bool _blocked(String who) {
    final list = _failures[who];
    if (list == null) return false;
    final cutoff = _now().subtract(const Duration(minutes: 15));
    list.removeWhere((t) => t.isBefore(cutoff));
    return list.length >= 10;
  }

  String _consent(
    Map<String, String> q,
    OAuthClient client,
    String? portalId,
    String? error, {
    Member? member,
    String? csrf,
    Map<String, String> signIn = const {},
  }) {
    final portal = portalId == null ? null : store.state.portal(portalId);
    final host = Uri.parse(q['redirect_uri']!).host;
    final hidden = [
      for (final k in [
        'client_id',
        'redirect_uri',
        'response_type',
        'code_challenge',
        'code_challenge_method',
        'state',
        'scope',
        'resource',
      ])
        if (q[k] != null)
          '<input type="hidden" name="$k" value="${escapeHtml(q[k]!)}">',
    ].join();
    return htmlPage('Connect ${escapeHtml(client.clientName)}', '''
<p><strong>${escapeHtml(client.clientName)}</strong>${host.isEmpty ? '' : ' (${escapeHtml(host)})'} wants to use
${portal == null ? 'the tools of this gateway' : 'the portal <strong>${escapeHtml(portal.name)}</strong>'}.</p>
${error == null ? '' : '<p class="error">${escapeHtml(error)}</p>'}
<form method="post" action="/oauth/authorize">
$hidden
${member != null ? '<p class="hint">Signed in as <strong>${escapeHtml(member.login)}</strong>.</p><input type="hidden" name="csrf" value="${escapeHtml(csrf ?? '')}">' : '${signIn.isEmpty ? '' : '${[for (final e in signIn.entries) '<p><a class="button" href="${escapeHtml(e.value)}">Sign in with ${escapeHtml(e.key)}</a></p>'].join()}<p class="hint">or use the admin token:</p>'}<label>Admin token<input type="password" name="password" autocomplete="current-password" ${signIn.isEmpty ? 'autofocus ' : ''}required></label>'}
<div class="row">
<button type="submit" name="decision" value="allow">Allow</button>
<button type="submit" name="decision" value="deny" class="secondary" formnovalidate>Deny</button>
</div>
</form>
<p class="hint">Only allow clients you started yourself. Anyone you allow can call the tools of this portal until you revoke access.</p>
''');
  }

  // ------------------------------------------------------------------- token

  Future<Response> _token(Request request) async {
    final text = await request.readAsString();
    final Map<String, String> body;
    if ((request.headers['content-type'] ?? '').contains('json')) {
      try {
        body = {
          for (final e in (jsonDecode(text) as Map).entries)
            '${e.key}': '${e.value}',
        };
      } catch (_) {
        return _oauthError(400, 'invalid_request');
      }
    } else {
      body = Uri.splitQueryString(text);
    }
    final grant = body['grant_type'];
    final now = _now();

    if (grant == 'authorization_code') {
      final code = body['code'];
      final verifier = body['code_verifier'];
      if (code == null || verifier == null || body['client_id'] == null) {
        return _oauthError(400, 'invalid_request');
      }
      final entry = _codes.remove(hashSecret(code));
      if (entry == null || !entry.expiresAt.isAfter(now)) {
        return _oauthError(400, 'invalid_grant');
      }
      if (entry.clientId != body['client_id'] ||
          entry.redirectUri != body['redirect_uri']) {
        return _oauthError(400, 'invalid_grant');
      }
      if (!constantTimeEquals(pkceS256(verifier), entry.challenge)) {
        return _oauthError(400, 'invalid_grant', 'PKCE verification failed');
      }
      return _issue(entry.clientId, entry.portalId);
    }

    if (grant == 'refresh_token') {
      final refresh = body['refresh_token'];
      final clientId = body['client_id'];
      if (refresh == null || clientId == null) {
        return _oauthError(400, 'invalid_request');
      }
      final hash = hashSecret(refresh);
      final state = store.state;
      final found = state.oauthGrants
          .where((g) => g.kind == 'refresh' && constantTimeEquals(g.hash, hash))
          .firstOrNull;
      if (found == null ||
          found.clientId != clientId ||
          found.revokedAt != null ||
          !found.expiresAt.isAfter(now)) {
        return _oauthError(400, 'invalid_grant');
      }
      // Each refresh token works once; the next one comes with the new tokens.
      await store.update((s) {
        final i = s.oauthGrants.indexWhere((g) => g.hash == found.hash);
        if (i >= 0) s.oauthGrants[i] = s.oauthGrants[i].revoke(now);
      });
      return _issue(clientId, found.portalId);
    }
    return _oauthError(400, 'unsupported_grant_type');
  }

  Future<Response> _issue(String clientId, String? portalId) async {
    final now = _now();
    final access = randomSecret(prefix: 'mcpa_');
    final refresh = randomSecret(prefix: 'mcpr_');
    await store.update((s) {
      s.oauthGrants.removeWhere(
        (g) => !g.expiresAt.isAfter(now.subtract(const Duration(days: 1))),
      );
      s.oauthGrants
        ..add(
          OAuthGrant(
            hash: hashSecret(access),
            kind: 'access',
            clientId: clientId,
            portalId: portalId,
            expiresAt: now.add(_accessTtl),
            createdAt: now,
          ),
        )
        ..add(
          OAuthGrant(
            hash: hashSecret(refresh),
            kind: 'refresh',
            clientId: clientId,
            portalId: portalId,
            expiresAt: now.add(_refreshTtl),
            createdAt: now,
          ),
        );
    });
    return Response.ok(
      jsonEncode({
        'access_token': access,
        'token_type': 'Bearer',
        'expires_in': _accessTtl.inSeconds,
        'refresh_token': refresh,
        'scope': 'mcp:tools',
      }),
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
        'pragma': 'no-cache',
      },
    );
  }
}

Response _oauthError(int status, String error, [String? description]) =>
    Response(
      status,
      body: jsonEncode({'error': error, 'error_description': ?description}),
      headers: {
        'content-type': 'application/json',
        'cache-control': 'no-store',
      },
    );

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);
