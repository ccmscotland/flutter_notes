import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/notebook.dart';
import '../../core/models/section.dart';
import '../../features/editor/editor_screen.dart';
import '../../features/notebooks/notebooks_provider.dart';
import '../../features/sections/sections_provider.dart';
import '../../features/tabs/tabs_provider.dart';
import '../providers/nav_state_provider.dart';
import '../utils/responsive.dart';
import 'browse_pane.dart';

/// Root shell widget provided to go_router's ShellRoute.
///
/// On narrow screens (< [kPhoneBreakpoint]) the original tab-strip layout is
/// used ([_NarrowShell]).  On wider screens a three-column layout is shown:
/// an [_AppRail] on the left, a [BrowsePane] in the centre, and an editor
/// area on the right ([_WideShell]).
class AppShell extends ConsumerWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabsState = ref.watch(tabsProvider);
    final layout    = ResponsiveLayout.of(context);

    if (layout.isPhone) {
      return _NarrowShell(child: child, tabsState: tabsState);
    }
    return _WideShell(child: child, tabsState: tabsState, layout: layout);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Narrow shell — original phone layout, unchanged behaviour
// ─────────────────────────────────────────────────────────────────────────────

class _NarrowShell extends StatelessWidget {
  final Widget child;
  final TabsState tabsState;

  const _NarrowShell({required this.child, required this.tabsState});

  @override
  Widget build(BuildContext context) {
    final activePageId    = tabsState.activePageId;
    final activeEditorIdx = activePageId == null
        ? -1
        : tabsState.tabs.indexWhere((t) => t.pageId == activePageId);
    final stackIdx = activeEditorIdx < 0 ? 0 : activeEditorIdx + 1;

    return Column(
      children: [
        _TabStrip(tabsState: tabsState),
        Expanded(
          child: IndexedStack(
            index: stackIdx,
            children: [
              // index 0: always-alive browse view
              child,
              // index 1..n: one EditorScreen per open tab
              ...tabsState.tabs.map(
                (tab) => EditorScreen(
                  key: ValueKey('editor_${tab.pageId}'),
                  notebookId: tab.notebookId,
                  sectionId: tab.sectionId,
                  pageId: tab.pageId,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Wide shell — Rail + BrowsePane + Editor (tablet / desktop / DEX)
// ─────────────────────────────────────────────────────────────────────────────

class _WideShell extends ConsumerWidget {
  final Widget child;
  final TabsState tabsState;
  final ResponsiveLayout layout;

  const _WideShell({
    required this.child,
    required this.tabsState,
    required this.layout,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navVisible = ref.watch(navVisibleProvider);

    return Row(
      children: [
        if (navVisible) ...[
          _AppRail(showLabels: layout.isRailExpanded),
          const VerticalDivider(width: 1, thickness: 1),
          SizedBox(
            width: kBrowsePaneWidth,
            child: const BrowsePane(),
          ),
          const VerticalDivider(width: 1, thickness: 1),
        ],
        Expanded(
          child: Column(
            children: [
              // Tab strip — same as narrow mode, hidden when no tabs open.
              _TabStrip(tabsState: tabsState),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Keep go_router navigator alive for route state preservation.
                    Offstage(offstage: true, child: child),
                    // Visible editor area.
                    _EditorArea(tabsState: tabsState),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Editor area (wide mode only)
// ─────────────────────────────────────────────────────────────────────────────

class _EditorArea extends StatelessWidget {
  final TabsState tabsState;

  const _EditorArea({required this.tabsState});

  @override
  Widget build(BuildContext context) {
    final tabs = tabsState.tabs;
    if (tabs.isEmpty) return const _SelectPagePlaceholder();

    final activeId  = tabsState.activePageId;
    final activeIdx = activeId == null
        ? 0
        : tabs.indexWhere((t) => t.pageId == activeId);

    return IndexedStack(
      index: activeIdx.clamp(0, tabs.length - 1),
      children: tabs
          .map(
            (tab) => EditorScreen(
              key: ValueKey('editor_wide_${tab.pageId}'),
              notebookId: tab.notebookId,
              sectionId: tab.sectionId,
              pageId: tab.pageId,
            ),
          )
          .toList(),
    );
  }
}

class _SelectPagePlaceholder extends StatelessWidget {
  const _SelectPagePlaceholder();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notes_outlined,
                size: 80, color: cs.onSurface.withOpacity(0.25)),
            const SizedBox(height: 16),
            Text(
              'Select a page to start editing',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: cs.onSurface.withOpacity(0.45),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// App Rail (left navigation panel — wide mode)
// ─────────────────────────────────────────────────────────────────────────────

class _AppRail extends ConsumerWidget {
  final bool showLabels;

  const _AppRail({required this.showLabels});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final navState       = ref.watch(navStateProvider);
    final notebooksAsync = ref.watch(notebooksProvider);
    final cs             = Theme.of(context).colorScheme;

    return Material(
      color: cs.surfaceContainer,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: showLabels ? kRailExpanded : kRailCollapsed,
        child: Column(
        children: [
          _RailHeader(showLabels: showLabels),
          const Divider(height: 1),
          Expanded(
            child: notebooksAsync.when(
              loading: () => const Center(
                  child: CircularProgressIndicator(strokeWidth: 2)),
              error: (_, __) => const SizedBox.shrink(),
              data: (notebooks) => ListView(
                padding: EdgeInsets.zero,
                children: notebooks
                    .map(
                      (nb) => _RailNotebookEntry(
                        notebook: nb,
                        showLabels: showLabels,
                        isSelected:
                            navState.selectedNotebookId == nb.id,
                        selectedSectionId:
                            navState.selectedNotebookId == nb.id
                                ? navState.selectedSectionId
                                : null,
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          const Divider(height: 1),
          _RailFooter(showLabels: showLabels),
        ],
        ),
      ),
    );
  }
}

class _RailHeader extends ConsumerWidget {
  final bool showLabels;

  const _RailHeader({required this.showLabels});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 56,
      child: showLabels
          ? Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Notes',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: 'New notebook',
                    onPressed: () => _createNotebook(context, ref),
                  ),
                ],
              ),
            )
          : const Center(child: Icon(Icons.notes, size: 26)),
    );
  }

  Future<void> _createNotebook(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(
        title: 'New Notebook',
        hint: 'Notebook name',
      ),
    );
    if (name != null && name.isNotEmpty) {
      await ref.read(notebooksProvider.notifier).create(name, 0xFF1565C0);
    }
  }
}

class _RailFooter extends ConsumerWidget {
  final bool showLabels;

  const _RailFooter({required this.showLabels});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Collapsed mode: show "New notebook" here since the header has no room
        if (!showLabels)
          IconButton(
            icon: const Icon(Icons.create_new_folder_outlined),
            tooltip: 'New notebook',
            onPressed: () async {
              final name = await showDialog<String>(
                context: context,
                builder: (_) => const _NameDialog(
                  title: 'New Notebook',
                  hint: 'Notebook name',
                ),
              );
              if (name != null && name.isNotEmpty) {
                await ref
                    .read(notebooksProvider.notifier)
                    .create(name, 0xFF1565C0);
              }
            },
          ),
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search',
          onPressed: () => context.push('/search'),
        ),
        IconButton(
          icon: const Icon(Icons.sync),
          tooltip: 'Sync',
          onPressed: () => context.push('/settings/sync'),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Rail entries
// ─────────────────────────────────────────────────────────────────────────────

class _RailNotebookEntry extends ConsumerWidget {
  final Notebook notebook;
  final bool showLabels;
  final bool isSelected;
  final String? selectedSectionId;

  const _RailNotebookEntry({
    required this.notebook,
    required this.showLabels,
    required this.isSelected,
    required this.selectedSectionId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs      = Theme.of(context).colorScheme;
    final nbColor = Color(notebook.color);

    return Column(
      children: [
        InkWell(
          onTap: () =>
              ref.read(navStateProvider.notifier).selectNotebook(notebook.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 48,
            color: isSelected ? cs.secondaryContainer : Colors.transparent,
            padding: showLabels
                ? const EdgeInsets.only(left: 12, right: 4)
                : EdgeInsets.zero,
            alignment:
                showLabels ? Alignment.centerLeft : Alignment.center,
            child: showLabels
                ? Row(
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: nbColor,
                        child: const Icon(Icons.menu_book,
                            color: Colors.white, size: 14),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          notebook.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert,
                            size: 14, color: cs.onSurfaceVariant),
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        tooltip: '',
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: Row(children: [
                              Icon(Icons.edit_outlined, size: 18),
                              SizedBox(width: 8),
                              Text('Rename / Colour'),
                            ]),
                          ),
                          const PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'delete',
                            child: Row(children: [
                              Icon(Icons.delete_outline,
                                  size: 18, color: cs.error),
                              const SizedBox(width: 8),
                              Text('Delete',
                                  style: TextStyle(color: cs.error)),
                            ]),
                          ),
                        ],
                        onSelected: (val) =>
                            _handleAction(context, ref, val),
                      ),
                    ],
                  )
                : CircleAvatar(
                    radius: 14,
                    backgroundColor: nbColor,
                    child: const Icon(Icons.menu_book,
                        color: Colors.white, size: 14),
                  ),
          ),
        ),
        if (isSelected)
          _SectionsList(
            notebookId: notebook.id,
            selectedSectionId: selectedSectionId,
            showLabels: showLabels,
          ),
      ],
    );
  }

  Future<void> _handleAction(
      BuildContext context, WidgetRef ref, String action) async {
    if (action == 'edit') {
      final result = await showDialog<(String, int)>(
        context: context,
        builder: (_) => _EditItemDialog(
          title: 'Edit Notebook',
          initialName: notebook.name,
          initialColor: notebook.color,
        ),
      );
      if (result != null) {
        await ref
            .read(notebooksProvider.notifier)
            .edit(notebook.copyWith(name: result.$1, color: result.$2));
      }
    } else if (action == 'delete') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Delete "${notebook.name}"?'),
          content: const Text(
              'All sections and pages inside will be permanently deleted.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(
              style:
                  TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirm == true) {
        await ref.read(notebooksProvider.notifier).delete(notebook.id);
      }
    }
  }
}

class _SectionsList extends ConsumerWidget {
  final String notebookId;
  final String? selectedSectionId;
  final bool showLabels;

  const _SectionsList({
    required this.notebookId,
    required this.selectedSectionId,
    required this.showLabels,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sectionsAsync = ref.watch(sectionsProvider(notebookId));
    final cs            = Theme.of(context).colorScheme;

    return sectionsAsync.when(
      loading: () => const SizedBox.shrink(),
      error:   (_, __) => const SizedBox.shrink(),
      data: (sections) => Column(
        children: [
          ...sections.map((s) {
            final isSelected = s.id == selectedSectionId;
            final sColor     = Color(s.color);
            return InkWell(
              onTap: () =>
                  ref.read(navStateProvider.notifier).selectSection(s.id),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 40,
                color: isSelected
                    ? cs.secondaryContainer
                    : Colors.transparent,
                child: showLabels
                    ? Row(
                        children: [
                          const SizedBox(width: 24),
                          // Coloured dot indicator
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                color: sColor,
                                shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              s.name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13,
                                color: isSelected
                                    ? cs.onSecondaryContainer
                                    : cs.onSurfaceVariant,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          // Popup menu
                          PopupMenuButton<String>(
                            icon: Icon(Icons.more_vert,
                                size: 14,
                                color: cs.onSurfaceVariant),
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            tooltip: '',
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Row(children: [
                                  Icon(Icons.edit_outlined, size: 18),
                                  SizedBox(width: 8),
                                  Text('Rename / Colour'),
                                ]),
                              ),
                              const PopupMenuDivider(),
                              PopupMenuItem(
                                value: 'delete',
                                child: Row(children: [
                                  Icon(Icons.delete_outline,
                                      size: 18, color: cs.error),
                                  const SizedBox(width: 8),
                                  Text('Delete',
                                      style:
                                          TextStyle(color: cs.error)),
                                ]),
                              ),
                            ],
                            onSelected: (val) =>
                                _handleSectionAction(
                                    context, ref, val, s),
                          ),
                          const SizedBox(width: 4),
                        ],
                      )
                    : Align(
                        alignment: Alignment.center,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                              color: sColor, shape: BoxShape.circle),
                        ),
                      ),
              ),
            );
          }),
          // "Add section" button
          InkWell(
            onTap: () => _createSection(context, ref),
            child: SizedBox(
              height: 36,
              child: Padding(
                padding: showLabels
                    ? const EdgeInsets.only(left: 40, right: 8)
                    : EdgeInsets.zero,
                child: Align(
                  alignment:
                      showLabels ? Alignment.centerLeft : Alignment.center,
                  child: showLabels
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add,
                                size: 14, color: cs.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(
                              'Add section',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant),
                            ),
                          ],
                        )
                      : Icon(Icons.add,
                          size: 14, color: cs.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createSection(BuildContext context, WidgetRef ref) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NameDialog(
        title: 'New Section',
        hint: 'Section name',
      ),
    );
    if (name != null && name.isNotEmpty) {
      final section = await ref
          .read(sectionsProvider(notebookId).notifier)
          .create(name, 0xFF1565C0);
      ref.read(navStateProvider.notifier).selectSection(section.id);
    }
  }

  Future<void> _handleSectionAction(
      BuildContext context, WidgetRef ref, String action, Section s) async {
    if (action == 'edit') {
      final result = await showDialog<(String, int)>(
        context: context,
        builder: (_) => _EditItemDialog(
          title: 'Edit Section',
          initialName: s.name,
          initialColor: s.color,
        ),
      );
      if (result != null) {
        await ref
            .read(sectionsProvider(notebookId).notifier)
            .edit(s.copyWith(name: result.$1, color: result.$2));
      }
    } else if (action == 'delete') {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Delete "${s.name}"?'),
          content: const Text(
              'All pages inside this section will be permanently deleted.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirm == true) {
        await ref
            .read(sectionsProvider(notebookId).notifier)
            .delete(s.id);
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Simple name-entry dialog (used for notebook and section creation)
// ─────────────────────────────────────────────────────────────────────────────

class _NameDialog extends StatefulWidget {
  final String title;
  final String hint;

  const _NameDialog({required this.title, required this.hint});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _ctrl.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Edit-item dialog — rename + choose colour for a notebook or section
// ─────────────────────────────────────────────────────────────────────────────

class _EditItemDialog extends StatefulWidget {
  final String title;
  final String initialName;
  final int    initialColor;

  const _EditItemDialog({
    required this.title,
    required this.initialName,
    required this.initialColor,
  });

  @override
  State<_EditItemDialog> createState() => _EditItemDialogState();
}

class _EditItemDialogState extends State<_EditItemDialog> {
  static const _palette = [
    0xFF1565C0, // Blue
    0xFF6A1B9A, // Purple
    0xFF00695C, // Teal
    0xFF2E7D32, // Green
    0xFF8D6E63, // Brown
    0xFFE65100, // Orange
    0xFFC62828, // Red
    0xFF37474F, // Slate
    0xFFAD1457, // Pink
    0xFFF57F17, // Amber
  ];

  late final TextEditingController _ctrl;
  late int _color;

  @override
  void initState() {
    super.initState();
    _ctrl  = TextEditingController(text: widget.initialName);
    _color = widget.initialColor;
    // If the current colour isn't in the palette, default to the first entry.
    if (!_palette.contains(_color)) _color = _palette.first;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _ctrl.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, (name, _color));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 20),
          Text('Colour',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _palette.map((c) {
              final selected = _color == c;
              return GestureDetector(
                onTap: () => setState(() => _color = c),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: selected
                        ? Border.all(color: Colors.black54, width: 2.5)
                        : null,
                  ),
                  child: selected
                      ? const Icon(Icons.check,
                          size: 14, color: Colors.white)
                      : null,
                ),
              );
            }).toList(),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab strip (narrow mode only)
// ─────────────────────────────────────────────────────────────────────────────

class _TabStrip extends ConsumerWidget {
  final TabsState tabsState;

  const _TabStrip({required this.tabsState});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (tabsState.tabs.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;

    return Material(
      color: cs.surfaceContainerHighest,
      elevation: 1,
      child: SizedBox(
        height: 38,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          itemCount: tabsState.tabs.length,
          itemBuilder: (_, i) {
            final tab      = tabsState.tabs[i];
            final isActive = tab.pageId == tabsState.activePageId;
            return _TabChip(
              key: ValueKey(tab.pageId),
              tab: tab,
              isActive: isActive,
              onTap: () =>
                  ref.read(tabsProvider.notifier).setActive(tab.pageId),
              onClose: () {
                final next =
                    ref.read(tabsProvider.notifier).closeTab(tab.pageId);
                if (isActive && next == null) {
                  context.go(
                    '/notebook/${tab.notebookId}/section/${tab.sectionId}',
                  );
                }
              },
            );
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _TabChip extends StatelessWidget {
  final TabEntry tab;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _TabChip({
    super.key,
    required this.tab,
    required this.isActive,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        constraints: const BoxConstraints(maxWidth: 200, minWidth: 80),
        margin: const EdgeInsets.only(right: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isActive ? cs.surface : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
          border: isActive
              ? Border.all(color: cs.outlineVariant, width: 0.5)
              : null,
          boxShadow: isActive
              ? [BoxShadow(color: cs.shadow.withOpacity(0.08), blurRadius: 2)]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.article_outlined,
              size: 13,
              color: isActive ? cs.primary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                tab.title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight:
                      isActive ? FontWeight.w600 : FontWeight.normal,
                  color: isActive ? cs.onSurface : cs.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.close,
                  size: 12,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
