import 'dart:convert';
import 'package:flutter/material.dart';

// ─── Tool enum ────────────────────────────────────────────────────────────────

enum DrawingTool {
  pen,
  highlighter,
  eraser,       // pixel / partial eraser (BlendMode.clear path)
  strokeEraser, // tap a stroke to delete the whole thing
  line,
  rectangle,
  circle,
}

/// Returns true for tools that draw geometric shapes (start + end point).
bool isShapeTool(DrawingTool t) =>
    t == DrawingTool.line ||
    t == DrawingTool.rectangle ||
    t == DrawingTool.circle;

// ─── Stroke model ─────────────────────────────────────────────────────────────

class DrawingStroke {
  final DrawingTool tool;
  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  const DrawingStroke({
    required this.tool,
    required this.points,
    required this.color,
    required this.strokeWidth,
  });

  Map<String, dynamic> toJson() => {
        'tool': tool.name,
        'points': points.map((p) => {'x': p.dx, 'y': p.dy}).toList(),
        'color': color.value,
        'strokeWidth': strokeWidth,
      };

  factory DrawingStroke.fromJson(Map<String, dynamic> j) => DrawingStroke(
        tool: DrawingTool.values.byName(j['tool'] as String),
        points: (j['points'] as List)
            .map((p) => Offset(
                  (p['x'] as num).toDouble(),
                  (p['y'] as num).toDouble(),
                ))
            .toList(),
        color: Color(j['color'] as int),
        strokeWidth: (j['strokeWidth'] as num).toDouble(),
      );
}

// ─── Hit-testing helpers ───────────────────────────────────────────────────────

double _pointToSegmentDistance(Offset p, Offset a, Offset b) {
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  if (dx == 0 && dy == 0) return (p - a).distance;
  final t = ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) /
      (dx * dx + dy * dy);
  final t2 = t.clamp(0.0, 1.0);
  return Offset(p.dx - (a.dx + t2 * dx), p.dy - (a.dy + t2 * dy)).distance;
}

/// Returns true if [point] is within [threshold] pixels of [stroke].
bool strokeTouchedBy(DrawingStroke stroke, Offset point,
    {double threshold = 16.0}) {
  if (stroke.points.isEmpty) return false;

  if (isShapeTool(stroke.tool)) {
    // For shapes, hit-test the outline segments
    if (stroke.points.length < 2) return false;
    final a = stroke.points.first;
    final b = stroke.points.last;

    if (stroke.tool == DrawingTool.line) {
      return _pointToSegmentDistance(point, a, b) <= threshold;
    }
    // Rect / circle: check proximity to the 4 edges of the bounding rect
    final rect = Rect.fromPoints(a, b);
    return _pointToSegmentDistance(point, rect.topLeft, rect.topRight) <=
            threshold ||
        _pointToSegmentDistance(point, rect.topRight, rect.bottomRight) <=
            threshold ||
        _pointToSegmentDistance(point, rect.bottomRight, rect.bottomLeft) <=
            threshold ||
        _pointToSegmentDistance(point, rect.bottomLeft, rect.topLeft) <=
            threshold;
  }

  // Freehand: check every segment
  for (int i = 0; i < stroke.points.length - 1; i++) {
    if (_pointToSegmentDistance(
            point, stroke.points[i], stroke.points[i + 1]) <=
        threshold) return true;
  }
  return false;
}

// ─── Action types for undo / redo ─────────────────────────────────────────────

sealed class DrawAction {}

/// A single stroke was added to the canvas.
final class ActionAddStroke extends DrawAction {
  final DrawingStroke stroke;
  ActionAddStroke(this.stroke);
}

/// One or more strokes were deleted by the stroke-eraser in a single drag.
/// [entries] holds (originalIndex, stroke) so undo can re-insert in order.
final class ActionRemoveStrokes extends DrawAction {
  final List<(int, DrawingStroke)> entries;
  ActionRemoveStrokes(this.entries);
}

// ─── DrawingCanvasScreen ───────────────────────────────────────────────────────

class DrawingCanvasScreen extends StatefulWidget {
  final String? initialJson;

  const DrawingCanvasScreen({super.key, this.initialJson});

  @override
  State<DrawingCanvasScreen> createState() => _DrawingCanvasScreenState();
}

class _DrawingCanvasScreenState extends State<DrawingCanvasScreen> {
  final List<DrawingStroke> _strokes = [];
  final List<DrawAction> _undoStack = [];
  final List<DrawAction> _redoStack = [];
  List<Offset> _currentPoints = [];
  List<(int, DrawingStroke)>? _pendingRemovals; // stroke-eraser in progress

  DrawingTool _tool = DrawingTool.pen;
  Color _color = Colors.black;
  double _strokeWidth = 3.0;

  @override
  void initState() {
    super.initState();
    if (widget.initialJson != null) {
      try {
        final list = jsonDecode(widget.initialJson!) as List;
        _strokes.addAll(
            list.map((e) => DrawingStroke.fromJson(e as Map<String, dynamic>)));
      } catch (_) {}
    }
  }

  String get _serialized =>
      jsonEncode(_strokes.map((s) => s.toJson()).toList());

  bool get _canUndo => _undoStack.isNotEmpty;
  bool get _canRedo => _redoStack.isNotEmpty;

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      final action = _undoStack.removeLast();
      _redoStack.add(action);
      if (action is ActionAddStroke) {
        _strokes.removeLast();
      } else if (action is ActionRemoveStrokes) {
        _reinsert(action.entries);
      }
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    setState(() {
      final action = _redoStack.removeLast();
      _undoStack.add(action);
      if (action is ActionAddStroke) {
        _strokes.add(action.stroke);
      } else if (action is ActionRemoveStrokes) {
        _removeByIdentity(action.entries.map((e) => e.$2).toList());
      }
    });
  }

  /// Re-insert strokes at their original indices (sorted ascending).
  void _reinsert(List<(int, DrawingStroke)> entries) {
    final sorted = List.of(entries)..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (idx, stroke) in sorted) {
      _strokes.insert(idx.clamp(0, _strokes.length), stroke);
    }
  }

  void _removeByIdentity(List<DrawingStroke> targets) {
    for (final target in targets) {
      final i = _strokes.indexWhere((s) => identical(s, target));
      if (i >= 0) _strokes.removeAt(i);
    }
  }

  void _onPanStart(DragStartDetails d) {
    setState(() {
      _currentPoints = [d.localPosition];
      if (_tool == DrawingTool.strokeEraser) {
        _pendingRemovals = [];
      }
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() {
      if (_tool == DrawingTool.strokeEraser) {
        for (int i = _strokes.length - 1; i >= 0; i--) {
          if (strokeTouchedBy(_strokes[i], d.localPosition)) {
            _pendingRemovals!.add((i, _strokes[i]));
            _strokes.removeAt(i);
          }
        }
      } else if (isShapeTool(_tool)) {
        _currentPoints = [_currentPoints.first, d.localPosition];
      } else {
        _currentPoints.add(d.localPosition);
      }
    });
  }

  void _onPanEnd(DragEndDetails _) {
    setState(() {
      if (_tool == DrawingTool.strokeEraser) {
        if (_pendingRemovals != null && _pendingRemovals!.isNotEmpty) {
          _undoStack.add(ActionRemoveStrokes(_pendingRemovals!));
          _redoStack.clear();
        }
        _pendingRemovals = null;
        return;
      }
      if (_currentPoints.length >= 2) {
        final stroke = DrawingStroke(
          tool: _tool,
          points: List.from(_currentPoints),
          color: _tool == DrawingTool.eraser ? Colors.transparent : _color,
          strokeWidth: _tool == DrawingTool.highlighter
              ? _strokeWidth * 4
              : _strokeWidth,
        );
        _strokes.add(stroke);
        _undoStack.add(ActionAddStroke(stroke));
        _redoStack.clear();
      }
      _currentPoints = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drawing'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: _canUndo ? _undo : null,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            onPressed: _canRedo ? _redo : null,
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _serialized),
            child: const Text('Done'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          DrawingToolbar(
            selectedTool: _tool,
            selectedColor: _color,
            strokeWidth: _strokeWidth,
            onToolChanged: (t) => setState(() => _tool = t),
            onColorChanged: (c) => setState(() => _color = c),
            onWidthChanged: (w) => setState(() => _strokeWidth = w),
          ),
          Expanded(
            child: GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: CustomPaint(
                painter: DrawingPainter(
                  strokes: _strokes,
                  currentPoints: _currentPoints,
                  currentTool: _tool,
                  currentColor: _color,
                  currentWidth: _strokeWidth,
                ),
                child: Container(
                  color: Colors.white,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── DrawingPainter ────────────────────────────────────────────────────────────

class DrawingPainter extends CustomPainter {
  final List<DrawingStroke> strokes;
  final List<Offset> currentPoints;
  final DrawingTool currentTool;
  final Color currentColor;
  final double currentWidth;

  DrawingPainter({
    required this.strokes,
    required this.currentPoints,
    required this.currentTool,
    required this.currentColor,
    required this.currentWidth,
  });

  Paint _makePaint(DrawingStroke stroke) {
    return Paint()
      ..color = stroke.tool == DrawingTool.highlighter
          ? stroke.color.withOpacity(0.4)
          : stroke.color
      ..strokeWidth = stroke.strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..blendMode =
          stroke.tool == DrawingTool.eraser ? BlendMode.clear : BlendMode.srcOver;
  }

  void _drawStroke(Canvas canvas, DrawingStroke stroke) {
    if (stroke.points.isEmpty) return;
    final paint = _makePaint(stroke);

    switch (stroke.tool) {
      case DrawingTool.line:
        if (stroke.points.length >= 2) {
          canvas.drawLine(stroke.points.first, stroke.points.last, paint);
        }
      case DrawingTool.rectangle:
        if (stroke.points.length >= 2) {
          canvas.drawRect(
              Rect.fromPoints(stroke.points.first, stroke.points.last), paint);
        }
      case DrawingTool.circle:
        if (stroke.points.length >= 2) {
          canvas.drawOval(
              Rect.fromPoints(stroke.points.first, stroke.points.last), paint);
        }
      default: // pen, highlighter, eraser — freehand path
        if (stroke.points.length < 2) return;
        final path = Path()
          ..moveTo(stroke.points[0].dx, stroke.points[0].dy);
        for (int i = 1; i < stroke.points.length; i++) {
          path.lineTo(stroke.points[i].dx, stroke.points[i].dy);
        }
        canvas.drawPath(path, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // saveLayer is required so that BlendMode.clear (eraser) punches holes in
    // the layer rather than compositing directly with whatever is behind.
    canvas.saveLayer(Offset.zero & size, Paint());

    for (final stroke in strokes) {
      _drawStroke(canvas, stroke);
    }

    // In-progress stroke preview
    if (currentPoints.length >= 2 &&
        currentTool != DrawingTool.strokeEraser) {
      _drawStroke(
        canvas,
        DrawingStroke(
          tool: currentTool,
          points: currentPoints,
          color: currentTool == DrawingTool.eraser
              ? Colors.transparent
              : currentColor,
          strokeWidth: currentTool == DrawingTool.highlighter
              ? currentWidth * 4
              : currentWidth,
        ),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(DrawingPainter old) => true;
}

// ─── DrawingToolbar ────────────────────────────────────────────────────────────

class DrawingToolbar extends StatelessWidget {
  final DrawingTool selectedTool;
  final Color selectedColor;
  final double strokeWidth;
  final ValueChanged<DrawingTool> onToolChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onWidthChanged;

  const DrawingToolbar({
    required this.selectedTool,
    required this.selectedColor,
    required this.strokeWidth,
    required this.onToolChanged,
    required this.onColorChanged,
    required this.onWidthChanged,
  });

  static const _colors = [
    Colors.black,
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.orange,
    Colors.purple,
  ];

  // Eraser is handled separately by _EraserButton (tap again to toggle mode).
  static const _toolsBefore = [
    (DrawingTool.pen,         Icons.edit,                'Pen',    'Pen'),
    (DrawingTool.highlighter, Icons.highlight,           'Hi-lite','Highlighter'),
  ];
  static const _toolsAfter = [
    (DrawingTool.line,        Icons.remove,              'Line',   'Straight line'),
    (DrawingTool.rectangle,   Icons.crop_square_outlined,'Rect',   'Rectangle'),
    (DrawingTool.circle,      Icons.circle_outlined,     'Circle', 'Circle'),
  ];

  bool get _isColorRelevant =>
      selectedTool != DrawingTool.eraser &&
      selectedTool != DrawingTool.strokeEraser;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Tool + colour row ───────────────────────────────────────────
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // Pen + highlighter
                for (final t in _toolsBefore)
                  _ToolButton(
                    icon: t.$2,
                    label: t.$3,
                    tooltip: t.$4,
                    selected: selectedTool == t.$1,
                    onTap: () => onToolChanged(t.$1),
                  ),
                // Eraser — tap again to toggle Pixel ↔ Stroke mode
                _EraserButton(
                  selectedTool: selectedTool,
                  onToolChanged: onToolChanged,
                ),
                // Shape tools
                for (final t in _toolsAfter)
                  _ToolButton(
                    icon: t.$2,
                    label: t.$3,
                    tooltip: t.$4,
                    selected: selectedTool == t.$1,
                    onTap: () => onToolChanged(t.$1),
                  ),
                const SizedBox(width: 4),
                const VerticalDivider(width: 12),
                const SizedBox(width: 4),
                // Colour dots (greyed out when tool has no colour)
                for (final c in _colors)
                  GestureDetector(
                    onTap: _isColorRelevant ? () => onColorChanged(c) : null,
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: _isColorRelevant ? c : c.withOpacity(0.3),
                        shape: BoxShape.circle,
                        border: selectedColor == c && _isColorRelevant
                            ? Border.all(color: cs.primary, width: 2)
                            : Border.all(color: Colors.grey.shade400),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // ── Width slider ────────────────────────────────────────────────
          if (selectedTool != DrawingTool.strokeEraser)
            Row(
              children: [
                const Icon(Icons.line_weight, size: 16),
                Expanded(
                  child: Slider(
                    value: strokeWidth,
                    min: 1.0,
                    max: 20.0,
                    onChanged: onWidthChanged,
                  ),
                ),
                Text('${strokeWidth.toStringAsFixed(0)}px'),
              ],
            ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: selected
              ? BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              Text(label, style: const TextStyle(fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Single eraser button that toggles between pixel-erase and stroke-erase
/// each time it is tapped while already selected.
class _EraserButton extends StatelessWidget {
  final DrawingTool selectedTool;
  final ValueChanged<DrawingTool> onToolChanged;

  const _EraserButton({
    required this.selectedTool,
    required this.onToolChanged,
  });

  bool get _isActive =>
      selectedTool == DrawingTool.eraser ||
      selectedTool == DrawingTool.strokeEraser;

  void _handleTap() {
    if (!_isActive) {
      onToolChanged(DrawingTool.eraser); // first tap → pixel mode
    } else if (selectedTool == DrawingTool.eraser) {
      onToolChanged(DrawingTool.strokeEraser); // toggle to stroke mode
    } else {
      onToolChanged(DrawingTool.eraser); // toggle back to pixel mode
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final subLabel = selectedTool == DrawingTool.strokeEraser ? 'Stroke' : 'Pixel';

    return Tooltip(
      message: _isActive
          ? 'Tap again to switch to ${selectedTool == DrawingTool.eraser ? "Stroke" : "Pixel"} eraser'
          : 'Eraser — tap again to toggle Pixel / Stroke mode',
      child: InkWell(
        onTap: _handleTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: _isActive
              ? BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_fix_normal, size: 20),
              const Text('Erase', style: TextStyle(fontSize: 10)),
              if (_isActive)
                Text(
                  subLabel,
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    color: cs.primary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── FloatingDrawingToolbar ────────────────────────────────────────────────────
//
// A compact, draggable floating panel for touch-friendly inking on mobile.
// Place this widget inside a Stack that also contains the drawing canvas.

class FloatingDrawingToolbar extends StatefulWidget {
  final DrawingTool selectedTool;
  final Color selectedColor;
  final double strokeWidth;
  final ValueChanged<DrawingTool> onToolChanged;
  final ValueChanged<Color> onColorChanged;
  final ValueChanged<double> onWidthChanged;

  const FloatingDrawingToolbar({
    super.key,
    required this.selectedTool,
    required this.selectedColor,
    required this.strokeWidth,
    required this.onToolChanged,
    required this.onColorChanged,
    required this.onWidthChanged,
  });

  @override
  State<FloatingDrawingToolbar> createState() =>
      _FloatingDrawingToolbarState();
}

class _FloatingDrawingToolbarState extends State<FloatingDrawingToolbar> {
  Offset _pos = const Offset(8, 80);

  static const _colors = [
    Colors.black,
    Colors.white,
    Colors.red,
    Colors.blue,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.yellow,
  ];

  static bool _colorRelevantFor(DrawingTool t) =>
      t != DrawingTool.eraser && t != DrawingTool.strokeEraser;

  static IconData _toolIcon(DrawingTool t) => switch (t) {
        DrawingTool.pen => Icons.edit,
        DrawingTool.highlighter => Icons.highlight,
        DrawingTool.eraser => Icons.auto_fix_normal,
        DrawingTool.strokeEraser => Icons.auto_fix_normal,
        DrawingTool.line => Icons.remove,
        DrawingTool.rectangle => Icons.crop_square_outlined,
        DrawingTool.circle => Icons.circle_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final cs = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: _pos.dx,
          top: _pos.dy,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(16),
            color: cs.surface,
            child: SizedBox(
              width: 52,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Drag handle (dragging moves the pill) ──────────────────
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) => setState(() {
                      _pos = Offset(
                        (_pos.dx + d.delta.dx).clamp(0.0, size.width - 52),
                        (_pos.dy + d.delta.dy).clamp(0.0, size.height - 100),
                      );
                    }),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 7),
                      child: Center(
                        child: Container(
                          width: 22,
                          height: 3,
                          decoration: BoxDecoration(
                            color: cs.onSurfaceVariant.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // ── Tool summary — tap to open sheet ──────────────────────
                  GestureDetector(
                    onTap: () => _openSheet(context),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_toolIcon(widget.selectedTool),
                              size: 22, color: cs.primary),
                          if (_colorRelevantFor(widget.selectedTool)) ...[
                            const SizedBox(height: 5),
                            Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: widget.selectedColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: cs.outline.withOpacity(0.5),
                                    width: 1),
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Text(
                            '${widget.strokeWidth.toStringAsFixed(0)}pt',
                            style: TextStyle(
                              fontSize: 9,
                              color: cs.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openSheet(BuildContext context) {
    // Local copies so the sheet stays in sync without needing parent rebuilds.
    DrawingTool tool = widget.selectedTool;
    Color color = widget.selectedColor;
    double width = widget.strokeWidth;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final cs = Theme.of(ctx).colorScheme;

          void changeTool(DrawingTool t) {
            tool = t;
            widget.onToolChanged(t);
            setState(() {}); // rebuild pill
            setSheet(() {}); // rebuild sheet
          }

          void changeColor(Color c) {
            color = c;
            widget.onColorChanged(c);
            setState(() {});
            setSheet(() {});
          }

          void changeWidth(double w) {
            width = w.clamp(1.0, 20.0);
            widget.onWidthChanged(width);
            setState(() {});
            setSheet(() {});
          }

          Widget toolBtn(DrawingTool t, IconData icon, String label) {
            final sel = tool == t;
            return GestureDetector(
              onTap: () => changeTool(t),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 72,
                height: 64,
                decoration: BoxDecoration(
                  color: sel
                      ? cs.primaryContainer
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon,
                        size: 22,
                        color: sel
                            ? cs.onPrimaryContainer
                            : cs.onSurface),
                    const SizedBox(height: 4),
                    Text(label,
                        style: TextStyle(
                            fontSize: 10,
                            color: sel
                                ? cs.onPrimaryContainer
                                : cs.onSurface,
                            fontWeight: sel
                                ? FontWeight.w600
                                : FontWeight.normal)),
                  ],
                ),
              ),
            );
          }

          final eraserActive = tool == DrawingTool.eraser ||
              tool == DrawingTool.strokeEraser;
          Widget eraserBtn() => GestureDetector(
                onTap: () {
                  if (!eraserActive) {
                    changeTool(DrawingTool.eraser);
                  } else if (tool == DrawingTool.eraser) {
                    changeTool(DrawingTool.strokeEraser);
                  } else {
                    changeTool(DrawingTool.eraser);
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 72,
                  height: 64,
                  decoration: BoxDecoration(
                    color: eraserActive
                        ? cs.primaryContainer
                        : cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.auto_fix_normal,
                          size: 22,
                          color: eraserActive
                              ? cs.onPrimaryContainer
                              : cs.onSurface),
                      const SizedBox(height: 4),
                      Text(
                          eraserActive
                              ? (tool == DrawingTool.strokeEraser
                                  ? 'Stroke'
                                  : 'Pixel')
                              : 'Eraser',
                          style: TextStyle(
                              fontSize: 10,
                              color: eraserActive
                                  ? cs.onPrimaryContainer
                                  : cs.onSurface,
                              fontWeight: eraserActive
                                  ? FontWeight.w600
                                  : FontWeight.normal)),
                    ],
                  ),
                ),
              );

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Sheet drag handle
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Tool grid
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      toolBtn(DrawingTool.pen, Icons.edit, 'Pen'),
                      toolBtn(DrawingTool.highlighter, Icons.highlight,
                          'Highlight'),
                      eraserBtn(),
                      toolBtn(DrawingTool.line, Icons.remove, 'Line'),
                      toolBtn(DrawingTool.rectangle,
                          Icons.crop_square_outlined, 'Rect'),
                      toolBtn(DrawingTool.circle, Icons.circle_outlined,
                          'Circle'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Colours
                  if (_colorRelevantFor(tool)) ...[
                    Text('Colour',
                        style: Theme.of(ctx).textTheme.labelMedium),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: _colors
                          .map((c) => GestureDetector(
                                onTap: () => changeColor(c),
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: c,
                                    shape: BoxShape.circle,
                                    border: color == c
                                        ? Border.all(
                                            color: cs.primary, width: 3)
                                        : Border.all(
                                            color: cs.outline
                                                .withOpacity(0.35),
                                            width: 1),
                                  ),
                                  child: color == c
                                      ? Icon(Icons.check,
                                          size: 14,
                                          color:
                                              c.computeLuminance() > 0.5
                                                  ? Colors.black
                                                  : Colors.white)
                                      : null,
                                ),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 16),
                  ],
                  // Width slider
                  if (tool != DrawingTool.strokeEraser) ...[
                    Text('Size',
                        style: Theme.of(ctx).textTheme.labelMedium),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: () => changeWidth(width - 1),
                        ),
                        Expanded(
                          child: Slider(
                            value: width,
                            min: 1,
                            max: 20,
                            divisions: 19,
                            label: width.toStringAsFixed(0),
                            onChanged: changeWidth,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () => changeWidth(width + 1),
                        ),
                        SizedBox(
                          width: 30,
                          child: Text('${width.toStringAsFixed(0)}pt',
                              textAlign: TextAlign.right,
                              style:
                                  Theme.of(ctx).textTheme.bodySmall),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
