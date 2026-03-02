import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import 'drawing_canvas.dart';

/// The return value from [AnnotateImageScreen].
typedef AnnotateImageResult = ({
  List<DrawingStroke> strokes,
  Size canvasSize,
});

/// Full-screen image annotation screen.
///
/// Displays [imagePath] as the background and lets the user draw ink strokes
/// on top of it.  Returns an [AnnotateImageResult] (or `null` if cancelled).
class AnnotateImageScreen extends StatefulWidget {
  final String imagePath;

  /// Pre-existing strokes to load (may be empty).
  final List<DrawingStroke> initialStrokes;

  /// The canvas size at which [initialStrokes] were recorded.
  /// Null if there are no pre-existing strokes.
  final Size? initialCanvasSize;

  const AnnotateImageScreen({
    super.key,
    required this.imagePath,
    this.initialStrokes = const [],
    this.initialCanvasSize,
  });

  @override
  State<AnnotateImageScreen> createState() => _AnnotateImageScreenState();
}

class _AnnotateImageScreenState extends State<AnnotateImageScreen> {
  // Drawing state
  final List<DrawingStroke> _strokes = [];
  final List<DrawAction> _undoStack = [];
  final List<DrawAction> _redoStack = [];
  List<Offset> _currentPoints = [];
  List<(int, DrawingStroke)>? _pendingRemovals;

  DrawingTool _tool = DrawingTool.pen;
  Color _color = Colors.black;
  double _strokeWidth = 3.0;
  bool _palmRejection = false;
  int? _activePointer;

  // Image dimensions (set after async load)
  Size? _naturalSize;

  // Canvas size as laid out (set from LayoutBuilder)
  double? _canvasWidth;
  double? _canvasHeight;
  bool _strokesLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    final file = File(widget.imagePath);
    if (!file.existsSync()) return;
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    if (!mounted) return;
    setState(() {
      _naturalSize = Size(img.width.toDouble(), img.height.toDouble());
    });
    img.dispose();
  }

  /// Rescale pre-existing strokes from [widget.initialCanvasSize] to the
  /// current display canvas size.  Called once after the first layout.
  void _loadScaledStrokes(double displayW, double displayH) {
    if (_strokesLoaded || widget.initialStrokes.isEmpty) {
      _strokesLoaded = true;
      return;
    }
    _strokesLoaded = true;

    final srcW = widget.initialCanvasSize?.width ?? displayW;
    final srcH = widget.initialCanvasSize?.height ?? displayH;
    final scaleX = displayW / srcW;
    final scaleY = displayH / srcH;

    for (final s in widget.initialStrokes) {
      _strokes.add(DrawingStroke(
        tool: s.tool,
        color: s.color,
        strokeWidth: s.strokeWidth,
        points: s.points.map((p) => Offset(p.dx * scaleX, p.dy * scaleY)).toList(),
      ));
    }
  }

  // ── Undo / Redo ────────────────────────────────────────────────────────────

  void _undo() {
    if (_undoStack.isEmpty) return;
    setState(() {
      final action = _undoStack.removeLast();
      _redoStack.add(action);
      if (action is ActionAddStroke) {
        _strokes.removeLast();
      } else if (action is ActionRemoveStrokes) {
        final sorted = List.of(action.entries)
          ..sort((a, b) => a.$1.compareTo(b.$1));
        for (final (idx, stroke) in sorted) {
          _strokes.insert(idx.clamp(0, _strokes.length), stroke);
        }
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
        for (final (_, stroke) in action.entries) {
          final i = _strokes.indexWhere((s) => identical(s, stroke));
          if (i >= 0) _strokes.removeAt(i);
        }
      }
    });
  }

  // ── Pan handlers ───────────────────────────────────────────────────────────

  void _onDown(Offset localPos) {
    setState(() {
      _currentPoints = [localPos];
      if (_tool == DrawingTool.strokeEraser) _pendingRemovals = [];
    });
  }

  void _onMove(Offset localPos) {
    setState(() {
      if (_tool == DrawingTool.strokeEraser) {
        for (int i = _strokes.length - 1; i >= 0; i--) {
          if (strokeTouchedBy(_strokes[i], localPos)) {
            _pendingRemovals!.add((i, _strokes[i]));
            _strokes.removeAt(i);
          }
        }
      } else if (isShapeTool(_tool)) {
        _currentPoints = [_currentPoints.first, localPos];
      } else {
        _currentPoints.add(localPos);
      }
    });
  }

  void _onUp() {
    setState(() {
      if (_tool == DrawingTool.strokeEraser) {
        if (_pendingRemovals != null && _pendingRemovals!.isNotEmpty) {
          _undoStack.add(ActionRemoveStrokes(_pendingRemovals!));
          _redoStack.clear();
        }
        _pendingRemovals = null;
        _currentPoints = [];
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

  void _done() {
    Navigator.pop<AnnotateImageResult>(
      context,
      (
        strokes: List.of(_strokes),
        canvasSize: Size(
          _canvasWidth ?? _naturalSize?.width ?? 800,
          _canvasHeight ?? _naturalSize?.height ?? 600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.pop(context, null),
        ),
        title: const Text('Annotate Image'),
        actions: [
          IconButton(
            icon: Icon(_palmRejection
                ? Icons.pan_tool
                : Icons.pan_tool_outlined),
            tooltip: _palmRejection
                ? 'Palm rejection on — tap to disable'
                : 'Palm rejection off — tap to enable',
            onPressed: () =>
                setState(() => _palmRejection = !_palmRejection),
          ),
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: _undoStack.isEmpty ? null : _undo,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            onPressed: _redoStack.isEmpty ? null : _redo,
          ),
          FilledButton(
            onPressed: _done,
            child: const Text('Done'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _naturalSize == null
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (ctx, constraints) {
                final nat = _naturalSize!;
                final displayW = constraints.maxWidth;
                final displayH = displayW * nat.height / nat.width;

                // Store canvas size for Done and update on first layout.
                if (_canvasWidth != displayW || _canvasHeight != displayH) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() {
                        _canvasWidth = displayW;
                        _canvasHeight = displayH;
                        _loadScaledStrokes(displayW, displayH);
                      });
                    }
                  });
                }

                return Stack(
                  children: [
                    Positioned.fill(
                      child: SingleChildScrollView(
                        child: SizedBox(
                          width: displayW,
                          height: displayH,
                          child: Stack(
                            children: [
                              // Image background
                              Image.file(
                                File(widget.imagePath),
                                width: displayW,
                                height: displayH,
                                fit: BoxFit.fill,
                              ),
                              // Drawing surface
                              Positioned.fill(
                                child: Listener(
                                  behavior: HitTestBehavior.opaque,
                                  onPointerDown: (e) {
                                    if (_activePointer != null) return;
                                    if (_palmRejection) {
                                      if (e.kind != PointerDeviceKind.stylus &&
                                          e.kind !=
                                              PointerDeviceKind
                                                  .invertedStylus) {
                                        if (e.kind ==
                                                PointerDeviceKind.touch &&
                                            e.radiusMajor > 0 &&
                                            e.radiusMajor >= 30) return;
                                      }
                                    }
                                    _activePointer = e.pointer;
                                    _onDown(e.localPosition);
                                  },
                                  onPointerMove: (e) {
                                    if (e.pointer != _activePointer) return;
                                    _onMove(e.localPosition);
                                  },
                                  onPointerUp: (e) {
                                    if (e.pointer != _activePointer) return;
                                    _activePointer = null;
                                    _onUp();
                                  },
                                  onPointerCancel: (e) {
                                    if (e.pointer != _activePointer) return;
                                    _activePointer = null;
                                    _onUp();
                                  },
                                  child: CustomPaint(
                                    painter: DrawingPainter(
                                      strokes: _strokes,
                                      currentPoints: _currentPoints,
                                      currentTool: _tool,
                                      currentColor: _color,
                                      currentWidth: _strokeWidth,
                                    ),
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: FloatingDrawingToolbar(
                        selectedTool: _tool,
                        selectedColor: _color,
                        strokeWidth: _strokeWidth,
                        onToolChanged: (t) => setState(() => _tool = t),
                        onColorChanged: (c) => setState(() => _color = c),
                        onWidthChanged: (w) => setState(() => _strokeWidth = w),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
