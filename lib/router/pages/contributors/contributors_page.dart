import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/app_info.dart';
import '../../../ui/links.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

class ContributorsPage extends ConsumerWidget {
  const ContributorsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return PageScaffold(
      title: 'Contributors',
      subtitle: 'The people who built $appName',
      child: ListView(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 900
                  ? 3
                  : constraints.maxWidth >= 560
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - 16 * (columns - 1)) / columns;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final c in contributors)
                    SizedBox(
                      width: width,
                      child: _ContributorCard(contributor: c),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          Text(
            'Contributions to MCP Manager are recorded as co-authors on the project\'s commits.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () =>
                  openLink(context, ref, '$appRepoUrl/graphs/contributors'),
              icon: const Icon(Icons.groups_outlined, size: 18),
              label: const Text('All contributors on GitHub'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContributorCard extends ConsumerWidget {
  const _ContributorCard({required this.contributor});
  final Contributor contributor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final c = contributor;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openLink(context, ref, c.profileUrl),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              ClipOval(
                child: SizedBox(
                  width: 84,
                  height: 84,
                  child: Image.network(
                    c.avatarUrl,
                    fit: BoxFit.cover,
                    // Initials while loading, offline, or if the image is blocked.
                    errorBuilder: (_, _, _) => _Initials(c.initials),
                    loadingBuilder: (_, child, progress) =>
                        progress == null ? child : _Initials(c.initials),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(c.name, style: theme.textTheme.titleMedium),
              Text(
                '@${c.login}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              StatusChip(c.role, StatusColors.info),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => openLink(context, ref, c.profileUrl),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('GitHub profile'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.primary.withValues(alpha: 0.2),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      ),
    );
  }
}
