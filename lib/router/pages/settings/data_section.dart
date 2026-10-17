import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/agent/chat_controller.dart';
import '../../../engine/audit/audit_log.dart';
import '../../../engine/core/prefs.dart';
import '../../../engine/llm/llm_settings.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/mcp/oauth/oauth_service.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../engine/settings/app_settings.dart';
import '../../../engine/settings/backup.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Re-reads every store after the underlying storage changed (import/reset).
void reloadAllStores(WidgetRef ref) {
  ref
    ..invalidate(mcpHubProvider)
    ..invalidate(llmSettingsProvider)
    ..invalidate(toolRulesProvider)
    ..invalidate(appSettingsProvider)
    ..invalidate(auditLogProvider)
    ..invalidate(oauthSessionsProvider)
    ..invalidate(chatControllerProvider);
}

/// What is stored in this browser, backup and restore, and clean-up.
class DataSection extends ConsumerStatefulWidget {
  const DataSection({super.key});

  @override
  ConsumerState<DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends ConsumerState<DataSection> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Rebuild when the things being counted change.
    ref
      ..watch(auditLogProvider)
      ..watch(chatControllerProvider)
      ..watch(toolRulesProvider)
      ..watch(mcpHubProvider);
    final prefs = ref.read(sharedPreferencesProvider);
    final report = storageReport(prefs);
    final total = report.fold<int>(0, (sum, e) => sum + e.bytes);
    final fraction = (total / storageBudgetBytes).clamp(0.0, 1.0);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return ListView(
      children: [
        Text('Stored in this browser', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Everything lives in this browser\'s local storage: nothing is sent to a MCP Manager server. '
          'Tokens and API keys are kept here too, so use a browser profile you trust.',
          style: muted,
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in report)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(flex: 3, child: Text(e.label)),
                        Expanded(flex: 3, child: Text(e.detail, style: muted)),
                        Text(formatBytes(e.bytes)),
                      ],
                    ),
                  ),
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text('Total', style: theme.textTheme.titleSmall),
                    ),
                    Text(
                      '${formatBytes(total)} of about ${formatBytes(storageBudgetBytes)}',
                      style: theme.textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: fraction,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                  color: fraction > 0.8
                      ? StatusColors.warn
                      : theme.colorScheme.primary,
                ),
                if (fraction > 0.8)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Getting full. Clear the audit log or old conversations below.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: StatusColors.warn,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Backup', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Move your servers, providers, rules and settings to another browser or machine. '
                  'A backup leaves credentials out unless you ask for them.',
                  style: muted,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const _ExportDialog(),
                      ),
                      icon: const Icon(Icons.upload_outlined, size: 18),
                      label: const Text('Export…'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => const _ImportDialog(),
                      ),
                      icon: const Icon(Icons.download_outlined, size: 18),
                      label: const Text('Import…'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Clean up', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              _DangerTile(
                icon: Icons.receipt_long_outlined,
                title: 'Clear the audit log',
                subtitle: '${ref.watch(auditLogProvider).length} events',
                action: 'Clear',
                confirmTitle: 'Clear the audit log?',
                confirmBody:
                    'All recorded events are deleted from this browser.',
                onConfirmed: () => ref.read(auditLogProvider.notifier).clear(),
              ),
              const Divider(height: 1),
              _DangerTile(
                icon: Icons.chat_outlined,
                title: 'Delete all conversations',
                subtitle:
                    '${ref.watch(chatControllerProvider).conversations.length} saved',
                action: 'Delete',
                confirmTitle: 'Delete all conversations?',
                confirmBody: 'Every saved Operator conversation is removed.',
                onConfirmed: () =>
                    ref.read(chatControllerProvider.notifier).deleteAll(),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.restart_alt, color: StatusColors.bad),
                title: const Text('Reset everything'),
                subtitle: const Text(
                  'Servers, sign-ins, providers and keys, rules, conversations, audit log and settings.',
                ),
                trailing: OutlinedButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const _ResetDialog(),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: StatusColors.bad,
                  ),
                  child: const Text('Reset…'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DangerTile extends StatelessWidget {
  const _DangerTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
    required this.confirmTitle,
    required this.confirmBody,
    required this.onConfirmed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String action;
  final String confirmTitle;
  final String confirmBody;
  final VoidCallback onConfirmed;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: OutlinedButton(
        onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(confirmTitle),
              content: Text('$confirmBody This cannot be undone.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(action),
                ),
              ],
            ),
          );
          if (ok == true) onConfirmed();
        },
        child: Text(action),
      ),
    );
  }
}

class _ExportDialog extends ConsumerStatefulWidget {
  const _ExportDialog();

  @override
  ConsumerState<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends ConsumerState<_ExportDialog> {
  bool _credentials = false;
  bool _chats = false;
  bool _audit = false;

  String _json() => const JsonEncoder.withIndent('  ').convert(
    buildBackup(
      ref.read(sharedPreferencesProvider),
      includeCredentials: _credentials,
      includeChats: _chats,
      includeAudit: _audit,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = _json();
    return AlertDialog(
      title: const Text('Export a backup'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Always included: servers, providers and models, tool rules, settings.',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _chats,
                onChanged: (v) => setState(() => _chats = v ?? false),
                title: const Text('Conversations'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _audit,
                onChanged: (v) => setState(() => _audit = v ?? false),
                title: const Text('Audit log'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _credentials,
                onChanged: (v) => setState(() => _credentials = v ?? false),
                title: const Text('Credentials'),
                subtitle: const Text(
                  'Bearer tokens, API keys and OAuth sign-ins',
                ),
              ),
              if (_credentials)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'This backup will contain secrets. Treat it like a password and do not share it.',
                    style: TextStyle(color: StatusColors.warn),
                  ),
                ),
              const SizedBox(height: 8),
              CodeBlock(text, maxHeight: 240),
              const SizedBox(height: 4),
              Text(formatBytes(text.length)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            showSnack(context, 'Backup copied to the clipboard');
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy'),
        ),
      ],
    );
  }
}

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog();

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _text = TextEditingController();
  String? _error;
  List<String> _sections = const [];
  bool _credentials = true;
  Map<String, dynamic>? _data;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _check() {
    final parsed = parseBackup(_text.text.trim());
    setState(() {
      _error = parsed.error;
      _data = parsed.data;
      _sections = parsed.data == null ? const [] : describeBackup(parsed.data!);
      _credentials = parsed.data?['includesCredentials'] == true;
      if (parsed.data != null && _sections.isEmpty) {
        _error = 'The backup contains nothing to restore.';
        _data = null;
      }
    });
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    final result = await restoreBackup(
      ref.read(sharedPreferencesProvider),
      _data!,
    );
    if (!mounted) return;
    if (result.ok) {
      reloadAllStores(ref);
      Navigator.pop(context);
      showSnack(context, 'Restored: ${result.restored.join(', ')}');
    } else {
      setState(() {
        _busy = false;
        _error = result.problems.join(' ');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Import a backup'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste the JSON from an export. Only the sections it contains are replaced.',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _text,
                minLines: 6,
                maxLines: 10,
                style: const TextStyle(
                  fontFamilyFallback: monoFonts,
                  fontSize: 12,
                ),
                decoration: const InputDecoration(
                  hintText: '{ "format": "mcp-manager-backup", … }',
                ),
                onChanged: (_) => setState(() {
                  _error = null;
                  _data = null;
                  _sections = const [];
                }),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: StatusColors.bad),
                  ),
                ),
              if (_data != null) ...[
                const SizedBox(height: 12),
                Text(
                  'This will replace:',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                for (final s in _sections) Text('• $s'),
                if (!_credentials)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'This backup has no credentials: servers will need their tokens or sign-in again. '
                      'API keys already stored here are kept.',
                      style: TextStyle(color: StatusColors.warn),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (_data == null)
          FilledButton(
            onPressed: _text.text.trim().isEmpty ? null : _check,
            child: const Text('Check'),
          )
        else
          FilledButton(
            onPressed: _busy ? null : _import,
            child: const Text('Import'),
          ),
      ],
    );
  }
}

class _ResetDialog extends ConsumerStatefulWidget {
  const _ResetDialog();

  @override
  ConsumerState<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends ConsumerState<_ResetDialog> {
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final armed = _confirm.text.trim() == 'RESET';
    return AlertDialog(
      title: const Text('Reset everything?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This deletes all MCP Manager data in this browser: servers, sign-ins, providers and keys, '
              'rules, conversations, the audit log and settings. It cannot be undone. Export a backup first if you might need it.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              decoration: const InputDecoration(
                labelText: 'Type RESET to confirm',
              ),
              onChanged: (_) => setState(() {}),
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
          style: FilledButton.styleFrom(backgroundColor: StatusColors.bad),
          onPressed: !armed
              ? null
              : () async {
                  await resetAll(ref.read(sharedPreferencesProvider));
                  reloadAllStores(ref);
                  if (context.mounted) {
                    Navigator.pop(context);
                    showSnack(context, 'Everything was reset');
                  }
                },
          child: const Text('Reset'),
        ),
      ],
    );
  }
}
