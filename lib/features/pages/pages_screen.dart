import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../core/models/page.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../export/export_service.dart';
import '../export/export_sheet.dart';
import '../sections/sections_provider.dart';
import '../tabs/tabs_provider.dart';
import 'pages_provider.dart';

class PagesScreen extends ConsumerWidget {
  final String notebookId;
  final String sectionId;

  const PagesScreen({
    super.key,
    required this.notebookId,
    required this.sectionId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sectionAsync = ref.watch(sectionsProvider(notebookId));
    final pagesAsync = ref.watch(pagesProvider(sectionId));

    final sectionName = sectionAsync.whenOrNull(
          data: (sections) =>
              sections.where((s) => s.id == sectionId).firstOrNull?.name,
        ) ??
        'Section';

    return Scaffold(
      appBar: AppBar(
        title: Text(sectionName),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: pagesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (pages) {
          if (pages.isEmpty) {
            return _EmptyState(
              onCreateTap: () => _createPage(context, ref),
            );
          }
          return PagesList(
            pages: pages,
            notebookId: notebookId,
            sectionId: sectionId,
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createPage(context, ref),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _createPage(BuildContext context, WidgetRef ref) async {
    final page = await ref.read(pagesProvider(sectionId).notifier).create();
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

/// Reusable pages list — used by [PagesScreen] and [BrowsePane].
///
/// Handles tab-opening on tap and deletion via swipe-to-dismiss.
class PagesList extends ConsumerWidget {
  final List<NotePage> pages;
  final String notebookId;
  final String sectionId;

  const PagesList({
    super.key,
    required this.pages,
    required this.notebookId,
    required this.sectionId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView.builder(
      itemCount: pages.length,
      itemBuilder: (_, i) => _PageTile(
        page: pages[i],
        onTap: () {
          ref.read(tabsProvider.notifier).openTab(TabEntry(
            pageId: pages[i].id,
            sectionId: sectionId,
            notebookId: notebookId,
            title: pages[i].title,
          ));
        },
        onExport: () => showExportSheet(
          context,
          title: 'Export "${pages[i].title}"',
          showOutputChoice: false,
          onExport: (fmt, _) =>
              ExportService().exportPage(context, pages[i], fmt),
        ),
        onDelete: () {
          showConfirmDialog(
            context,
            title: 'Delete Page',
            message: 'Delete "${pages[i].title}"?',
            confirmColor: Colors.red,
          ).then((confirmed) {
            if (confirmed) {
              ref
                  .read(pagesProvider(sectionId).notifier)
                  .delete(pages[i].id);
            }
          });
        },
      ),
    );
  }
}

class _PageTile extends StatelessWidget {
  final NotePage page;
  final VoidCallback onTap;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  const _PageTile({
    required this.page,
    required this.onTap,
    required this.onExport,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final updated = DateTime.fromMillisecondsSinceEpoch(page.updatedAt);
    final formatted = DateFormat('MMM d, yyyy').format(updated);

    return Dismissible(
      key: ValueKey(page.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        onDelete();
        return false; // let provider handle the actual deletion
      },
      child: ListTile(
        leading: const Icon(Icons.article_outlined),
        title: Text(page.title),
        subtitle: Text(formatted),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
        onLongPress: onExport,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onCreateTap;

  const _EmptyState({required this.onCreateTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.article_outlined,
              size: 80,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text('No pages yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5),
                  )),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onCreateTap,
            icon: const Icon(Icons.add),
            label: const Text('Create Page'),
          ),
        ],
      ),
    );
  }
}
