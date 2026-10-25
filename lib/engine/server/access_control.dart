import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/json.dart';
import 'access.dart';
import 'server_client.dart';
import 'server_events.dart';
import 'session.dart';

/// Someone who has signed in to the server.
class MemberInfo {
  const MemberInfo({
    required this.id,
    required this.login,
    required this.provider,
    required this.role,
    required this.viaInvite,
    this.name,
    this.email,
    this.avatarUrl,
    this.serverIds,
    this.portalIds,
    this.lastSeenAt,
  });

  final String id;
  final String login;
  final String? name;
  final String? email;
  final String? avatarUrl;
  final String provider;
  final String role;

  /// Limited to these servers and portals; null means all.
  final List<String>? serverIds;
  final List<String>? portalIds;
  final bool viaInvite;
  final DateTime? lastSeenAt;

  String get label => name ?? login;

  factory MemberInfo.fromJson(Json j) {
    List<String>? list(String k) =>
        j[k] == null ? null : [for (final e in j[k] as List) '$e'];
    return MemberInfo(
      id: j['id'] as String,
      login: j['login'] as String,
      name: j['name'] as String?,
      email: j['email'] as String?,
      avatarUrl: j['avatarUrl'] as String?,
      provider: j['provider'] as String? ?? 'github',
      role: j['role'] as String? ?? 'viewer',
      serverIds: list('serverIds'),
      portalIds: list('portalIds'),
      viaInvite: j['viaInvite'] == true,
      lastSeenAt: j['lastSeenAt'] == null
          ? null
          : DateTime.tryParse(j['lastSeenAt'] as String)?.toLocal(),
    );
  }
}

/// A named set of permissions.
class RoleInfo {
  const RoleInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.permissions,
    required this.builtin,
    required this.members,
    required this.invites,
  });

  final String id;
  final String name;
  final String description;
  final Set<String> permissions;
  final bool builtin;
  final int members;
  final int invites;

  factory RoleInfo.fromJson(Json j) => RoleInfo(
    id: j['id'] as String,
    name: j['name'] as String,
    description: j['description'] as String? ?? '',
    permissions: {
      for (final p in (j['permissions'] as List?) ?? const []) '$p',
    },
    builtin: j['builtin'] == true,
    members: (j['members'] as num?)?.toInt() ?? 0,
    invites: (j['invites'] as num?)?.toInt() ?? 0,
  );
}

/// One permission, with the group it is shown under.
class PermissionInfo {
  const PermissionInfo(this.id, this.group, this.label);
  final String id;
  final String group;
  final String label;

  factory PermissionInfo.fromJson(Json j) => PermissionInfo(
    j['id'] as String,
    j['group'] as String,
    j['label'] as String,
  );
}

/// An invitation to join, pending or used.
class InviteInfo {
  const InviteInfo({
    required this.id,
    required this.role,
    required this.status,
    required this.createdBy,
    required this.expiresAt,
    this.email,
    this.serverIds,
    this.portalIds,
    this.usedBy,
  });

  final String id;
  final String? email;
  final String role;

  /// `pending`, `used` or `expired`.
  final String status;
  final String createdBy;
  final DateTime expiresAt;
  final List<String>? serverIds;
  final List<String>? portalIds;
  final String? usedBy;

  factory InviteInfo.fromJson(Json j) {
    List<String>? list(String k) =>
        j[k] == null ? null : [for (final e in j[k] as List) '$e'];
    return InviteInfo(
      id: j['id'] as String,
      email: j['email'] as String?,
      role: j['role'] as String,
      status: j['status'] as String? ?? 'pending',
      createdBy: j['createdBy'] as String? ?? '',
      expiresAt: DateTime.parse(j['expiresAt'] as String).toLocal(),
      serverIds: list('serverIds'),
      portalIds: list('portalIds'),
      usedBy: j['usedBy'] as String?,
    );
  }
}

/// What the server returns when an invitation is made: the link, shown once.
class CreatedInvite {
  const CreatedInvite({required this.invite, required this.url});
  final InviteInfo invite;
  final String url;
}

class AccessControlState {
  const AccessControlState({
    this.members = const [],
    this.roles = const [],
    this.invites = const [],
    this.permissions = const [],
    this.loading = true,
    this.error,
  });

  final List<MemberInfo> members;
  final List<RoleInfo> roles;
  final List<InviteInfo> invites;
  final List<PermissionInfo> permissions;
  final bool loading;
  final String? error;

  RoleInfo? role(String id) => roles.where((r) => r.id == id).firstOrNull;
  String roleName(String id) => role(id)?.name ?? id;
}

final accessControlProvider =
    NotifierProvider<AccessControlNotifier, AccessControlState>(
      AccessControlNotifier.new,
    );

/// Members, roles and invitations, kept on the server.
class AccessControlNotifier extends Notifier<AccessControlState> {
  ServerClient? _client;

  @override
  AccessControlState build() {
    _client = ref.watch(serverClientProvider);
    listenToServer(ref, (e) {
      final changed = e.type == 'changed'
          ? ((e.data['collections'] as List?) ?? const [])
          : const [];
      if (e.type == 'ready' ||
          changed.any(
            (c) => c == 'members' || c == 'roles' || c == 'invites',
          )) {
        unawaited(reload());
      }
    });
    if (_client == null || !ref.read(accessProvider).can('members.view')) {
      return const AccessControlState(loading: false);
    }
    Future.microtask(reload);
    return const AccessControlState();
  }

  ServerClient get _api =>
      _client ?? (throw ServerException(0, 'signed_out', 'Sign in first.'));

  Future<void> reload() async {
    final client = _client;
    if (client == null || !ref.read(accessProvider).can('members.view')) return;
    try {
      final results = await Future.wait([
        client.getList('/api/members'),
        client.getList('/api/roles'),
        client.getList('/api/invites'),
        client.getList('/api/permissions'),
      ]);
      if (!ref.mounted) return;
      state = AccessControlState(
        members: [for (final j in results[0]) MemberInfo.fromJson(j)],
        roles: [for (final j in results[1]) RoleInfo.fromJson(j)],
        invites: [for (final j in results[2]) InviteInfo.fromJson(j)],
        permissions: [for (final j in results[3]) PermissionInfo.fromJson(j)],
        loading: false,
      );
    } on ServerException catch (e) {
      if (!ref.mounted) return;
      state = AccessControlState(
        members: state.members,
        roles: state.roles,
        invites: state.invites,
        permissions: state.permissions,
        loading: false,
        error: e.message,
      );
    }
  }

  // ----------------------------------------------------------------- members

  /// Changes a member's role and what they are limited to. A null list means
  /// all servers (or portals).
  Future<void> updateMember(
    String id, {
    required String role,
    required List<String>? serverIds,
    required List<String>? portalIds,
  }) async {
    await _api.putMap('/api/members/${Uri.encodeComponent(id)}', {
      'role': role,
      'serverIds': serverIds,
      'portalIds': portalIds,
    });
    await reload();
  }

  Future<void> removeMember(String id) async {
    await _api.delete('/api/members/${Uri.encodeComponent(id)}');
    await reload();
  }

  // ------------------------------------------------------------------- roles

  Future<void> saveRole({
    String? id,
    required String name,
    required String description,
    required Set<String> permissions,
  }) async {
    final body = {
      'name': name,
      'description': description,
      'permissions': permissions.toList()..sort(),
    };
    if (id == null) {
      await _api.postMap('/api/roles', body);
    } else {
      await _api.putMap('/api/roles/$id', body);
    }
    await reload();
  }

  Future<void> deleteRole(String id) async {
    await _api.delete('/api/roles/$id');
    await reload();
  }

  // ----------------------------------------------------------------- invites

  /// Makes an invitation; the link comes back once and is not stored.
  Future<CreatedInvite> invite({
    required String role,
    String? email,
    List<String>? serverIds,
    List<String>? portalIds,
    int expiresInDays = 7,
    String? returnTo,
  }) async {
    final j = await _api.postMap('/api/invites', {
      'role': role,
      if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      'serverIds': serverIds,
      'portalIds': portalIds,
      'expiresInDays': expiresInDays,
      'returnTo': ?returnTo,
    });
    await reload();
    return CreatedInvite(
      invite: InviteInfo.fromJson(j),
      url: j['url'] as String,
    );
  }

  Future<void> revokeInvite(String id) async {
    await _api.delete('/api/invites/$id');
    await reload();
  }
}
