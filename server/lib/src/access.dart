import 'models.dart';
import 'security.dart';
import 'state.dart';

/// Who is calling a portal.
class Principal {
  const Principal({required this.kind, required this.id, required this.name});

  /// `token` for a static access token, `oauth` for a client signed in by OAuth.
  final String kind;
  final String id;
  final String name;

  Map<String, dynamic> toJson() => {'kind': kind, 'id': id, 'name': name};
}

enum AuthFailure {
  /// No credential, or one that is unknown, revoked or expired.
  invalid,

  /// A valid credential that does not open this portal.
  forbidden,
}

class AuthResult {
  const AuthResult.ok(Principal this.principal) : failure = null;
  const AuthResult.fail(AuthFailure this.failure) : principal = null;
  final Principal? principal;
  final AuthFailure? failure;
}

/// Checks the bearer credential of a request to a portal.
class PortalAuthenticator {
  PortalAuthenticator(this.store, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final StateStore store;
  final DateTime Function() _now;

  Future<AuthResult> authenticate(String? authorization, Portal portal) async {
    final secret = bearerToken(authorization);
    if (secret == null) return const AuthResult.fail(AuthFailure.invalid);
    final hash = hashSecret(secret);
    final now = _now();
    final state = store.state;

    for (final token in state.tokens) {
      if (!constantTimeEquals(token.hash, hash)) continue;
      if (token.revoked || token.expired(now)) {
        return const AuthResult.fail(AuthFailure.invalid);
      }
      if (!token.allows(portal.id)) {
        return const AuthResult.fail(AuthFailure.forbidden);
      }
      _touch(token, now);
      return AuthResult.ok(
        Principal(kind: 'token', id: token.id, name: token.name),
      );
    }

    for (final grant in state.oauthGrants) {
      if (grant.kind != 'access' || !constantTimeEquals(grant.hash, hash)) {
        continue;
      }
      if (grant.revokedAt != null || !grant.expiresAt.isAfter(now)) {
        return const AuthResult.fail(AuthFailure.invalid);
      }
      if (grant.portalId != null && grant.portalId != portal.id) {
        return const AuthResult.fail(AuthFailure.forbidden);
      }
      final client = state.oauthClients
          .where((c) => c.clientId == grant.clientId)
          .firstOrNull;
      return AuthResult.ok(
        Principal(
          kind: 'oauth',
          id: grant.clientId,
          name: client?.clientName ?? grant.clientId,
        ),
      );
    }
    return const AuthResult.fail(AuthFailure.invalid);
  }

  /// "Last used" is saved at most once a minute, so a busy client does not
  /// rewrite the state file on every call.
  void _touch(AccessToken token, DateTime now) {
    final last = token.lastUsedAt;
    if (last != null && now.difference(last) < const Duration(minutes: 1)) {
      return;
    }
    store.update((state) {
      final i = state.tokens.indexWhere((t) => t.id == token.id);
      if (i >= 0) state.tokens[i] = state.tokens[i].copyWith(lastUsedAt: now);
    });
  }

  /// Whether [secret] is the admin token.
  bool isAdmin(String? authorization, {required String? envToken}) {
    final secret = bearerToken(authorization);
    if (secret == null) return false;
    if (envToken != null && envToken.isNotEmpty) {
      return constantTimeEquals(secret, envToken);
    }
    final stored = store.state.adminTokenHash;
    return stored != null && constantTimeEquals(hashSecret(secret), stored);
  }
}
