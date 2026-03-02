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
import 'sections_provider.dart';

class SectionsScreen extends ConsumerWidget {
  final String notebookId;

  const SectionsScreen({super.key, required this.notebookId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notebookAsync = ref.watch(notebooksProvider);
    final sectionsAsync = ref.watch(sectionsProvider(notebookId));

    final notebookName = notebookAsync.whenOrNull(
          data: (nbs) =>
              nbs.where((n) => n.id == notebookId).firstOrNull?.name,
        ) ??
        'Notebook';

    return Scaffold(
      appBar: AppBar(
        title: Text(notebookName),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: sectionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (sections) {
          if (sections.isEmpty) {
            return _EmptyState(
              onCreateTap: () => _showCreateDialog(context, ref),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: sections.length,
            itemBuilder: (_, i) => _SectionTile(
              section: sections[i],
              onTap: () => context.push(
                  '/notebook/$notebookId/section/${sections[i].id}'),
              onLongPress: () =>
                  _showContextMenu(context, ref, sections[i]),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Section'),
      ),
    );
  }

  Future<void> _showCreateDialog(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<_SectionFormResult>(
      context: context,
      builder: (_) => const _SectionFormDialog(),
    );
    if (result != null) {
      await ref
          .read(sectionsProvider(notebookId).notifier)
          .create(result.name, result.color);
    }
  }

  Future<void> _showContextMenu(
      BuildContext context, WidgetRef ref, Section section) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _SectionActionsSheet(section: section),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'rename':
        final result = await showDialog<_SectionFormResult>(
          context: context,
          builder: (_) => _SectionFormDialog(
            initialName: section.name,
            initialColor: section.color,
          ),
        );
        if (result != null) {
          await ref.read(sectionsProvider(notebookId).notifier).edit(
                section.copyWith(name: result.name, color: result.color),
              );
        }
      case 'export':
        if (context.mounted) {
          await showExportSheet(
            context,
            title: 'Export "${section.name}"',
            showOutputChoice: true,
            onExport: (fmt, output) =>
                ExportService().exportSection(context, section, fmt, output),
          );
        }
      case 'delete':
        final confirmed = await showConfirmDialog(
          context,
          title: 'Delete Section',
          message: 'Delete "${section.name}"? All pages will be removed.',
          confirmColor: Colors.red,
        );
        if (confirmed) {
          await ref
              .read(sectionsProvider(notebookId).notifier)
              .delete(section.id);
        }
    }
  }
}

class _SectionTile extends StatelessWidget {
  final Section section;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _SectionTile({
    required this.section,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(section.color);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color,
        child: const Icon(Icons.folder, color: Colors.white, size: 20),
      ),
      title: Text(section.name),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
      onLongPress: onLongPress,
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
          Icon(Icons.folder_outlined,
              size: 80,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text('No sections yet',
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
            label: const Text('Create Section'),
          ),
        ],
      ),
    );
  }
}

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
                          .withValues(alpha: 0.5),
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

class _SectionActionsSheet extends StatelessWidget {
  final Section section;

  const _SectionActionsSheet({required this.section});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Rename / Change Color'),
            onTap: () => Navigator.pop(context, 'rename'),
          ),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('Export section'),
            onTap: () => Navigator.pop(context, 'export'),
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title:
                const Text('Delete', style: TextStyle(color: Colors.red)),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ],
      ),
    );
  }
}
