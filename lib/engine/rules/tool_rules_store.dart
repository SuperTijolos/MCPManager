import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../core/prefs.dart';
import '../mcp/mcp_models.dart';
import 'tool_rules.dart';

const _storageKey = 'mcpm.toolrules.v1';

class ToolRulesState {
  const ToolRulesState({this.rules = const [], this.overrides = const {}});

  /// Highest priority first.
  final List<ToolRule> rules;

  /// Keyed by `serverId/toolName`.
  final Map<String, ToolOverride> overrides;

  /// Declared by the server, or vouched for by the user.
  bool isReadOnly(McpServerConfig server, McpTool tool) =>
      safety(server, tool).index <= ToolSafety.readOnlyByUser.index;

  ToolSafety safety(McpServerConfig server, McpTool tool) {
    if (tool.isReadOnly) return ToolSafety.readOnly;
    if (tool.declaresWrite) return ToolSafety.mayModify;
    if (overrides[toolKey(server.id, tool.name)]?.readOnly == true) {
      return ToolSafety.readOnlyByUser;
    }
    return ToolSafety.unmarked;
  }

  EffectiveTool effective(McpServerConfig server, McpTool tool) =>
      computeEffective(
        server,
        tool,
        rules,
        overrides[toolKey(server.id, tool.name)],
      );
}

final toolRulesProvider = NotifierProvider<ToolRulesNotifier, ToolRulesState>(
  ToolRulesNotifier.new,
);

class ToolRulesNotifier extends Notifier<ToolRulesState> {
  @override
  ToolRulesState build() {
    final raw = readJson(ref.read(sharedPreferencesProvider), _storageKey);
    if (raw is! Map) return const ToolRulesState();
    final rules = <ToolRule>[];
    for (final r in (raw['rules'] as List?) ?? const []) {
      try {
        rules.add(ToolRule.fromJson((r as Map).cast<String, dynamic>()));
      } catch (_) {
        // Skip rules written by an incompatible version.
      }
    }
    final overrides = <String, ToolOverride>{};
    for (final e in ((raw['overrides'] as Map?) ?? const {}).entries) {
      try {
        overrides['${e.key}'] = ToolOverride.fromJson(
          (e.value as Map).cast<String, dynamic>(),
        );
      } catch (_) {}
    }
    return ToolRulesState(rules: rules, overrides: overrides);
  }

  String newRuleId() => newId('rule');

  /// Adds [rule], or replaces the rule with the same id.
  void upsert(ToolRule rule) {
    final exists = state.rules.any((r) => r.id == rule.id);
    _set(
      ToolRulesState(
        rules: exists
            ? [for (final r in state.rules) r.id == rule.id ? rule : r]
            : [...state.rules, rule],
        overrides: state.overrides,
      ),
    );
  }

  void remove(String id) => _set(
    ToolRulesState(
      rules: [
        for (final r in state.rules)
          if (r.id != id) r,
      ],
      overrides: state.overrides,
    ),
  );

  void setEnabled(String id, bool enabled) {
    final rule = state.rules.where((r) => r.id == id).firstOrNull;
    if (rule != null) upsert(rule.copyWith(enabled: enabled));
  }

  /// Moves a rule in the priority order (index 0 wins conflicts).
  void move(int from, int to) {
    final list = [...state.rules];
    final rule = list.removeAt(from);
    list.insert(to.clamp(0, list.length), rule);
    _set(ToolRulesState(rules: list, overrides: state.overrides));
  }

  /// Bulk helper: one rule that adds [args] to exactly the given tools.
  ToolRule addToTools({
    required String name,
    required List<String> toolKeys,
    required List<RuleArg> args,
  }) {
    final rule = ToolRule(
      id: newRuleId(),
      name: name,
      scope: RuleScope.tools,
      toolKeys: toolKeys,
      args: args,
    );
    upsert(rule);
    return rule;
  }

  void setOverride(String key, ToolOverride override) {
    final next = {...state.overrides};
    if (override.isEmpty) {
      next.remove(key);
    } else {
      next[key] = override;
    }
    _set(ToolRulesState(rules: state.rules, overrides: next));
  }

  /// Hides or shows several tools from the Operator at once.
  void setHidden(Iterable<String> keys, bool hidden) {
    final next = {...state.overrides};
    for (final k in keys) {
      final current = next[k] ?? const ToolOverride();
      final updated = current.copyWith(hidden: hidden);
      if (updated.isEmpty) {
        next.remove(k);
      } else {
        next[k] = updated;
      }
    }
    _set(ToolRulesState(rules: state.rules, overrides: next));
  }

  /// Marks several tools as read-only (or removes the mark) in one go.
  void setReadOnly(Iterable<String> keys, bool readOnly) {
    final next = {...state.overrides};
    for (final k in keys) {
      final updated = (next[k] ?? const ToolOverride()).copyWith(
        readOnly: readOnly,
      );
      if (updated.isEmpty) {
        next.remove(k);
      } else {
        next[k] = updated;
      }
    }
    _set(ToolRulesState(rules: state.rules, overrides: next));
  }

  void _set(ToolRulesState next) {
    state = next;
    writeJson(ref.read(sharedPreferencesProvider), _storageKey, {
      'rules': [for (final r in next.rules) r.toJson()],
      'overrides': {
        for (final e in next.overrides.entries) e.key: e.value.toJson(),
      },
    });
  }
}
