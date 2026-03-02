import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/models/notebook.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/utils/responsive.dart';
import '../../shared/widgets/color_picker_dialog.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../export/export_service.dart';
import '../export/export_sheet.dart';
import 'notebooks_provider.dart';

class NotebooksScreen extends ConsumerWidget {
  const NotebooksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notebooksAsync = ref.watch(notebooksProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notebooks'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: () => context.push('/settings/sync'),
          ),
        ],
      ),
      body: notebooksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (notebooks) {
          if (notebooks.isEmpty) {
            return _EmptyState(
              onCreateTap: () => _showCreateDialog(context, ref),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount:
                  ResponsiveLayout.of(context).adaptiveGridColumns(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.1,
            ),
            itemCount: notebooks.length,
            itemBuilder: (_, i) => _NotebookCard(
              notebook: notebooks[i],
              onTap: () => context.push('/notebook/${notebooks[i].id}'),
              onLongPress: () =>
                  _showContextMenu(context, ref, notebooks[i]),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Notebook'),
      ),
    );
  }

  Future<void> _showCreateDialog(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<_NotebookFormResult>(
      context: context,
      builder: (_) => const _NotebookFormDialog(),
    );
    if (result != null) {
      await ref
          .read(notebooksProvider.notifier)
          .create(result.name, result.color);
    }
  }

  Future<void> _showContextMenu(
      BuildContext context, WidgetRef ref, Notebook nb) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _NotebookActionsSheet(notebook: nb),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'rename':
        final result = await showDialog<_NotebookFormResult>(
          context: context,
          builder: (_) => _NotebookFormDialog(
            initialName: nb.name,
            initialColor: nb.color,
          ),
        );
        if (result != null) {
          await ref.read(notebooksProvider.notifier).edit(
                nb.copyWith(name: result.name, color: result.color),
              );
        }
      case 'export':
        if (context.mounted) {
          await showExportSheet(
            context,
            title: 'Export "${nb.name}"',
            showOutputChoice: true,
            onExport: (fmt, output) =>
                ExportService().exportNotebook(context, nb, fmt, output),
          );
        }
      case 'delete':
        final confirmed = await showConfirmDialog(
          context,
          title: 'Delete Notebook',
          message:
              'Delete "${nb.name}"? All sections and pages will be removed.',
          confirmColor: Colors.red,
        );
        if (confirmed) {
          await ref.read(notebooksProvider.notifier).delete(nb.id);
        }
    }
  }
}

class _NotebookCard extends StatelessWidget {
  final Notebook notebook;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _NotebookCard({
    required this.notebook,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final color = Color(notebook.color);
    return Card(
      color: color,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.menu_book, color: Colors.white, size: 32),
              const Spacer(),
              Text(
                notebook.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
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
          Icon(Icons.menu_book_outlined,
              size: 80,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            'No notebooks yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5),
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onCreateTap,
            icon: const Icon(Icons.add),
            label: const Text('Create Notebook'),
          ),
        ],
      ),
    );
  }
}

class _NotebookFormResult {
  final String name;
  final int color;
  _NotebookFormResult(this.name, this.color);
}

class _NotebookFormDialog extends StatefulWidget {
  final String? initialName;
  final int? initialColor;

  const _NotebookFormDialog({this.initialName, this.initialColor});

  @override
  State<_NotebookFormDialog> createState() => _NotebookFormDialogState();
}

class _NotebookFormDialogState extends State<_NotebookFormDialog> {
  late TextEditingController _nameCtrl;
  late int _color;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName ?? '');
    _color = widget.initialColor ?? AppTheme.notebookColors.first.value;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initialName == null ? 'New Notebook' : 'Edit Notebook'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'My Notebook',
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
                      color:
                          Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
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
            Navigator.pop(context, _NotebookFormResult(name, _color));
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _NotebookActionsSheet extends StatelessWidget {
  final Notebook notebook;

  const _NotebookActionsSheet({required this.notebook});

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
            title: const Text('Export notebook'),
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
