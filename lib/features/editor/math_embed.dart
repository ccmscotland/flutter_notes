import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:math_expressions/math_expressions.dart';

// ── Embed key ─────────────────────────────────────────────────────────────────

const _kMathKey = 'math';

// ── Embed builder ─────────────────────────────────────────────────────────────

/// Renders a math embed as a LaTeX formula (display mode) or an evaluated
/// arithmetic result, depending on [MathEmbedData.mode].
class MathEmbedBuilder extends EmbedBuilder {
  @override
  String get key => _kMathKey;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final data = MathEmbedData.fromJson(
        embedContext.node.value.data as String);
    return _MathWidget(data: data, embedContext: embedContext);
  }
}

// ── Inline widget ─────────────────────────────────────────────────────────────

class _MathWidget extends StatelessWidget {
  final MathEmbedData data;
  final EmbedContext embedContext;
  const _MathWidget({required this.data, required this.embedContext});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget content;
    if (data.mode == MathMode.latex) {
      content = Math.tex(
        data.source,
        textStyle: TextStyle(fontSize: 16, color: cs.onSurface),
        onErrorFallback: (e) => Text(
          data.source,
          style: TextStyle(color: cs.error, fontFamily: 'monospace'),
        ),
      );
    } else {
      // arithmetic mode — show "expression = result"
      final result = _evaluate(data.source);
      content = RichText(
        text: TextSpan(
          style: TextStyle(fontSize: 15, color: cs.onSurface),
          children: [
            TextSpan(
              text: data.source,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            TextSpan(
              text: '  =  ',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            TextSpan(
              text: result,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: result.startsWith('Error') ? cs.error : cs.primary,
              ),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      onTap: () => _edit(context),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            content,
            const SizedBox(width: 8),
            Icon(Icons.edit_outlined, size: 14, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  void _edit(BuildContext context) {
    showDialog<MathEmbedData>(
      context: context,
      builder: (_) => MathEditDialog(initial: data),
    ).then((updated) {
      if (updated == null) return;
      final offset = embedContext.node.documentOffset;
      embedContext.controller
        ..replaceText(
          offset, 1,
          BlockEmbed.custom(CustomBlockEmbed(_kMathKey, updated.toJson())),
          null,
        );
    });
  }
}

// ── Arithmetic evaluator ──────────────────────────────────────────────────────

String _evaluate(String expression) {
  try {
    final parser = Parser();
    final exp    = parser.parse(expression
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('^', '^'));
    final result = exp.evaluate(EvaluationType.REAL, ContextModel());
    if (result is double) {
      // Show integer when no fractional part
      if (result == result.truncateToDouble() && result.abs() < 1e15) {
        return result.toInt().toString();
      }
      // Up to 10 significant figures, strip trailing zeros
      return double.parse(result.toStringAsPrecision(10)).toString();
    }
    return result.toString();
  } catch (e) {
    return 'Error: ${e.toString().replaceAll('Exception: ', '')}';
  }
}

// ── Data model ────────────────────────────────────────────────────────────────

enum MathMode { latex, arithmetic }

class MathEmbedData {
  final String source;
  final MathMode mode;

  const MathEmbedData({required this.source, required this.mode});

  factory MathEmbedData.fromJson(String json) {
    try {
      final m = jsonDecode(json) as Map<String, dynamic>;
      return MathEmbedData(
        source: m['source'] as String? ?? '',
        mode:   m['mode'] == 'latex' ? MathMode.latex : MathMode.arithmetic,
      );
    } catch (_) {
      // Legacy: raw string treated as arithmetic
      return MathEmbedData(source: json, mode: MathMode.arithmetic);
    }
  }

  String toJson() => jsonEncode({'source': source, 'mode': mode.name});
}

// ── Edit dialog ───────────────────────────────────────────────────────────────

class MathEditDialog extends StatefulWidget {
  final MathEmbedData initial;
  const MathEditDialog({super.key, required this.initial});

  @override
  State<MathEditDialog> createState() => _MathEditDialogState();
}

class _MathEditDialogState extends State<MathEditDialog> {
  late final TextEditingController _ctrl;
  late MathMode _mode;
  String _preview = '';

  @override
  void initState() {
    super.initState();
    _ctrl    = TextEditingController(text: widget.initial.source);
    _mode    = widget.initial.mode;
    _preview = widget.initial.source;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _updatePreview(String v) => setState(() => _preview = v);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Math'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Mode toggle
            SegmentedButton<MathMode>(
              segments: const [
                ButtonSegment(
                  value: MathMode.arithmetic,
                  label: Text('Calculate'),
                  icon: Icon(Icons.calculate_outlined),
                ),
                ButtonSegment(
                  value: MathMode.latex,
                  label: Text('LaTeX'),
                  icon: Icon(Icons.functions_outlined),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) =>
                  setState(() => _mode = s.first),
            ),
            const SizedBox(height: 12),
            // Input
            TextField(
              controller: _ctrl,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                labelText: _mode == MathMode.arithmetic
                    ? 'Expression  (e.g. (12 + 8) * 3 / 4)'
                    : r'LaTeX  (e.g. \frac{a}{b} + \sqrt{x})',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              onChanged: _updatePreview,
            ),
            const SizedBox(height: 16),
            // Live preview
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: _preview.isEmpty
                  ? Text('Preview',
                      style: TextStyle(color: cs.onSurfaceVariant))
                  : _buildPreview(cs),
            ),
            if (_mode == MathMode.arithmetic) ...[
              const SizedBox(height: 8),
              _QuickButtons(onInsert: (s) {
                final pos = _ctrl.selection.baseOffset
                    .clamp(0, _ctrl.text.length);
                final newText =
                    _ctrl.text.substring(0, pos) + s + _ctrl.text.substring(pos);
                _ctrl.value = TextEditingValue(
                  text: newText,
                  selection: TextSelection.collapsed(offset: pos + s.length),
                );
                _updatePreview(newText);
              }),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _ctrl.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    MathEmbedData(
                      source: _ctrl.text.trim(),
                      mode: _mode,
                    ),
                  ),
          child: const Text('Insert'),
        ),
      ],
    );
  }

  Widget _buildPreview(ColorScheme cs) {
    if (_mode == MathMode.latex) {
      return Math.tex(
        _preview,
        textStyle: TextStyle(fontSize: 16, color: cs.onSurface),
        onErrorFallback: (e) => Text(
          'Invalid LaTeX',
          style: TextStyle(color: cs.error),
        ),
      );
    }
    final result = _evaluate(_preview);
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 15, color: cs.onSurface),
        children: [
          TextSpan(
            text: _preview,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          TextSpan(
            text: '  =  ',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          TextSpan(
            text: result,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: result.startsWith('Error') ? cs.error : cs.primary,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Quick-insert buttons (arithmetic mode) ────────────────────────────────────

class _QuickButtons extends StatelessWidget {
  final void Function(String) onInsert;
  const _QuickButtons({required this.onInsert});

  static const _buttons = [
    '(', ')', '+', '−', '×', '÷', '^', 'sqrt(',
    'sin(', 'cos(', 'tan(', 'log(', 'ln(', 'π', 'e',
  ];

  // Map display symbols → expression strings
  static const _map = {
    '−': '-',
    '×': '*',
    '÷': '/',
    'π': 'pi',
    'e': 'e',
  };

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: _buttons.map((b) {
        return ActionChip(
          label: Text(b, style: const TextStyle(fontSize: 12)),
          padding: EdgeInsets.zero,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onPressed: () => onInsert(_map[b] ?? b),
        );
      }).toList(),
    );
  }
}
