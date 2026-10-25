import 'package:flutter/material.dart';

import '../engine/core/json.dart';

/// `expected_result` → `Expected result`.
String humanizeKey(String key) {
  final text = key.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  return text.isEmpty ? key : text[0].toUpperCase() + text.substring(1);
}

String _text(Object? v) => v is String ? v : '$v';

/// One labelled line.
class LabeledValue {
  const LabeledValue(this.label, this.value, {this.color});
  final String label;
  final String value;

  /// For a value that should stand out, such as an error.
  final Color? color;
}

/// The audit-only values a model supplied (a reason, what it expects, …) as
/// labelled lines.
List<LabeledValue> contextEntries(Json fields) => [
  for (final e in fields.entries)
    if (e.value != null && _text(e.value).trim().isNotEmpty)
      LabeledValue(humanizeKey(e.key), _text(e.value)),
];

/// Labels in one column, values in another.
///
/// [compact] is for a list row: no panel, one shortened line per value. The
/// default is for a dialog: a quiet panel, values that wrap and can be
/// selected.
class ContextFields extends StatelessWidget {
  const ContextFields(this.entries, {super.key, this.compact = false});
  final List<LabeledValue> entries;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final label = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final value = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.92),
    );
    final labelWidth = compact ? 104.0 : 128.0;

    final rows = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in entries)
          Padding(
            padding: EdgeInsets.symmetric(vertical: compact ? 1 : 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    e.label,
                    style: label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: compact
                      ? Text(
                          e.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: value?.copyWith(color: e.color),
                        )
                      : SelectableText(
                          e.value,
                          style: value?.copyWith(color: e.color),
                        ),
                ),
              ],
            ),
          ),
      ],
    );
    if (compact) return rows;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.35,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: rows,
    );
  }
}
