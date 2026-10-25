import 'dart:async';
import 'dart:convert';
import 'package:mcp_core/mcp_core.dart';

import 'models.dart';
import 'permissions.dart';

/// Everything the gateway remembers, in one document.
class PortalState {
  PortalState({
    this.adminTokenHash,
    List<UpstreamServer>? servers,
    List<Portal>? portals,
    List<AccessToken>? tokens,
    List<ToolRule>? rules,
    Map<String, ToolOverride>? overrides,
    List<OAuthClient>? oauthClients,
    List<OAuthGrant>? oauthGrants,
    List<Member>? members,
    List<DashSession>? sessions,
    Map<String, OAuthSession>? upstreamOAuth,
    List<LlmProviderConfig>? llmProviders,
    List<AuthProviderConfig>? authProviders,
    List<Role>? roles,
    List<Invite>? invites,
  }) : servers = servers ?? [],
       portals = portals ?? [],
       tokens = tokens ?? [],
       rules = rules ?? [],
       overrides = overrides ?? {},
       oauthClients = oauthClients ?? [],
       oauthGrants = oauthGrants ?? [],
       members = members ?? [],
       sessions = sessions ?? [],
       upstreamOAuth = upstreamOAuth ?? {},
       llmProviders = llmProviders ?? [],
       authProviders = authProviders ?? [],
       roles = roles ?? [],
       invites = invites ?? [];

  /// Set when the admin token was generated at first start.
  String? adminTokenHash;
  final List<UpstreamServer> servers;
  final List<Portal> portals;
  final List<AccessToken> tokens;

  /// Tool rules and per-tool overrides, in the same format the app saves.
  List<ToolRule> rules;
  Map<String, ToolOverride> overrides;
  final List<OAuthClient> oauthClients;
  final List<OAuthGrant> oauthGrants;
  final List<Member> members;
  final List<DashSession> sessions;

  /// Per upstream server: the OAuth client the gateway registered there and
  /// the tokens it holds. Secrets.
  final Map<String, OAuthSession> upstreamOAuth;

  /// Language-model endpoints for the dashboard's chat (keys are secrets).
  final List<LlmProviderConfig> llmProviders;

  /// The ways to sign in to the dashboard that were set up in the dashboard
  /// (the environment's GitHub app is separate). Secrets.
  final List<AuthProviderConfig> authProviders;

  /// Roles someone created (the built-in ones are in [builtinRoles]).
  final List<Role> roles;

  /// Invitations, pending and used.
  final List<Invite> invites;

  /// A built-in or custom role by id.
  Role? role(String id) =>
      [...builtinRoles, ...roles].where((r) => r.id == id).firstOrNull;

  UpstreamServer? server(String id) =>
      servers.where((s) => s.id == id).firstOrNull;
  Portal? portal(String id) => portals.where((p) => p.id == id).firstOrNull;
  Portal? portalBySlug(String slug) =>
      portals.where((p) => p.slug == slug).firstOrNull;

  Json toJson() => {
    'version': 1,
    'adminTokenHash': ?adminTokenHash,
    'servers': [for (final s in servers) s.toJson()],
    'portals': [for (final p in portals) p.toJson()],
    'tokens': [for (final t in tokens) t.toJson()],
    'rules': [for (final r in rules) r.toJson()],
    'overrides': {for (final e in overrides.entries) e.key: e.value.toJson()},
    'oauthClients': [for (final c in oauthClients) c.toJson()],
    'oauthGrants': [for (final g in oauthGrants) g.toJson()],
    'members': [for (final m in members) m.toJson()],
    'sessions': [for (final x in sessions) x.toJson()],
    'llmProviders': [for (final p in llmProviders) p.toJson()],
    'authProviders': [for (final p in authProviders) p.toJson()],
    'roles': [for (final r in roles) r.toJson()],
    'invites': [for (final i in invites) i.toJson()],
    'upstreamOAuth': {
      for (final e in upstreamOAuth.entries) e.key: e.value.toJson(),
    },
  };

  factory PortalState.fromJson(Json json) {
    List<T> list<T>(String key, T Function(Json) parse) => [
      for (final item in (json[key] as List?) ?? const [])
        parse((item as Map).cast<String, dynamic>()),
    ];
    return PortalState(
      adminTokenHash: json['adminTokenHash'] as String?,
      servers: list('servers', UpstreamServer.fromJson),
      portals: list('portals', Portal.fromJson),
      tokens: list('tokens', AccessToken.fromJson),
      rules: list('rules', ToolRule.fromJson),
      overrides: {
        for (final e in ((json['overrides'] as Map?) ?? const {}).entries)
          '${e.key}': ToolOverride.fromJson(
            (e.value as Map).cast<String, dynamic>(),
          ),
      },
      oauthClients: list('oauthClients', OAuthClient.fromJson),
      oauthGrants: list('oauthGrants', OAuthGrant.fromJson),
      members: list('members', Member.fromJson),
      sessions: list('sessions', DashSession.fromJson),
      llmProviders: list('llmProviders', LlmProviderConfig.fromJson),
      authProviders: list('authProviders', AuthProviderConfig.fromJson),
      roles: list('roles', Role.fromJson),
      invites: list('invites', Invite.fromJson),
      upstreamOAuth: {
        for (final e in ((json['upstreamOAuth'] as Map?) ?? const {}).entries)
          '${e.key}': OAuthSession.fromJson(
            (e.value as Map).cast<String, dynamic>(),
          ),
      },
    );
  }
}

/// Where the state lives between runs.
abstract class StatePersistence {
  Future<PortalState> load();

  /// Writes what changed since the last [load] or [save].
  Future<void> save(PortalState state);
}

/// Holds the [PortalState] in memory and writes it through [StatePersistence]
/// after every change. Changes run one after another. If a write fails the
/// change stays in memory and the next successful write carries it over.
class StateStore {
  StateStore._(this._persistence, this.state);

  /// A store that never touches a database, for tests.
  StateStore.memory([PortalState? state])
    : _persistence = null,
      state = state ?? PortalState();

  final StatePersistence? _persistence;
  final PortalState state;
  Future<void> _queue = Future.value();

  /// Called after a change is saved, with the names of what changed (only
  /// things the dashboard shows: not sessions or OAuth grants).
  void Function(List<String> changed)? onChanged;

  static const _watched = [
    'servers',
    'upstreamOAuth',
    'llmProviders',
    'authProviders',
    'portals',
    'tokens',
    'rules',
    'overrides',
    'members',
    'roles',
    'invites',
  ];

  Map<String, String> _snapshot() {
    final json = state.toJson();
    return {for (final k in _watched) k: jsonEncode(json[k])};
  }

  static Future<StateStore> open(StatePersistence persistence) async =>
      StateStore._(persistence, await persistence.load());

  /// Applies [change] and saves.
  Future<T> update<T>(T Function(PortalState state) change) {
    final result = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        final before = onChanged == null ? null : _snapshot();
        final value = change(state);
        await _persistence?.save(state);
        if (before != null) {
          final after = _snapshot();
          final changed = [
            for (final k in _watched)
              if (before[k] != after[k]) k,
          ];
          if (changed.isNotEmpty) onChanged!(changed);
        }
        result.complete(value);
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }
}
