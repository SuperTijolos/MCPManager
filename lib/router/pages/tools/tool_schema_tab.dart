import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/core/json.dart';
import '../../../engine/core/line_diff.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

enum _View { original, effective, diff }

/// The tool's definition three ways: as the server sent it, as the Operator
/// sees it after rules, and the difference between the two.
class ToolSchemaTab extends ConsumerStatefulWidget {
  const ToolSchemaTab({super.key, required this.toolRef});

  final ToolRef toolRef;

  @override
  ConsumerState<ToolSchemaTab> createState() => _ToolSchemaTabState();
}

class _ToolSchemaTabState extends ConsumerState<ToolSchemaTab> {
  _View _view = _View.original;

  @override
  Widget build(BuildContext context) {
    final tool = widget.toolRef.tool;
    final effective = ref
        .watch(toolRulesProvider)
        .effective(widget.toolRef.server, tool);
    final original = prettyJson({
      'description': tool.description,
      'inputSchema': tool.inputSchema,
    });
    final operator = prettyJson({
      'description': effective.description,
      'inputSchema': effective.inputSchema,
    });
    final changed = original != operator;

    return ListView(
      padding: const EdgeInsets.only(top: 12),
      children: [
        SegmentedButton<_View>(
          showSelectedIcon: false,
          segments: [
            const ButtonSegment(
              value: _View.original,
              label: Text('Original'),
              icon: Icon(Icons.dns_outlined),
            ),
            const ButtonSegment(
              value: _View.effective,
              label: Text('Operator sees'),
              icon: Icon(Icons.smart_toy_outlined),
            ),
            ButtonSegment(
              value: _View.diff,
              label: Text(changed ? 'Diff' : 'Diff (none)'),
              icon: const Icon(Icons.difference_outlined),
            ),
          ],
          selected: {_view},
          onSelectionChanged: (s) => setState(() => _view = s.first),
        ),
        const SizedBox(height: 8),
        Text(switch (_view) {
          _View.original =>
            'Exactly what the server reports. This is never modified.',
          _View.effective => 'What the Operator is given: the original plus the effect of the rules below.',
          _View.diff =>
            changed
                ? 'Green lines are added for the Operator, red lines are removed from what it sees.'
                : 'No rule changes this tool.',
        }, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 10),
        if (_view == _View.original) CodeBlock(original, maxHeight: 520),
        if (_view == _View.effective) CodeBlock(operator, maxHeight: 520),
        if (_view == _View.diff) _DiffView(lineDiff(original, operator)),
        if (_view != _View.original && effective.warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final w in effective.warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: StatusColors.warn,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      w,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _DiffView extends StatelessWidget {
  const _DiffView(this.lines);
  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    if (!lines.any((l) => l.kind != DiffKind.same)) {
      return const CodeBlock('No differences.', maxHeight: 80);
    }
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 520),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant
              .withValues(alpha: 0.5),
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final l in lines)
                Container(
                  width: double.infinity,
                  color: switch (l.kind) {
                    DiffKind.added => StatusColors.ok.withValues(alpha: 0.14),
                    DiffKind.removed => StatusColors.bad.withValues(
                      alpha: 0.14,
                    ),
                    DiffKind.same => null,
                  },
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '${switch (l.kind) {
                      DiffKind.added => '+ ',
                      DiffKind.removed => '- ',
                      DiffKind.same => '  ',
                    }}${l.text}',
                    style: const TextStyle(
                      fontFamilyFallback: monoFonts,
                      fontSize: 12.5,
                      height: 1.45,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
