import 'package:flutter/material.dart';

import 'export_service.dart';

/// Shows the export bottom sheet and calls [onExport] with the chosen options.
///
/// [title] is displayed in the sheet header, e.g. "Export "My Page"".
/// [showOutputChoice] adds the Merged / ZIP selector for multi-page exports.
Future<void> showExportSheet(
  BuildContext context, {
  required String title,
  required bool showOutputChoice,
  required Future<void> Function(ExportFormat, MultiPageOutput) onExport,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ExportSheet(
      title: title,
      showOutputChoice: showOutputChoice,
      onExport: onExport,
    ),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({
    required this.title,
    required this.showOutputChoice,
    required this.onExport,
  });

  final String title;
  final bool showOutputChoice;
  final Future<void> Function(ExportFormat, MultiPageOutput) onExport;

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  ExportFormat _format = ExportFormat.pdf;
  MultiPageOutput _output = MultiPageOutput.merged;
  bool _running = false;

  Future<void> _doExport() async {
    setState(() => _running = true);
    try {
      await widget.onExport(_format, _output);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titleText = widget.title.length > 40
        ? '${widget.title.substring(0, 37)}…'
        : widget.title;

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ────────────────────────────────────────────────────────
          Row(
            children: [
              Expanded(
                child: Text(
                  titleText,
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: _running ? null : () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Format ────────────────────────────────────────────────────────
          Text('Format', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<ExportFormat>(
            segments: const [
              ButtonSegment(
                value: ExportFormat.pdf,
                label: Text('PDF'),
                icon: Icon(Icons.picture_as_pdf_outlined),
              ),
              ButtonSegment(
                value: ExportFormat.html,
                label: Text('HTML'),
                icon: Icon(Icons.html_outlined),
              ),
              ButtonSegment(
                value: ExportFormat.markdown,
                label: Text('Markdown'),
                icon: Icon(Icons.text_snippet_outlined),
              ),
            ],
            selected: {_format},
            onSelectionChanged: _running
                ? null
                : (s) => setState(() => _format = s.first),
          ),

          // ── Output (multi-page only) ──────────────────────────────────────
          if (widget.showOutputChoice) ...[
            const SizedBox(height: 20),
            Text('Output', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<MultiPageOutput>(
              segments: const [
                ButtonSegment(
                  value: MultiPageOutput.merged,
                  label: Text('Merged'),
                  icon: Icon(Icons.merge_outlined),
                ),
                ButtonSegment(
                  value: MultiPageOutput.zip,
                  label: Text('ZIP'),
                  icon: Icon(Icons.folder_zip_outlined),
                ),
              ],
              selected: {_output},
              onSelectionChanged: _running
                  ? null
                  : (s) => setState(() => _output = s.first),
            ),
          ],

          const SizedBox(height: 24),

          // ── Actions ───────────────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _running ? null : () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _running ? null : _doExport,
                icon: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.ios_share),
                label: Text(_running ? 'Exporting…' : 'Export'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
