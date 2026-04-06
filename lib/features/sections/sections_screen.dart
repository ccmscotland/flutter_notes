import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/section.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/color_picker_dialog.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../export/export_service.dart';
import '../export/export_sheet.dart';
import '../notebooks/notebooks_provider.dart';
import '../pages/pages_provider.dart';
import '../pages/pages_screen.dart';
import '../tabs/tabs_provider.dart';
import 'sections_provider.dart';

/// Shows the contents of a notebook: top-level pages directly, plus
/// expandable sections (OneNote-style).  No separate "sections list" screen —
/// everything is visible in one scrollable view.
class SectionsScreen extends ConsumerStatefulWidget {
  final String notebookId;

  const SectionsScreen({super.key, required this.notebookId});

  @override
  ConsumerState<SectionsScreen> createState() => _SectionsScreenState();
}

class _SectionsScreenState extends ConsumerState<SectionsScreen> {
  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final notebookAsync  = ref.watch(notebooksProvider);
    final sectionsAsync  = ref.watch(sectionsProvider(widget.notebookId));
    final defaultIdAsync = ref.watch(defaultSectionIdProvider(widget.notebookId));

    final notebookName = notebookAsync.whenOrNull(
          data: (nbs) =>
              nbs.where((n) => n.id == widget.notebookId).firstOrNull?.name,
        ) ??
        'Notebook';

    final defaultId = defaultIdAsync.valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(notebookName),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'New section',
            onPressed: _showCreateSectionDialog,
          ),
        ],
      ),
      body: sectionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (sections) {
          if (defaultId == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return _NotebookContents(
            notebookId: widget.notebookId,
            defaultSectionId: defaultId,
            sections: sections,
            onCreateInDefault: () => _createPage(defaultId),
          );
        },
      ),
      floatingActionButton: defaultId != null
          ? FloatingActionButton(
              onPressed: () => _createPage(defaultId),
              tooltip: 'New page',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _createPage(String sectionId) async {
    final page = await ref.read(pagesProvider(sectionId).notifier).create();
    if (!mounted) return;
    ref.read(tabsProvider.notifier).openTab(TabEntry(
      pageId: page.id,
      sectionId: sectionId,
      notebookId: widget.notebookId,
      title: page.title,
    ));
  }

  Future<void> _showCreateSectionDialog() async {
    final result = await showDialog<_SectionFormResult>(
      context: context,
      builder: (_) => const _SectionFormDialog(),
    );
    if (result != null) {
      await ref
          .read(sectionsProvider(widget.notebookId).notifier)
          .create(result.name, result.color);
    }
  }
}

// ── Notebook contents (combined pages + expandable sections) ──────────────────

class _NotebookContents extends ConsumerWidget {
  final String notebookId;
  final String defaultSectionId;
  final List<Section> sections;
  final VoidCallback onCreateInDefault;

  const _NotebookContents({
    required this.notebookId,
    required this.defaultSectionId,
    required this.sections,
    required this.onCreateInDefault,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defaultPages =
        ref.watch(pagesProvider(defaultSectionId)).valueOrNull ?? [];

    if (defaultPages.isEmpty && sections.isEmpty) {
      return _EmptyState(onCreateTap: onCreateInDefault);
    }

    final showPagesLabel = sections.isNotEmpty && defaultPages.isNotEmpty;

    return ListView(
      children: [
        // ── Top-level (unsectioned) pages ─────────────────────────────────
        if (showPagesLabel) const _GroupHeader(label: 'Pages'),
        if (defaultPages.isNotEmpty)
          PagesList(
            pages: defaultPages,
            notebookId: notebookId,
            sectionId: defaultSectionId,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
          ),

        // ── User sections (expandable) ────────────────────────────────────
        ...sections.map(
          (s) => _SectionExpansionTile(
            key: ValueKey(s.id),
            section: s,
            notebookId: notebookId,
          ),
        ),

        const SizedBox(height: 88), // breathing room above FAB
      ],
    );
  }
}

// ── Expandable section tile ───────────────────────────────────────────────────

class _SectionExpansionTile extends ConsumerStatefulWidget {
  final Section section;
  final String notebookId;

  const _SectionExpansionTile({
    super.key,
    required this.section,
    required this.notebookId,
  });

  @override
  ConsumerState<_SectionExpansionTile> createState() =>
      _SectionExpansionTileState();
}

class _SectionExpansionTileState
    extends ConsumerState<_SectionExpansionTile> {
  @override
  Widget build(BuildContext context) {
    final pages =
        ref.watch(pagesProvider(widget.section.id)).valueOrNull ?? [];
    final cs    = Theme.of(context).colorScheme;
    final color = Color(widget.section.color);

    return ExpansionTile(
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: color,
        child: const Icon(Icons.folder, color: Colors.white, size: 16),
      ),
      // Title row: name + "…" popup menu (popup absorbs its tap so the tile
      // still toggles expand/collapse on tap elsewhere)
      title: Row(
        children: [
          Expanded(child: Text(widget.section.name)),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, size: 18, color: cs.onSurfaceVariant),
            iconSize: 20,
            padding: EdgeInsets.zero,
            tooltip: '',
            onSelected: _handleMenuAction,
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'add_page',
                child: Row(children: [
                  Icon(Icons.add, size: 18),
                  SizedBox(width: 8),
                  Text('Add page here'),
                ]),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'rename',
                child: Row(children: [
                  Icon(Icons.edit_outlined, size: 18),
                  SizedBox(width: 8),
                  Text('Rename / Change Color'),
                ]),
              ),
              const PopupMenuItem(
                value: 'export',
                child: Row(children: [
                  Icon(Icons.ios_share, size: 18),
                  SizedBox(width: 8),
                  Text('Export section'),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'delete',
                child: Row(children: [
                  Icon(Icons.delete_outline, size: 18, color: cs.error),
                  const SizedBox(width: 8),
                  Text('Delete', style: TextStyle(color: cs.error)),
                ]),
              ),
            ],
          ),
        ],
      ),
      children: [
        if (pages.isEmpty)
          // Empty section — inline prompt
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 4, 16, 8),
            child: Row(
              children: [
                Text(
                  'No pages yet',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withOpacity(0.45),
                      ),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: _addPage,
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('Add page'),
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
          )
        else ...[
          PagesList(
            pages: pages,
            notebookId: widget.notebookId,
            sectionId: widget.section.id,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
          ),
          // "Add page" row at the bottom of the expanded section
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 56, right: 16),
            leading:
                Icon(Icons.add, size: 16, color: cs.onSurface.withOpacity(0.45)),
            title: Text(
              'Add page',
              style: TextStyle(
                  fontSize: 13, color: cs.onSurface.withOpacity(0.45)),
            ),
            onTap: _addPage,
          ),
        ],
      ],
    );
  }

  // ── Section actions ────────────────────────────────────────────────────────

  Future<void> _addPage() async {
    final page =
        await ref.read(pagesProvider(widget.section.id).notifier).create();
    if (!mounted) return;
    ref.read(tabsProvider.notifier).openTab(TabEntry(
      pageId: page.id,
      sectionId: widget.section.id,
      notebookId: widget.notebookId,
      title: page.title,
    ));
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'add_page':
        await _addPage();

      case 'rename':
        final result = await showDialog<_SectionFormResult>(
          context: context,
          builder: (_) => _SectionFormDialog(
            initialName: widget.section.name,
            initialColor: widget.section.color,
          ),
        );
        if (result != null) {
          await ref.read(sectionsProvider(widget.notebookId).notifier).edit(
                widget.section
                    .copyWith(name: result.name, color: result.color),
              );
        }

      case 'export':
        if (mounted) {
          await showExportSheet(
            context,
            title: 'Export "${widget.section.name}"',
            showOutputChoice: true,
            onExport: (fmt, output) =>
                ExportService().exportSection(context, widget.section, fmt, output),
          );
        }

      case 'delete':
        final confirmed = await showConfirmDialog(
          context,
          title: 'Delete Section',
          message:
              'Delete "${widget.section.name}"? All pages will be removed.',
          confirmColor: Colors.red,
        );
        if (confirmed) {
          await ref
              .read(sectionsProvider(widget.notebookId).notifier)
              .delete(widget.section.id);
        }
    }
  }
}

// ── Group label ("Pages" shown when top-level pages coexist with sections) ────

class _GroupHeader extends StatelessWidget {
  final String label;

  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              letterSpacing: 1.0,
            ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

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
              color:
                  Theme.of(context).colorScheme.onSurface.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text(
            'No pages yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.5),
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Use + to create a page, or add sections to organise your notes.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withOpacity(0.4),
                ),
          ),
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

// ── Section form (create / edit) ──────────────────────────────────────────────

class _SectionFormResult {
  final String name;
  final int color;
  _SectionFormResult(this.name, this.color);
}

class _SectionFormDialog extends StatefulWidget {
  final String? initialName;
  final int? initialColor;

  const _SectionFormDialog({this.initialName, this.initialColor});

  @override
  State<_SectionFormDialog> createState() => _SectionFormDialogState();
}

class _SectionFormDialogState extends State<_SectionFormDialog> {
  late TextEditingController _nameCtrl;
  late int _color;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName ?? '');
    _color = widget.initialColor ?? AppTheme.notebookColors[2].value;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title:
          Text(widget.initialName == null ? 'New Section' : 'Edit Section'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'My Section',
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Color: '),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () async {
                  final picked = await showColorPicker(context, _color);
                  if (picked != null) setState(() => _color = picked);
                },
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Color(_color),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withOpacity(0.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text('tap to change'),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, _SectionFormResult(name, _color));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
