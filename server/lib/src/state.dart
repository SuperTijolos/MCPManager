import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_core/mcp_core.dart';

import 'models.dart';

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
  }) : servers = servers ?? [],
       portals = portals ?? [],
       tokens = tokens ?? [],
       rules = rules ?? [],
       overrides = overrides ?? {},
       oauthClients = oauthClients ?? [],
       oauthGrants = oauthGrants ?? [];

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
    );
  }
}

/// Holds the [PortalState] in memory and saves it after every change. Writes
/// go to a temporary file first, so a crash never leaves half a document.
class StateStore {
  StateStore._(this._file, this.state);

  /// A store that never touches the disk, for tests.
  StateStore.memory([PortalState? state])
    : _file = null,
      state = state ?? PortalState();

  final File? _file;
  final PortalState state;
  Future<void> _queue = Future.value();

  static Future<StateStore> open(File file) async {
    var state = PortalState();
    if (await file.exists()) {
      final text = await file.readAsString();
      if (text.trim().isNotEmpty) {
        state = PortalState.fromJson(
          (jsonDecode(text) as Map).cast<String, dynamic>(),
        );
      }
    } else {
      await file.parent.create(recursive: true);
    }
    return StateStore._(file, state);
  }

  /// Applies [change] and saves. Changes run one after another.
  Future<T> update<T>(T Function(PortalState state) change) {
    final result = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        final value = change(state);
        await _save();
        result.complete(value);
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(state.toJson()), flush: true);
    // The state holds upstream credentials: keep it to the owner.
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', temp.path]);
      } on ProcessException {
        // A minimal container has no chmod; the data directory is private anyway.
      }
    }
    await temp.rename(file.path);
  }
}
