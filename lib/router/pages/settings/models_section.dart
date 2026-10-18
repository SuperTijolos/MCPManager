import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/llm/llm_settings.dart';
import '../../../engine/llm/provider_config.dart';
import '../../../engine/llm/provider_presets.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'provider_dialogs.dart';

/// Where the Operator's model comes from: providers, which models are on, and
/// which one is active.
class ModelsSection extends ConsumerWidget {
  const ModelsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(llmSettingsProvider);
    final theme = Theme.of(context);

    return ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Model providers',
                style: theme.textTheme.titleMedium,
              ),
            ),
            PopupMenuButton<ProviderPreset>(
              tooltip: 'Add a provider',
              onSelected: (p) => showProviderDialog(context, preset: p),
              itemBuilder: (_) => [
                for (final p in providerPresets)
                  PopupMenuItem(
                    value: p,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.label),
                        Text(p.description, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
              ],
              child: const Chip(
                avatar: Icon(Icons.add, size: 18),
                label: Text('Add provider'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (settings.providers.isEmpty)
          const SizedBox(
            height: 220,
            child: EmptyState(
              icon: Icons.memory,
              title: 'No providers',
              message: 'Add Ollama (Gemma 4), or any OpenAI-compatible endpoint, with "Add provider".',
            ),
          ),
        for (final p in settings.providers) ...[
          ProviderCard(
            provider: p,
            active: p.id == settings.activeProviderId,
            activeModel: settings.activeModel,
          ),
          const SizedBox(height: 12),
        ],
        const _CorsHelp(),
      ],
    );
  }
}

class ProviderCard extends ConsumerStatefulWidget {
  const ProviderCard({
    super.key,
    required this.provider,
    required this.active,
    required this.activeModel,
  });

  final ProviderConfig provider;
  final bool active;
  final String? activeModel;

  @override
  ConsumerState<ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends ConsumerState<ProviderCard> {
  bool _checking = false;
  String? _result;
  bool _ok = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    final provider = ref.read(llmProviderFactoryProvider)(widget.provider);
    try {
      final models = await provider.listModels();
      final missing = [
        for (final m in widget.provider.models)
          if (!models.any((x) => x.name == m || x.name.split(':').first == m))
            m,
      ];
      if (!mounted) return;
      setState(() {
        _ok = missing.isEmpty;
        _result = missing.isEmpty
            ? 'Reachable · ${models.length} model${models.length == 1 ? '' : 's'}'
            : 'Reachable, but not installed: ${missing.join(', ')}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = '$e';
      });
    } finally {
      provider.close();
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final keyFormatError =
        p.kind == ProviderKind.openaiCompatible &&
            Uri.tryParse(p.baseUrl)?.host.toLowerCase() == 'openrouter.ai'
        ? openRouterKeyProblem(p.apiKey)
        : null;
    final theme = Theme.of(context);
    final store = ref.read(llmSettingsProvider.notifier);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: theme.textTheme.titleMedium),
                      Text(
                        '${p.kind.label} · ${p.baseUrl}',
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ],
                  ),
                ),
                if (widget.active)
                  const StatusChip(
                    'active',
                    StatusColors.ok,
                    icon: Icons.check,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                StatusChip(
                  p.bearerKey.isEmpty
                      ? 'no API key'
                      : keyFormatError != null
                      ? 'invalid API key format'
                      : 'API key set',
                  keyFormatError != null
                      ? StatusColors.bad
                      : StatusColors.muted,
                  icon: Icons.vpn_key_outlined,
                ),
                if (p.kind == ProviderKind.ollama)
                  StatusChip(
                    'context ${p.contextLength ?? defaultOllamaContext}',
                    StatusColors.muted,
                    icon: Icons.memory,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Enabled models', style: muted),
            const SizedBox(height: 6),
            if (p.models.isEmpty)
              Text(
                'None yet. Use "Manage models" to discover or add one.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: StatusColors.warn,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final m in p.models)
                    ChoiceChip(
                      label: Text(m),
                      selected: widget.active && m == widget.activeModel,
                      onSelected: (_) => store.setActive(p.id, m),
                    ),
                ],
              ),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _ok ? Icons.check_circle_outline : Icons.error_outline,
                      size: 16,
                      color: _ok ? StatusColors.ok : StatusColors.bad,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _result!,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: _ok ? StatusColors.ok : StatusColors.bad,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _checking ? null : _check,
                  icon: _checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check, size: 18),
                  label: const Text('Check'),
                ),
                OutlinedButton.icon(
                  onPressed: () => showModelsDialog(context, p),
                  icon: const Icon(Icons.checklist_rounded, size: 18),
                  label: const Text('Manage models'),
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => showProviderDialog(context, existing: p),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmRemove(context, store),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    LlmSettingsNotifier store,
  ) async {
    final p = widget.provider;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${p.name}?'),
        content: const Text(
          'Its saved settings and API key are deleted from this browser.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) store.remove(p.id);
  }
}

class _CorsHelp extends StatelessWidget {
  const _CorsHelp();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: const ExpansionTile(
          leading: Icon(Icons.help_outline),
          title: Text('Using Ollama from the browser'),
          childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The browser blocks requests to Ollama unless it allows this origin. Restart Ollama with:',
            ),
            SizedBox(height: 8),
            CodeBlock(
              'OLLAMA_ORIGINS="*" OLLAMA_HOST=0.0.0.0 ollama serve',
              maxHeight: 80,
            ),
            SizedBox(height: 8),
            Text(
              'Then pull the model once: ollama pull gemma4 (use the exact tag shown by ollama list). '
              'Tool calling needs a model with the "tools" capability.',
            ),
          ],
        ),
      ),
    );
  }
}
