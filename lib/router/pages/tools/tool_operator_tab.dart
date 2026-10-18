import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/rules/tool_rules.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'rule_dialog.dart';

/// How the Operator sees this tool: whether it is offered at all, extra
/// instructions, which rules apply, and where each argument comes from.
class ToolOperatorTab extends ConsumerStatefulWidget {
  const ToolOperatorTab({super.key, required this.toolRef});

  final ToolRef toolRef;

  @override
  ConsumerState<ToolOperatorTab> createState() => _ToolOperatorTabState();
}

class _ToolOperatorTabState extends ConsumerState<ToolOperatorTab> {
  late final TextEditingController _instructions;
  Timer? _debounce;

  String get _key =>
      toolKey(widget.toolRef.server.id, widget.toolRef.tool.name);

  @override
  void initState() {
    super.initState();
    _instructions = TextEditingController(
      text: ref.read(toolRulesProvider).overrides[_key]?.instructions ?? '',
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _instructions.dispose();
    super.dispose();
  }

  void _saveInstructions(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final store = ref.read(toolRulesProvider.notifier);
      final current =
          ref.read(toolRulesProvider).overrides[_key] ?? const ToolOverride();
      store.setOverride(_key, current.copyWith(instructions: text));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(toolRulesProvider);
    final server = widget.toolRef.server;
    final tool = widget.toolRef.tool;
    final effective = state.effective(server, tool);
    final override = state.overrides[_key] ?? const ToolOverride();
    final applied = [
      for (final r in state.rules)
        if (r.enabled && r.matches(server, tool)) r,
    ];
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final props = ((effective.inputSchema['properties'] as Map?) ?? const {})
        .cast<String, dynamic>();
    final requiredNames = {
      for (final r in (effective.inputSchema['required'] as List?) ?? const [])
        '$r',
    };
    final extraByName = {
      for (final e in effective.extras) e.arg.name.trim(): e,
    };

    return ListView(
      padding: const EdgeInsets.only(top: 12),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Offer this tool to the Operator'),
          subtitle: Text(
            override.hidden
                ? 'Hidden: the Operator cannot call it (you still can, from the Test tab).'
                : 'The Operator can call it, asking you first unless it is read-only.',
          ),
          value: !override.hidden,
          onChanged: (visible) => ref
              .read(toolRulesProvider.notifier)
              .setOverride(_key, override.copyWith(hidden: !visible)),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _instructions,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Extra instructions for this tool',
            helperText: 'Appended to its description for the Operator, e.g. "Never use on /etc."',
            alignLabelWithHint: true,
          ),
          onChanged: _saveInstructions,
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                'Rules that apply',
                style: theme.textTheme.titleSmall,
              ),
            ),
            TextButton.icon(
              onPressed: () => showRuleDialog(context, toolKeys: [_key]),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add argument'),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final p in rulePresets.take(4))
              ActionChip(
                avatar: const Icon(Icons.auto_awesome, size: 16),
                label: Text('+ ${p.name}'),
                onPressed: () =>
                    showRuleDialog(context, toolKeys: [_key], preset: p),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (applied.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('No rule changes this tool.', style: muted),
          )
        else
          for (final r in applied)
            Card(
              child: ListTile(
                dense: true,
                title: Text(r.name),
                subtitle: Text(
                  '${r.scopeSummary}${r.args.isEmpty ? '' : ' · ${r.args.map((a) => a.name).join(', ')}'}',
                ),
                trailing: Wrap(
                  children: [
                    IconButton(
                      tooltip: 'Edit rule',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => showRuleDialog(context, existing: r),
                    ),
                    IconButton(
                      tooltip: 'Turn rule off',
                      icon: const Icon(Icons.toggle_on_outlined, size: 22),
                      onPressed: () => ref
                          .read(toolRulesProvider.notifier)
                          .setEnabled(r.id, false),
                    ),
                  ],
                ),
              ),
            ),
        for (final w in effective.warnings)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: StatusColors.warn,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(w, style: muted)),
              ],
            ),
          ),
        const SizedBox(height: 20),
        Text(
          'Arguments the Operator provides',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final name in props.keys)
                _ArgRow(
                  name: name,
                  type: (props[name] as Map?)?['type']?.toString() ?? 'any',
                  required: requiredNames.contains(name),
                  origin: extraByName[name] == null
                      ? ('server', StatusColors.muted, Icons.dns_outlined)
                      : extraByName[name]!.arg.forward
                      ? (
                          '${extraByName[name]!.rule} · sent to the server',
                          StatusColors.info,
                          Icons.send_outlined,
                        )
                      : (
                          '${extraByName[name]!.rule} · audit only',
                          StatusColors.ok,
                          Icons.receipt_long_outlined,
                        ),
                ),
              for (final f in effective.fixed)
                _ArgRow(
                  name: f.arg.name,
                  type: f.arg.type,
                  required: false,
                  origin: (
                    '${f.rule} · fixed to ${f.arg.fixedValue}, hidden from the model',
                    StatusColors.warn,
                    Icons.lock_outline,
                  ),
                  dimmed: true,
                ),
              if (props.isEmpty && effective.fixed.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text('This tool takes no arguments.', style: muted),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ArgRow extends StatelessWidget {
  const _ArgRow({
    required this.name,
    required this.type,
    required this.required,
    required this.origin,
    this.dimmed = false,
  });

  final String name;
  final String type;
  final bool required;
  final (String, Color, IconData) origin;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: dimmed ? 0.75 : 1,
      child: ListTile(
        dense: true,
        title: Row(
          children: [
            Flexible(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamilyFallback: monoFonts),
              ),
            ),
            Flexible(
              child: Text(
                '  $type${required ? ' · required' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: StatusChip(origin.$1, origin.$2, icon: origin.$3),
        ),
      ),
    );
  }
}
