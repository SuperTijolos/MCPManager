import 'dart:convert';

import 'package:mcp_core/mcp_core.dart';
import 'package:postgres/postgres.dart';

import '../models.dart';
import '../state.dart';
import 'database.dart';

/// Keeps a [PortalState] in Postgres rows.
///
/// The server holds the state in memory and calls [save] after each change;
/// only the rows that differ from what is already stored are written, in one
/// transaction. The dashboard reads those rows (and watches them over
/// Realtime), so the tables are proper columns rather than one document.
class PgStatePersistence implements StatePersistence {
  PgStatePersistence(this.db);

  final Database db;

  /// What each table holds right now, as `key -> encoded row`.
  final Map<String, Map<String, String>> _stored = {
    for (final t in _tables) t.name: {},
  };

  @override
  Future<PortalState> load() async {
    final state = PortalState();
    final rows = <String, List<Map<String, Object?>>>{};
    for (final t in _tables) {
      final result = await db.pool.execute(
        'select * from ${t.name}${t.order == null ? '' : ' order by ${t.order}'}',
      );
      rows[t.name] = [for (final r in result) r.toColumnMap()];
    }

    final credentials = {
      for (final r in rows['server_credentials']!)
        r['server_id'] as String: _jsonMap(r['headers']),
    };
    for (final r in rows['servers']!) {
      final id = r['id'] as String;
      state.servers.add(
        UpstreamServer.fromJson({
          'id': id,
          'name': r['name'],
          'slug': r['slug'],
          'url': r['url'],
          'transport': r['transport'],
          'enabled': r['enabled'],
          'oauth': r['oauth'],
          'oauthClientId': r['oauth_client_id'],
          'oauthScope': r['oauth_scope'],
          'headers': credentials[id] ?? const {},
        }),
      );
    }
    final keys = {
      for (final r in rows['llm_provider_secrets']!)
        r['provider_id'] as String: r['api_key'] as String,
    };
    for (final r in rows['llm_providers']!) {
      final id = r['id'] as String;
      state.llmProviders.add(
        LlmProviderConfig.fromJson({
          'id': id,
          'name': r['name'],
          'kind': r['kind'],
          'baseUrl': r['base_url'],
          'apiKey': keys[id],
          'models': _strings(r['models']),
          'contextLength': r['context_length'],
        }),
      );
    }
    final authSecrets = {
      for (final r in rows['auth_provider_secrets']!)
        r['provider_id'] as String: r['client_secret'] as String,
    };
    for (final r in rows['auth_providers']!) {
      final id = r['id'] as String;
      state.authProviders.add(
        AuthProviderConfig.fromJson({
          'id': id,
          'kind': r['kind'],
          'name': r['name'],
          'clientId': r['client_id'],
          'clientSecret': authSecrets[id],
          'enabled': r['enabled'],
          'orgs': _strings(r['orgs']),
          'users': _strings(r['users']),
          'domains': _strings(r['domains']),
          'emails': _strings(r['emails']),
        }),
      );
    }
    for (final r in rows['server_oauth']!) {
      state.upstreamOAuth[r['server_id'] as String] = OAuthSession.fromJson(
        _jsonMap(r['session']),
      );
    }
    for (final r in rows['portals']!) {
      state.portals.add(
        Portal.fromJson({
          'id': r['id'],
          'slug': r['slug'],
          'name': r['name'],
          'description': r['description'],
          'enabled': r['enabled'],
          'servers': r['servers'],
          'excludedTools': _strings(r['excluded_tools']),
        }),
      );
    }
    for (final r in rows['access_tokens']!) {
      state.tokens.add(
        AccessToken.fromJson({
          'id': r['id'],
          'name': r['name'],
          'hash': r['hash'],
          'prefix': r['prefix'],
          'portalIds': _strings(r['portal_ids']),
          'createdAt': _iso(r['created_at']),
          'lastUsedAt': _iso(r['last_used_at']),
          'revokedAt': _iso(r['revoked_at']),
          'expiresAt': _iso(r['expires_at']),
        }),
      );
    }
    for (final r in rows['oauth_clients']!) {
      state.oauthClients.add(
        OAuthClient.fromJson({
          'clientId': r['client_id'],
          'clientName': r['client_name'],
          'redirectUris': _strings(r['redirect_uris']),
          'createdAt': _iso(r['created_at']),
        }),
      );
    }
    for (final r in rows['oauth_grants']!) {
      state.oauthGrants.add(
        OAuthGrant.fromJson({
          'hash': r['hash'],
          'kind': r['kind'],
          'clientId': r['client_id'],
          'portalId': r['portal_id'],
          'expiresAt': _iso(r['expires_at']),
          'createdAt': _iso(r['created_at']),
          'revokedAt': _iso(r['revoked_at']),
        }),
      );
    }
    for (final r in rows['members']!) {
      state.members.add(
        Member.fromJson({
          'id': r['id'],
          'login': r['login'],
          'name': r['name'],
          'email': r['email'],
          'avatarUrl': r['avatar_url'],
          'orgs': _strings(r['orgs']),
          'emails': _strings(r['emails']),
          'provider': r['provider'],
          'role': r['role'],
          'createdAt': _iso(r['created_at']),
          'lastSeenAt': _iso(r['last_seen_at']),
        }),
      );
    }
    for (final r in rows['sessions']!) {
      state.sessions.add(
        DashSession.fromJson({
          'hash': r['hash'],
          'memberId': r['member_id'],
          'createdAt': _iso(r['created_at']),
          'expiresAt': _iso(r['expires_at']),
        }),
      );
    }
    state.rules = [
      for (final r in rows['tool_rules']!)
        ToolRule.fromJson(_jsonMap(r['data'])),
    ];
    state.overrides = {
      for (final r in rows['tool_overrides']!)
        r['tool_key'] as String: ToolOverride.fromJson(_jsonMap(r['data'])),
    };
    for (final r in rows['settings']!) {
      if (r['key'] == 'admin_token_hash') {
        state.adminTokenHash = '${_decodeJson(r['value'])}';
      }
    }

    // Remember what is stored so the next save only writes the difference.
    final wanted = _desired(state);
    for (final t in _tables) {
      _stored[t.name] = {
        for (final e in wanted[t.name]!.entries) e.key: _encode(e.value),
      };
    }
    return state;
  }

  @override
  Future<void> save(PortalState state) async {
    final wanted = _desired(state);
    final writes = <_Write>[];

    // Deletes first and children before parents, so a slug freed by one row
    // can be taken by another in the same change.
    for (final t in _tables.reversed) {
      final stored = _stored[t.name]!;
      for (final key in stored.keys) {
        if (!wanted[t.name]!.containsKey(key)) {
          writes.add(_Write.delete(t, key));
        }
      }
    }
    for (final t in _tables) {
      final stored = _stored[t.name]!;
      for (final e in wanted[t.name]!.entries) {
        if (stored[e.key] != _encode(e.value)) {
          writes.add(_Write.upsert(t, e.key, e.value));
        }
      }
    }
    if (writes.isEmpty) return;

    await db.pool.runTx((tx) async {
      for (final w in writes) {
        await tx.execute(Sql.named(w.sql), parameters: w.parameters);
      }
    });
    for (final w in writes) {
      final stored = _stored[w.table.name]!;
      if (w.row == null) {
        stored.remove(w.key);
      } else {
        stored[w.key] = _encode(w.row!);
      }
    }
  }

  /// Every row the state should have, by table and primary key.
  Map<String, Map<String, Map<String, Object?>>> _desired(PortalState s) {
    final out = <String, Map<String, Map<String, Object?>>>{
      for (final t in _tables) t.name: {},
    };
    var i = 0;
    for (final x in s.servers) {
      out['servers']![x.id] = {
        'id': x.id,
        'position': i,
        'slug': x.slug,
        'name': x.name,
        'url': x.url,
        'transport': x.transport.wire,
        'enabled': x.enabled,
        'header_names': (x.headers.keys.toList()..sort()),
        'oauth': x.oauth,
        'oauth_client_id': x.oauthClientId,
        'oauth_scope': x.oauthScope,
      };
      out['server_credentials']![x.id] = {
        'server_id': x.id,
        'headers': x.headers,
      };
      i++;
    }
    i = 0;
    for (final x in s.llmProviders) {
      out['llm_providers']![x.id] = {
        'id': x.id,
        'position': i++,
        'name': x.name,
        'kind': x.kind,
        'base_url': x.baseUrl,
        'models': x.models,
        'context_length': x.contextLength,
      };
      final key = x.apiKey;
      if (key != null && key.isNotEmpty) {
        out['llm_provider_secrets']![x.id] = {
          'provider_id': x.id,
          'api_key': key,
        };
      }
    }
    i = 0;
    for (final x in s.authProviders) {
      out['auth_providers']![x.id] = {
        'id': x.id,
        'position': i++,
        'kind': x.kind,
        'name': x.name,
        'client_id': x.clientId,
        'enabled': x.enabled,
        'orgs': x.orgs,
        'users': x.users,
        'domains': x.domains,
        'emails': x.emails,
      };
      final secret = x.clientSecret;
      if (secret != null && secret.isNotEmpty) {
        out['auth_provider_secrets']![x.id] = {
          'provider_id': x.id,
          'client_secret': secret,
        };
      }
    }
    for (final e in s.upstreamOAuth.entries) {
      if (s.servers.every((x) => x.id != e.key)) continue;
      out['server_oauth']![e.key] = {
        'server_id': e.key,
        'session': e.value.toJson(),
      };
    }
    i = 0;
    for (final x in s.portals) {
      final j = x.toJson();
      out['portals']![x.id] = {
        'id': x.id,
        'position': i++,
        'slug': x.slug,
        'name': x.name,
        'description': x.description,
        'enabled': x.enabled,
        'servers': j['servers'],
        'excluded_tools': x.excludedTools,
      };
    }
    i = 0;
    for (final x in s.tokens) {
      out['access_tokens']![x.id] = {
        'id': x.id,
        'position': i++,
        'name': x.name,
        'hash': x.hash,
        'prefix': x.prefix,
        'portal_ids': x.portalIds,
        'created_at': x.createdAt,
        'last_used_at': x.lastUsedAt,
        'revoked_at': x.revokedAt,
        'expires_at': x.expiresAt,
      };
    }
    for (final x in s.oauthClients) {
      out['oauth_clients']![x.clientId] = {
        'client_id': x.clientId,
        'client_name': x.clientName,
        'redirect_uris': x.redirectUris,
        'created_at': x.createdAt,
      };
    }
    for (final x in s.oauthGrants) {
      out['oauth_grants']![x.hash] = {
        'hash': x.hash,
        'kind': x.kind,
        'client_id': x.clientId,
        'portal_id': x.portalId,
        'expires_at': x.expiresAt,
        'created_at': x.createdAt,
        'revoked_at': x.revokedAt,
      };
    }
    for (final x in s.members) {
      out['members']![x.id] = {
        'id': x.id,
        'login': x.login,
        'name': x.name,
        'email': x.email,
        'avatar_url': x.avatarUrl,
        'orgs': x.orgs,
        'emails': x.emails,
        'provider': x.provider,
        'role': x.role,
        'created_at': x.createdAt,
        'last_seen_at': x.lastSeenAt,
      };
    }
    for (final x in s.sessions) {
      out['sessions']![x.hash] = {
        'hash': x.hash,
        'member_id': x.memberId,
        'created_at': x.createdAt,
        'expires_at': x.expiresAt,
      };
    }
    i = 0;
    for (final x in s.rules) {
      out['tool_rules']![x.id] = {
        'id': x.id,
        'position': i++,
        'data': x.toJson(),
      };
    }
    for (final e in s.overrides.entries) {
      out['tool_overrides']![e.key] = {
        'tool_key': e.key,
        'data': e.value.toJson(),
      };
    }
    final hash = s.adminTokenHash;
    if (hash != null) {
      out['settings']!['admin_token_hash'] = {
        'key': 'admin_token_hash',
        'value': hash,
      };
    }
    return out;
  }
}

// ---------------------------------------------------------------- tables

class _Table {
  const _Table(this.name, this.key, this.columns, {this.order, this.touch});

  final String name;
  final String key;

  /// Column name → SQL type (as the driver names it).
  final Map<String, String> columns;
  final String? order;

  /// Extra assignment on update, e.g. `updated_at = now()`.
  final String? touch;
}

// Parents before children (see the foreign key on server_credentials).
const _tables = [
  _Table(
    'servers',
    'id',
    {
      'id': 'text',
      'position': 'int4',
      'slug': 'text',
      'name': 'text',
      'url': 'text',
      'transport': 'text',
      'enabled': 'boolean',
      'header_names': '_text',
      'oauth': 'boolean',
      'oauth_client_id': 'text',
      'oauth_scope': 'text',
    },
    order: 'position',
    touch: 'updated_at = now()',
  ),
  _Table('server_credentials', 'server_id', {
    'server_id': 'text',
    'headers': 'jsonb',
  }),
  _Table('server_oauth', 'server_id', {
    'server_id': 'text',
    'session': 'jsonb',
  }, touch: 'updated_at = now()'),
  _Table(
    'auth_providers',
    'id',
    {
      'id': 'text',
      'position': 'int4',
      'kind': 'text',
      'name': 'text',
      'client_id': 'text',
      'enabled': 'boolean',
      'orgs': '_text',
      'users': '_text',
      'domains': '_text',
      'emails': '_text',
    },
    order: 'position',
    touch: 'updated_at = now()',
  ),
  _Table('auth_provider_secrets', 'provider_id', {
    'provider_id': 'text',
    'client_secret': 'text',
  }),
  _Table(
    'llm_providers',
    'id',
    {
      'id': 'text',
      'position': 'int4',
      'name': 'text',
      'kind': 'text',
      'base_url': 'text',
      'models': '_text',
      'context_length': 'int4',
    },
    order: 'position',
    touch: 'updated_at = now()',
  ),
  _Table('llm_provider_secrets', 'provider_id', {
    'provider_id': 'text',
    'api_key': 'text',
  }),
  _Table(
    'portals',
    'id',
    {
      'id': 'text',
      'position': 'int4',
      'slug': 'text',
      'name': 'text',
      'description': 'text',
      'enabled': 'boolean',
      'servers': 'jsonb',
      'excluded_tools': '_text',
    },
    order: 'position',
    touch: 'updated_at = now()',
  ),
  _Table('access_tokens', 'id', {
    'id': 'text',
    'position': 'int4',
    'name': 'text',
    'hash': 'text',
    'prefix': 'text',
    'portal_ids': '_text',
    'created_at': 'timestamptz',
    'last_used_at': 'timestamptz',
    'revoked_at': 'timestamptz',
    'expires_at': 'timestamptz',
  }, order: 'position'),
  _Table('members', 'id', {
    'id': 'text',
    'login': 'text',
    'name': 'text',
    'email': 'text',
    'avatar_url': 'text',
    'orgs': '_text',
    'emails': '_text',
    'provider': 'text',
    'role': 'text',
    'created_at': 'timestamptz',
    'last_seen_at': 'timestamptz',
  }, order: 'created_at'),
  _Table('sessions', 'hash', {
    'hash': 'text',
    'member_id': 'text',
    'created_at': 'timestamptz',
    'expires_at': 'timestamptz',
  }, order: 'created_at'),
  _Table('oauth_clients', 'client_id', {
    'client_id': 'text',
    'client_name': 'text',
    'redirect_uris': '_text',
    'created_at': 'timestamptz',
  }, order: 'created_at'),
  _Table('oauth_grants', 'hash', {
    'hash': 'text',
    'kind': 'text',
    'client_id': 'text',
    'portal_id': 'text',
    'expires_at': 'timestamptz',
    'created_at': 'timestamptz',
    'revoked_at': 'timestamptz',
  }, order: 'created_at'),
  _Table(
    'tool_rules',
    'id',
    {'id': 'text', 'position': 'int4', 'data': 'jsonb'},
    order: 'position',
    touch: 'updated_at = now()',
  ),
  _Table('tool_overrides', 'tool_key', {
    'tool_key': 'text',
    'data': 'jsonb',
  }, touch: 'updated_at = now()'),
  _Table('settings', 'key', {
    'key': 'text',
    'value': 'jsonb',
  }, touch: 'updated_at = now()'),
];

class _Write {
  _Write._(this.table, this.key, this.row, this.sql, this.parameters);

  factory _Write.delete(_Table t, String key) => _Write._(
    t,
    key,
    null,
    'delete from ${t.name} where ${t.key} = @key:text',
    {'key': key},
  );

  factory _Write.upsert(_Table t, String key, Map<String, Object?> row) {
    final cols = t.columns.keys.toList();
    final sets = [
      for (final c in cols)
        if (c != t.key) '$c = excluded.$c',
      ?t.touch,
    ];
    final sql =
        'insert into ${t.name} (${cols.join(', ')}) values '
        '(${[for (final c in cols) '@$c:${t.columns[c]}'].join(', ')}) '
        'on conflict (${t.key}) do update set ${sets.join(', ')}';
    return _Write._(t, key, row, sql, {for (final c in cols) c: row[c]});
  }

  final _Table table;
  final String key;
  final Map<String, Object?>? row;
  final String sql;
  final Map<String, Object?> parameters;
}

String _encode(Map<String, Object?> row) => jsonEncode(
  row,
  toEncodable: (o) => o is DateTime ? o.toUtc().toIso8601String() : '$o',
);

Object? _decodeJson(Object? v) {
  if (v is String) {
    try {
      return jsonDecode(v);
    } catch (_) {
      return v;
    }
  }
  if (v is UndecodedBytes) return jsonDecode(v.asString);
  return v;
}

Map<String, dynamic> _jsonMap(Object? v) {
  final d = _decodeJson(v);
  return d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
}

List<String> _strings(Object? v) => [
  for (final e in (v as List?) ?? const []) '$e',
];

String? _iso(Object? v) => v is DateTime ? v.toUtc().toIso8601String() : null;
