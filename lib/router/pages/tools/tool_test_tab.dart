import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/audit/audit_models.dart';
import '../../../engine/core/json.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/mcp/mcp_models.dart';
import '../../../engine/mcp/schema.dart';
import '../../../engine/rules/tool_rules.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/json_syntax.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Run a tool by hand: edit the arguments, press Run, read the result.
///
/// With "Apply rules" on (the default when rules apply) the call goes through
/// the same path as the Operator's: extra arguments are required and recorded,
/// audit-only ones are stripped, fixed values are injected.
class ToolTestTab extends ConsumerStatefulWidget {
  const ToolTestTab({super.key, required this.toolRef});

  final ToolRef toolRef;

  @override
  ConsumerState<ToolTestTab> createState() => _ToolTestTabState();
}

class _ToolTestTabState extends ConsumerState<ToolTestTab> {
  late final JsonEditingController _args = JsonEditingController();
  bool _applyRules = true;
  McpToolResult? _result;
  Json? _forwarded;
  int? _durationMs;
  String? _argsError;
  bool _running = false;

  /// Confirmed once for this tool in this panel; switching tools asks again.
  bool _confirmedWrite = false;

  McpTool get _tool => widget.toolRef.tool;

  EffectiveTool get _effective =>
      ref.read(toolRulesProvider).effective(widget.toolRef.server, _tool);

  @override
  void initState() {
    super.initState();
    _applyRules = _effective.extras.isNotEmpty || _effective.fixed.isNotEmpty;
    _resetTemplate();
  }

  @override
  void dispose() {
    _args.dispose();
    super.dispose();
  }

  void _resetTemplate() {
    final schema = _applyRules ? _effective.inputSchema : _tool.inputSchema;
    _args.text = prettyJson(skeletonFromSchema(schema));
  }

  Future<void> _run() async {
    final parsed = tryDecodeObject(
      _args.text.trim().isEmpty ? '{}' : _args.text,
    );
    if (parsed == null) {
      setState(() => _argsError = 'Arguments must be a valid JSON object.');
      return;
    }
    final effective = _effective;
    final prepared = _applyRules ? prepareCall(effective, parsed) : null;
    if (prepared?.error != null) {
      setState(() {
        _argsError = null;
        _forwarded = null;
        _result = McpToolResult.error(prepared!.error!);
        _durationMs = 0;
      });
      return;
    }

    final rules = ref.read(toolRulesProvider);
    final safety = rules.safety(widget.toolRef.server, _tool);
    if (!_confirmedWrite && !rules.isReadOnly(widget.toolRef.server, _tool)) {
      final go = await _confirmRun(safety, prepared?.forwarded ?? parsed);
      if (go != true || !mounted) return;
      _confirmedWrite = true;
    }

    setState(() {
      _argsError = null;
      _running = true;
      _result = null;
      _forwarded = prepared?.forwarded;
    });
    final watch = Stopwatch()..start();
    final result = await ref
        .read(mcpHubProvider.notifier)
        .callTool(
          serverId: widget.toolRef.server.id,
          toolName: _tool.name,
          args: prepared?.forwarded ?? parsed,
          clientArgs: prepared == null ? null : parsed,
          context: prepared?.context,
          source: AuditSource.workbench,
          actor: 'user',
        );
    watch.stop();
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
      _durationMs = watch.elapsedMilliseconds;
    });
  }

  /// Nothing stops a click from running `delete_file` with the template's
  /// placeholder values, so ask first unless the tool is known to only read.
  Future<bool?> _confirmRun(ToolSafety safety, Json args) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Run ${_tool.displayName}?'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              safety == ToolSafety.mayModify
                  ? 'The server says this tool may modify data.'
                  : 'The server does not say whether this tool changes '
                        'anything, so it might.',
            ),
            const SizedBox(height: 10),
            Text('It will be called on ${widget.toolRef.server.name} with:'),
            const SizedBox(height: 6),
            JsonBlock(args, maxHeight: 160),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Run'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effective = ref
        .watch(toolRulesProvider)
        .effective(widget.toolRef.server, _tool);
    final hasRules = effective.extras.isNotEmpty || effective.fixed.isNotEmpty;
    final result = _result;
    var output = result?.text ?? '';
    final asJson = result == null ? null : tryDecodeJson(output);
    if (asJson != null) output = prettyJson(asJson);

    return ListView(
      padding: const EdgeInsets.only(top: 12),
      children: [
        if (hasRules)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Apply rules (as the Operator would)'),
            subtitle: Text(
              effective.extras.isEmpty
                  ? 'Fixed values are injected and hidden.'
                  : 'Also fill in: ${effective.extras.map((e) => e.arg.name).join(', ')}',
            ),
            value: _applyRules,
            onChanged: (v) => setState(() {
              _applyRules = v;
              _resetTemplate();
            }),
          ),
        Text('Arguments (JSON)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        TextField(
          controller: _args,
          minLines: 4,
          maxLines: 12,
          cursorColor: theme.colorScheme.primary,
          style: const TextStyle(
            fontFamilyFallback: monoFonts,
            fontSize: 12.5,
            height: 1.4,
            color: Color(0xFFE6EDF3),
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: kCodePanelBackground,
            contentPadding: const EdgeInsets.all(10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: theme.colorScheme.primary),
            ),
            errorText: _argsError,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _running ? null : _run,
              icon: _running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('Run'),
            ),
            const SizedBox(width: 12),
            if (result != null) ...[
              StatusChip(
                result.isError ? 'error' : 'ok',
                result.isError ? StatusColors.bad : StatusColors.ok,
              ),
              const SizedBox(width: 8),
              Text('$_durationMs ms', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
        if (_forwarded != null && result != null) ...[
          const SizedBox(height: 12),
          Text('Sent to the server', style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          JsonBlock(_forwarded, maxHeight: 140),
        ],
        if (result != null) ...[
          const SizedBox(height: 12),
          CodeBlock(output, maxHeight: 360),
        ],
      ],
    );
  }
}
