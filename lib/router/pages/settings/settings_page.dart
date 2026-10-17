import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/core/ids.dart';
import '../../../engine/core/url.dart';
import '../../../engine/llm/llm_settings.dart';
import '../../../engine/llm/llm_types.dart';
import '../../../engine/llm/provider_config.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(llmSettingsProvider);
    final notifier = ref.read(llmSettingsProvider.notifier);

    return PageScaffold(
      title: 'Settings',
      subtitle: 'Model providers for the Operator',
      actions: [
        FilledButton.icon(
          onPressed: () => showProviderDialog(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('Add provider'),
        ),
      ],
      child: ListView(
        children: [
          for (final p in settings.providers) ...[
            _ProviderCard(
              provider: p,
              active: p.id == settings.activeProviderId,
              activeModel: settings.activeModel,
              onUse: (model) => notifier.setActive(p.id, model),
            ),
            const SizedBox(height: 12),
          ],
          if (settings.providers.isEmpty)
            const SizedBox(
              height: 240,
              child: EmptyState(
                icon: Icons.memory,
                title: 'No providers',
                message:
                    'Add Ollama (Gemma 4) or any OpenAI-compatible endpoint.',
              ),
            ),
          const _CorsHelp(),
        ],
      ),
    );
  }
}

class _ProviderCard extends ConsumerWidget {
  const _ProviderCard({
    required this.provider,
    required this.active,
    required this.activeModel,
    required this.onUse,
  });

  final ProviderConfig provider;
  final bool active;
  final String? activeModel;
  final ValueChanged<String> onUse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(llmSettingsProvider.notifier);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(provider.name, style: theme.textTheme.titleMedium),
                      Text(
                        '${provider.kind.label} · ${provider.baseUrl}',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (active)
                  const StatusChip(
                    'active',
                    StatusColors.ok,
                    icon: Icons.check,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Enabled models', style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            if (provider.models.isEmpty)
              Text(
                'None yet — use "Manage models" to discover or add one.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: StatusColors.warn,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final m in provider.models)
                    ChoiceChip(
                      label: Text(m),
                      selected: active && m == activeModel,
                      onSelected: (_) => onUse(m),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => _ModelsDialog(provider: provider),
                  ),
                  icon: const Icon(Icons.checklist_rounded, size: 18),
                  label: const Text('Manage models'),
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () =>
                      showProviderDialog(context, ref, existing: provider),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => notifier.remove(provider.id),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CorsHelp extends StatelessWidget {
  const _CorsHelp();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Using Ollama from the browser',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            const Text(
              'The browser blocks requests to Ollama unless it allows this origin. '
              'Restart Ollama with:',
            ),
            const SizedBox(height: 8),
            const CodeBlock(
              'OLLAMA_ORIGINS="*" OLLAMA_HOST=0.0.0.0 ollama serve',
              maxHeight: 80,
            ),
            const SizedBox(height: 8),
            const Text(
              'Then pull the model once: ollama pull gemma4 (use the exact tag shown by ollama list). '
              'Tool calling needs a model with the "tools" capability.',
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showProviderDialog(
  BuildContext context,
  WidgetRef ref, {
  ProviderConfig? existing,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ProviderDialog(existing: existing),
  );
}

class _ProviderDialog extends ConsumerStatefulWidget {
  const _ProviderDialog({this.existing});
  final ProviderConfig? existing;

  @override
  ConsumerState<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends ConsumerState<_ProviderDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late ProviderKind _kind;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    _kind = p?.kind ?? ProviderKind.ollama;
    _name = TextEditingController(text: p?.name ?? '');
    _url = TextEditingController(text: p?.baseUrl ?? '');
    _key = TextEditingController(text: p?.apiKey ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  String get _urlHint => _kind == ProviderKind.ollama
      ? 'http://localhost:11434'
      : 'https://host/v1';

  void _save() {
    if (!_form.currentState!.validate()) return;
    final existing = widget.existing;
    final key = _key.text.trim();
    final url = normalizeBaseUrl(_url.text);
    final notifier = ref.read(llmSettingsProvider.notifier);
    if (existing == null) {
      notifier.upsert(
        ProviderConfig(
          id: newId('llm'),
          name: _name.text.trim(),
          kind: _kind,
          baseUrl: url,
          apiKey: key.isEmpty ? null : key,
          models: _kind == ProviderKind.ollama
              ? const [defaultOllamaModel]
              : const [],
        ),
      );
    } else {
      notifier.upsert(
        existing.copyWith(
          name: _name.text.trim(),
          kind: _kind,
          baseUrl: url,
          apiKey: key.isEmpty ? null : key,
          clearApiKey: key.isEmpty,
        ),
      );
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add provider' : 'Edit provider'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<ProviderKind>(
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: [
                    for (final k in ProviderKind.values)
                      DropdownMenuItem(value: k, child: Text(k.label)),
                  ],
                  onChanged: (v) => setState(() => _kind = v ?? _kind),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Base URL',
                    hintText: _urlHint,
                  ),
                  validator: (v) => isValidHttpUrl(normalizeBaseUrl(v ?? ''))
                      ? null
                      : 'Enter a valid http(s) URL',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _key,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API key (optional)',
                    helperText: 'Stored in this browser only.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _ModelsDialog extends ConsumerStatefulWidget {
  const _ModelsDialog({required this.provider});
  final ProviderConfig provider;

  @override
  ConsumerState<_ModelsDialog> createState() => _ModelsDialogState();
}

class _ModelsDialogState extends ConsumerState<_ModelsDialog> {
  late final Set<String> _enabled = {...widget.provider.models};
  final _custom = TextEditingController();
  List<LlmModel> _discovered = const [];
  String? _error;
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _discover();
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _discover() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final provider = ref.read(llmProviderFactoryProvider)(widget.provider);
    try {
      final models = await provider.listModels();
      if (mounted) setState(() => _discovered = models);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      provider.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  void _addCustom() {
    final name = _custom.text.trim();
    if (name.isEmpty) return;
    setState(() {
      _enabled.add(name);
      _custom.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final names = <String, LlmModel?>{
      for (final m in _discovered) m.name: m,
      for (final m in _enabled) m: null,
    };
    for (final m in _discovered) {
      names[m.name] = m;
    }
    final visible =
        names.keys.where((n) => n.toLowerCase().contains(_query)).toList()
          ..sort();

    return AlertDialog(
      title: Text('Models · ${widget.provider.name}'),
      content: SizedBox(
        width: 460,
        height: 460,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _custom,
                    decoration: const InputDecoration(
                      labelText: 'Add a model by name',
                      hintText: 'e.g. gemma4:e4b',
                    ),
                    onSubmitted: (_) => _addCustom(),
                  ),
                ),
                IconButton(onPressed: _addCustom, icon: const Icon(Icons.add)),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Filter',
              ),
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Could not list models: $_error',
                  style: const TextStyle(
                    color: StatusColors.bad,
                    fontSize: 12.5,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : visible.isEmpty
                  ? const Center(child: Text('No models'))
                  : ListView(
                      children: [
                        for (final name in visible)
                          CheckboxListTile(
                            dense: true,
                            value: _enabled.contains(name),
                            title: Text(name),
                            subtitle: switch (names[name]?.supportsTools) {
                              false => const Text(
                                'No tool support — the Operator cannot call tools',
                              ),
                              null when names[name] == null => const Text(
                                'Not found on the server',
                              ),
                              _ => null,
                            },
                            onChanged: (v) => setState(
                              () => v == true
                                  ? _enabled.add(name)
                                  : _enabled.remove(name),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : _discover,
          child: const Text('Refresh'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            ref
                .read(llmSettingsProvider.notifier)
                .upsert(
                  widget.provider.copyWith(models: _enabled.toList()..sort()),
                );
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
