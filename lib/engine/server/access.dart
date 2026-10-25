import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/json.dart';
import 'server_events.dart';
import 'session.dart';

/// What the signed-in person may do, as the server says. The server checks
/// every request; this only decides what the dashboard offers.
class Access {
  const Access({required this.permissions, this.serverIds, this.portalIds})
    : _all = false;

  /// Everything, for the admin token and for servers that do not say.
  const Access.all()
    : permissions = const {},
      serverIds = null,
      portalIds = null,
      _all = true;

  final Set<String> permissions;

  /// The servers and portals they are limited to; null means all of them.
  final List<String>? serverIds;
  final List<String>? portalIds;
  final bool _all;

  bool can(String permission) => _all || permissions.contains(permission);
  bool get allServers => serverIds == null;
  bool get allPortals => portalIds == null;

  factory Access.fromJson(Json json) {
    List<String>? list(String k) =>
        json[k] == null ? null : [for (final e in json[k] as List) '$e'];
    return Access(
      permissions: {
        for (final p in (json['permissions'] as List?) ?? const []) '$p',
      },
      serverIds: list('serverIds'),
      portalIds: list('portalIds'),
    );
  }
}

/// What the signed-in person may do.
final accessProvider = Provider<Access>(
  (ref) =>
      ref.watch(sessionProvider.select((s) => s.identity?.access)) ??
      const Access.all(),
);

/// Keeps the person's own access fresh: when roles or members change on the
/// server, ask who we are again. Watched once by the app shell.
final identityRefresherProvider = Provider<void>((ref) {
  listenToServer(ref, (e) {
    final changed = e.type == 'changed'
        ? ((e.data['collections'] as List?) ?? const [])
        : const [];
    if (changed.contains('members') || changed.contains('roles')) {
      ref.read(sessionProvider.notifier).refreshIdentity();
    }
  });
});
