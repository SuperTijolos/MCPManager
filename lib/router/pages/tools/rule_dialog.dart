import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/rules/tool_rules.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Opens the rule editor.
///
/// - Create a rule: leave [existing] null. Pass [toolKeys] to start with an
///   exact selection of tools (the bulk "add an argument to these tools" flow)
///   and [preset] to start from one of the built-in argument sets.
/// - Edit a rule: pass [existing].
Future<void> showRuleDialog(
  BuildContext context, {
  ToolRule? existing,
  List<String> toolKeys = const [],
  RulePreset? preset,
}) {
  final narrow = MediaQuery.sizeOf(context).width < 700;
  final body = RuleDialog(
    existing: existing,
    toolKeys: toolKeys,
    preset: preset,
  );
  return showDialog<void>(
    context: context,
    builder: (_) => narrow
        ? Dialog.fullscreen(child: body)
        : Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760, maxHeight: 820),
              child: body,
            ),
          ),
  );
}

enum _ArgMode {
  audit('Ask the model · audit only'),
  forward('Ask the model · also send to the server'),
  fixed('Fixed value · hidden from the model');

  const _ArgMode(this.label);
  final String label;
}

class _ArgDraft {
  _ArgDraft({
    String name = '',
    String description = '',
    this.type = 'string',
    this.mode = _ArgMode.audit,
    this.required = false,
    String fixedValue = '',
  }) : name = TextEditingController(text: name),
       description = TextEditingController(text: description),
       fixedValue = TextEditingController(text: fixedValue);

  factory _ArgDraft.from(RuleArg a) => _ArgDraft(
    name: a.name,
    description: a.description,
    type: a.type,
    required: a.required,
    fixedValue: a.fixedValue,
    mode: a.source == ArgSource.hardcoded
        ? _ArgMode.fixed
        : a.forward
        ? _ArgMode.forward
        : _ArgMode.audit,
  );

  final TextEditingController name;
  final TextEditingController description;
  final TextEditingController fixedValue;
  String type;
  _ArgMode mode;
  bool required;

  RuleArg build() => RuleArg(
    name: name.text.trim(),
    description: description.text.trim(),
    type: type,
    required: mode != _ArgMode.fixed && required,
    forward: mode == _ArgMode.forward,
    source: mode == _ArgMode.fixed ? ArgSource.hardcoded : ArgSource.custom,
    fixedValue: mode == _ArgMode.fixed ? fixedValue.text : '',
  );

  void dispose() {
    name.dispose();
    description.dispose();
    fixedValue.dispose();
  }
}

class _CondDraft {
  _CondDraft({
    this.field = ConditionField.name,
    this.op = ConditionOp.contains,
    String value = '',
  }) : value = TextEditingController(text: value);

  ConditionField field;
  ConditionOp op;
  final TextEditingController value;

  RuleCondition build() =>
      RuleCondition(field: field, op: op, value: value.text.trim());

  void dispose() => value.dispose();
}

final _argName = RegExp(r'^[A-Za-z_][A-Za-z0-9_-]{0,63}$');

class RuleDialog extends ConsumerStatefulWidget {
  const RuleDialog({
    super.key,
    this.existing,
    this.toolKeys = const [],
    this.preset,
  });

  final ToolRule? existing;
  final List<String> toolKeys;
  final RulePreset? preset;

  @override
  ConsumerState<RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends ConsumerState<RuleDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _instructions;
  late RuleScope _scope;
  late final Set<String> _servers;
  late List<String> _tools;
  late final List<_CondDraft> _conditions;
  late MatchMode _mode;
  late final List<_ArgDraft> _args;
  late bool _enabled;
  bool _nameIsAuto = false;
  String? _error;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    _name = TextEditingController(text: r?.name ?? '');
    _description = TextEditingController(text: r?.description ?? '');
    _instructions = TextEditingController(text: r?.instructions ?? '');
    _scope =
        r?.scope ??
        (widget.toolKeys.isNotEmpty ? RuleScope.tools : RuleScope.all);
    _servers = {...?r?.serverIds};
    _tools = [...?r?.toolKeys, if (r == null) ...widget.toolKeys];
    _conditions = [
      for (final c in r?.conditions ?? const <RuleCondition>[])
        _CondDraft(field: c.field, op: c.op, value: c.value),
    ];
    _mode = r?.matchMode ?? MatchMode.any;
    _args = [for (final a in r?.args ?? const <RuleArg>[]) _ArgDraft.from(a)];
    _enabled = r?.enabled ?? true;
    final p = widget.preset;
    if (r == null && p != null) _applyPreset(p);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _instructions.dispose();
    for (final a in _args) {
      a.dispose();
    }
    for (final c in _conditions) {
      c.dispose();
    }
    super.dispose();
  }

  void _applyPreset(RulePreset p) {
    for (final a in _args) {
      a.dispose();
    }
    _args
      ..clear()
      ..addAll([for (final a in p.args) _ArgDraft.from(a)]);
    if (_name.text.trim().isEmpty || _nameIsAuto) {
      _name.text = p.name;
      _nameIsAuto = true;
    }
  }

  ToolRule _build() => ToolRule(
    id: widget.existing?.id ?? ref.read(toolRulesProvider.notifier).newRuleId(),
    name: _name.text.trim(),
    description: _description.text.trim(),
    enabled: _enabled,
    scope: _scope,
    serverIds: _scope == RuleScope.all ? _servers.toList() : const [],
    toolKeys: _scope == RuleScope.tools ? _tools : const [],
    conditions: _scope == RuleScope.all
        ? [for (final c in _conditions) c.build()]
        : const [],
    matchMode: _mode,
    args: [for (final a in _args) a.build()],
    instructions: _instructions.text.trim(),
  );

  List<ToolRef> _matched(ToolRule rule) => [
    for (final t in ref.read(mcpHubProvider).availableTools)
      if (rule.matches(t.server, t.tool)) t,
  ];

  String? _validate(ToolRule rule) {
    if (rule.name.isEmpty) return 'Give the rule a name.';
    if (rule.args.isEmpty && rule.instructions.isEmpty) {
      return 'Add at least one argument, or some instructions.';
    }
    final seen = <String>{};
    for (final a in rule.args) {
      if (!_argName.hasMatch(a.name)) {
        return 'Argument names use letters, digits, _ or - (and do not start with a digit): "${a.name}".';
      }
      if (!seen.add(a.name)) return 'The argument "${a.name}" appears twice.';
      if (a.source == ArgSource.hardcoded && a.fixedValue.trim().isEmpty) {
        return 'Give "${a.name}" a fixed value, or change how it works.';
      }
    }
    if (rule.scope == RuleScope.tools && rule.toolKeys.isEmpty) {
      return 'Choose at least one tool, or apply the rule to all tools.';
    }
    for (final c in rule.conditions) {
      if (c.op == ConditionOp.regex && c.value.isNotEmpty) {
        try {
          RegExp(c.value);
        } catch (_) {
          return 'The pattern "${c.value}" is not a valid regular expression.';
        }
      }
    }
    return null;
  }

  Future<void> _save() async {
    final rule = _build();
    final problem = _validate(rule);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final total = ref.read(mcpHubProvider).availableTools.length;
    final matched = _matched(rule).length;
    final existing = widget.existing;
    final wasEverything =
        existing != null &&
        existing.enabled &&
        _matched(existing).length == total;
    // A rule that quietly touches every tool is usually an unfinished scope.
    if (rule.enabled && total > 1 && matched == total && !wasEverything) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Apply to all $total tools?'),
          content: Text(
            'This rule matches every connected tool, including ones it has '
            'nothing to do with. Narrow it to a server, a name pattern or '
            'selected tools, or keep it if everything should change.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Go back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Apply to all $total'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    ref.read(toolRulesProvider.notifier).upsert(rule);
    Navigator.pop(context);
    showSnack(
      context,
      'Rule saved · applies to $matched tool${matched == 1 ? '' : 's'} right now',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hub = ref.watch(mcpHubProvider);
    // Rebuild the preview on every edit.
    final preview = _matched(_build());

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        title: Text(_editing ? 'Edit rule' : 'New rule'),
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      // A plain scroll view (not a lazy ListView): the form is short enough to
      // build in full, and every control stays reachable.
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'A rule changes what the Operator sees of a tool and what is sent to '
              'the server. The server\'s own definition is never modified.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
              onChanged: (_) => _nameIsAuto = false,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
              ),
            ),
            if (!_editing) ...[
              const SizedBox(height: 20),
              Text('Start from', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in rulePresets)
                    Tooltip(
                      message: p.description,
                      child: ActionChip(
                        label: Text(p.name),
                        avatar: const Icon(Icons.auto_awesome, size: 16),
                        onPressed: () => setState(() => _applyPreset(p)),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            _sectionTitle(
              theme,
              'Arguments',
              'Extra arguments the model must provide, or values to inject.',
            ),
            for (var i = 0; i < _args.length; i++)
              _ArgCard(
                key: ObjectKey(_args[i]),
                draft: _args[i],
                onChanged: () => setState(() {}),
                onRemove: () => setState(() => _args.removeAt(i).dispose()),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _args.add(_ArgDraft())),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add argument'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _instructions,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Instructions (optional)',
                helperText:
                    'Appended to the tool\'s description for the model.',
                alignLabelWithHint: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 20),
            _sectionTitle(theme, 'Applies to', null),
            SegmentedButton<RuleScope>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: RuleScope.all,
                  label: Text('Tools matching…'),
                  icon: Icon(Icons.filter_alt_outlined),
                ),
                ButtonSegment(
                  value: RuleScope.tools,
                  label: Text('Selected tools'),
                  icon: Icon(Icons.checklist),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (s) => setState(() => _scope = s.first),
            ),
            const SizedBox(height: 12),
            if (_scope == RuleScope.all) ..._allScope(theme, hub),
            if (_scope == RuleScope.tools) ..._toolsScope(theme, hub),
            const SizedBox(height: 16),
            _Preview(matches: preview, totalTools: hub.availableTools.length),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Rule enabled'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Pinned here so it is visible however far the form is scrolled.
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 18,
                      color: StatusColors.bad,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: StatusColors.bad),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Icon(
                  preview.isEmpty
                      ? Icons.warning_amber_rounded
                      : Icons.fact_check_outlined,
                  size: 18,
                  color: preview.isEmpty
                      ? StatusColors.warn
                      : StatusColors.info,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${preview.length} of ${hub.availableTools.length} tools',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _save,
                  child: Text(_editing ? 'Save rule' : 'Create rule'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String title, String? subtitle) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            if (subtitle != null)
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      );

  List<Widget> _allScope(ThemeData theme, McpHubState hub) {
    return [
      Text('Servers', style: theme.textTheme.bodySmall),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          ChoiceChip(
            label: const Text('All servers'),
            selected: _servers.isEmpty,
            onSelected: (_) => setState(_servers.clear),
          ),
          for (final s in hub.servers)
            FilterChip(
              label: Text(s.config.name),
              selected: _servers.contains(s.config.id),
              onSelected: (on) => setState(
                () => on
                    ? _servers.add(s.config.id)
                    : _servers.remove(s.config.id),
              ),
            ),
        ],
      ),
      const SizedBox(height: 14),
      Row(
        children: [
          Text('Only tools where', style: theme.textTheme.bodySmall),
          const SizedBox(width: 8),
          if (_conditions.length > 1)
            SegmentedButton<MatchMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: MatchMode.any, label: Text('any')),
                ButtonSegment(value: MatchMode.all, label: Text('all')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
        ],
      ),
      for (var i = 0; i < _conditions.length; i++)
        _ConditionRow(
          key: ObjectKey(_conditions[i]),
          draft: _conditions[i],
          onChanged: () => setState(() {}),
          onRemove: () => setState(() => _conditions.removeAt(i).dispose()),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _conditions.add(_CondDraft())),
          icon: const Icon(Icons.add, size: 18),
          label: Text(
            _conditions.isEmpty ? 'Narrow down by name…' : 'Add condition',
          ),
        ),
      ),
    ];
  }

  List<Widget> _toolsScope(ThemeData theme, McpHubState hub) {
    String label(String key) {
      for (final t in hub.availableTools) {
        if (toolKey(t.server.id, t.tool.name) == key) {
          return '${t.server.name} · ${t.tool.name}';
        }
      }
      return key; // a tool of a server that is offline right now
    }

    return [
      if (_tools.isEmpty)
        Text(
          'No tools chosen yet.',
          style: theme.textTheme.bodySmall?.copyWith(color: StatusColors.warn),
        )
      else
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final k in _tools)
              InputChip(
                label: Text(label(k)),
                onDeleted: () => setState(() => _tools.remove(k)),
              ),
          ],
        ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Choose tools…'),
          onPressed: () async {
            final picked = await showDialog<Set<String>>(
              context: context,
              builder: (_) => _ToolPicker(initial: _tools.toSet()),
            );
            if (picked != null) setState(() => _tools = picked.toList());
          },
        ),
      ),
    ];
  }
}

class _ArgCard extends StatelessWidget {
  const _ArgCard({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.onRemove,
  });

  final _ArgDraft draft;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  static const _types = ['string', 'number', 'integer', 'boolean'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final explain = switch (draft.mode) {
      _ArgMode.audit => 'The model fills this in on every call. It is stored in the audit log and removed before the call reaches the server.',
      _ArgMode.forward => 'The model fills this in and it is also sent to the server (and recorded in the audit log).',
      _ArgMode.fixed => 'Always sent to the server with this value. The model never sees it and cannot change it.',
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: draft.name,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'e.g. reason',
                      ),
                      onChanged: (_) => onChanged(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      initialValue: draft.type,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: [
                        for (final t in _types)
                          DropdownMenuItem(value: t, child: Text(t)),
                      ],
                      onChanged: (v) {
                        draft.type = v ?? draft.type;
                        onChanged();
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Remove argument',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onRemove,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<_ArgMode>(
                initialValue: draft.mode,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'How it works'),
                items: [
                  for (final m in _ArgMode.values)
                    DropdownMenuItem(
                      value: m,
                      child: Text(m.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  draft.mode = v ?? draft.mode;
                  onChanged();
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text(
                  explain,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (draft.mode == _ArgMode.fixed)
                TextField(
                  controller: draft.fixedValue,
                  decoration: const InputDecoration(
                    labelText: 'Value',
                    helperText:
                        'Numbers, true/false and JSON are parsed by type.',
                  ),
                  onChanged: (_) => onChanged(),
                )
              else ...[
                TextField(
                  controller: draft.description,
                  decoration: const InputDecoration(
                    labelText: 'Description for the model',
                    hintText: 'Why this tool is being called.',
                  ),
                  onChanged: (_) => onChanged(),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Required'),
                  subtitle: const Text(
                    'A call without it is bounced back to the model.',
                  ),
                  value: draft.required,
                  onChanged: (v) {
                    draft.required = v;
                    onChanged();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ConditionRow extends StatelessWidget {
  const _ConditionRow({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.onRemove,
  });

  final _CondDraft draft;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  static const _fields = {
    ConditionField.name: 'tool name',
    ConditionField.description: 'description',
    ConditionField.server: 'server name',
  };
  static const _ops = {
    ConditionOp.contains: 'contains',
    ConditionOp.equals: 'equals',
    ConditionOp.glob: 'matches glob',
    ConditionOp.regex: 'matches regex',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 140,
            child: DropdownButtonFormField<ConditionField>(
              initialValue: draft.field,
              isExpanded: true,
              items: [
                for (final e in _fields.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) {
                draft.field = v ?? draft.field;
                onChanged();
              },
            ),
          ),
          SizedBox(
            width: 150,
            child: DropdownButtonFormField<ConditionOp>(
              initialValue: draft.op,
              isExpanded: true,
              items: [
                for (final e in _ops.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) {
                draft.op = v ?? draft.op;
                onChanged();
              },
            ),
          ),
          SizedBox(
            width: 200,
            child: TextField(
              controller: draft.value,
              decoration: InputDecoration(
                hintText: draft.op == ConditionOp.glob
                    ? 'e.g. write_*'
                    : 'text',
              ),
              onChanged: (_) => onChanged(),
            ),
          ),
          IconButton(
            tooltip: 'Remove condition',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Live answer to "which tools does this hit?".
class _Preview extends StatelessWidget {
  const _Preview({required this.matches, required this.totalTools});

  final List<ToolRef> matches;
  final int totalTools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final none = matches.isEmpty;
    final color = none ? StatusColors.warn : StatusColors.info;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                none ? Icons.warning_amber_rounded : Icons.fact_check_outlined,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  none
                      ? totalTools == 0
                            ? 'No tools are connected right now, so nothing can be previewed. The rule still applies once servers connect.'
                            : 'This rule matches none of the $totalTools connected tools.'
                      : 'Applies to ${matches.length} of $totalTools connected tool${totalTools == 1 ? '' : 's'}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (!none) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final m in matches.take(12))
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      '${m.server.name} · ${m.tool.name}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                if (matches.length > 12)
                  Text(
                    '+${matches.length - 12} more',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ToolPicker extends ConsumerStatefulWidget {
  const _ToolPicker({required this.initial});
  final Set<String> initial;

  @override
  ConsumerState<_ToolPicker> createState() => _ToolPickerState();
}

class _ToolPickerState extends ConsumerState<_ToolPicker> {
  late final Set<String> _picked = {...widget.initial};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(mcpHubProvider).availableTools;
    final shown = [
      for (final t in all)
        if (_query.isEmpty ||
            t.tool.name.toLowerCase().contains(_query) ||
            t.server.name.toLowerCase().contains(_query))
          t,
    ];
    final shownKeys = [
      for (final t in shown) toolKey(t.server.id, t.tool.name),
    ];
    final allShownPicked =
        shownKeys.isNotEmpty && shownKeys.every(_picked.contains);

    return AlertDialog(
      title: const Text('Choose tools'),
      content: SizedBox(
        width: 480,
        height: 460,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search tools or servers',
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('Select all ${shownKeys.length} shown'),
              value: allShownPicked,
              onChanged: (on) => setState(
                () => on == true
                    ? _picked.addAll(shownKeys)
                    : _picked.removeAll(shownKeys),
              ),
            ),
            const Divider(),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No tools'))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final t = shown[i];
                        final key = toolKey(t.server.id, t.tool.name);
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(t.tool.name),
                          subtitle: Text(t.server.name),
                          value: _picked.contains(key),
                          onChanged: (on) => setState(
                            () => on == true
                                ? _picked.add(key)
                                : _picked.remove(key),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _picked),
          child: Text('Use ${_picked.length}'),
        ),
      ],
    );
  }
}
