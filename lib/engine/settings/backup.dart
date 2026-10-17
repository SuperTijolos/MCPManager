import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/json.dart';

/// Everything MCP Manager keeps lives in the browser's local storage under
/// keys starting with this prefix.
const storagePrefix = 'mcpm.';

const _serversKey = 'mcpm.servers.v1';
const _llmKey = 'mcpm.llm.v1';
const _auditKey = 'mcpm.audit.v1';
const _oauthKey = 'mcpm.oauth.v1';
const _rulesKey = 'mcpm.toolrules.v1';
const _settingsKey = 'mcpm.settings.v1';
const _chatIndexKey = 'mcpm.chats.index.v1';
const _chatActiveKey = 'mcpm.chats.active.v1';
final _chatBodyKey = RegExp(r'^mcpm\.chat\.(.+)\.v1$');

const backupFormat = 'mcp-manager-backup';
const backupVersion = 1;

final _secretHeader = RegExp(
  r'(authorization|token|secret|api[-_]?key|cookie|password)',
  caseSensitive: false,
);

/// One line of the storage report.
class StorageEntry {
  const StorageEntry(this.label, this.detail, this.bytes);
  final String label;
  final String detail;
  final int bytes;
}

/// What is stored and how much room it takes. Sizes are the characters kept in
/// local storage, which is what the browser's limit (about 5 MB) counts.
List<StorageEntry> storageReport(SharedPreferences prefs) {
  // Only keys that actually hold something take room.
  int size(Iterable<String> keys) => keys.fold(0, (sum, k) {
    final value = prefs.getString(k);
    return value == null ? sum : sum + k.length + value.length;
  });
  int count(String key, {String? field}) {
    final raw = _decode(prefs.getString(key));
    if (field != null && raw is Map) return (raw[field] as List?)?.length ?? 0;
    if (raw is List) return raw.length;
    if (raw is Map) return raw.length;
    return 0;
  }

  final keys = prefs.getKeys();
  final chatKeys = keys.where(
    (k) =>
        _chatBodyKey.hasMatch(k) || k == _chatIndexKey || k == _chatActiveKey,
  );
  final rules = _decode(prefs.getString(_rulesKey));
  final overrideCount = rules is Map
      ? ((rules['overrides'] as Map?)?.length ?? 0)
      : 0;

  return [
    StorageEntry(
      'Servers',
      '${count(_serversKey)} configured',
      size([_serversKey]),
    ),
    StorageEntry(
      'Sign-in sessions',
      '${count(_oauthKey)} OAuth',
      size([_oauthKey]),
    ),
    StorageEntry('Audit log', '${count(_auditKey)} events', size([_auditKey])),
    StorageEntry(
      'Conversations',
      '${count(_chatIndexKey)} saved',
      size(chatKeys),
    ),
    StorageEntry(
      'Tool rules',
      '${count(_rulesKey, field: 'rules')} rules · $overrideCount overrides',
      size([_rulesKey]),
    ),
    StorageEntry(
      'Providers & models',
      '${count(_llmKey, field: 'providers')} providers',
      size([_llmKey]),
    ),
    StorageEntry('Operator settings', '', size([_settingsKey])),
    StorageEntry(
      'Layout & other',
      '',
      size(
        keys.where((k) => k.startsWith(storagePrefix)).toSet().difference({
          _serversKey,
          _oauthKey,
          _auditKey,
          _rulesKey,
          _llmKey,
          _settingsKey,
          ...chatKeys,
        }),
      ),
    ),
  ];
}

Object? _decode(String? raw) {
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } catch (_) {
    return null;
  }
}

/// A portable copy of the configuration.
///
/// By default no credentials are included: bearer tokens and other secret
/// headers are stripped from servers, provider API keys are removed, and OAuth
/// sign-ins are left out. Conversations and the audit log are opt-in.
Json buildBackup(
  SharedPreferences prefs, {
  bool includeCredentials = false,
  bool includeChats = false,
  bool includeAudit = false,
  DateTime? now,
}) {
  final out = <String, dynamic>{
    'format': backupFormat,
    'version': backupVersion,
    'exportedAt': (now ?? DateTime.now()).toIso8601String(),
    'includesCredentials': includeCredentials,
  };

  final servers = _decode(prefs.getString(_serversKey));
  if (servers is List) {
    out['servers'] = [
      for (final s in servers)
        if (s is Map)
          {
            ...s.cast<String, dynamic>(),
            'headers': {
              for (final h in ((s['headers'] as Map?) ?? const {}).entries)
                if (includeCredentials || !_secretHeader.hasMatch('${h.key}'))
                  '${h.key}': h.value,
            },
          },
    ];
  }

  final llm = _decode(prefs.getString(_llmKey));
  if (llm is Map) {
    out['llm'] = {
      ...llm.cast<String, dynamic>(),
      'providers': [
        for (final p in (llm['providers'] as List?) ?? const [])
          if (p is Map)
            {
              for (final e in p.entries)
                if (includeCredentials || e.key != 'apiKey')
                  '${e.key}': e.value,
            },
      ],
    };
  }

  for (final (key, field) in [
    (_rulesKey, 'toolRules'),
    (_settingsKey, 'settings'),
  ]) {
    final v = _decode(prefs.getString(key));
    if (v != null) out[field] = v;
  }

  if (includeCredentials) {
    final oauth = _decode(prefs.getString(_oauthKey));
    if (oauth != null) out['oauth'] = oauth;
  }
  if (includeAudit) {
    final audit = _decode(prefs.getString(_auditKey));
    if (audit != null) out['audit'] = audit;
  }
  if (includeChats) {
    final index = _decode(prefs.getString(_chatIndexKey));
    if (index is List) {
      out['chats'] = {
        'index': index,
        'bodies': {
          for (final k in prefs.getKeys())
            if (_chatBodyKey.hasMatch(k) && _decode(prefs.getString(k)) != null)
              _chatBodyKey.firstMatch(k)!.group(1)!: _decode(
                prefs.getString(k),
              ),
        },
      };
    }
  }
  return out;
}

class RestoreResult {
  const RestoreResult({this.restored = const [], this.problems = const []});

  /// Sections that were written, for example `servers (3)`.
  final List<String> restored;

  /// Why it could not be restored, when nothing was.
  final List<String> problems;

  bool get ok => problems.isEmpty && restored.isNotEmpty;
}

/// Checks that [text] is a backup this version understands, without writing.
({Json? data, String? error}) parseBackup(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return (data: null, error: 'That is not valid JSON.');
  }
  if (decoded is! Map || decoded['format'] != backupFormat) {
    return (data: null, error: 'That is not an MCP Manager backup.');
  }
  final version = decoded['version'];
  if (version is! int || version > backupVersion) {
    return (
      data: null,
      error: 'This backup was made by a newer version (format $version).',
    );
  }
  final servers = decoded['servers'];
  if (servers != null &&
      (servers is! List ||
          servers.any(
            (s) =>
                s is! Map ||
                s['id'] is! String ||
                s['name'] is! String ||
                s['url'] is! String,
          ))) {
    return (
      data: null,
      error: 'The servers section of this backup is damaged.',
    );
  }
  return (data: decoded.cast<String, dynamic>(), error: null);
}

/// Writes the sections present in [backup]; sections it does not contain are
/// left as they are. The caller should reload the stores afterwards.
Future<RestoreResult> restoreBackup(
  SharedPreferences prefs,
  Json backup,
) async {
  final restored = <String>[];
  Future<void> put(String key, Object value) =>
      prefs.setString(key, jsonEncode(value));

  final servers = backup['servers'];
  if (servers is List) {
    await put(_serversKey, servers);
    restored.add('servers (${servers.length})');
  }
  final llm = backup['llm'];
  if (llm is Map) {
    // A backup without credentials must not wipe the keys already stored.
    final current = _decode(prefs.getString(_llmKey));
    final keys = {
      if (current is Map)
        for (final p in (current['providers'] as List?) ?? const [])
          if (p is Map && p['apiKey'] != null) '${p['id']}': p['apiKey'],
    };
    final providers = [
      for (final p in (llm['providers'] as List?) ?? const [])
        if (p is Map)
          {
            ...p.cast<String, dynamic>(),
            if (p['apiKey'] == null && keys['${p['id']}'] != null)
              'apiKey': keys['${p['id']}'],
          },
    ];
    await put(_llmKey, {
      ...llm.cast<String, dynamic>(),
      'providers': providers,
    });
    restored.add('model providers (${providers.length})');
  }
  final rules = backup['toolRules'];
  if (rules is Map) {
    await put(_rulesKey, rules);
    restored.add('tool rules (${(rules['rules'] as List?)?.length ?? 0})');
  }
  final settings = backup['settings'];
  if (settings is Map) {
    await put(_settingsKey, settings);
    restored.add('operator settings');
  }
  final oauth = backup['oauth'];
  if (oauth is Map) {
    await put(_oauthKey, oauth);
    restored.add('sign-ins (${oauth.length})');
  }
  final audit = backup['audit'];
  if (audit is List) {
    await put(_auditKey, audit);
    restored.add('audit log (${audit.length})');
  }
  final chats = backup['chats'];
  if (chats is Map && chats['index'] is List) {
    final index = chats['index'] as List;
    final bodies = (chats['bodies'] as Map?) ?? const {};
    await removeConversations(prefs);
    for (final e in bodies.entries) {
      await put('mcpm.chat.${e.key}.v1', e.value as Object);
    }
    await put(_chatIndexKey, index);
    restored.add('conversations (${index.length})');
  }
  if (restored.isEmpty) {
    return const RestoreResult(
      problems: ['The backup contains nothing to restore.'],
    );
  }
  return RestoreResult(restored: restored);
}

/// Deletes every saved conversation.
Future<void> removeConversations(SharedPreferences prefs) async {
  for (final k in prefs.getKeys().toList()) {
    if (_chatBodyKey.hasMatch(k) || k == _chatIndexKey || k == _chatActiveKey) {
      await prefs.remove(k);
    }
  }
}

/// Deletes everything MCP Manager stored, leaving other sites' data alone.
Future<int> resetAll(SharedPreferences prefs) async {
  var n = 0;
  for (final k in prefs.getKeys().toList()) {
    if (k.startsWith(storagePrefix)) {
      await prefs.remove(k);
      n++;
    }
  }
  return n;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

/// The typical local-storage allowance of a browser origin.
const storageBudgetBytes = 5 * 1024 * 1024;

/// What a parsed backup would restore, as short labels for a confirmation.
List<String> describeBackup(Json backup) {
  int n(Object? v) => v is List ? v.length : (v is Map ? v.length : 0);
  return [
    if (backup['servers'] is List) 'servers (${n(backup['servers'])})',
    if (backup['llm'] is Map)
      'model providers (${n((backup['llm'] as Map)['providers'])})',
    if (backup['toolRules'] is Map)
      'tool rules (${n((backup['toolRules'] as Map)['rules'])})',
    if (backup['settings'] is Map) 'operator settings',
    if (backup['oauth'] is Map) 'sign-ins (${n(backup['oauth'])})',
    if (backup['audit'] is List) 'audit log (${n(backup['audit'])})',
    if (backup['chats'] is Map)
      'conversations (${n((backup['chats'] as Map)['index'])})',
  ];
}
