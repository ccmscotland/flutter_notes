import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/notebooks_dao.dart';
import '../../core/database/pages_dao.dart';
import '../../core/database/sections_dao.dart';
import '../../core/models/notebook.dart';
import '../../core/models/page.dart';
import '../../core/models/page_group.dart';
import '../../core/models/section.dart';
import '../export/export_service.dart';
import '../export/export_sheet.dart';
import 'groups_provider.dart';

class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(groupsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Collections')),
      body: groupsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (groups) {
          if (groups.isEmpty) {
            return _EmptyState(
              onCreateTap: () => _createGroup(context, ref),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(8),
            itemCount: groups.length,
            itemBuilder: (_, i) => _GroupTile(group: groups[i]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _createGroup(context, ref),
        tooltip: 'New collection',
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _createGroup(BuildContext context, WidgetRef ref) async {
    final name = await _showNameDialog(context, title: 'New Collection');
    if (name != null && name.isNotEmpty) {
      await ref.read(groupsProvider.notifier).create(name);
    }
  }
}

// ── Group tile ────────────────────────────────────────────────────────────────

class _GroupTile extends ConsumerWidget {
  final PageGroup group;
  const _GroupTile({required this.group});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.collections_bookmark_outlined),
        title: Text(group.name, style: const TextStyle(fontWeight: FontWeight.w500)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.ios_share_outlined, size: 20),
              tooltip: 'Export collection',
              onPressed: () => _export(context),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              tooltip: '',
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'manage',
                  child: Row(children: [
                    Icon(Icons.playlist_add_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Manage pages'),
                  ]),
                ),
                const PopupMenuItem(
                  value: 'rename',
                  child: Row(children: [
                    Icon(Icons.edit_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('Rename'),
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
              onSelected: (val) async {
                if (val == 'manage') _managePages(context, ref);
                if (val == 'rename') _rename(context, ref);
                if (val == 'delete') _delete(context, ref);
              },
            ),
          ],
        ),
        onTap: () => _managePages(context, ref),
      ),
    );
  }

  void _export(BuildContext context) {
    showExportSheet(
      context,
      title: 'Export "${group.name}"',
      showOutputChoice: true,
      onExport: (fmt, output) =>
          ExportService().exportGroup(context, group, fmt, output),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final name = await _showNameDialog(context,
        title: 'Rename Collection', initial: group.name);
    if (name != null && name.isNotEmpty) {
      await ref.read(groupsProvider.notifier).rename(group.id, name);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Collection'),
        content: Text(
            'Delete "${group.name}"? Pages are not affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(groupsProvider.notifier).delete(group.id);
    }
  }

  void _managePages(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog.fullscreen(
        child: _ManagePagesScreen(group: group),
      ),
    );
  }
}

// ── Manage pages screen ───────────────────────────────────────────────────────

class _ManagePagesScreen extends ConsumerStatefulWidget {
  final PageGroup group;
  const _ManagePagesScreen({required this.group});

  @override
  ConsumerState<_ManagePagesScreen> createState() => _ManagePagesScreenState();
}

class _ManagePagesScreenState extends ConsumerState<_ManagePagesScreen> {
  Set<String> _memberIds = {};
  bool _loading = true;

  // Full tree for page picker
  List<({Notebook notebook, List<({Section section, List<NotePage> pages})> sections})> _tree = [];
  bool _treeLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  Future<void> _loadMembers() async {
    final ids = await ref
        .read(groupsProvider.notifier)
        .getPageIds(widget.group.id);
    if (mounted) setState(() { _memberIds = ids.toSet(); _loading = false; });
  }

  Future<void> _loadTree() async {
    final notebooks = await NotebooksDao().getAll();
    final tree = <({Notebook notebook, List<({Section section, List<NotePage> pages})> sections})>[];
    for (final nb in notebooks) {
      final sections = await SectionsDao().getByNotebook(nb.id);
      final secNodes = <({Section section, List<NotePage> pages})>[];
      for (final sec in sections) {
        final pages = await PagesDao().getBySection(sec.id);
        if (pages.isNotEmpty) secNodes.add((section: sec, pages: pages));
      }
      if (secNodes.isNotEmpty) tree.add((notebook: nb, sections: secNodes));
    }
    if (mounted) setState(() { _tree = tree; _treeLoaded = true; });
  }

  Future<void> _togglePage(String pageId, bool add) async {
    final notifier = ref.read(groupsProvider.notifier);
    if (add) {
      await notifier.addPage(widget.group.id, pageId);
      setState(() => _memberIds.add(pageId));
    } else {
      await notifier.removePage(widget.group.id, pageId);
      setState(() => _memberIds.remove(pageId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.name),
        actions: [
          TextButton.icon(
            onPressed: _treeLoaded ? null : _loadTree,
            icon: const Icon(Icons.add),
            label: const Text('Add pages'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_treeLoaded) return _buildPicker();

    // Show current members
    if (_memberIds.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.collections_bookmark_outlined,
                size: 64,
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3)),
            const SizedBox(height: 16),
            const Text('No pages yet'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loadTree,
              icon: const Icon(Icons.add),
              label: const Text('Add pages'),
            ),
          ],
        ),
      );
    }

    return _MemberList(
      memberIds: _memberIds,
      onRemove: (id) => _togglePage(id, false),
    );
  }

  Widget _buildPicker() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Check pages to add or uncheck to remove.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final nb in _tree) ...[
                _SectionHeader(nb.notebook.name, color: Color(nb.notebook.color)),
                for (final sec in nb.sections) ...[
                  _SubHeader(sec.section.name, color: Color(sec.section.color)),
                  for (final pg in sec.pages)
                    CheckboxListTile(
                      value: _memberIds.contains(pg.id),
                      onChanged: (v) => _togglePage(pg.id, v ?? false),
                      title: Text(pg.title,
                          style: const TextStyle(fontSize: 14)),
                      secondary: const Icon(Icons.article_outlined, size: 18),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── Current members list ──────────────────────────────────────────────────────

class _MemberList extends StatelessWidget {
  final Set<String> memberIds;
  final void Function(String pageId) onRemove;

  const _MemberList({required this.memberIds, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return _ResolvedPageList(pageIds: memberIds.toList(), onRemove: onRemove);
  }
}

class _ResolvedPageList extends StatefulWidget {
  final List<String> pageIds;
  final void Function(String) onRemove;

  const _ResolvedPageList({required this.pageIds, required this.onRemove});

  @override
  State<_ResolvedPageList> createState() => _ResolvedPageListState();
}

class _ResolvedPageListState extends State<_ResolvedPageList> {
  List<NotePage> _pages = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ResolvedPageList old) {
    super.didUpdateWidget(old);
    if (old.pageIds.length != widget.pageIds.length) _load();
  }

  Future<void> _load() async {
    final dao = PagesDao();
    final pages = <NotePage>[];
    for (final id in widget.pageIds) {
      final pg = await dao.getById(id);
      if (pg != null && !pg.isDeleted) pages.add(pg);
    }
    if (mounted) setState(() { _pages = pages; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView.builder(
      itemCount: _pages.length,
      itemBuilder: (_, i) => ListTile(
        leading: const Icon(Icons.article_outlined),
        title: Text(_pages[i].title),
        trailing: IconButton(
          icon: const Icon(Icons.remove_circle_outline, size: 20),
          tooltip: 'Remove from collection',
          onPressed: () => widget.onRemove(_pages[i].id),
        ),
      ),
    );
  }
}

// ── Tree header widgets ───────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final Color color;
  const _SectionHeader(this.label, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: color,
            child: const Icon(Icons.menu_book, size: 10, color: Colors.white),
          ),
          const SizedBox(width: 8),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SubHeader extends StatelessWidget {
  final String label;
  final Color color;
  const _SubHeader(this.label, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 4, 16, 2),
      child: Row(
        children: [
          Container(
              width: 8, height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
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
          Icon(Icons.collections_bookmark_outlined,
              size: 80,
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('No collections yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                  )),
          const SizedBox(height: 8),
          Text(
            'Create a collection to group pages\nfor export together.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onCreateTap,
            icon: const Icon(Icons.add),
            label: const Text('New Collection'),
          ),
        ],
      ),
    );
  }
}

// ── Shared helpers ─────────────────────────────────────────────────────────────

Future<String?> _showNameDialog(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final ctrl = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Save')),
      ],
    ),
  );
  ctrl.dispose();
  return result;
}
