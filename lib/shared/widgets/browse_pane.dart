import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/import/import_service.dart';
import '../../features/pages/pages_provider.dart';
import '../../features/pages/pages_screen.dart';
import '../../features/sections/sections_provider.dart';
import '../../features/tabs/tabs_provider.dart';
import '../providers/nav_state_provider.dart';
import '../providers/recent_pages_provider.dart';
import '../providers/starred_pages_provider.dart';

/// Centre pane shown in the wide-mode shell.
///
/// Shows the pages list for the currently selected section, or a placeholder
/// when no section is selected.  Has no [Scaffold] — raw content only.
class BrowsePane extends ConsumerWidget {
  const BrowsePane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navState = ref.watch(navStateProvider);
    final sectionId   = navState.selectedSectionId;
    final notebookId  = navState.selectedNotebookId;

    if (sectionId == null || notebookId == null) {
      return const _QuickAccessPane();
    }

    final pagesAsync   = ref.watch(pagesProvider(sectionId));
    final sectionAsync = ref.watch(sectionsProvider(notebookId));

    final sectionName = sectionAsync.whenOrNull(
          data: (sections) =>
              sections.where((s) => s.id == sectionId).firstOrNull?.name,
        ) ??
        'Section';

    final pageCount = pagesAsync.whenOrNull(data: (p) => p.length);

    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header bar
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sectionName,
                        style: Theme.of(context).textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (pageCount != null)
                        Text(
                          '$pageCount ${pageCount == 1 ? "page" : "pages"}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                    ],
                  ),
                ),
                // Import page button
                IconButton(
                  icon: const Icon(Icons.upload_file_outlined),
                  tooltip: 'Import page',
                  onPressed: () =>
                      _importPage(context, ref, notebookId, sectionId),
                ),
                // New page button
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'New page',
                  onPressed: () =>
                      _createPage(context, ref, notebookId, sectionId),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        // Pages list
        Expanded(
          child: pagesAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
            data: (pages) {
              if (pages.isEmpty) {
                return const _EmptyBrowsePlaceholder();
              }
              return PagesList(
                pages: pages,
                notebookId: notebookId,
                sectionId: sectionId,
              );
            },
          ),
        ),
      ],
      ),
    );
  }

  Future<void> _importPage(
    BuildContext context,
    WidgetRef ref,
    String notebookId,
    String sectionId,
  ) async {
    final result = await ImportService().pickAndParse();
    if (result == null || !context.mounted) return;
    final page = await ref
        .read(pagesProvider(sectionId).notifier)
        .create(title: result.title, content: result.deltaJson);
    if (context.mounted) {
      ref.read(tabsProvider.notifier).openTab(TabEntry(
        pageId: page.id,
        sectionId: sectionId,
        notebookId: notebookId,
        title: page.title,
      ));
    }
  }

  Future<void> _createPage(
    BuildContext context,
    WidgetRef ref,
    String notebookId,
    String sectionId,
  ) async {
    final page =
        await ref.read(pagesProvider(sectionId).notifier).create();
    if (context.mounted) {
      ref.read(tabsProvider.notifier).openTab(TabEntry(
        pageId: page.id,
        sectionId: sectionId,
        notebookId: notebookId,
        title: page.title,
      ));
    }
  }
}

// ── Quick-access pane (starred + recent) ─────────────────────────────────────

class _QuickAccessPane extends ConsumerWidget {
  const _QuickAccessPane();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs          = Theme.of(context).colorScheme;
    final starredIds  = ref.watch(starredPagesProvider).valueOrNull ?? {};
    final recentAsync = ref.watch(recentPagesProvider);
    final recent      = recentAsync.valueOrNull ?? [];
    final starred     = recent.where((r) => starredIds.contains(r.pageId)).toList();
    final nonStarred  = recent.where((r) => !starredIds.contains(r.pageId)).toList();

    if (recent.isEmpty && starredIds.isEmpty) {
      return Material(
        color: cs.surface,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_open_outlined,
                  size: 64, color: cs.onSurface.withOpacity(0.25)),
              const SizedBox(height: 12),
              Text(
                'Select a section',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface.withOpacity(0.45),
                    ),
              ),
            ],
          ),
        ),
      );
    }

    return Material(
      color: cs.surface,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (starred.isNotEmpty) ...[
            _SectionHeader(
                icon: Icons.star_outlined,
                color: Colors.amber.shade600,
                label: 'Starred'),
            ...starred.map((r) => _QuickTile(ref: r)),
          ],
          if (nonStarred.isNotEmpty) ...[
            _SectionHeader(
                icon: Icons.history,
                color: cs.onSurfaceVariant,
                label: 'Recent'),
            ...nonStarred.map((r) => _QuickTile(ref: r)),
          ],
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;

  const _SectionHeader(
      {required this.icon, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: cs.onSurfaceVariant, letterSpacing: 0.8),
          ),
        ],
      ),
    );
  }
}

class _QuickTile extends ConsumerWidget {
  final RecentPageRef ref;

  const _QuickTile({required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef widgetRef) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.article_outlined, size: 18),
      title: Text(ref.title, overflow: TextOverflow.ellipsis),
      onTap: () {
        widgetRef.read(tabsProvider.notifier).openTab(TabEntry(
              pageId: ref.pageId,
              sectionId: ref.sectionId,
              notebookId: ref.notebookId,
              title: ref.title,
            ));
      },
    );
  }
}

class _EmptyBrowsePlaceholder extends StatelessWidget {
  const _EmptyBrowsePlaceholder();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.article_outlined,
              size: 48, color: cs.onSurface.withOpacity(0.25)),
          const SizedBox(height: 12),
          Text(
            'No pages — tap + to create one',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withOpacity(0.45),
                ),
          ),
        ],
      ),
    );
  }
}
