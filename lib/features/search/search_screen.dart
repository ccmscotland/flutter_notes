import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/page.dart';
import '../../core/database/pages_dao.dart';
import '../../core/database/sections_dao.dart';
import '../pages/pages_provider.dart';
import '../notebooks/notebooks_provider.dart';

final _searchResultsProvider =
    FutureProvider.family<List<NotePage>, String>((ref, query) async {
  if (query.trim().isEmpty) return [];
  final dao = PagesDao();
  return dao.search(query.trim());
});

/// Returns [TextSpan] children highlighting every occurrence of [query]
/// (case-insensitive) inside [text] using [highlightStyle].
List<TextSpan> _buildHighlightSpans(
  String text,
  String query,
  TextStyle highlightStyle,
) {
  if (query.isEmpty) return [TextSpan(text: text)];
  final lower = text.toLowerCase();
  final queryLower = query.toLowerCase();
  final spans = <TextSpan>[];
  int start = 0;

  while (true) {
    final idx = lower.indexOf(queryLower, start);
    if (idx == -1) {
      spans.add(TextSpan(text: text.substring(start)));
      break;
    }
    if (idx > start) {
      spans.add(TextSpan(text: text.substring(start, idx)));
    }
    spans.add(TextSpan(
      text: text.substring(idx, idx + query.length),
      style: highlightStyle,
    ));
    start = idx + query.length;
  }
  return spans;
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _ctrl = TextEditingController();
  String _query = '';
  Timer? _debounce;

  @override
  void dispose() {
    _ctrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final resultsAsync = ref.watch(_searchResultsProvider(_query));

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search notes...',
            border: InputBorder.none,
          ),
          onChanged: _onQueryChanged,
        ),
        actions: [
          if (_ctrl.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _ctrl.clear();
                setState(() => _query = '');
              },
            ),
        ],
      ),
      body: resultsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (pages) {
          if (_query.isEmpty) {
            return _SearchHint();
          }
          if (pages.isEmpty) {
            return Center(
              child: Text(
                'No results for "$_query"',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            );
          }
          return _SearchResultsList(pages: pages, query: _query);
        },
      ),
    );
  }
}

class _SearchHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search,
              size: 64,
              color:
                  Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 12),
          Text(
            'Search by title or content',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5),
                ),
          ),
        ],
      ),
    );
  }
}

class _SearchResultsList extends ConsumerWidget {
  final List<NotePage> pages;
  final String query;

  const _SearchResultsList({required this.pages, required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notebooksAsync = ref.watch(notebooksProvider);
    final notebooks = notebooksAsync.whenOrNull(data: (n) => n) ?? [];

    return ListView.separated(
      itemCount: pages.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final page = pages[i];
        return _SearchResultTile(
          page: page,
          query: query,
          notebooks: notebooks,
        );
      },
    );
  }
}

class _SearchResultTile extends ConsumerWidget {
  final NotePage page;
  final String query;
  final List notebooks;

  const _SearchResultTile({
    required this.page,
    required this.query,
    required this.notebooks,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final highlightStyle = TextStyle(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      fontWeight: FontWeight.bold,
    );

    // Extract a preview of the content (strip quill JSON)
    String contentPreview = '';
    try {
      contentPreview = _extractText(page.content);
    } catch (_) {}

    return ListTile(
      leading: const Icon(Icons.article_outlined),
      title: RichText(
        text: TextSpan(
          children: _buildHighlightSpans(page.title, query, highlightStyle),
          style: DefaultTextStyle.of(context).style,
        ),
      ),
      subtitle: contentPreview.isNotEmpty
          ? _HighlightedText(text: contentPreview, query: query, maxLines: 2)
          : null,
      onTap: () async {
        final sectionId = page.sectionId;
        final sectionsDao = SectionsDao();
        final section = await sectionsDao.getById(sectionId);
        if (section == null || !context.mounted) return;
        final notebookId = section.notebookId;
        context.push(
          '/notebook/$notebookId/section/$sectionId/page/${page.id}',
        );
      },
    );
  }

  String _extractText(String deltaJson) {
    if (deltaJson.isEmpty || deltaJson == '[]') return '';
    try {
      final ops = jsonDecode(deltaJson) as List;
      final buffer = StringBuffer();
      for (final op in ops) {
        if (op is Map && op['insert'] is String) {
          buffer.write(op['insert'] as String);
          if (buffer.length > 200) break;
        }
      }
      final text = buffer.toString().replaceAll('\n', ' ').trim();
      return text.length > 200 ? '${text.substring(0, 200)}...' : text;
    } catch (_) {
      return '';
    }
  }
}

class _HighlightedText extends StatelessWidget {
  final String text;
  final String query;
  final int maxLines;

  const _HighlightedText({
    required this.text,
    required this.query,
    this.maxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final highlightStyle = TextStyle(
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      fontWeight: FontWeight.bold,
    );

    return RichText(
      text: TextSpan(
        children: _buildHighlightSpans(text, query, highlightStyle),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
