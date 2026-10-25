import 'package:mcp_core/mcp_core.dart';

/// One thing a member can be allowed to do.
class PermissionDef {
  const PermissionDef(this.id, this.group, this.label);

  /// `area.action`, e.g. `servers.manage`.
  final String id;
  final String group;
  final String label;

  Json toJson() => {'id': id, 'group': group, 'label': label};
}

/// Every permission, grouped for the dashboard. Routes check these.
const allPermissionDefs = [
  PermissionDef('servers.view', 'MCP servers', 'See servers and their health'),
  PermissionDef(
    'servers.manage',
    'MCP servers',
    'Add, edit, remove and sign in to servers',
  ),
  PermissionDef('tools.view', 'MCP tools', 'See tools and their rules'),
  PermissionDef('tools.call', 'MCP tools', 'Run tools by hand'),
  PermissionDef('rules.manage', 'MCP tools', 'Change tool rules and overrides'),
  PermissionDef('portals.view', 'MCP portals', 'See portals'),
  PermissionDef(
    'portals.manage',
    'MCP portals',
    'Create, edit and delete portals',
  ),
  PermissionDef(
    'tokens.manage',
    'MCP portals',
    'Create and revoke access tokens',
  ),
  PermissionDef('audit.view', 'Audit', 'Read the audit log'),
  PermissionDef('audit.manage', 'Audit', 'Delete audit events'),
  PermissionDef('chats.use', 'Chat', 'Use the Chat and the model providers'),
  PermissionDef('llm.manage', 'Chat', 'Add and edit model providers and keys'),
  PermissionDef('members.view', 'Access', 'See members, roles and invites'),
  PermissionDef(
    'members.manage',
    'Access',
    'Invite, change and remove members',
  ),
  PermissionDef('roles.manage', 'Access', 'Create and edit roles'),
  PermissionDef(
    'providers.manage',
    'Access',
    'Set up sign-in with GitHub and Google',
  ),
];

final allPermissionIds = {for (final p in allPermissionDefs) p.id};

/// A named set of permissions. The built-in ones cannot be changed.
class Role {
  const Role({
    required this.id,
    required this.name,
    required this.permissions,
    this.description = '',
    this.builtin = false,
    this.createdAt,
  });

  final String id;
  final String name;
  final String description;
  final Set<String> permissions;
  final bool builtin;
  final DateTime? createdAt;

  Role copyWith({
    String? name,
    String? description,
    Set<String>? permissions,
  }) => Role(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    permissions: permissions ?? this.permissions,
    builtin: builtin,
    createdAt: createdAt,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'permissions': permissions.toList()..sort(),
    'builtin': builtin,
    if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
  };

  factory Role.fromJson(Json json) => Role(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String? ?? '',
    permissions: {
      for (final p in (json['permissions'] as List?) ?? const []) '$p',
    },
    createdAt: json['createdAt'] == null
        ? null
        : DateTime.parse(json['createdAt'] as String),
  );
}

/// The roles every server has.
final builtinRoles = [
  Role(
    id: 'admin',
    name: 'Admin',
    description: 'Everything, including members, roles and sign-in.',
    permissions: allPermissionIds,
    builtin: true,
  ),
  const Role(
    id: 'operator',
    name: 'Operator',
    description:
        'Runs the gateway: servers, tools, portals, tokens and the audit log. '
        'No access to members, roles, sign-in or model providers.',
    permissions: {
      'servers.view',
      'servers.manage',
      'tools.view',
      'tools.call',
      'rules.manage',
      'portals.view',
      'portals.manage',
      'tokens.manage',
      'audit.view',
      'chats.use',
    },
    builtin: true,
  ),
  const Role(
    id: 'viewer',
    name: 'Viewer',
    description: 'Can look at servers, tools, portals and the audit log.',
    permissions: {'servers.view', 'tools.view', 'portals.view', 'audit.view'},
    builtin: true,
  ),
];

/// What one signed-in caller may do, worked out from their role on each
/// request, so a change to the role applies at once.
class Access {
  const Access({
    required this.permissions,
    this.serverIds,
    this.portalIds,
    this.isAdminToken = false,
  });

  /// Everything, for the admin token.
  Access.all()
    : permissions = allPermissionIds,
      serverIds = null,
      portalIds = null,
      isAdminToken = true;

  final Set<String> permissions;

  /// The servers and portals they are limited to; null means all of them.
  final List<String>? serverIds;
  final List<String>? portalIds;
  final bool isAdminToken;

  bool can(String permission) => permissions.contains(permission);

  bool get allServers => serverIds == null;
  bool get allPortals => portalIds == null;

  bool canServer(String id) => serverIds == null || serverIds!.contains(id);
  bool canPortal(String id) => portalIds == null || portalIds!.contains(id);

  /// The permissions that let someone change who has access.
  static const accessPermissions = {
    'members.manage',
    'roles.manage',
    'providers.manage',
  };

  /// Whether they may change or remove a member who has [role]: not when that
  /// member can manage access in ways they cannot.
  bool canManageMember(Role role) =>
      permissions.containsAll(role.permissions.intersection(accessPermissions));

  /// Whether they may hand out [role] with access to [servers] and [portals]
  /// (null meaning all): nobody can give away more than they have.
  bool canGrant(Role role, List<String>? servers, List<String>? portals) {
    if (!permissions.containsAll(role.permissions)) return false;
    bool within(List<String>? mine, List<String>? asked) {
      if (mine == null) return true;
      if (asked == null) return false;
      return mine.toSet().containsAll(asked);
    }

    return within(serverIds, servers) && within(portalIds, portals);
  }

  Json toJson() => {
    'permissions': permissions.toList()..sort(),
    'serverIds': serverIds,
    'portalIds': portalIds,
  };
}

/// A link or a pre-approved email that lets someone in with a role.
class Invite {
  const Invite({
    required this.id,
    required this.hash,
    required this.role,
    required this.createdAt,
    required this.expiresAt,
    this.email,
    this.serverIds,
    this.portalIds,
    this.returnTo,
    this.createdBy = '',
    this.usedBy,
    this.usedAt,
  });

  final String id;

  /// Only the hash of the link's token is kept.
  final String hash;

  /// When set, only someone with this verified email can use it.
  final String? email;
  final String role;
  final List<String>? serverIds;
  final List<String>? portalIds;

  /// Where the browser goes after joining (the dashboard's address).
  final String? returnTo;
  final String createdBy;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String? usedBy;
  final DateTime? usedAt;

  bool get used => usedAt != null;
  bool expired(DateTime now) => !expiresAt.isAfter(now);
  bool pending(DateTime now) => !used && !expired(now);

  Invite markUsed(String memberId, DateTime now) => Invite(
    id: id,
    hash: hash,
    role: role,
    createdAt: createdAt,
    expiresAt: expiresAt,
    email: email,
    serverIds: serverIds,
    portalIds: portalIds,
    returnTo: returnTo,
    createdBy: createdBy,
    usedBy: memberId,
    usedAt: now,
  );

  Json toPublicJson(DateTime now) => {
    'id': id,
    'email': email,
    'role': role,
    'serverIds': serverIds,
    'portalIds': portalIds,
    'createdBy': createdBy,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'usedBy': usedBy,
    'usedAt': usedAt?.toUtc().toIso8601String(),
    'status': used
        ? 'used'
        : expired(now)
        ? 'expired'
        : 'pending',
  };

  Json toJson() => {
    'id': id,
    'hash': hash,
    'email': email,
    'role': role,
    'serverIds': serverIds,
    'portalIds': portalIds,
    'returnTo': returnTo,
    'createdBy': createdBy,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'usedBy': usedBy,
    'usedAt': usedAt?.toUtc().toIso8601String(),
  };

  factory Invite.fromJson(Json json) {
    List<String>? list(String k) =>
        json[k] == null ? null : [for (final e in json[k] as List) '$e'];
    DateTime? date(String k) =>
        json[k] == null ? null : DateTime.parse(json[k] as String);
    return Invite(
      id: json['id'] as String,
      hash: json['hash'] as String,
      email: json['email'] as String?,
      role: json['role'] as String,
      serverIds: list('serverIds'),
      portalIds: list('portalIds'),
      returnTo: json['returnTo'] as String?,
      createdBy: json['createdBy'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      expiresAt: DateTime.parse(json['expiresAt'] as String),
      usedBy: json['usedBy'] as String?,
      usedAt: date('usedAt'),
    );
  }
}
