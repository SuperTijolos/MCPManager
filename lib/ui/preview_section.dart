import 'dart:convert';

import 'package:flutter/material.dart';

import '../engine/audit/audit_text.dart';
import '../engine/core/redact.dart' show previewWasShortened;
import 'widgets.dart';

/// One recorded value in the detail dialog. JSON that holds file contents or
/// other long text is shown as readable lines instead of one escaped string,
/// with a switch back to the raw JSON.
class PreviewSection extends StatefulWidget {
  const PreviewSection(this.label, this.text, this.maxHeight, {super.key});
  final String label;
  final String text;
  final double maxHeight;

  @override
  State<PreviewSection> createState() => _PreviewSectionState();
}

class _PreviewSectionState extends State<PreviewSection> {
  bool _raw = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parsed = parsePreview(widget.text);
    final bulky = parsed != null && hasBulkText(parsed);
    final readable = bulky && !_raw;
    final shown = parsed == null
        ? widget.text
        : readable
        ? readableValue(parsed)
        : const JsonEncoder.withIndent('  ').convert(parsed);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.label)),
              if (bulky)
                TextButton(
                  key: ValueKey('audit-raw-${widget.label}'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => setState(() => _raw = !_raw),
                  child: Text(readable ? 'Show raw JSON' : 'Show readable'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          CodeBlock(
            shown,
            maxHeight: widget.maxHeight,
            // Coloured only when it is JSON on screen, not the readable form.
            json: parsed != null && !readable,
          ),
          if (previewWasShortened(widget.text))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Shortened to keep the audit log small. The full text is not '
                'stored.',
                key: const ValueKey('audit-shortened-note'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
