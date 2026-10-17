import 'package:flutter/material.dart';

/// The slice of a list shown on one page, with the numbers a footer needs.
class PageRange {
  PageRange({required this.total, required int page, required this.pageSize})
    : pageCount = total == 0 ? 1 : ((total + pageSize - 1) ~/ pageSize),
      page = total == 0
          ? 0
          : page.clamp(0, ((total + pageSize - 1) ~/ pageSize) - 1);

  final int total;
  final int pageSize;
  final int pageCount;

  /// Zero-based, already clamped into range.
  final int page;

  int get start => page * pageSize;
  int get end => (start + pageSize) > total ? total : start + pageSize;
  bool get hasPrevious => page > 0;
  bool get hasNext => page < pageCount - 1;

  List<T> slice<T>(List<T> items) =>
      items.isEmpty ? <T>[] : items.sublist(start, end);

  /// "26–50 of 137", or "0 of 0".
  String get label => total == 0 ? '0 of 0' : '${start + 1}–$end of $total';
}

const pageSizeOptions = [10, 25, 50, 100];

/// Footer with rows-per-page, the visible range, and first/previous/next/last.
class PaginationBar extends StatelessWidget {
  const PaginationBar({
    super.key,
    required this.range,
    required this.onPage,
    required this.onPageSize,
  });

  final PageRange range;
  final ValueChanged<int> onPage;
  final ValueChanged<int> onPageSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 4,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Rows per page', style: muted),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: range.pageSize,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final n in pageSizeOptions)
                    DropdownMenuItem(value: n, child: Text('$n')),
                ],
                onChanged: (v) {
                  if (v != null) onPageSize(v);
                },
              ),
            ],
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(range.label, style: muted),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'First page',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.first_page),
                onPressed: range.hasPrevious ? () => onPage(0) : null,
              ),
              IconButton(
                tooltip: 'Previous page',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_left),
                onPressed: range.hasPrevious
                    ? () => onPage(range.page - 1)
                    : null,
              ),
              Text('${range.page + 1} / ${range.pageCount}', style: muted),
              IconButton(
                tooltip: 'Next page',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_right),
                onPressed: range.hasNext ? () => onPage(range.page + 1) : null,
              ),
              IconButton(
                tooltip: 'Last page',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.last_page),
                onPressed: range.hasNext
                    ? () => onPage(range.pageCount - 1)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
