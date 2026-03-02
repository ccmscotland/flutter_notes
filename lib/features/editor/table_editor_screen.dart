import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard;

class TableEditorScreen extends StatefulWidget {
  final List<List<String>> initialData;

  const TableEditorScreen({super.key, required this.initialData});

  @override
  State<TableEditorScreen> createState() => _TableEditorScreenState();
}

class _TableEditorScreenState extends State<TableEditorScreen> {
  late List<List<TextEditingController>> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = widget.initialData
        .map((row) =>
            row.map((cell) => TextEditingController(text: cell)).toList())
        .toList();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  int get _rowCount => _controllers.length;
  int get _colCount => _controllers.isEmpty ? 0 : _controllers[0].length;

  void _addRow() {
    setState(() {
      _controllers
          .add(List.generate(_colCount, (_) => TextEditingController()));
    });
  }

  void _removeLastRow() {
    if (_rowCount <= 1) return;
    setState(() {
      for (final ctrl in _controllers.last) {
        ctrl.dispose();
      }
      _controllers.removeLast();
    });
  }

  void _addColumn() {
    setState(() {
      for (final row in _controllers) {
        row.add(TextEditingController());
      }
    });
  }

  void _removeLastColumn() {
    if (_colCount <= 1) return;
    setState(() {
      for (final row in _controllers) {
        row.last.dispose();
        row.removeLast();
      }
    });
  }

  void _insertColumnAt(int colIndex) {
    setState(() {
      for (final row in _controllers) {
        row.insert(colIndex, TextEditingController());
      }
    });
  }

  void _deleteColumnAt(int colIndex) {
    if (_colCount <= 1) return;
    setState(() {
      for (final row in _controllers) {
        if (colIndex < row.length) {
          row[colIndex].dispose();
          row.removeAt(colIndex);
        }
      }
    });
  }

  void _insertRowAt(int rowIndex) {
    setState(() {
      _controllers.insert(
        rowIndex,
        List.generate(_colCount, (_) => TextEditingController()),
      );
    });
  }

  void _deleteRowAt(int rowIndex) {
    if (_rowCount <= 1) return;
    setState(() {
      for (final ctrl in _controllers[rowIndex]) {
        ctrl.dispose();
      }
      _controllers.removeAt(rowIndex);
    });
  }

  String _buildJson() => jsonEncode(
        _controllers.map((r) => r.map((c) => c.text).toList()).toList(),
      );

  static List<List<String>>? _parseTabularData(String text) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    final delimiter = lines.first.contains('\t') ? '\t' : ',';
    return lines
        .map((line) => line.split(delimiter).map((c) => c.trim()).toList())
        .toList();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Clipboard is empty')),
        );
      }
      return;
    }
    final rows = _parseTabularData(text);
    if (rows == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No tabular data found in clipboard')),
        );
      }
      return;
    }

    // Ask before replacing if the table already has non-empty content.
    final hasContent = _controllers.any(
      (row) => row.any((ctrl) => ctrl.text.isNotEmpty),
    );
    if (hasContent && mounted) {
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Paste data'),
          content: const Text('Add pasted rows after the existing data, or replace all content?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'append'),
              child: const Text('Append'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'replace'),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (action == null || action == 'cancel') return;

      if (action == 'append') {
        setState(() {
          // Normalise column count across all rows.
          final targetCols = _colCount;
          for (final row in rows) {
            while (row.length < targetCols) row.add('');
            _controllers.add(
              row.map((cell) => TextEditingController(text: cell)).toList(),
            );
          }
        });
        return;
      }
      // action == 'replace' → fall through
    }

    setState(() {
      _disposeControllers();
      _controllers = rows
          .map((row) =>
              row.map((cell) => TextEditingController(text: cell)).toList())
          .toList();
    });
  }

  void _disposeControllers() {
    for (final row in _controllers) {
      for (final ctrl in row) {
        ctrl.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit Table'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _buildJson()),
            child: const Text('Save'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: _buildGrid(),
              ),
            ),
          ),
          _buildToolbar(),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return Table(
      border: TableBorder.all(color: Colors.grey.shade400),
      // Column 0 = row-control strip; remaining columns = data
      columnWidths: const {0: FixedColumnWidth(32)},
      defaultColumnWidth: const FixedColumnWidth(140),
      children: [
        // Top-left corner cell + one column-control popup per data column
        TableRow(
          decoration: BoxDecoration(color: Colors.grey.shade300),
          children: [
            const SizedBox(height: 32), // corner spacer
            ...List.generate(_colCount, (ci) {
              return SizedBox(
                height: 32,
                child: Center(
                  child: PopupMenuButton<String>(
                    tooltip: 'Column ${ci + 1} options',
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    icon: const Icon(Icons.more_horiz),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'before',
                          child: Text('Insert column before')),
                      const PopupMenuItem(
                          value: 'after',
                          child: Text('Insert column after')),
                      PopupMenuItem(
                        value: 'delete',
                        enabled: _colCount > 1,
                        child: const Text('Delete column'),
                      ),
                    ],
                    onSelected: (action) {
                      switch (action) {
                        case 'before':
                          _insertColumnAt(ci);
                        case 'after':
                          _insertColumnAt(ci + 1);
                        case 'delete':
                          _deleteColumnAt(ci);
                      }
                    },
                  ),
                ),
              );
            }),
          ],
        ),
        // Data rows: leading row-control cell + data cells
        ..._controllers.asMap().entries.map((entry) {
          final ri = entry.key;
          final isHeader = ri == 0;
          return TableRow(
            decoration:
                isHeader ? BoxDecoration(color: Colors.grey.shade100) : null,
            children: [
              // Row-control cell
              Center(
                child: PopupMenuButton<String>(
                  tooltip: 'Row ${ri + 1} options',
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  icon: const Icon(Icons.more_vert),
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                        value: 'before', child: Text('Insert row before')),
                    const PopupMenuItem(
                        value: 'after', child: Text('Insert row after')),
                    PopupMenuItem(
                      value: 'delete',
                      enabled: _rowCount > 1,
                      child: const Text('Delete row'),
                    ),
                  ],
                  onSelected: (action) {
                    switch (action) {
                      case 'before':
                        _insertRowAt(ri);
                      case 'after':
                        _insertRowAt(ri + 1);
                      case 'delete':
                        _deleteRowAt(ri);
                    }
                  },
                ),
              ),
              // Data cells
              ...entry.value.map((ctrl) {
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: TextField(
                    controller: ctrl,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    ),
                    style: isHeader
                        ? const TextStyle(fontWeight: FontWeight.bold)
                        : null,
                    minLines: 1,
                    maxLines: 3,
                  ),
                );
              }),
            ],
          );
        }),
      ],
    );
  }

  Widget _buildToolbar() {
    return SafeArea(
      child: Wrap(
        children: [
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add Row'),
            onPressed: _addRow,
          ),
          TextButton.icon(
            icon: const Icon(Icons.remove),
            label: const Text('Remove Row'),
            onPressed: _rowCount > 1 ? _removeLastRow : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add Col'),
            onPressed: _addColumn,
          ),
          TextButton.icon(
            icon: const Icon(Icons.remove),
            label: const Text('Remove Col'),
            onPressed: _colCount > 1 ? _removeLastColumn : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.content_paste),
            label: const Text('Paste'),
            onPressed: _pasteFromClipboard,
          ),
        ],
      ),
    );
  }
}
