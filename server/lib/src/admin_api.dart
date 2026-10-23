import 'dart:convert';

import 'package:mcp_core/mcp_core.dart';
import 'package:shelf/shelf.dart';

import 'access.dart';
import 'audit.dart';
import 'catalog.dart';
import 'mcp_endpoint.dart' show gatewayVersion;
import 'models.dart';
import 'security.dart';
import 'state.dart';
import 'upstream.dart';

class ApiError implements Exception {
  ApiError(this.status, this.code, [this.message]);
  final int status;
  final String code;
  final String? message;
}

final _slugPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');

String slugify(String text) {
  final slug = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty
      ? 'server'
      : (slug.length > 63 ? slug.substring(0, 63) : slug);
}

/// The REST API the app (or any script) uses to manage the gateway.
/// Every route needs the admin token.
class AdminApi {
  AdminApi({
    required this.store,
    required this.pool,
    required this.audit,
    required this.auth,
    required this.adminEnvToken,
    required this.baseUrl,
  });

  final StateStore store;
  final UpstreamPool pool;
  final GatewayAuditLog audit;
  final PortalAuthenticator auth;
  final String? adminEnvToken;
  final String Function(Request request) baseUrl;

  /// Null when [request] is not for this API.
  Future<Response?> handle(Request request) async {
    final path = request.url.path;
    if (!path.startsWith('api/') && path != 'api') return null;

    if (!auth.isAdmin(
      request.headers['authorization'],
      envToken: adminEnvToken,
    )) {
      return _json(401, {
        'error': 'unauthorized',
        'message': 'The admin token is missing or wrong.',
      });
    }
    try {
      return await _route(
        request,
        path.substring(3).replaceAll(RegExp(r'^/|/$'), ''),
      );
    } on ApiError catch (e) {
      return _json(e.status, {'error': e.code, 'message': ?e.message});
    } on FormatException catch (e) {
      return _json(400, {'error': 'invalid_json', 'message': e.message});
    }
  }

  Future<Response> _route(Request request, String path) async {
    final parts = path.isEmpty ? <String>[] : path.split('/');
    final method = request.method;
    final first = parts.isEmpty ? '' : parts.first;

    switch (first) {
      case 'status' when method == 'GET' && parts.length == 1:
        return _json(200, _status(request));
      case 'servers':
        return _servers(request, method, parts);
      case 'portals':
        return _portals(request, method, parts);
      case 'tokens':
        return _tokens(request, method, parts);
      case 'rules' when parts.length == 1:
        return _rules(request, method);
      case 'audit' when method == 'GET' && parts.length == 1:
        final q = request.url.queryParameters;
        return _json(200, {
          'events': [
            for (final e in audit.recent(
              limit: (int.tryParse(q['limit'] ?? '') ?? 100).clamp(1, 1000),
              portalId: q['portal'],
              status: q['status'],
              query: q['q'],
            ))
              e.toJson(),
          ],
        });
    }
    throw ApiError(404, 'not_found');
  }

  Json _status(Request request) {
    final s = store.state;
    return {
      'version': gatewayVersion,
      'baseUrl': baseUrl(request),
      'servers': s.servers.length,
      'portals': s.portals.length,
      'tokens': s.tokens.where((t) => !t.revoked).length,
      'rules': s.rules.length,
    };
  }

  // ----------------------------------------------------------------- servers

  Future<Response> _servers(
    Request request,
    String method,
    List<String> parts,
  ) async {
    final state = store.state;
    if (parts.length == 1) {
      if (method == 'GET') {
        return _json(200, [for (final s in state.servers) s.toPublicJson()]);
      }
      if (method == 'POST') {
        final body = await _body(request);
        return _json(
          201,
          await _saveServer(newId('srv'), body, creating: true),
        );
      }
    } else if (parts.length == 2) {
      final id = parts[1];
      if (method == 'GET') {
        final server =
            state.server(id) ?? (throw ApiError(404, 'server_not_found'));
        return _json(200, server.toPublicJson());
      }
      if (method == 'PUT') {
        final body = await _body(request);
        return _json(
          200,
          await _saveServer(id, body, creating: state.server(id) == null),
        );
      }
      if (method == 'DELETE') {
        if (state.server(id) == null) throw ApiError(404, 'server_not_found');
        await store.update((s) {
          s.servers.removeWhere((x) => x.id == id);
          for (var i = 0; i < s.portals.length; i++) {
            final p = s.portals[i];
            s.portals[i] = p.copyWith(
              servers: [
                for (final r in p.servers)
                  if (r.serverId != id) r,
              ],
            );
          }
        });
        await pool.invalidate(id);
        return _json(200, {'ok': true});
      }
    } else if (parts.length == 3 && method == 'POST' && parts[2] == 'test') {
      final server =
          state.server(parts[1]) ?? (throw ApiError(404, 'server_not_found'));
      final catalog = await pool.catalog(server, refresh: true);
      return _json(200, {
        'ok': catalog.ok,
        'error': catalog.error,
        'server': catalog.info == null
            ? null
            : {'name': catalog.info!.name, 'version': catalog.info!.version},
        'transport': catalog.transport?.wire,
        'toolCount': catalog.tools.length,
        'tools': [for (final t in catalog.tools) t.name],
      });
    } else if (parts.length == 3 && method == 'GET' && parts[2] == 'tools') {
      final server =
          state.server(parts[1]) ?? (throw ApiError(404, 'server_not_found'));
      final catalog = await pool.catalog(server);
      return _json(200, {
        'error': catalog.error,
        'tools': [
          for (final t in catalog.tools)
            {
              'name': t.name,
              'title': t.title,
              'description': t.description,
              'annotations': t.annotations,
              'inputSchema': t.inputSchema,
            },
        ],
      });
    }
    throw ApiError(405, 'method_not_allowed');
  }

  Future<Json> _saveServer(
    String id,
    Json body, {
    required bool creating,
  }) async {
    final existing = store.state.server(id);

    String text(String key, {String? fallback}) {
      final v = body[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (fallback != null) return fallback;
      throw ApiError(400, 'invalid_$key', '$key is required');
    }

    final name = text('name', fallback: existing?.name);
    final url = normalizeBaseUrl(text('url', fallback: existing?.url));
    if (!isValidHttpUrl(url)) {
      throw ApiError(
        400,
        'invalid_url',
        'The URL must be a valid http(s) address',
      );
    }
    final slug = body.containsKey('slug')
        ? text('slug')
        : (existing?.slug ?? _freeServerSlug(slugify(name), id));
    if (!_slugPattern.hasMatch(slug)) {
      throw ApiError(
        400,
        'invalid_slug',
        'Use lowercase letters, numbers and hyphens',
      );
    }
    if (store.state.servers.any((s) => s.id != id && s.slug == slug)) {
      throw ApiError(409, 'slug_in_use');
    }

    Map<String, String> headers = existing?.headers ?? const {};
    if (body.containsKey('headers')) {
      final raw = body['headers'];
      if (raw is! Map) throw ApiError(400, 'invalid_headers');
      headers = {for (final e in raw.entries) '${e.key}': '${e.value}'};
    }

    final server = UpstreamServer(
      id: id,
      name: name,
      slug: slug,
      url: url,
      headers: headers,
      transport: body.containsKey('transport')
          ? McpTransport.parse(body['transport'])
          : (existing?.transport ?? McpTransport.auto),
      enabled: body['enabled'] as bool? ?? existing?.enabled ?? true,
    );
    await store.update((s) {
      final i = s.servers.indexWhere((x) => x.id == id);
      if (i >= 0) {
        s.servers[i] = server;
      } else {
        s.servers.add(server);
      }
    });
    await pool.invalidate(id);
    return server.toPublicJson();
  }

  String _freeServerSlug(String base, String id) {
    var slug = base;
    var n = 2;
    while (store.state.servers.any((s) => s.id != id && s.slug == slug)) {
      slug = '$base-$n';
      n++;
    }
    return slug;
  }

  // ----------------------------------------------------------------- portals

  Json _portalJson(Portal p, Request request) => {
    ...p.toJson(),
    'endpoint': '${baseUrl(request)}/mcp/${p.slug}',
  };

  Future<Response> _portals(
    Request request,
    String method,
    List<String> parts,
  ) async {
    final state = store.state;
    if (parts.length == 1) {
      if (method == 'GET') {
        return _json(200, [
          for (final p in state.portals) _portalJson(p, request),
        ]);
      }
      if (method == 'POST') {
        final body = await _body(request);
        final saved = await _savePortal(newId('portal'), body, creating: true);
        return _json(201, _portalJson(saved, request));
      }
    } else if (parts.length == 2) {
      final id = parts[1];
      if (method == 'GET') {
        final portal =
            state.portal(id) ?? (throw ApiError(404, 'portal_not_found'));
        return _json(200, _portalJson(portal, request));
      }
      if (method == 'PUT') {
        final body = await _body(request);
        final saved = await _savePortal(
          id,
          body,
          creating: state.portal(id) == null,
        );
        return _json(200, _portalJson(saved, request));
      }
      if (method == 'DELETE') {
        if (state.portal(id) == null) throw ApiError(404, 'portal_not_found');
        await store.update((s) => s.portals.removeWhere((p) => p.id == id));
        return _json(200, {'ok': true});
      }
    } else if (parts.length == 3 && method == 'GET' && parts[2] == 'tools') {
      final portal =
          state.portal(parts[1]) ?? (throw ApiError(404, 'portal_not_found'));
      final q = request.url.queryParameters;
      final catalog = await buildCatalog(
        portal,
        state,
        pool,
        includeHidden: q['includeHidden'] == '1',
        refresh: q['refresh'] == '1',
      );
      return _json(200, {
        'problems': catalog.problems,
        'tools': [
          for (final t in catalog.tools)
            {
              'name': t.exposedName,
              'serverId': t.server.id,
              'serverName': t.server.name,
              'tool': t.tool.name,
              'title': t.tool.title,
              'description': t.effective.description,
              'visible': t.effective.visible,
              'excluded': t.excluded,
              'rules': t.effective.rules,
              'readOnly': t.effective.readOnly,
              'inputSchema': t.effective.inputSchema,
            },
        ],
      });
    }
    throw ApiError(405, 'method_not_allowed');
  }

  Future<Portal> _savePortal(
    String id,
    Json body, {
    required bool creating,
  }) async {
    final existing = store.state.portal(id);
    final name =
        (body['name'] is String && (body['name'] as String).trim().isNotEmpty)
        ? (body['name'] as String).trim()
        : (existing?.name ??
              (throw ApiError(400, 'invalid_name', 'name is required')));
    final slug = body.containsKey('slug')
        ? '${body['slug']}'.trim().toLowerCase()
        : (existing?.slug ?? slugify(name));
    if (!_slugPattern.hasMatch(slug)) {
      throw ApiError(
        400,
        'invalid_slug',
        'Use lowercase letters, numbers and hyphens',
      );
    }
    if (store.state.portals.any((p) => p.id != id && p.slug == slug)) {
      throw ApiError(409, 'portal_slug_in_use');
    }

    List<PortalServerRef> refs = existing?.servers ?? const [];
    if (body.containsKey('servers')) {
      final raw = body['servers'];
      if (raw is! List) throw ApiError(400, 'invalid_servers');
      final seen = <String>{};
      refs = [
        for (final item in raw)
          if (item is String
              ? seen.add(item)
              : item is Map && seen.add('${item['serverId']}'))
            item is String
                ? PortalServerRef(item)
                : PortalServerRef.fromJson(
                    (item as Map).cast<String, dynamic>(),
                  ),
      ];
      for (final r in refs) {
        if (store.state.server(r.serverId) == null) {
          throw ApiError(400, 'unknown_server', 'No server "${r.serverId}"');
        }
      }
    }

    final portal = Portal(
      id: id,
      slug: slug,
      name: name,
      description: body['description'] is String
          ? (body['description'] as String).trim()
          : (existing?.description ?? ''),
      enabled: body['enabled'] as bool? ?? existing?.enabled ?? true,
      servers: refs,
      excludedTools: body.containsKey('excludedTools')
          ? [for (final t in (body['excludedTools'] as List? ?? const [])) '$t']
          : (existing?.excludedTools ?? const []),
    );
    await store.update((s) {
      final i = s.portals.indexWhere((p) => p.id == id);
      if (i >= 0) {
        s.portals[i] = portal;
      } else {
        s.portals.add(portal);
      }
    });
    return portal;
  }

  // ------------------------------------------------------------------ tokens

  Future<Response> _tokens(
    Request request,
    String method,
    List<String> parts,
  ) async {
    final state = store.state;
    if (parts.length == 1 && method == 'GET') {
      return _json(200, [for (final t in state.tokens) t.toPublicJson()]);
    }
    if (parts.length == 1 && method == 'POST') {
      final body = await _body(request);
      final name = '${body['name'] ?? ''}'.trim();
      if (name.isEmpty) throw ApiError(400, 'invalid_name', 'name is required');
      final portalIds = [
        for (final p in (body['portalIds'] as List? ?? const [])) '$p',
      ];
      for (final p in portalIds) {
        if (state.portal(p) == null) {
          throw ApiError(400, 'unknown_portal', 'No portal "$p"');
        }
      }
      final days = body['expiresInDays'];
      final secret = randomSecret(prefix: 'mcp_');
      final token = AccessToken(
        id: newId('tok'),
        name: name,
        hash: hashSecret(secret),
        prefix: secret.substring(0, 8),
        portalIds: portalIds,
        createdAt: DateTime.now(),
        expiresAt: days is int && days > 0
            ? DateTime.now().add(Duration(days: days))
            : null,
      );
      await store.update((s) => s.tokens.add(token));
      // The only time the secret is shown.
      return _json(201, {'token': token.toPublicJson(), 'secret': secret});
    }
    if (parts.length == 2 && method == 'DELETE') {
      final id = parts[1];
      final i = state.tokens.indexWhere((t) => t.id == id);
      if (i < 0) throw ApiError(404, 'token_not_found');
      await store.update((s) {
        s.tokens[i] = s.tokens[i].copyWith(revokedAt: DateTime.now());
      });
      return _json(200, {'ok': true});
    }
    throw ApiError(405, 'method_not_allowed');
  }

  // ------------------------------------------------------------------- rules

  Future<Response> _rules(Request request, String method) async {
    final state = store.state;
    if (method == 'GET') {
      return _json(200, {
        'rules': [for (final r in state.rules) r.toJson()],
        'overrides': {
          for (final e in state.overrides.entries) e.key: e.value.toJson(),
        },
      });
    }
    if (method == 'PUT') {
      final body = await _body(request);
      final List<ToolRule> rules;
      final Map<String, ToolOverride> overrides;
      try {
        rules = [
          for (final r in (body['rules'] as List? ?? const []))
            ToolRule.fromJson((r as Map).cast<String, dynamic>()),
        ];
        overrides = {
          for (final e in ((body['overrides'] as Map?) ?? const {}).entries)
            '${e.key}': ToolOverride.fromJson(
              (e.value as Map).cast<String, dynamic>(),
            ),
        };
      } catch (_) {
        throw ApiError(
          400,
          'invalid_rules',
          'The rules or overrides could not be read',
        );
      }
      await store.update((s) {
        s.rules = rules;
        s.overrides = overrides;
      });
      return _json(200, {'rules': rules.length, 'overrides': overrides.length});
    }
    throw ApiError(405, 'method_not_allowed');
  }

  Future<Json> _body(Request request) async {
    final text = await request.readAsString();
    if (text.trim().isEmpty) return {};
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw ApiError(400, 'invalid_body', 'Send a JSON object');
    }
    return decoded.cast<String, dynamic>();
  }
}

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);
