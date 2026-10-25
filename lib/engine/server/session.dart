import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/json.dart';
import '../core/prefs.dart';
import 'access.dart';
import 'platform.dart';
import 'server_client.dart';

const _storageKey = 'mcpm.session.v1';

/// Creates the HTTP client the app talks to the server with. Overridden in
/// tests to reach an in-process server.
final serverHttpClientProvider = Provider<http.Client Function()>(
  (ref) => http.Client.new,
);

/// Sends this window to another address (the server's sign-in).
/// Overridden in tests, where there is no browser to leave.
final sessionNavigatorProvider = Provider<void Function(Uri url)>(
  (ref) => navigateTo,
);

enum SessionStatus { signedOut, checking, signedIn }

/// Who the server says is signed in.
class SessionIdentity {
  const SessionIdentity({
    required this.kind,
    this.id,
    this.login,
    this.name,
    this.avatarUrl,
    this.role,
    this.access,
  });

  /// `member` (signed in with a provider) or `admin` (the admin token).
  final String kind;
  final String? id;
  final String? login;
  final String? name;
  final String? avatarUrl;
  final String? role;

  /// What they may do; null from a server that does not say.
  final Access? access;

  String get label => switch (kind) {
    'admin' => 'Admin token',
    _ => name ?? login ?? 'Member',
  };

  factory SessionIdentity.fromJson(Json json) {
    final member = (json['member'] as Map?)?.cast<String, dynamic>();
    return SessionIdentity(
      kind: json['kind'] as String? ?? 'member',
      id: member?['id'] as String?,
      login: member?['login'] as String?,
      name: member?['name'] as String?,
      avatarUrl: member?['avatarUrl'] as String?,
      role: member?['role'] as String?,
      access: json['access'] is Map
          ? Access.fromJson((json['access'] as Map).cast<String, dynamic>())
          : null,
    );
  }
}

/// One way to sign in that a server offers.
class SignInProvider {
  const SignInProvider({
    required this.id,
    required this.kind,
    required this.name,
  });

  final String id;

  /// `github` or `google`.
  final String kind;
  final String name;
}

/// What a server offers for signing in.
class ServerSignIn {
  const ServerSignIn({this.providers = const [], this.orgs = const []});

  final List<SignInProvider> providers;

  /// Organisations the first GitHub sign-in lets in, when it lists any.
  final List<String> orgs;

  bool get github => providers.any((p) => p.kind == 'github');
  bool get any => providers.isNotEmpty;
}

class SessionState {
  const SessionState({
    this.status = SessionStatus.signedOut,
    this.serverUrl,
    this.token,
    this.identity,
    this.error,
  });

  final SessionStatus status;
  final String? serverUrl;
  final String? token;
  final SessionIdentity? identity;

  /// Why the last sign-in or check failed, for the sign-in page.
  final String? error;

  bool get signedIn => status == SessionStatus.signedIn;
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(
  SessionNotifier.new,
);

/// The server's address and the token to talk to it with: the only things the
/// dashboard keeps about the server. Everything else lives on the server.
class SessionNotifier extends Notifier<SessionState> {
  @override
  SessionState build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = readJson(prefs, _storageKey);
    var url = raw is Map ? raw['url'] as String? : null;
    var token = raw is Map ? raw['token'] as String? : null;

    // Coming back from the server's sign-in: the token is in the address. A
    // server named there is only shown on the sign-in page, never trusted
    // with a token the dashboard did not ask for.
    final handed = takeSessionFromUrl();
    if (handed != null) {
      if (url != null && url.isNotEmpty) {
        if (handed.token != null) token = handed.token;
      } else if (handed.server != null) {
        url = normalizeServerUrl(handed.server!);
        token = null;
        _save(url, null);
      }
    }

    if (url == null || url.isEmpty) {
      return SessionState(serverUrl: url);
    }
    if (token == null || token.isEmpty) {
      return SessionState(serverUrl: url);
    }
    _save(url, token);
    Future.microtask(_validate);
    return SessionState(
      status: SessionStatus.checking,
      serverUrl: url,
      token: token,
    );
  }

  /// Asks the server which sign-in methods it has (no credential needed).
  Future<ServerSignIn> inspect(String url) async {
    final client = ServerClient(
      baseUrl: url,
      token: '',
      httpClient: ref.read(serverHttpClientProvider)(),
    );
    try {
      final r = await client.getMap('/auth/config');
      return ServerSignIn(
        providers: [
          for (final p in (r['providers'] as List?) ?? const [])
            if (p is Map)
              SignInProvider(
                id: '${p['id']}',
                kind: '${p['kind']}',
                name: '${p['name']}',
              ),
        ],
        orgs: [for (final o in (r['orgs'] as List?) ?? const []) '$o'],
      );
    } finally {
      client.close();
    }
  }

  /// Signs in with the admin token. Returns an error message, or null.
  Future<String?> signInWithAdminToken(String url, String token) async {
    final address = normalizeServerUrl(url);
    final trimmed = token.trim();
    if (address.isEmpty) return 'Enter the server address.';
    if (trimmed.isEmpty) return 'Enter the admin token.';
    final client = ServerClient(
      baseUrl: address,
      token: trimmed,
      httpClient: ref.read(serverHttpClientProvider)(),
    );
    try {
      final me = await client.getMap('/api/me');
      _save(address, trimmed);
      state = SessionState(
        status: SessionStatus.signedIn,
        serverUrl: address,
        token: trimmed,
        identity: SessionIdentity.fromJson(me),
      );
      return null;
    } on ServerException catch (e) {
      return e.unauthorized ? 'That token is not accepted.' : e.message;
    } finally {
      client.close();
    }
  }

  /// Sends this window to the server's sign-in through [providerId] (the
  /// first provider when null); it comes back here with a session. Returns an
  /// error message when that cannot start.
  Future<String?> beginSignIn(String url, [String? providerId]) async {
    final address = normalizeServerUrl(url);
    if (address.isEmpty) return 'Enter the server address.';
    String id;
    try {
      final options = await inspect(address);
      if (!options.any) {
        return 'This server has no sign-in set up. Use the admin token.';
      }
      final match = options.providers.where(
        (p) => providerId == null || p.id == providerId,
      );
      if (match.isEmpty) return 'This server does not offer that sign-in.';
      id = match.first.id;
    } on ServerException catch (e) {
      return e.message;
    }
    // Remember the address so the way back knows where the server is.
    _save(address, null);
    final here = currentAppUri().replace(fragment: '', query: '');
    final target = Uri.parse('$address/auth/$id').replace(
      queryParameters: {'return_to': here.toString().replaceAll('#', '')},
    );
    ref.read(sessionNavigatorProvider)(target);
    return null;
  }

  Future<void> _validate() async {
    final url = state.serverUrl;
    final token = state.token;
    if (url == null || token == null) return;
    final client = ServerClient(
      baseUrl: url,
      token: token,
      httpClient: ref.read(serverHttpClientProvider)(),
    );
    try {
      final me = await client.getMap('/api/me');
      if (!ref.mounted) return;
      state = SessionState(
        status: SessionStatus.signedIn,
        serverUrl: url,
        token: token,
        identity: SessionIdentity.fromJson(me),
      );
    } on ServerException catch (e) {
      if (!ref.mounted) return;
      if (e.unauthorized) {
        _forget('Your session has ended. Sign in again.');
      } else {
        // The server may just be down: keep the token and say so.
        state = SessionState(serverUrl: url, token: token, error: e.message);
      }
    } finally {
      client.close();
    }
  }

  /// Asks the server who we are again, for when our role changed. A failure
  /// (other than being signed out) keeps what is shown.
  Future<void> refreshIdentity() async {
    final url = state.serverUrl;
    final token = state.token;
    if (!state.signedIn || url == null || token == null) return;
    final client = ServerClient(
      baseUrl: url,
      token: token,
      httpClient: ref.read(serverHttpClientProvider)(),
    );
    try {
      final me = await client.getMap('/api/me');
      if (!ref.mounted || !state.signedIn || state.token != token) return;
      state = SessionState(
        status: SessionStatus.signedIn,
        serverUrl: url,
        token: token,
        identity: SessionIdentity.fromJson(me),
      );
    } on ServerException catch (e) {
      if (ref.mounted && e.unauthorized) expired();
    } finally {
      client.close();
    }
  }

  /// Tries again after the server could not be reached.
  Future<void> retry() async {
    if (state.token == null) return;
    state = SessionState(
      status: SessionStatus.checking,
      serverUrl: state.serverUrl,
      token: state.token,
    );
    await _validate();
  }

  /// The server refused our token.
  void expired() {
    if (state.status == SessionStatus.signedOut) return;
    _forget('Your session has ended. Sign in again.');
  }

  Future<void> signOut() async {
    final url = state.serverUrl;
    final token = state.token;
    if (url != null && token != null && state.identity?.kind == 'member') {
      final client = ServerClient(
        baseUrl: url,
        token: token,
        httpClient: ref.read(serverHttpClientProvider)(),
      );
      try {
        await client.send('POST', '/api/logout');
      } on ServerException {
        // Signing out locally is what matters.
      } finally {
        client.close();
      }
    }
    if (ref.mounted) _forget(null);
  }

  void _forget(String? message) {
    _save(state.serverUrl, null);
    state = SessionState(serverUrl: state.serverUrl, error: message);
  }

  void _save(String? url, String? token) {
    writeJson(ref.read(sharedPreferencesProvider), _storageKey, {
      'url': ?url,
      'token': ?token,
    });
  }
}

/// Where an upstream MCP server sends the browser back after signing in: the
/// gateway's own callback, so the server needs no CORS and no app address.
final oauthRedirectUriProvider = Provider<Uri>((ref) {
  final url = ref.watch(sessionProvider).serverUrl ?? 'http://localhost:8787';
  return Uri.parse('$url/oauth/upstream/callback');
});

/// The server address to suggest on the sign-in page when none is saved and
/// no `PORTAL_URL` is set: the address the dashboard itself was loaded from.
/// That is right when one address serves both (behind a reverse proxy) and
/// useless while developing, where the dashboard is on its own port, so
/// localhost gets no guess.
String? guessServerUrl(Uri app) {
  if (app.scheme != 'http' && app.scheme != 'https') return null;
  final host = app.host;
  if (host.isEmpty ||
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host == '127.0.0.1' ||
      host == '::1') {
    return null;
  }
  return Uri(
    scheme: app.scheme,
    host: host,
    port: app.hasPort ? app.port : null,
  ).toString();
}

final sameOriginServerProvider = Provider<String?>(
  (ref) => guessServerUrl(currentAppUri()),
);

/// The address this dashboard is served from, for links that send people
/// back to it. Null when it is not a web address (tests).
final dashboardAddressProvider = Provider<String?>((ref) {
  final u = currentAppUri();
  if (u.scheme != 'http' && u.scheme != 'https') return null;
  return Uri(
    scheme: u.scheme,
    host: u.host,
    port: u.hasPort ? u.port : null,
    path: u.path.isEmpty ? '/' : u.path,
  ).toString();
});

/// The client for the signed-in server, or null when nobody is signed in.
final serverClientProvider = Provider<ServerClient?>((ref) {
  // Only these three: a change of role must not rebuild the client.
  final signedIn = ref.watch(sessionProvider.select((s) => s.signedIn));
  final url = ref.watch(sessionProvider.select((s) => s.serverUrl));
  final token = ref.watch(sessionProvider.select((s) => s.token));
  if (!signedIn || url == null || token == null) return null;
  final client = ServerClient(
    baseUrl: url,
    token: token,
    httpClient: ref.read(serverHttpClientProvider)(),
    onUnauthorized: () => ref.read(sessionProvider.notifier).expired(),
  );
  ref.onDispose(client.close);
  return client;
});
