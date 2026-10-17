import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/core/ids.dart';
import '../../../engine/core/url.dart';
import '../../../engine/llm/llm_settings.dart';
import '../../../engine/llm/llm_types.dart';
import '../../../engine/llm/provider_config.dart';
import '../../../engine/llm/provider_presets.dart';
import '../../../ui/theme.dart';

/// Add a provider (optionally from a [preset]) or edit [existing].
Future<void> showProviderDialog(
  BuildContext context, {
  ProviderConfig? existing,
  ProviderPreset? preset,
}) => showDialog<void>(
  context: context,
  builder: (_) => ProviderDialog(existing: existing, preset: preset),
);

class ProviderDialog extends ConsumerStatefulWidget {
  const ProviderDialog({super.key, this.existing, this.preset});
  final ProviderConfig? existing;
  final ProviderPreset? preset;

  @override
  ConsumerState<ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends ConsumerState<ProviderDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _context;
  late ProviderKind _kind;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    final p = widget.existing;
    final preset = widget.preset;
    _kind = p?.kind ?? preset?.kind ?? ProviderKind.ollama;
    _name = TextEditingController(text: p?.name ?? preset?.name ?? '');
    _url = TextEditingController(text: p?.baseUrl ?? preset?.baseUrl ?? '');
    _key = TextEditingController(text: p?.apiKey ?? '');
    _context = TextEditingController(
      text: '${p?.contextLength ?? defaultOllamaContext}',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    _context.dispose();
    super.dispose();
  }

  String get _urlHint =>
      widget.preset?.urlHint ??
      (_kind == ProviderKind.ollama
          ? 'http://localhost:11434'
          : 'https://host/v1');

  void _save() {
    if (!_form.currentState!.validate()) return;
    final existing = widget.existing;
    final key = normalizeApiKey(_key.text);
    final url = normalizeBaseUrl(_url.text);
    final notifier = ref.read(llmSettingsProvider.notifier);
    final numCtx = _kind == ProviderKind.ollama
        ? int.tryParse(_context.text.trim())
        : null;
    if (existing == null) {
      notifier.upsert(
        ProviderConfig(
          id: newId('llm'),
          name: _name.text.trim(),
          kind: _kind,
          baseUrl: url,
          apiKey: key.isEmpty ? null : key,
          models:
              widget.preset?.models ??
              (_kind == ProviderKind.ollama
                  ? const [defaultOllamaModel]
                  : const []),
          contextLength: numCtx,
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
          contextLength: numCtx,
          clearContextLength: numCtx == null,
        ),
      );
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final preset = widget.preset;
    return AlertDialog(
      title: Text(
        widget.existing != null
            ? 'Edit provider'
            : preset != null
            ? 'Add ${preset.label}'
            : 'Add provider',
      ),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (preset != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        preset.description,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                DropdownButtonFormField<ProviderKind>(
                  initialValue: _kind,
                  isExpanded: true,
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
                  obscureText: !_showKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText:
                        preset?.needsKey == true ||
                            providerRequiresApiKey(
                              _kind,
                              normalizeBaseUrl(_url.text),
                            )
                        ? 'API key'
                        : 'API key (optional)',
                    helperText: 'Stored in this browser only. Paste a key with or without Bearer.',
                    suffixIcon: IconButton(
                      tooltip: _showKey ? 'Hide key' : 'Show key',
                      icon: Icon(
                        _showKey
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _showKey = !_showKey),
                    ),
                  ),
                  validator: (v) =>
                      (preset?.needsKey == true ||
                              providerRequiresApiKey(
                                _kind,
                                normalizeBaseUrl(_url.text),
                              )) &&
                          normalizeApiKey(v).isEmpty
                      ? 'This service needs a key'
                      : null,
                ),
                if (_kind == ProviderKind.ollama) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _context,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Context window (tokens)',
                      helperText:
                          'Ollama\'s own default is small; the Operator\'s tool list needs a few thousand. Empty = $defaultOllamaContext. Larger uses more memory.',
                      helperMaxLines: 3,
                    ),
                    validator: (v) {
                      final text = (v ?? '').trim();
                      if (text.isEmpty) return null;
                      final n = int.tryParse(text);
                      return n == null || n < 1024 || n > 1048576
                          ? 'Enter 1024 or more, or leave empty for the default'
                          : null;
                    },
                  ),
                ],
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

/// Discover what a provider offers and choose which models the picker shows.
Future<void> showModelsDialog(BuildContext context, ProviderConfig provider) =>
    showDialog<void>(
      context: context,
      builder: (_) => ModelsDialog(provider: provider),
    );

class ModelsDialog extends ConsumerStatefulWidget {
  const ModelsDialog({super.key, required this.provider});
  final ProviderConfig provider;

  @override
  ConsumerState<ModelsDialog> createState() => _ModelsDialogState();
}

class _ModelsDialogState extends ConsumerState<ModelsDialog> {
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
    final byName = {for (final m in _discovered) m.name: m};
    final names = {...byName.keys, ..._enabled};
    final visible =
        names.where((n) => n.toLowerCase().contains(_query)).toList()..sort();
    final allVisibleOn = visible.isNotEmpty && visible.every(_enabled.contains);

    return AlertDialog(
      title: Text('Models · ${widget.provider.name}'),
      content: SizedBox(
        width: 480,
        height: 480,
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
                IconButton(
                  tooltip: 'Add',
                  onPressed: _addCustom,
                  icon: const Icon(Icons.add),
                ),
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
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${_enabled.length} enabled · ${visible.length} shown',
              ),
              value: allVisibleOn,
              onChanged: visible.isEmpty
                  ? null
                  : (on) => setState(
                      () => on == true
                          ? _enabled.addAll(visible)
                          : _enabled.removeAll(visible),
                    ),
            ),
            const Divider(),
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
                            contentPadding: EdgeInsets.zero,
                            value: _enabled.contains(name),
                            title: Text(name),
                            subtitle: _subtitle(byName[name], name),
                            secondary: _badge(byName[name]),
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

  Widget? _subtitle(LlmModel? model, String name) {
    if (model == null && !_loading && _error == null) {
      return const Text('Not found on the server');
    }
    if (model?.supportsTools == false) {
      return const Text('No tool support: the Operator cannot call tools');
    }
    return null;
  }

  Widget? _badge(LlmModel? model) => switch (model?.supportsTools) {
    true => const Tooltip(
      message: 'Supports tools',
      child: Icon(
        Icons.build_circle_outlined,
        size: 18,
        color: StatusColors.ok,
      ),
    ),
    false => const Tooltip(
      message: 'No tool support',
      child: Icon(Icons.block, size: 18, color: StatusColors.warn),
    ),
    null => null,
  };
}
