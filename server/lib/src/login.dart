import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

import 'config.dart';
import 'models.dart';
import 'pages.dart';
import 'security.dart';
import 'state.dart';

const sessionCookie = 'mcp_session';
const _stateCookie = 'mcp_login';
const sessionPrefix = 'mcps_';
const _pendingTtl = Duration(minutes: 10);
const _maxPending = 500;

class _Pending {
  _Pending(this.providerId, this.returnTo, this.expiresAt);
  final String providerId;
  final String returnTo;
  final DateTime expiresAt;
}

/// Ids that are not providers.
const reservedProviderIds = {'config', 'done'};

/// Signing in to the dashboard with GitHub, Google, or any other provider set
/// up for it.
///
/// The browser is sent to the provider and comes back to
/// `/auth/<id>/callback`. The server reads who the person is (and, for GitHub,
/// which organisations they belong to), checks that against the provider's
/// allow-list, and hands out a session token. The provider's own token is used
/// once and thrown away.
class LoginService {
  LoginService({
    required this.store,
    required this.config,
    required this.baseUrl,
    required this.originAllowed,
    http.Client Function()? httpClient,
    DateTime Function()? clock,
  }) : _http = httpClient ?? http.Client.new,
       _now = clock ?? DateTime.now;

  final StateStore store;
  final GatewayConfig config;
  final String Function(Request request) baseUrl;
  final bool Function(String origin) originAllowed;
  final http.Client Function() _http;
  final DateTime Function() _now;

  final _pending = <String, _Pending>{};

  /// Every way to sign in: the GitHub app of the server's environment (unless
  /// one set up in the dashboard has the same id), then the ones set up in the
  /// dashboard.
  List<AuthProviderConfig> providers() {
    final saved = store.state.authProviders;
    return [
      if (config.githubConfigured && saved.every((p) => p.id != 'github'))
        AuthProviderConfig(
          id: 'github',
          kind: 'github',
          name: 'GitHub',
          clientId: config.githubClientId!,
          clientSecret: config.githubClientSecret,
          orgs: config.githubOrgs,
          users: config.githubUsers,
          fromEnvironment: true,
        ),
      ...saved,
    ];
  }

  AuthProviderConfig? provider(String id) =>
      providers().where((p) => p.id == id).firstOrNull;

  /// The ones that can be used right now.
  List<AuthProviderConfig> enabledProviders() => [
    for (final p in providers())
      if (p.enabled && p.configured) p,
  ];

  bool get enabled => enabledProviders().isNotEmpty;

  /// Whether [member] may use the dashboard right now: their provider must
  /// still be on, and they must match its allow-list. Checked on every
  /// request, so taking someone off the list locks them out at once.
  bool allowed(Member member) {
    final p = provider(member.provider);
    if (p == null || !p.enabled || !p.configured) return false;
    return matchesAllowList(p, member);
  }

  /// Whether [member] is on [p]'s allow-list (anyone listed by login,
  /// organisation, email domain or email address).
  static bool matchesAllowList(AuthProviderConfig p, Member member) {
    bool any(List<String> list, Iterable<String> have) {
      final set = {for (final h in have) h.toLowerCase()};
      return list.any((x) => set.contains(x.toLowerCase()));
    }

    if (p.kind == 'github') {
      if (any(p.users, [member.login])) return true;
      if (any(p.orgs, member.orgs)) return true;
    }
    if (any(p.emails, member.emails)) return true;
    final domains = [
      for (final e in member.emails)
        if (e.contains('@')) e.substring(e.lastIndexOf('@') + 1),
    ];
    return any(p.domains, domains);
  }

  // ------------------------------------------------------------- identity

  /// The member behind a session token (`Authorization: Bearer mcps_…`).
  Member? memberForToken(String? token) {
    if (token == null || !token.startsWith(sessionPrefix)) return null;
    final hash = hashSecret(token);
    final state = store.state;
    final now = _now();
    for (final s in state.sessions) {
      if (!constantTimeEquals(s.hash, hash)) continue;
      if (!s.expiresAt.isAfter(now)) return null;
      final member = state.members.where((m) => m.id == s.memberId).firstOrNull;
      return member != null && allowed(member) ? member : null;
    }
    return null;
  }

  /// The member behind the session cookie, for the pages a browser opens.
  Member? memberForRequest(Request request) =>
      memberForToken(sessionTokenFromCookie(request));

  String? sessionTokenFromCookie(Request request) =>
      _readCookie(request, sessionCookie);

  /// A value a form must carry back so a page on another site cannot post
  /// for the signed-in person.
  String csrfFor(String sessionToken) =>
      sha256.convert(utf8.encode('csrf:$sessionToken')).toString();

  /// Ends the session behind [token].
  Future<void> signOut(String token) => store.update(
    (s) => s.sessions.removeWhere((x) => x.hash == hashSecret(token)),
  );

  // -------------------------------------------------------------- routes

  /// Null when [request] is not for the sign-in routes.
  Future<Response?> handle(Request request) async {
    final path = request.url.path;
    if (!path.startsWith('auth/') && path != 'auth') return null;
    final method = request.method;

    if (path == 'auth/config' && method == 'GET') {
      final on = enabledProviders();
      final github = on.where((p) => p.kind == 'github').firstOrNull;
      return _json(200, {
        'providers': [
          for (final p in on) {'id': p.id, 'kind': p.kind, 'name': p.name},
        ],
        // The first GitHub app, for dashboards that predate several providers.
        'github': github != null,
        'orgs': github?.orgs ?? const <String>[],
      });
    }
    if (path == 'auth/done' && method == 'GET') return _done(request);

    final route = RegExp(r'^auth/([a-z0-9-]+)(/callback)?$').firstMatch(path);
    if (route == null || method != 'GET') {
      return _json(404, {'error': 'not_found'});
    }
    final id = route.group(1)!;
    final p = reservedProviderIds.contains(id) ? null : provider(id);
    if (p == null || !p.enabled || !p.configured) {
      return htmlResponse(
        404,
        htmlPage(
          'Sign-in is not set up',
          '<p>This server has no sign-in called <code>${escapeHtml(id)}</code> '
              'turned on. Set one up under Settings → Sign-in in the dashboard.</p>',
        ),
      );
    }
    return route.group(2) == null ? _begin(request, p) : _callback(request, p);
  }

  Response _begin(Request request, AuthProviderConfig p) {
    final returnTo = safeReturn(request.url.queryParameters['return_to']);
    if (returnTo == null) {
      return htmlResponse(
        400,
        htmlPage(
          'Cannot sign in',
          '<p>That return address is not one this server knows. Add the '
              'dashboard\'s address to <code>PORTAL_ALLOWED_ORIGINS</code>.</p>',
        ),
      );
    }
    final now = _now();
    _pending.removeWhere((_, p) => !p.expiresAt.isAfter(now));
    if (_pending.length >= _maxPending) {
      return htmlResponse(
        429,
        htmlPage('Try again', '<p>Too many sign-ins at once.</p>'),
      );
    }
    final state = randomSecret(bytes: 24);
    _pending[state] = _Pending(p.id, returnTo, now.add(_pendingTtl));

    final base = baseUrl(request);
    final redirectUri = '$base/auth/${p.id}/callback';
    final url = p.kind == 'google'
        ? Uri.parse(config.googleAuthUrl).replace(
            queryParameters: {
              'client_id': p.clientId,
              'redirect_uri': redirectUri,
              'response_type': 'code',
              'scope': 'openid email profile',
              'state': state,
              'prompt': 'select_account',
            },
          )
        : Uri.parse('${config.githubUrl}/login/oauth/authorize').replace(
            queryParameters: {
              'client_id': p.clientId,
              'redirect_uri': redirectUri,
              'scope': 'read:user read:org user:email',
              'state': state,
              'allow_signup': 'false',
            },
          );
    return Response.found(
      url,
      headers: {
        'set-cookie': _cookie(
          _stateCookie,
          state,
          base,
          path: '/auth',
          maxAge: _pendingTtl,
        ),
        'cache-control': 'no-store',
      },
    );
  }

  Future<Response> _callback(Request request, AuthProviderConfig p) async {
    final q = request.url.queryParameters;
    final base = baseUrl(request);
    final clearState = _cookie(
      _stateCookie,
      '',
      base,
      path: '/auth',
      maxAge: Duration.zero,
    );

    Response fail(int status, String title, String message) => htmlResponse(
      status,
      htmlPage(title, '<p>${escapeHtml(message)}</p>'),
    ).change(headers: {'set-cookie': clearState});

    final state = q['state'];
    final pending = state == null ? null : _pending.remove(state);
    final cookieState = _readCookie(request, _stateCookie);
    if (pending == null ||
        pending.providerId != p.id ||
        !pending.expiresAt.isAfter(_now()) ||
        cookieState == null ||
        !constantTimeEquals(cookieState, state!)) {
      return fail(
        400,
        'Cannot sign in',
        'This sign-in did not start here, or it took too long. Start again.',
      );
    }
    if (q['error'] != null) {
      return fail(403, 'Sign-in cancelled', '${p.name} did not sign you in.');
    }
    final code = q['code'];
    if (code == null || code.isEmpty) {
      return fail(400, 'Cannot sign in', '${p.name} sent no code.');
    }

    final _Person person;
    try {
      person = p.kind == 'google'
          ? await _fetchGoogle(p, code, '$base/auth/${p.id}/callback')
          : await _fetchGitHub(p, code, '$base/auth/${p.id}/callback');
    } on _LoginFailure catch (e) {
      return fail(502, 'Cannot sign in', e.message);
    }

    final candidate = Member(
      id: '${p.kind}:${person.id}',
      login: person.login,
      name: person.name,
      email: person.email,
      avatarUrl: person.avatarUrl,
      orgs: person.orgs,
      emails: person.emails,
      provider: p.id,
      createdAt: _now(),
      lastSeenAt: _now(),
    );
    if (!matchesAllowList(p, candidate)) {
      return fail(
        403,
        'Not allowed',
        '${person.login} is not on the list this server lets in through '
            '${p.name}.',
      );
    }

    final token = randomSecret(prefix: sessionPrefix);
    final now = _now();
    await store.update((s) {
      final i = s.members.indexWhere((m) => m.id == candidate.id);
      if (i >= 0) {
        s.members[i] = s.members[i].copyWith(
          login: candidate.login,
          name: candidate.name,
          email: candidate.email,
          avatarUrl: candidate.avatarUrl,
          orgs: candidate.orgs,
          emails: candidate.emails,
          lastSeenAt: now,
        );
      } else {
        s.members.add(candidate);
      }
      s.sessions.removeWhere((x) => !x.expiresAt.isAfter(now));
      s.sessions.add(
        DashSession(
          hash: hashSecret(token),
          memberId: candidate.id,
          createdAt: now,
          expiresAt: now.add(Duration(days: config.sessionDays)),
        ),
      );
    });

    final cookie = _cookie(
      sessionCookie,
      token,
      base,
      path: '/',
      maxAge: Duration(days: config.sessionDays),
    );
    final target = Uri.parse(pending.returnTo);
    // A dashboard on another address gets the token in the fragment, which
    // never reaches a server or a log.
    final location = target.hasScheme
        ? target.replace(fragment: 'session=$token').toString()
        : pending.returnTo;
    return Response.found(
      location,
      headers: {
        'set-cookie': [cookie, clearState],
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
      },
    );
  }

  Response _done(Request request) {
    final member = memberForRequest(request);
    if (member == null) {
      return htmlResponse(
        401,
        htmlPage('Not signed in', '<p>Sign in from the dashboard first.</p>'),
      );
    }
    return htmlResponse(
      200,
      htmlPage(
        'Signed in',
        '<p>You are signed in as <strong>${escapeHtml(member.login)}</strong>. '
            'You can close this tab.</p>',
      ),
    );
  }

  // ------------------------------------------------------------ providers

  Future<_Person> _fetchGitHub(
    AuthProviderConfig p,
    String code,
    String redirectUri,
  ) async {
    final client = _http();
    try {
      final tokenResponse = await client
          .post(
            Uri.parse('${config.githubUrl}/login/oauth/access_token'),
            headers: {'accept': 'application/json'},
            body: {
              'client_id': p.clientId,
              'client_secret': p.clientSecret!,
              'code': code,
              'redirect_uri': redirectUri,
            },
          )
          .timeout(const Duration(seconds: 15));
      final tokenJson = _decode(tokenResponse.body);
      final accessToken = tokenJson['access_token'];
      if (tokenResponse.statusCode != 200 || accessToken is! String) {
        throw _LoginFailure('GitHub did not accept the sign-in. Start again.');
      }

      Future<http.Response> api(String path) => client
          .get(
            Uri.parse('${config.githubApiUrl}$path'),
            headers: {
              'authorization': 'Bearer $accessToken',
              'accept': 'application/vnd.github+json',
              'user-agent': 'mcp-portal',
            },
          )
          .timeout(const Duration(seconds: 15));

      final user = await api('/user');
      final userJson = _decode(user.body);
      if (user.statusCode != 200 || userJson['id'] == null) {
        throw _LoginFailure('Could not read your GitHub profile.');
      }
      final orgs = <String>[];
      final orgsResponse = await api('/user/orgs?per_page=100');
      if (orgsResponse.statusCode == 200) {
        final decoded = jsonDecode(orgsResponse.body);
        if (decoded is List) {
          for (final o in decoded) {
            if (o is Map && o['login'] is String) {
              orgs.add(o['login'] as String);
            }
          }
        }
      }
      // Only addresses GitHub has verified count towards the allow-list.
      final emails = <String>{};
      final emailsResponse = await api('/user/emails');
      if (emailsResponse.statusCode == 200) {
        final decoded = jsonDecode(emailsResponse.body);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map && e['verified'] == true && e['email'] is String) {
              emails.add((e['email'] as String).toLowerCase());
            }
          }
        }
      }
      return _Person(
        id: '${userJson['id']}',
        login: '${userJson['login']}',
        name: userJson['name'] as String?,
        email: userJson['email'] as String?,
        avatarUrl: userJson['avatar_url'] as String?,
        orgs: orgs,
        emails: emails.toList(),
      );
    } on _LoginFailure {
      rethrow;
    } catch (_) {
      throw _LoginFailure('GitHub could not be reached. Try again.');
    } finally {
      client.close();
    }
  }

  Future<_Person> _fetchGoogle(
    AuthProviderConfig p,
    String code,
    String redirectUri,
  ) async {
    final client = _http();
    try {
      final tokenResponse = await client
          .post(
            Uri.parse(config.googleTokenUrl),
            headers: {'accept': 'application/json'},
            body: {
              'client_id': p.clientId,
              'client_secret': p.clientSecret!,
              'code': code,
              'redirect_uri': redirectUri,
              'grant_type': 'authorization_code',
            },
          )
          .timeout(const Duration(seconds: 15));
      final tokenJson = _decode(tokenResponse.body);
      final accessToken = tokenJson['access_token'];
      if (tokenResponse.statusCode != 200 || accessToken is! String) {
        throw _LoginFailure('Google did not accept the sign-in. Start again.');
      }
      final info = await client
          .get(
            Uri.parse(config.googleUserinfoUrl),
            headers: {'authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 15));
      final json = _decode(info.body);
      if (info.statusCode != 200 || json['sub'] == null) {
        throw _LoginFailure('Could not read your Google profile.');
      }
      final email = json['email'] as String?;
      final verified = json['email_verified'] == true;
      return _Person(
        id: '${json['sub']}',
        login: email ?? '${json['sub']}',
        name: json['name'] as String?,
        email: email,
        avatarUrl: json['picture'] as String?,
        orgs: const [],
        // An address Google has not verified proves nothing.
        emails: email != null && verified ? [email.toLowerCase()] : const [],
      );
    } on _LoginFailure {
      rethrow;
    } catch (_) {
      throw _LoginFailure('Google could not be reached. Try again.');
    } finally {
      client.close();
    }
  }

  // -------------------------------------------------------------- helpers

  /// [raw] if it is a path on this server or an address of an allowed origin.
  String? safeReturn(String? raw) {
    if (raw == null || raw.isEmpty) return '/auth/done';
    if (raw.startsWith('/') && !raw.startsWith('//') && !raw.contains(r'\')) {
      return raw;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return originAllowed(uri.origin) ? raw : null;
  }

  String _cookie(
    String name,
    String value,
    String base, {
    required String path,
    required Duration maxAge,
  }) =>
      '$name=$value; Path=$path; Max-Age=${maxAge.inSeconds}; HttpOnly; '
      'SameSite=Lax${base.startsWith('https://') ? '; Secure' : ''}';

  String? _readCookie(Request request, String name) {
    final header = request.headers['cookie'];
    if (header == null) return null;
    for (final part in header.split(';')) {
      final i = part.indexOf('=');
      if (i > 0 && part.substring(0, i).trim() == name) {
        final v = part.substring(i + 1).trim();
        return v.isEmpty ? null : v;
      }
    }
    return null;
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final d = jsonDecode(body);
      return d is Map ? d.cast<String, dynamic>() : {};
    } catch (_) {
      return {};
    }
  }
}

class _Person {
  _Person({
    required this.id,
    required this.login,
    required this.orgs,
    required this.emails,
    this.name,
    this.email,
    this.avatarUrl,
  });
  final String id;
  final String login;
  final String? name;
  final String? email;
  final String? avatarUrl;
  final List<String> orgs;
  final List<String> emails;
}

class _LoginFailure implements Exception {
  _LoginFailure(this.message);
  final String message;
}

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);
