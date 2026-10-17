import 'dart:convert';

import '../core/json.dart';
import '../mcp/mcp_models.dart';

/// Rules reshape what the Operator model sees of a tool, and what is sent to
/// the server, without touching the server's own definition: they can add
/// arguments the model must fill in (for the audit trail, or forwarded),
/// inject hidden fixed values, and append instructions.

enum ArgSource {
  /// An extra argument the model fills in.
  custom,

  /// A value fixed by the user: hidden from the model, always injected.
  hardcoded,
}

class RuleArg {
  const RuleArg({
    required this.name,
    this.description = '',
    this.type = 'string',
    this.required = false,
    this.forward = false,
    this.source = ArgSource.custom,
    this.fixedValue = '',
  });

  final String name;
  final String description;

  /// JSON Schema type: string, number, integer or boolean.
  final String type;
  final bool required;

  /// Custom arguments: pass it on to the server too. When false the value is
  /// recorded in the audit log only and stripped before the call.
  final bool forward;
  final ArgSource source;

  /// Hard-coded arguments: the value, as text (parsed according to [type]).
  final String fixedValue;

  RuleArg copyWith({
    String? name,
    String? description,
    String? type,
    bool? required,
    bool? forward,
    ArgSource? source,
    String? fixedValue,
  }) => RuleArg(
    name: name ?? this.name,
    description: description ?? this.description,
    type: type ?? this.type,
    required: required ?? this.required,
    forward: forward ?? this.forward,
    source: source ?? this.source,
    fixedValue: fixedValue ?? this.fixedValue,
  );

  Json toJson() => {
    'name': name,
    'description': description,
    'type': type,
    'required': required,
    'forward': forward,
    'source': source.name,
    'fixedValue': fixedValue,
  };

  factory RuleArg.fromJson(Json json) => RuleArg(
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    type: json['type'] as String? ?? 'string',
    required: json['required'] as bool? ?? false,
    forward: json['forward'] as bool? ?? false,
    source: ArgSource.values.asNameMap()[json['source']] ?? ArgSource.custom,
    fixedValue: json['fixedValue'] as String? ?? '',
  );

  /// The typed value for a hard-coded argument.
  Object? get fixedParsed => parseFixedValue(fixedValue, type);
}

Object? parseFixedValue(String text, String type) {
  final t = text.trim();
  switch (type) {
    case 'number':
      return num.tryParse(t) ?? t;
    case 'integer':
      return int.tryParse(t) ?? num.tryParse(t) ?? t;
    case 'boolean':
      return t.toLowerCase() == 'true'
          ? true
          : t.toLowerCase() == 'false'
          ? false
          : t;
    default:
      if (t.startsWith('{') || t.startsWith('[')) {
        try {
          return jsonDecode(t);
        } catch (_) {}
      }
      return text;
  }
}

enum RuleScope { all, tools }

enum MatchMode { any, all }

enum ConditionField { name, description, server }

enum ConditionOp { contains, equals, glob, regex }

class RuleCondition {
  const RuleCondition({
    this.field = ConditionField.name,
    this.op = ConditionOp.contains,
    this.value = '',
  });

  final ConditionField field;
  final ConditionOp op;
  final String value;

  Json toJson() => {'field': field.name, 'op': op.name, 'value': value};

  factory RuleCondition.fromJson(Json json) => RuleCondition(
    field:
        ConditionField.values.asNameMap()[json['field']] ?? ConditionField.name,
    op: ConditionOp.values.asNameMap()[json['op']] ?? ConditionOp.contains,
    value: json['value'] as String? ?? '',
  );

  bool test(String subject) {
    final v = value.trim();
    if (v.isEmpty) return true;
    final s = subject.toLowerCase();
    switch (op) {
      case ConditionOp.contains:
        return s.contains(v.toLowerCase());
      case ConditionOp.equals:
        return s == v.toLowerCase();
      case ConditionOp.glob:
        return globToRegExp(v).hasMatch(subject);
      case ConditionOp.regex:
        try {
          return RegExp(v, caseSensitive: false).hasMatch(subject);
        } catch (_) {
          return false;
        }
    }
  }
}

RegExp globToRegExp(String glob) {
  final pattern = glob.split('').map((c) {
    if (c == '*') return '.*';
    if (c == '?') return '.';
    return RegExp.escape(c);
  }).join();
  return RegExp('^$pattern\$', caseSensitive: false);
}

String toolKey(String serverId, String toolName) => '$serverId/$toolName';

class ToolRule {
  const ToolRule({
    required this.id,
    required this.name,
    this.description = '',
    this.enabled = true,
    this.scope = RuleScope.all,
    this.serverIds = const [],
    this.toolKeys = const [],
    this.conditions = const [],
    this.matchMode = MatchMode.any,
    this.args = const [],
    this.instructions = '',
  });

  final String id;
  final String name;
  final String description;
  final bool enabled;
  final RuleScope scope;

  /// Scope "all": limit to these servers (empty = every server).
  final List<String> serverIds;

  /// Scope "tools": exactly these tools, as `serverId/toolName`.
  final List<String> toolKeys;

  /// Scope "all": only tools matching these conditions (empty = every tool).
  final List<RuleCondition> conditions;
  final MatchMode matchMode;
  final List<RuleArg> args;

  /// Appended to the description the model sees.
  final String instructions;

  ToolRule copyWith({
    String? name,
    String? description,
    bool? enabled,
    RuleScope? scope,
    List<String>? serverIds,
    List<String>? toolKeys,
    List<RuleCondition>? conditions,
    MatchMode? matchMode,
    List<RuleArg>? args,
    String? instructions,
  }) => ToolRule(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    enabled: enabled ?? this.enabled,
    scope: scope ?? this.scope,
    serverIds: serverIds ?? this.serverIds,
    toolKeys: toolKeys ?? this.toolKeys,
    conditions: conditions ?? this.conditions,
    matchMode: matchMode ?? this.matchMode,
    args: args ?? this.args,
    instructions: instructions ?? this.instructions,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'enabled': enabled,
    'scope': scope.name,
    'serverIds': serverIds,
    'toolKeys': toolKeys,
    'conditions': [for (final c in conditions) c.toJson()],
    'matchMode': matchMode.name,
    'args': [for (final a in args) a.toJson()],
    'instructions': instructions,
  };

  factory ToolRule.fromJson(Json json) => ToolRule(
    id: json['id'] as String,
    name: json['name'] as String? ?? 'Rule',
    description: json['description'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    scope: RuleScope.values.asNameMap()[json['scope']] ?? RuleScope.all,
    serverIds: ((json['serverIds'] as List?) ?? const []).cast<String>(),
    toolKeys: ((json['toolKeys'] as List?) ?? const []).cast<String>(),
    conditions: [
      for (final c in (json['conditions'] as List?) ?? const [])
        RuleCondition.fromJson((c as Map).cast<String, dynamic>()),
    ],
    matchMode: MatchMode.values.asNameMap()[json['matchMode']] ?? MatchMode.any,
    args: [
      for (final a in (json['args'] as List?) ?? const [])
        RuleArg.fromJson((a as Map).cast<String, dynamic>()),
    ],
    instructions: json['instructions'] as String? ?? '',
  );

  bool matches(McpServerConfig server, McpTool tool) {
    if (scope == RuleScope.tools) {
      return toolKeys.contains(toolKey(server.id, tool.name));
    }
    if (serverIds.isNotEmpty && !serverIds.contains(server.id)) return false;
    if (conditions.isEmpty) return true;
    bool test(RuleCondition c) => c.test(switch (c.field) {
      ConditionField.name => tool.name,
      ConditionField.description => tool.description ?? '',
      ConditionField.server => server.name,
    });
    return matchMode == MatchMode.any
        ? conditions.any(test)
        : conditions.every(test);
  }

  /// One line for lists: what it does and where.
  String get scopeSummary => switch (scope) {
    RuleScope.tools =>
      '${toolKeys.length} selected tool${toolKeys.length == 1 ? '' : 's'}',
    RuleScope.all =>
      '${serverIds.isEmpty ? 'All servers' : '${serverIds.length} server${serverIds.length == 1 ? '' : 's'}'}'
          '${conditions.isEmpty ? '' : ' · ${conditions.length} condition${conditions.length == 1 ? '' : 's'}'}',
  };
}

/// Per-tool exceptions that win over rules.
class ToolOverride {
  const ToolOverride({this.hidden = false, this.instructions = ''});

  /// Hidden tools are not offered to the Operator at all.
  final bool hidden;
  final String instructions;

  bool get isEmpty => !hidden && instructions.trim().isEmpty;

  ToolOverride copyWith({bool? hidden, String? instructions}) => ToolOverride(
    hidden: hidden ?? this.hidden,
    instructions: instructions ?? this.instructions,
  );

  Json toJson() => {'hidden': hidden, 'instructions': instructions};

  factory ToolOverride.fromJson(Json json) => ToolOverride(
    hidden: json['hidden'] as bool? ?? false,
    instructions: json['instructions'] as String? ?? '',
  );
}

/// Built-in starting points, taken from the old project's presets.
class RulePreset {
  const RulePreset(this.id, this.name, this.description, this.args);

  final String id;
  final String name;
  final String description;
  final List<RuleArg> args;
}

const rulePresets = [
  RulePreset(
    'reason',
    'Reason',
    'The model says why it is calling the tool. Audit only.',
    [
      RuleArg(
        name: 'reason',
        description: 'Why this tool is being called.',
        required: true,
      ),
    ],
  ),
  RulePreset(
    'expected_result',
    'Expected result',
    'What the model expects the call to return. Audit only.',
    [
      RuleArg(
        name: 'expected_result',
        description: 'What you expect this call to return or change.',
        required: true,
      ),
    ],
  ),
  RulePreset(
    'reason_expected',
    'Reason & expected result',
    'Both arguments, required, audit only.',
    [
      RuleArg(
        name: 'reason',
        description: 'Why this tool is being called.',
        required: true,
      ),
      RuleArg(
        name: 'expected_result',
        description: 'What you expect this call to return or change.',
        required: true,
      ),
    ],
  ),
  RulePreset(
    'explanation',
    'Require explanation',
    'A required plain-language explanation. Audit only.',
    [
      RuleArg(
        name: 'explanation',
        description: 'Explain in one sentence what you are doing and why.',
        required: true,
      ),
    ],
  ),
  RulePreset(
    'chat_context',
    'Chat context',
    'Optional conversation id and name. Audit only.',
    [
      RuleArg(name: 'chat_id', description: 'Id of the current conversation.'),
      RuleArg(
        name: 'chat_name',
        description: 'Name of the current conversation.',
      ),
    ],
  ),
];

/// A tool as the Operator sees it, after rules and overrides.
class EffectiveTool {
  const EffectiveTool({
    required this.server,
    required this.tool,
    required this.visible,
    required this.description,
    required this.inputSchema,
    required this.extras,
    required this.fixed,
    required this.rules,
    required this.warnings,
    required this.instructions,
  });

  final McpServerConfig server;
  final McpTool tool;
  final bool visible;
  final String description;
  final Json inputSchema;

  /// Arguments the model must/may provide on top of the server's own.
  final List<({RuleArg arg, String rule})> extras;

  /// Hard-coded values injected on every call.
  final List<({RuleArg arg, String rule})> fixed;

  /// Names of the rules that apply, highest priority first.
  final List<String> rules;
  final List<String> warnings;
  final String instructions;

  bool get isModified =>
      !visible ||
      extras.isNotEmpty ||
      fixed.isNotEmpty ||
      instructions.isNotEmpty;
}

/// Applies [rules] (highest priority first) and [override] to [tool]. When two
/// rules define the same argument the earlier rule wins.
EffectiveTool computeEffective(
  McpServerConfig server,
  McpTool tool,
  List<ToolRule> rules,
  ToolOverride? override,
) {
  final applicable = [
    for (final r in rules)
      if (r.enabled && r.matches(server, tool)) r,
  ];
  final upstream = ((tool.inputSchema['properties'] as Map?) ?? const {}).keys
      .map((k) => '$k')
      .toSet();
  final seen = <String>{};
  final extras = <({RuleArg arg, String rule})>[];
  final fixed = <({RuleArg arg, String rule})>[];
  final warnings = <String>[];
  final notes = <String>[];

  for (final rule in applicable) {
    for (final arg in rule.args) {
      final name = arg.name.trim();
      if (name.isEmpty || !seen.add(name)) continue;
      if (arg.source == ArgSource.hardcoded) {
        fixed.add((arg: arg, rule: rule.name));
      } else if (upstream.contains(name)) {
        warnings.add(
          '"$name" (rule "${rule.name}") clashes with an argument the server '
          'already defines, so it is skipped.',
        );
      } else {
        extras.add((arg: arg, rule: rule.name));
      }
    }
    if (rule.instructions.trim().isNotEmpty) {
      notes.add(rule.instructions.trim());
    }
  }
  final overrideNote = override?.instructions.trim() ?? '';
  if (overrideNote.isNotEmpty) notes.add(overrideNote);

  final schema = jsonDecode(jsonEncode(tool.inputSchema)) as Json;
  schema['type'] ??= 'object';
  final properties = ((schema['properties'] as Map?) ?? {})
      .cast<String, dynamic>();
  final required = ((schema['required'] as List?) ?? const <Object?>[])
      .map((e) => '$e')
      .toList();
  for (final f in fixed) {
    properties.remove(f.arg.name.trim());
    required.remove(f.arg.name.trim());
  }
  for (final e in extras) {
    final name = e.arg.name.trim();
    properties[name] = {
      'type': e.arg.type,
      if (e.arg.description.trim().isNotEmpty)
        'description': e.arg.description.trim(),
    };
    if (e.arg.required) required.add(name);
  }
  schema['properties'] = properties;
  if (required.isEmpty) {
    schema.remove('required');
  } else {
    schema['required'] = required.toSet().toList();
  }

  final base = tool.description ?? tool.displayName;
  return EffectiveTool(
    server: server,
    tool: tool,
    visible: override?.hidden != true,
    description: notes.isEmpty ? base : '$base\n\n${notes.join('\n')}',
    inputSchema: schema,
    extras: extras,
    fixed: fixed,
    rules: [for (final r in applicable) r.name],
    warnings: warnings,
    instructions: notes.join('\n'),
  );
}

class PreparedCall {
  const PreparedCall({
    this.forwarded = const {},
    this.context = const {},
    this.error,
  });

  /// Arguments to send to the server.
  final Json forwarded;

  /// Values of the extra arguments, for the audit log.
  final Json context;

  /// Set when the call must not be made (missing required arguments).
  final String? error;
}

/// Turns what the model sent into what the server receives: checks required
/// extras, strips audit-only ones, and injects hard-coded values (which the
/// model can never override).
PreparedCall prepareCall(EffectiveTool tool, Json modelArgs) {
  final missing = <String>[
    for (final e in tool.extras)
      if (e.arg.required && _isBlank(modelArgs[e.arg.name.trim()]))
        e.arg.name.trim(),
  ];
  if (missing.isNotEmpty) {
    return PreparedCall(
      error:
          'Missing required argument${missing.length == 1 ? '' : 's'}: '
          '${missing.join(', ')}. Provide ${missing.length == 1 ? 'it' : 'them'} and call the tool again.',
    );
  }

  final forwarded = {...modelArgs};
  final context = <String, dynamic>{};
  for (final e in tool.extras) {
    final name = e.arg.name.trim();
    if (modelArgs.containsKey(name)) context[name] = modelArgs[name];
    if (!e.arg.forward) forwarded.remove(name);
  }
  for (final f in tool.fixed) {
    forwarded[f.arg.name.trim()] = f.arg.fixedParsed;
  }
  return PreparedCall(forwarded: forwarded, context: context);
}

bool _isBlank(Object? v) => v == null || (v is String && v.trim().isEmpty);
