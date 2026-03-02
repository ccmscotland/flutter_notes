import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData, HardwareKeyboard;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../core/models/page.dart';
import '../../core/models/page_asset.dart';
import '../../core/database/page_assets_dao.dart';
import '../../core/database/pages_dao.dart';
import '../pages/pages_provider.dart';
import '../tabs/tabs_provider.dart';
import '../../shared/providers/nav_state_provider.dart';
import '../../shared/utils/responsive.dart';
import '../export/export_service.dart';
import '../export/export_sheet.dart';
import 'annotate_image_screen.dart';
import 'drawing_canvas.dart';
import 'table_editor_screen.dart';

class EditorScreen extends ConsumerStatefulWidget {
  final String notebookId;
  final String sectionId;
  final String pageId;

  const EditorScreen({
    super.key,
    required this.notebookId,
    required this.sectionId,
    required this.pageId,
  });

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  QuillController? _controller;
  late TextEditingController _titleCtrl;
  late FocusNode _editorFocusNode;
  late ScrollController _editorScroll;
  Timer? _saveTimer;
  NotePage? _page;
  bool _loading = true;
  String _bgStyle        = 'none';
  int    _bgColor        = 0;
  double _bgSpacing      = 28.0;
  String _pageSize        = 'infinite';
  String _pageOrientation = 'portrait';
  double _zoom            = 1.0;
  final _pageAssetsDao = PageAssetsDao();
  final _imagePicker = ImagePicker();
  PagesDao? _pagesDao;
  late ScrollController _hScroll;

  // ── Ink annotation state (embed-inserting mode) ─────────────────────────
  bool _inkMode = false;
  final List<DrawingStroke> _inkStrokes = [];
  final List<DrawAction> _inkUndoStack = [];
  final List<DrawAction> _inkRedoActions = [];
  List<(int, DrawingStroke)>? _inkPendingRemovals;
  List<Offset> _inkCurrentPoints = [];
  DrawingTool _inkTool = DrawingTool.pen;
  Color _inkColor = Colors.black;
  double _inkWidth = 3.0;

  // ── Page-level persistent ink layer ─────────────────────────────────────
  bool _pageInkMode = false;
  final List<DrawingStroke> _pageInkStrokes = [];
  List<DrawingStroke>? _pageInkSnapshot;
  final List<DrawAction> _pageInkUndoStack = [];
  final List<DrawAction> _pageInkRedoActions = [];
  List<(int, DrawingStroke)>? _pageInkPendingRemovals;
  List<Offset> _pageInkCurrentPoints = [];
  DrawingTool _pageInkTool = DrawingTool.pen;
  Color _pageInkColor = Colors.black;
  double _pageInkWidth = 3.0;
  bool _palmRejection = false;
  int? _pageInkActivePointer;
  bool _fabExpanded = false;

  // ── Pinch-to-zoom (touch only, gesture-arena-free) ───────────────────────
  final Map<int, Offset> _pinchPointers = {};
  double? _pinchBaseDistance;
  double _pinchBaseZoom = 1.0;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController();
    _editorFocusNode = FocusNode();
    _editorScroll = ScrollController();
    _hScroll = ScrollController();
    _loadPage();
  }

  Future<void> _loadPage() async {
    final dao = ref.read(pagesDaoProvider);
    _pagesDao = dao;
    final page = await dao.getById(widget.pageId);
    if (!mounted) return;

    Document doc;
    try {
      if (page != null && page.content.isNotEmpty && page.content != '[]') {
        final deltaJson = jsonDecode(page.content) as List;
        doc = Document.fromJson(deltaJson);
      } else {
        doc = Document();
      }
    } catch (_) {
      doc = Document();
    }

    setState(() {
      _page = page;
      _titleCtrl.text = page?.title ?? '';
      _controller = QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 0),
      );
      _bgStyle        = page?.backgroundStyle   ?? 'none';
      _bgColor        = page?.backgroundColor   ?? 0;
      _bgSpacing      = page?.backgroundSpacing ?? 28.0;
      _pageSize        = page?.pageSize        ?? 'infinite';
      _pageOrientation = page?.pageOrientation ?? 'portrait';
      _loading = false;
    });

    // Load persistent page ink strokes.
    _pageInkStrokes.clear();
    final storedInk = page?.inkStrokes ?? '';
    if (storedInk.isNotEmpty) {
      try {
        final list = jsonDecode(storedInk) as List;
        _pageInkStrokes.addAll(
          list.map((e) => DrawingStroke.fromJson(e as Map<String, dynamic>)));
      } catch (_) {}
    }
    _editorScroll.addListener(_onEditorScroll);

    _controller!.document.changes.listen((_) => _scheduleSave());
    _titleCtrl.addListener(_scheduleSave);

    // Update the tab title with the DB-loaded title.
    // Only call openTab() if no tab exists yet (e.g. deep-link / search nav).
    // When opened via PagesScreen the tab already exists and we must NOT
    // change activePageId, otherwise all IndexedStack editors firing in
    // parallel would fight over which tab appears active.
    final title = page?.title ?? 'Untitled';
    final tabsState = ref.read(tabsProvider);
    if (tabsState.tabs.any((t) => t.pageId == widget.pageId)) {
      ref.read(tabsProvider.notifier).updateTitle(widget.pageId, title);
    } else {
      ref.read(tabsProvider.notifier).openTab(TabEntry(
        pageId: widget.pageId,
        sectionId: widget.sectionId,
        notebookId: widget.notebookId,
        title: title,
      ));
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    if (_page == null || _controller == null) return;
    final deltaJson =
        jsonEncode(_controller!.document.toDelta().toJson());
    final title = _titleCtrl.text.trim().isEmpty
        ? 'Untitled'
        : _titleCtrl.text.trim();
    final updated = _page!.copyWith(
      title: title,
      content: deltaJson,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _pagesDao!.update(updated);
    _page = updated;
    if (mounted) {
      ref.invalidate(pagesProvider(widget.sectionId));
      ref.read(tabsProvider.notifier).updateTitle(widget.pageId, title);
    }
  }

  Future<void> _insertImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => _ImageSourceSheet(),
    );
    if (source == null) return;

    final picked =
        await _imagePicker.pickImage(source: source, imageQuality: 85);
    if (picked == null) return;

    final dir = await getApplicationDocumentsDirectory();
    final assetDir =
        Directory(p.join(dir.path, 'assets', widget.pageId));
    await assetDir.create(recursive: true);

    final assetId = const Uuid().v4();
    final ext = p.extension(picked.path).isEmpty
        ? '.jpg'
        : p.extension(picked.path);
    final destPath = p.join(assetDir.path, '$assetId$ext');
    await File(picked.path).copy(destPath);

    final asset = PageAsset(
      id: assetId,
      pageId: widget.pageId,
      fileName: '$assetId$ext',
      localPath: destPath,
      mimeType: 'image/jpeg',
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _pageAssetsDao.insert(asset);

    final index = _controller!.selection.baseOffset;
    _controller!.document.insert(index, BlockEmbed.image(destPath));
  }

  void _cancelInk() => setState(() => _inkMode = false);

  void _commitInk() {
    if (_inkStrokes.isNotEmpty) {
      final json =
          jsonEncode(_inkStrokes.map((s) => s.toJson()).toList());
      final index = _controller!.selection.baseOffset;
      _controller!.document.insert(
        index,
        BlockEmbed.custom(CustomBlockEmbed('drawing', json)),
      );
    }
    setState(() => _inkMode = false);
  }

  void _inkUndo() {
    if (_inkUndoStack.isEmpty) return;
    setState(() {
      final action = _inkUndoStack.removeLast();
      _inkRedoActions.add(action);
      if (action is ActionAddStroke) {
        _inkStrokes.removeLast();
      } else if (action is ActionRemoveStrokes) {
        final sorted = List.of(action.entries)
          ..sort((a, b) => a.$1.compareTo(b.$1));
        for (final (idx, stroke) in sorted) {
          _inkStrokes.insert(idx.clamp(0, _inkStrokes.length), stroke);
        }
      }
    });
  }

  void _inkRedo() {
    if (_inkRedoActions.isEmpty) return;
    setState(() {
      final action = _inkRedoActions.removeLast();
      _inkUndoStack.add(action);
      if (action is ActionAddStroke) {
        _inkStrokes.add(action.stroke);
      } else if (action is ActionRemoveStrokes) {
        for (final (_, stroke) in action.entries) {
          final i = _inkStrokes.indexWhere((s) => identical(s, stroke));
          if (i >= 0) _inkStrokes.removeAt(i);
        }
      }
    });
  }

  // ── Page ink layer methods ───────────────────────────────────────────────

  void _onEditorScroll() {
    // Background repaints are handled by _BackgroundCanvas (direct subscription).
    // Only rebuild here for the page-ink overlay, which needs parent setState.
    if (_pageInkStrokes.isNotEmpty || _pageInkCurrentPoints.isNotEmpty) {
      setState(() {});
    }
  }

  void _startPageInk() {
    _pageInkSnapshot = List.of(_pageInkStrokes);
    setState(() {
      _pageInkMode = true;
      _pageInkUndoStack.clear();
      _pageInkRedoActions.clear();
      _pageInkPendingRemovals = null;
      _pageInkCurrentPoints = [];
    });
  }

  void _cancelPageInk() {
    setState(() {
      _pageInkStrokes..clear()..addAll(_pageInkSnapshot ?? []);
      _pageInkSnapshot = null;
      _pageInkMode = false;
    });
  }

  Future<void> _commitPageInk() async {
    setState(() => _pageInkMode = false);
    _pageInkSnapshot = null;
    if (_page == null || _pagesDao == null) return;
    final json = jsonEncode(_pageInkStrokes.map((s) => s.toJson()).toList());
    final updated = _page!.copyWith(
      inkStrokes: json,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _pagesDao!.update(updated);
    _page = updated;
  }

  void _pageInkUndo() {
    if (_pageInkUndoStack.isEmpty) return;
    setState(() {
      final action = _pageInkUndoStack.removeLast();
      _pageInkRedoActions.add(action);
      if (action is ActionAddStroke) {
        _pageInkStrokes.removeLast();
      } else if (action is ActionRemoveStrokes) {
        final sorted = List.of(action.entries)
          ..sort((a, b) => a.$1.compareTo(b.$1));
        for (final (idx, stroke) in sorted) {
          _pageInkStrokes.insert(idx.clamp(0, _pageInkStrokes.length), stroke);
        }
      }
    });
  }

  void _pageInkRedo() {
    if (_pageInkRedoActions.isEmpty) return;
    setState(() {
      final action = _pageInkRedoActions.removeLast();
      _pageInkUndoStack.add(action);
      if (action is ActionAddStroke) {
        _pageInkStrokes.add(action.stroke);
      } else if (action is ActionRemoveStrokes) {
        for (final (_, stroke) in action.entries) {
          final i = _pageInkStrokes.indexWhere((s) => identical(s, stroke));
          if (i >= 0) _pageInkStrokes.removeAt(i);
        }
      }
    });
  }

  void _pageInkDown(Offset localPos) {
    final scrollY = _editorScroll.hasClients ? _editorScroll.offset : 0.0;
    final docPt = localPos.translate(0, scrollY);
    setState(() {
      _pageInkCurrentPoints = [docPt];
      if (_pageInkTool == DrawingTool.strokeEraser) {
        _pageInkPendingRemovals = [];
      }
    });
  }

  void _pageInkMove(Offset localPos) {
    final scrollY = _editorScroll.hasClients ? _editorScroll.offset : 0.0;
    final docPt = localPos.translate(0, scrollY);
    setState(() {
      if (_pageInkTool == DrawingTool.strokeEraser) {
        for (int i = _pageInkStrokes.length - 1; i >= 0; i--) {
          if (strokeTouchedBy(_pageInkStrokes[i], docPt)) {
            _pageInkPendingRemovals!.add((i, _pageInkStrokes[i]));
            _pageInkStrokes.removeAt(i);
          }
        }
      } else if (isShapeTool(_pageInkTool)) {
        _pageInkCurrentPoints = [_pageInkCurrentPoints.first, docPt];
      } else {
        _pageInkCurrentPoints.add(docPt);
      }
    });
  }

  void _pageInkUp() {
    setState(() {
      if (_pageInkTool == DrawingTool.strokeEraser) {
        if (_pageInkPendingRemovals != null &&
            _pageInkPendingRemovals!.isNotEmpty) {
          _pageInkUndoStack.add(ActionRemoveStrokes(_pageInkPendingRemovals!));
          _pageInkRedoActions.clear();
        }
        _pageInkPendingRemovals = null;
        _pageInkCurrentPoints = [];
        return;
      }
      if (_pageInkCurrentPoints.length >= 2) {
        final stroke = DrawingStroke(
          tool: _pageInkTool,
          points: List.from(_pageInkCurrentPoints),
          color: _pageInkTool == DrawingTool.eraser
              ? Colors.transparent
              : _pageInkColor,
          strokeWidth: _pageInkTool == DrawingTool.highlighter
              ? _pageInkWidth * 4
              : _pageInkWidth,
        );
        _pageInkStrokes.add(stroke);
        _pageInkUndoStack.add(ActionAddStroke(stroke));
        _pageInkRedoActions.clear();
      }
      _pageInkCurrentPoints = [];
    });
  }

  Future<void> _insertTable() async {
    final size = await showDialog<(int, int)>(
      context: context,
      builder: (_) => const _InsertTableDialog(),
    );
    if (size == null) return;
    final (rows, cols) = size;

    // Build initial data: first row is headers, rest are empty cells
    final data = List.generate(
      rows,
      (r) => List.generate(cols, (c) => r == 0 ? 'Col ${c + 1}' : ''),
    );
    final jsonData = jsonEncode(data);

    final index = _controller!.selection.baseOffset;
    _controller!.document.insert(
      index,
      BlockEmbed.custom(CustomBlockEmbed('table', jsonData)),
    );
  }

  /// Shows a bottom sheet letting the user choose between a blank new table
  /// or pasting one from the clipboard.
  void _showTableInsertOptions() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: const Text('New Table'),
              onTap: () {
                Navigator.pop(ctx);
                _insertTable();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: const Text('Paste from Clipboard'),
              subtitle: const Text('Supports tab-separated and CSV data'),
              onTap: () {
                Navigator.pop(ctx);
                _insertTableFromClipboard();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _insertTableFromClipboard() async {
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
    final index = _controller!.selection.baseOffset;
    _controller!.document.insert(
      index,
      BlockEmbed.custom(CustomBlockEmbed('table', jsonEncode(rows))),
    );
  }

  static List<List<String>>? _parseTabularData(String text) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    // Use tabs if present (Excel / Sheets copy format), otherwise commas.
    final delimiter = lines.first.contains('\t') ? '\t' : ',';
    return lines
        .map((line) => line.split(delimiter).map((c) => c.trim()).toList())
        .toList();
  }

  void _showBackgroundPicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _PageBackgroundSheet(
        currentStyle:   _bgStyle,
        currentColor:   _bgColor,
        currentSpacing: _bgSpacing,
        onChanged: _applyBackground,
      ),
    );
  }

  Future<void> _applyBackground(String style, int color, double spacing) async {
    setState(() {
      _bgStyle   = style;
      _bgColor   = color;
      _bgSpacing = spacing;
    });
    if (_page == null || _pagesDao == null) return;
    final updated = _page!.copyWith(
        backgroundStyle:   style,
        backgroundColor:   color,
        backgroundSpacing: spacing);
    await _pagesDao!.update(updated);
    _page = updated;
  }

  void _adjustZoom(double delta) {
    setState(() => _zoom = (_zoom + delta).clamp(0.5, 3.0));
  }

  void _pinchDown(PointerDownEvent e) {
    // Track all non-mouse pointer kinds (touch, stylus, etc.)
    if (e.kind == PointerDeviceKind.mouse) return;
    _pinchPointers[e.pointer] = e.localPosition;
    if (_pinchPointers.length == 2) {
      final pts = _pinchPointers.values.toList();
      _pinchBaseDistance = (pts[0] - pts[1]).distance;
      _pinchBaseZoom = _zoom;
    }
  }

  void _pinchMove(PointerMoveEvent e) {
    if (!_pinchPointers.containsKey(e.pointer)) return;
    _pinchPointers[e.pointer] = e.localPosition;
    if (_pinchPointers.length == 2 &&
        _pinchBaseDistance != null &&
        _pinchBaseDistance! > 0) {
      final pts = _pinchPointers.values.toList();
      final dist = (pts[0] - pts[1]).distance;
      setState(
          () => _zoom = (_pinchBaseZoom * dist / _pinchBaseDistance!).clamp(0.5, 3.0));
    }
  }

  void _pinchUp(PointerUpEvent e) => _pinchPointers.remove(e.pointer);
  void _pinchCancel(PointerCancelEvent e) => _pinchPointers.remove(e.pointer);

  Widget _buildZoomBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      child: SizedBox(
        height: 28,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(Icons.remove, size: 13),
              iconSize: 13,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
              tooltip: 'Zoom out  (Ctrl + scroll)',
              onPressed: _zoom > 0.5 ? () => _adjustZoom(-0.1) : null,
            ),
            GestureDetector(
              onDoubleTap: () => setState(() => _zoom = 1.0),
              child: SizedBox(
                width: 44,
                child: Text(
                  '${(_zoom * 100).round()}%',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 13),
              iconSize: 13,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
              tooltip: 'Zoom in  (Ctrl + scroll)',
              onPressed: _zoom < 3.0 ? () => _adjustZoom(0.1) : null,
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  // Returns the paper width in logical pixels, or null for infinite mode.
  double? _paperWidthPx() {
    const mmToPx = 3.7795275591; // 1 mm at 96 DPI
    final widthMm = switch (_pageSize) {
      'a5' => _pageOrientation == 'portrait' ? 148.0 : 210.0,
      'a4' => _pageOrientation == 'portrait' ? 210.0 : 297.0,
      'a3' => _pageOrientation == 'portrait' ? 297.0 : 420.0,
      _ => null,
    };
    return widthMm == null ? null : widthMm * mmToPx;
  }

  // Returns the paper height in logical pixels, or null for infinite mode.
  double? _paperHeightPx() {
    const mmToPx = 3.7795275591;
    final heightMm = switch (_pageSize) {
      'a5' => _pageOrientation == 'portrait' ? 210.0 : 148.0,
      'a4' => _pageOrientation == 'portrait' ? 297.0 : 210.0,
      'a3' => _pageOrientation == 'portrait' ? 420.0 : 297.0,
      _ => null,
    };
    return heightMm == null ? null : heightMm * mmToPx;
  }

  void _showPageSizePicker() {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => _PageSizeSheet(
        currentSize:        _pageSize,
        currentOrientation: _pageOrientation,
        onChanged:          _applyPageLayout,
      ),
    );
  }

  Future<void> _applyPageLayout(String size, String orientation) async {
    setState(() {
      _pageSize        = size;
      _pageOrientation = orientation;
    });
    if (_page == null || _pagesDao == null) return;
    final updated = _page!.copyWith(
        pageSize: size, pageOrientation: orientation);
    await _pagesDao!.update(updated);
    _page = updated;
  }

  @override
  void dispose() {
    _editorScroll.removeListener(_onEditorScroll);
    _saveTimer?.cancel();
    _save();
    _controller?.dispose();
    _titleCtrl.dispose();
    _editorFocusNode.dispose();
    _editorScroll.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }

    final inTabMode = ref.watch(tabsProvider).tabs.isNotEmpty;

    // ── AppBar ──────────────────────────────────────────────────────────────
    final appBar = (_inkMode || _pageInkMode)
        ? AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
              onPressed: _inkMode ? _cancelInk : _cancelPageInk,
            ),
            title: Text(_inkMode ? 'Annotate' : 'Page Ink'),
            actions: [
              if (_pageInkMode)
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
                onPressed: _inkMode
                    ? (_inkUndoStack.isEmpty ? null : _inkUndo)
                    : (_pageInkUndoStack.isEmpty ? null : _pageInkUndo),
              ),
              IconButton(
                icon: const Icon(Icons.redo),
                onPressed: _inkMode
                    ? (_inkRedoActions.isEmpty ? null : _inkRedo)
                    : (_pageInkRedoActions.isEmpty ? null : _pageInkRedo),
              ),
              FilledButton(
                onPressed: _inkMode ? _commitInk : _commitPageInk,
                child: const Text('Done'),
              ),
              const SizedBox(width: 8),
            ],
          )
        : AppBar(
            leading: (inTabMode && !ResponsiveLayout.of(context).isWide)
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back to pages',
                    onPressed: () =>
                        ref.read(tabsProvider.notifier).goToBrowse(),
                  )
                : null,
            titleSpacing: 0,
            title: TextField(
              controller: _titleCtrl,
              decoration: const InputDecoration(
                hintText: 'Page title',
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(horizontal: 8),
              ),
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600),
            ),
            actions: ResponsiveLayout.of(context).isPhone
                ? [
                    // Phone: ink only — Page & Table settings are in the toolbar.
                    if (_page != null)
                      IconButton(
                        icon: const Icon(Icons.ios_share),
                        onPressed: () => showExportSheet(
                          context,
                          title: 'Export "${_page!.title}"',
                          showOutputChoice: false,
                          onExport: (fmt, _) =>
                              ExportService().exportPage(context, _page!, fmt),
                        ),
                        tooltip: 'Export page',
                      ),
                    IconButton(
                      icon: const Icon(Icons.brush_outlined),
                      onPressed: _startPageInk,
                      tooltip: 'Page ink',
                    ),
                  ]
                : [
                    // Wide screens: Image + Ink in AppBar; Table/Page/Format in toolbar.
                    if (_page != null)
                      IconButton(
                        icon: const Icon(Icons.ios_share),
                        onPressed: () => showExportSheet(
                          context,
                          title: 'Export "${_page!.title}"',
                          showOutputChoice: false,
                          onExport: (fmt, _) =>
                              ExportService().exportPage(context, _page!, fmt),
                        ),
                        tooltip: 'Export page',
                      ),
                    IconButton(
                      icon: const Icon(Icons.image_outlined),
                      onPressed: _insertImage,
                      tooltip: 'Insert Image',
                    ),
                    IconButton(
                      icon: const Icon(Icons.brush_outlined),
                      onPressed: _startPageInk,
                      tooltip: 'Page ink',
                    ),
                    if (ResponsiveLayout.of(context).isWide)
                      IconButton(
                        icon: Icon(ref.watch(navVisibleProvider)
                            ? Icons.menu_open
                            : Icons.menu),
                        tooltip: ref.watch(navVisibleProvider)
                            ? 'Hide navigation'
                            : 'Show navigation',
                        onPressed: () => ref
                            .read(navVisibleProvider.notifier)
                            .update((v) => !v),
                      ),
                  ],
          );

    // ── Body ─────────────────────────────────────────────────────────────
    final bgColor = _bgColor != 0
        ? Color(_bgColor)
        : Theme.of(context).colorScheme.surface;
    final lineColor = bgColor.computeLuminance() > 0.5
        ? Colors.black.withValues(alpha: 0.13)
        : Colors.white.withValues(alpha: 0.20);

    // When a lined/grid/cornell background is active, snap text line-height
    // to the background spacing so typed lines sit on the ruled lines.
    // Font size is 16px (flutter_quill default); TextStyle.height is a
    // multiplier, so height = spacing/16.
    //
    // Background lines are drawn at y = lineStart, lineStart+sp, …
    // lineStart is measured at runtime via TextPainter so it matches the
    // actual font/platform baseline exactly, regardless of font metrics.
    final bool _alignToLines =
        _bgStyle == 'lined' || _bgStyle == 'grid' || _bgStyle == 'cornell';
    const double _baseFontSize = 16.0;
    final double _lineHeight = _alignToLines ? _bgSpacing / _baseFontSize : 1.15;
    // Measure the real baseline for this font/size/height combination.
    double? _lineStart;
    if (_alignToLines) {
      final _tp = TextPainter(
        text: TextSpan(
          text: 'A',
          style: TextStyle(fontSize: _baseFontSize, height: _lineHeight),
        ),
        textDirection: TextDirection.ltr,
      );
      _tp.layout(maxWidth: double.infinity);
      final _metrics = _tp.computeLineMetrics();
      _tp.dispose();
      _lineStart = _metrics.isNotEmpty
          ? _metrics.first.baseline
          : _bgSpacing / 2 + 5.5; // fallback
    }
    // No top padding in align mode: text starts at y=0, baseline at lineStart.
    final double _topPad = _alignToLines ? 0.0 : 16.0;

    final _alignStyle = DefaultTextBlockStyle(
      TextStyle(
        fontSize: _baseFontSize,
        height: _lineHeight,
        color: Colors.black,
        decoration: TextDecoration.none,
      ),
      const HorizontalSpacing(0, 0),
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
    );
    // Always apply black text; only change line-height when aligning to rules.
    final _baseStyle = DefaultTextBlockStyle(
      const TextStyle(
        fontSize: _baseFontSize,
        height: 1.15,
        color: Colors.black,
        decoration: TextDecoration.none,
      ),
      const HorizontalSpacing(0, 0),
      VerticalSpacing.zero,
      VerticalSpacing.zero,
      null,
    );
    final DefaultStyles _customStyles = _alignToLines
        ? DefaultStyles(paragraph: _alignStyle, align: _alignStyle)
        : DefaultStyles(paragraph: _baseStyle, align: _baseStyle);

    // Core editor stack (shared between infinite and paper modes)
    final pageBreakPx = _paperHeightPx(); // null = infinite mode
    final editorStack = Stack(
      children: [
        // Background lines/grid and page-break bands.
        // _BackgroundCanvas subscribes to the scroll controller directly so it
        // repaints every scroll tick without going through the parent setState.
        if (_bgStyle != 'none' || pageBreakPx != null)
          Positioned.fill(
            child: _BackgroundCanvas(
              scrollController: _editorScroll,
              style: _bgStyle,
              lineColor: lineColor,
              spacing: _bgSpacing,
              lineStart: _lineStart,
              pageBreakInterval: pageBreakPx,
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(16, _topPad, 16, 16),
          child: ScrollbarTheme(
            data: const ScrollbarThemeData(
              thumbVisibility: WidgetStatePropertyAll(true),
              trackVisibility: WidgetStatePropertyAll(true),
              thickness: WidgetStatePropertyAll(10.0),
              radius: Radius.circular(5),
            ),
            child: Scrollbar(
              controller: _editorScroll,
              thumbVisibility: true,
              trackVisibility: true,
              child: QuillEditor(
                controller: _controller!,
                focusNode: _editorFocusNode,
                scrollController: _editorScroll,
                config: QuillEditorConfig(
                  placeholder: 'Start writing...',
                  expands: false,
                  padding: EdgeInsets.zero,
                  customStyles: _customStyles,
                  embedBuilders: [
                    LocalImageEmbedBuilder(),
                    DrawingEmbedBuilder(),
                    TableEmbedBuilder(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );

    // Zoom transform — scales content by _zoom; ClipRect hides overflow.
    // OverflowBox is used instead of SizedBox so the child can exceed the
    // tight constraints imposed by Container/LayoutBuilder when zoom < 1
    // (SizedBox would be clamped to the parent max, leaving the lower portion
    // of the page uncovered after the visual scale transform).
    Widget _zoomed(Widget child, BoxConstraints c) {
      if (_zoom == 1.0) return child;
      final w = c.maxWidth  / _zoom;
      final h = c.maxHeight / _zoom;
      return ClipRect(
        child: Transform.scale(
          scale: _zoom,
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: w, maxWidth: w,
            minHeight: h, maxHeight: h,
            child: child,
          ),
        ),
      );
    }

    final paperWidth = _paperWidthPx();
    final quillEditor = Expanded(
      child: Listener(
        // Ctrl+scroll → zoom (desktop); pinch → zoom (touch)
        onPointerSignal: (event) {
          if (event is PointerScrollEvent &&
              HardwareKeyboard.instance.isControlPressed) {
            _adjustZoom(-event.scrollDelta.dy / 500);
          }
        },
        onPointerDown: _pinchDown,
        onPointerMove: _pinchMove,
        onPointerUp: _pinchUp,
        onPointerCancel: _pinchCancel,
        child: paperWidth != null
            // ── Paper mode: grey desk + centred paper column with shadow ──
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: LayoutBuilder(builder: (ctx, outerConstraints) {
                  final displayW = paperWidth * _zoom;
                  final needsHScroll = displayW > outerConstraints.maxWidth;
                  final scrollW = needsHScroll
                      ? displayW
                      : outerConstraints.maxWidth;
                  return ScrollbarTheme(
                    data: ScrollbarThemeData(
                      thumbVisibility:
                          WidgetStatePropertyAll(needsHScroll),
                      trackVisibility:
                          WidgetStatePropertyAll(needsHScroll),
                      thickness: const WidgetStatePropertyAll(10.0),
                      radius: const Radius.circular(5),
                    ),
                    child: Scrollbar(
                    controller: _hScroll,
                    thumbVisibility: needsHScroll,
                    trackVisibility: needsHScroll,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      controller: _hScroll,
                      child: SizedBox(
                        width: scrollW,
                        height: outerConstraints.maxHeight,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            width: displayW,
                            // Cap to actual page height at current zoom so the
                            // grey desk is visible below the paper when zoomed
                            // out enough to see the full page.
                            height: (pageBreakPx! * _zoom)
                                .clamp(0.0, outerConstraints.maxHeight),
                            decoration: BoxDecoration(
                              color: bgColor,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.18),
                                  blurRadius: 10,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: LayoutBuilder(
                              builder: (_, c) => _zoomed(editorStack, c),
                            ),
                          ),
                        ),
                      ),
                    ),    // closes SingleChildScrollView
                    ),    // closes Scrollbar
                  );      // closes ScrollbarTheme
                }),
              )
            // ── Infinite mode: fills available space ──────────────────────
            : ColoredBox(
                color: bgColor,
                child: LayoutBuilder(
                  builder: (_, c) => _zoomed(editorStack, c),
                ),
              ),
      ),
    );

    // Speed-dial FAB for phone (Image + Table insert actions).
    final bool showFab = _controller != null &&
        !_inkMode &&
        !_pageInkMode &&
        ResponsiveLayout.of(context).isPhone;
    final cs = Theme.of(context).colorScheme;

    Widget? fab;
    if (showFab) {
      fab = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Image mini-FAB
          AnimatedOpacity(
            opacity: _fabExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_fabExpanded,
              child: AnimatedSlide(
                offset: _fabExpanded ? Offset.zero : const Offset(0, 0.5),
                duration: const Duration(milliseconds: 150),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('Image',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurface)),
                      ),
                      const SizedBox(width: 8),
                      FloatingActionButton.small(
                        heroTag: 'fab_image',
                        onPressed: () {
                          setState(() => _fabExpanded = false);
                          _insertImage();
                        },
                        tooltip: 'Insert Image',
                        child: const Icon(Icons.image_outlined),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Table mini-FAB
          AnimatedOpacity(
            opacity: _fabExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_fabExpanded,
              child: AnimatedSlide(
                offset: _fabExpanded ? Offset.zero : const Offset(0, 0.5),
                duration: const Duration(milliseconds: 150),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('Table',
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurface)),
                      ),
                      const SizedBox(width: 8),
                      FloatingActionButton.small(
                        heroTag: 'fab_table',
                        onPressed: () {
                          setState(() => _fabExpanded = false);
                          _showTableInsertOptions();
                        },
                        tooltip: 'Insert Table',
                        child: const Icon(Icons.table_chart_outlined),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Main FAB
          FloatingActionButton(
            heroTag: 'fab_main',
            onPressed: () => setState(() => _fabExpanded = !_fabExpanded),
            tooltip: _fabExpanded ? 'Close' : 'Insert',
            child: AnimatedRotation(
              turns: _fabExpanded ? 0.125 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.add),
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: appBar,
      floatingActionButton: fab,
      body: Stack(
        children: [
          // ── Layer 1: normal editor (always visible) ──────────────────────
          Column(
            children: [
              if (!_inkMode && !_pageInkMode) ...[
                Focus(
                  descendantsAreFocusable: false,
                  child: _TabbedToolbar(
                    controller: _controller!,
                    onShowBackground: _showBackgroundPicker,
                    onShowPageSize: _showPageSizePicker,
                    onInsertTable: _showTableInsertOptions,
                  ),
                ),
                const Divider(height: 1),
              ],
              quillEditor,
              // ── Zoom status bar ──────────────────────────────────────────
              if (!_inkMode && !_pageInkMode) _buildZoomBar(context),
            ],
          ),

          // ── Layer 2: transparent ink overlay (ink mode only) ─────────────
          if (_inkMode)
            Positioned.fill(
              child: Column(
                children: [
                  // Ink toolbar sits at the top of the overlay
                  DrawingToolbar(
                    selectedTool: _inkTool,
                    selectedColor: _inkColor,
                    strokeWidth: _inkWidth,
                    onToolChanged: (t) => setState(() => _inkTool = t),
                    onColorChanged: (c) => setState(() => _inkColor = c),
                    onWidthChanged: (w) => setState(() => _inkWidth = w),
                  ),
                  // Transparent drawing surface — text shows through
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (d) => setState(() {
                        _inkCurrentPoints = [d.localPosition];
                        if (_inkTool == DrawingTool.strokeEraser) {
                          _inkPendingRemovals = [];
                        }
                      }),
                      onPanUpdate: (d) => setState(() {
                        if (_inkTool == DrawingTool.strokeEraser) {
                          for (int i = _inkStrokes.length - 1; i >= 0; i--) {
                            if (strokeTouchedBy(_inkStrokes[i], d.localPosition)) {
                              _inkPendingRemovals!.add((i, _inkStrokes[i]));
                              _inkStrokes.removeAt(i);
                            }
                          }
                        } else if (isShapeTool(_inkTool)) {
                          _inkCurrentPoints = [
                            _inkCurrentPoints.first,
                            d.localPosition
                          ];
                        } else {
                          _inkCurrentPoints.add(d.localPosition);
                        }
                      }),
                      onPanEnd: (_) => setState(() {
                        if (_inkTool == DrawingTool.strokeEraser) {
                          if (_inkPendingRemovals != null &&
                              _inkPendingRemovals!.isNotEmpty) {
                            _inkUndoStack.add(ActionRemoveStrokes(_inkPendingRemovals!));
                            _inkRedoActions.clear();
                          }
                          _inkPendingRemovals = null;
                          _inkCurrentPoints = [];
                          return;
                        }
                        if (_inkCurrentPoints.length >= 2) {
                          final stroke = DrawingStroke(
                            tool: _inkTool,
                            points: List.from(_inkCurrentPoints),
                            color: _inkTool == DrawingTool.eraser
                                ? Colors.transparent
                                : _inkColor,
                            strokeWidth: _inkTool == DrawingTool.highlighter
                                ? _inkWidth * 4
                                : _inkWidth,
                          );
                          _inkStrokes.add(stroke);
                          _inkUndoStack.add(ActionAddStroke(stroke));
                          _inkRedoActions.clear();
                        }
                        _inkCurrentPoints = [];
                      }),
                      child: CustomPaint(
                        painter: DrawingPainter(
                          strokes: _inkStrokes,
                          currentPoints: _inkCurrentPoints,
                          currentTool: _inkTool,
                          currentColor: _inkColor,
                          currentWidth: _inkWidth,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Layer 3: persistent page ink overlay ──────────────────────────
          if (_pageInkStrokes.isNotEmpty || _pageInkMode)
            Positioned.fill(
              child: _pageInkMode
                  ? Stack(
                      children: [
                        Positioned.fill(
                          child: Listener(
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (e) {
                              if (_pageInkActivePointer != null) return;
                              if (_palmRejection) {
                                if (e.kind != PointerDeviceKind.stylus &&
                                    e.kind != PointerDeviceKind.invertedStylus) {
                                  if (e.kind == PointerDeviceKind.touch &&
                                      e.radiusMajor > 0 &&
                                      e.radiusMajor >= 30) return;
                                }
                              }
                              _pageInkActivePointer = e.pointer;
                              _pageInkDown(e.localPosition);
                            },
                            onPointerMove: (e) {
                              if (e.pointer != _pageInkActivePointer) return;
                              _pageInkMove(e.localPosition);
                            },
                            onPointerUp: (e) {
                              if (e.pointer != _pageInkActivePointer) return;
                              _pageInkActivePointer = null;
                              _pageInkUp();
                            },
                            onPointerCancel: (e) {
                              if (e.pointer != _pageInkActivePointer) return;
                              _pageInkActivePointer = null;
                              _pageInkUp();
                            },
                            child: CustomPaint(
                              painter: _PageInkPainter(
                                strokes: _pageInkStrokes,
                                currentPoints: _pageInkCurrentPoints,
                                currentTool: _pageInkTool,
                                currentColor: _pageInkColor,
                                currentWidth: _pageInkWidth,
                                scrollOffset: _editorScroll.hasClients
                                    ? _editorScroll.offset
                                    : 0,
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ),
                        ),
                        Positioned.fill(
                          child: FloatingDrawingToolbar(
                            selectedTool: _pageInkTool,
                            selectedColor: _pageInkColor,
                            strokeWidth: _pageInkWidth,
                            onToolChanged: (t) =>
                                setState(() => _pageInkTool = t),
                            onColorChanged: (c) =>
                                setState(() => _pageInkColor = c),
                            onWidthChanged: (w) =>
                                setState(() => _pageInkWidth = w),
                          ),
                        ),
                      ],
                    )
                  : IgnorePointer(
                      child: CustomPaint(
                        painter: _PageInkPainter(
                          strokes: _pageInkStrokes,
                          currentPoints: const [],
                          currentTool: DrawingTool.pen,
                          currentColor: Colors.black,
                          currentWidth: 1,
                          scrollOffset: _editorScroll.hasClients
                              ? _editorScroll.offset
                              : 0,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

class _ImageSourceSheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: const Text('Camera'),
            onTap: () => Navigator.pop(context, ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Gallery'),
            onTap: () => Navigator.pop(context, ImageSource.gallery),
          ),
        ],
      ),
    );
  }
}

/// Embed builder for local file images (tap to resize).
class LocalImageEmbedBuilder extends EmbedBuilder {
  @override
  String get key => BlockEmbed.imageType;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final data  = embedContext.node.value.data as String;
    final embed = _ImageEmbed.parse(data);
    return _ResizableImage(embed: embed, embedContext: embedContext);
  }
}

/// Stores the path and optional explicit width for an image embed.
///
/// Serialised as a plain path (legacy / no custom width) or as JSON
/// `{"path":"…","width":400.0}` where width is in logical pixels (≥ 2.0).
/// Values < 2.0 are treated as legacy fractions and ignored (→ full width).
class _ImageEmbed {
  const _ImageEmbed({
    required this.path,
    this.widthPixels,
    this.inkStrokes,
    this.inkCanvasWidth,
    this.inkCanvasHeight,
    this.compositePath,
  });

  final String  path;
  final double? widthPixels;      // logical pixels, null = full width
  final List<DrawingStroke>? inkStrokes;
  final double? inkCanvasWidth;   // canvas width when strokes were drawn
  final double? inkCanvasHeight;  // canvas height when strokes were drawn
  final String? compositePath;    // path to baked composite PNG (image + strokes)

  static _ImageEmbed parse(String data) {
    try {
      final m = jsonDecode(data) as Map<String, dynamic>;
      final w = (m['width'] as num?)?.toDouble();

      List<DrawingStroke>? strokes;
      final rawStrokes = m['inkStrokes'] as List?;
      if (rawStrokes != null) {
        strokes = rawStrokes
            .map((e) => DrawingStroke.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      return _ImageEmbed(
        path: m['path'] as String,
        // Ignore legacy fraction values (< 2.0)
        widthPixels: (w != null && w >= 2.0) ? w : null,
        inkStrokes: strokes,
        inkCanvasWidth:  (m['inkCanvasWidth']  as num?)?.toDouble(),
        inkCanvasHeight: (m['inkCanvasHeight'] as num?)?.toDouble(),
        compositePath: m['compositePath'] as String?,
      );
    } catch (_) {
      return _ImageEmbed(path: data);
    }
  }

  String toData() {
    final hasInk = inkStrokes != null && inkStrokes!.isNotEmpty;
    if (widthPixels == null && !hasInk && compositePath == null) return path;
    final m = <String, dynamic>{'path': path};
    if (widthPixels != null) m['width'] = widthPixels;
    if (hasInk) {
      m['inkStrokes']     = inkStrokes!.map((s) => s.toJson()).toList();
      m['inkCanvasWidth']  = inkCanvasWidth;
      m['inkCanvasHeight'] = inkCanvasHeight;
    }
    if (compositePath != null) m['compositePath'] = compositePath;
    return jsonEncode(m);
  }
}

/// Image widget that sits inside a Quill embed.
///
/// Trigger annotation: **long-press** anywhere on the image.
/// Trigger resize:     tap the ↔ badge at the bottom-right corner.
///
/// The GestureDetector is the ROOT widget so it wins the gesture arena
/// over Quill's ancestor EditorTextSelectionGestureDetector (same pattern
/// as _InlineTableWidget, which is confirmed to work).
class _ResizableImage extends StatefulWidget {
  const _ResizableImage({required this.embed, required this.embedContext});

  final _ImageEmbed  embed;
  final EmbedContext embedContext;

  @override
  State<_ResizableImage> createState() => _ResizableImageState();
}

class _ResizableImageState extends State<_ResizableImage> {
  _ImageEmbed  get embed        => widget.embed;
  EmbedContext get embedContext => widget.embedContext;

  double _containerWidth = double.infinity;

  void _showOptions() {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.draw_outlined),
              title: const Text('Annotate image'),
              onTap: () { Navigator.pop(sheetCtx); _startAnnotation(); },
            ),
            ListTile(
              leading: const Icon(Icons.photo_size_select_large),
              title: const Text('Resize image'),
              onTap: () { Navigator.pop(sheetCtx); _showSizePicker(); },
            ),
          ],
        ),
      ),
    );
  }

  void _showSizePicker() {
    final containerWidth = _containerWidth;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _ImageSizePicker(
        initialPixels: embed.widthPixels,
        maxPixels: containerWidth,
        onApply: (pixels) {
          final updated = _ImageEmbed(
            path: embed.path,
            widthPixels: pixels,
            inkStrokes: embed.inkStrokes,
            inkCanvasWidth: embed.inkCanvasWidth,
            inkCanvasHeight: embed.inkCanvasHeight,
            compositePath: embed.compositePath,
          );
          embedContext.controller.replaceText(
            embedContext.node.documentOffset,
            1,
            BlockEmbed.image(updated.toData()),
            null,
          );
        },
      ),
    );
  }

  Future<void> _startAnnotation() async {
    if (embedContext.readOnly) return;
    final result = await Navigator.push<AnnotateImageResult>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => AnnotateImageScreen(
          imagePath: embed.path,
          // Always re-edit from the original vector strokes — not the composite
          // raster — so the user works at full fidelity.
          initialStrokes: embed.inkStrokes ?? [],
          initialCanvasSize: (embed.inkCanvasWidth != null &&
                  embed.inkCanvasHeight != null)
              ? Size(embed.inkCanvasWidth!, embed.inkCanvasHeight!)
              : null,
        ),
      ),
    );
    if (result == null || !mounted) return;

    // Bake annotation strokes into a composite PNG so annotations are literal
    // image pixels — they zoom, pan, and resize with the image perfectly.
    String? compositePath;
    if (result.strokes.isNotEmpty) {
      try {
        final bytes = await File(embed.path).readAsBytes();
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        final img   = frame.image;
        final natW  = img.width.toDouble();
        final natH  = img.height.toDouble();

        final recorder = ui.PictureRecorder();
        final canvas   = ui.Canvas(recorder);
        canvas.drawImage(img, Offset.zero, Paint());
        img.dispose();

        // Scale stroke coords (annotation-canvas space) → natural image pixels.
        canvas.save();
        canvas.scale(
          natW / result.canvasSize.width,
          natH / result.canvasSize.height,
        );
        DrawingPainter(
          strokes: result.strokes,
          currentPoints: const [],
          currentTool: DrawingTool.pen,
          currentColor: Colors.black,
          currentWidth: 1,
        ).paint(canvas, result.canvasSize);
        canvas.restore();

        final picture      = recorder.endRecording();
        final compositeImg = await picture.toImage(natW.round(), natH.round());
        picture.dispose();
        final byteData = await compositeImg.toByteData(
            format: ui.ImageByteFormat.png);
        compositeImg.dispose();

        // Use a timestamp in the filename so Flutter's image cache never
        // serves a stale version when the user annotates more than once.
        final dir       = p.dirname(embed.path);
        final name      = p.basenameWithoutExtension(embed.path);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        compositePath   = '$dir/${name}_annotated_$timestamp.png';
        await File(compositePath).writeAsBytes(byteData!.buffer.asUint8List());

        // Evict the old composite from Flutter's image cache and delete the
        // file so storage doesn't grow unboundedly across re-annotations.
        if (embed.compositePath != null) {
          try {
            await FileImage(File(embed.compositePath!)).evict();
            await File(embed.compositePath!).delete();
          } catch (_) {}
        }
      } catch (e) {
        debugPrint('Annotation bake failed: $e');
      }
    } else {
      // All strokes cleared — remove the stale composite.
      if (embed.compositePath != null) {
        try {
          await FileImage(File(embed.compositePath!)).evict();
          await File(embed.compositePath!).delete();
        } catch (_) {}
      }
    }

    if (!mounted) return;
    final updated = _ImageEmbed(
      path: embed.path,
      widthPixels: embed.widthPixels,
      inkStrokes: result.strokes.isEmpty ? null : result.strokes,
      inkCanvasWidth:  result.strokes.isEmpty ? null : result.canvasSize.width,
      inkCanvasHeight: result.strokes.isEmpty ? null : result.canvasSize.height,
      compositePath: compositePath,
    );
    embedContext.controller.replaceText(
      embedContext.node.documentOffset,
      1,
      BlockEmbed.image(updated.toData()),
      null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasComposite = embed.compositePath != null &&
        File(embed.compositePath!).existsSync();
    final displayFile = File(hasComposite ? embed.compositePath! : embed.path);

    // Legacy: embeds that have vector strokes but no composite yet.
    final hasLegacyInk = !hasComposite &&
        embed.inkStrokes != null &&
        embed.inkStrokes!.isNotEmpty;

    // Root widget is the GestureDetector so it wins the Quill gesture arena
    // (same pattern as _InlineTableWidget).  Tap opens a bottom sheet with
    // Annotate and Resize options.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: embedContext.readOnly ? null : _showOptions,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final containerWidth = constraints.maxWidth;
          _containerWidth = containerWidth;
          final displayWidth   = embed.widthPixels == null
              ? containerWidth
              : embed.widthPixels!.clamp(48.0, containerWidth);

          final displayHeight = hasLegacyInk && embed.inkCanvasWidth != null
              ? displayWidth * embed.inkCanvasHeight! / embed.inkCanvasWidth!
              : null;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Stack(
                alignment: Alignment.topLeft,
                children: [
                  // Image (composite when available, original otherwise).
                  // key: ValueKey forces widget rebuild (and cache miss) when
                  // the composite path changes after re-annotation.
                  displayFile.existsSync()
                      ? Image.file(displayFile,
                          key: ValueKey(displayFile.path),
                          width: displayWidth,
                          fit: BoxFit.contain,
                          alignment: Alignment.topLeft)
                      : SizedBox(
                          width: displayWidth,
                          child: const Icon(Icons.broken_image, size: 48)),

                  // Legacy vector overlay for old embeds without a composite.
                  if (hasLegacyInk && displayHeight != null)
                    Positioned.fill(
                      child: SizedBox(
                        width: displayWidth,
                        height: displayHeight,
                        child: CustomPaint(
                          painter: _ScaledInkPainter(
                            strokes: embed.inkStrokes!,
                            inkCanvasWidth:  embed.inkCanvasWidth!,
                            inkCanvasHeight: embed.inkCanvasHeight!,
                            displayWidth:  displayWidth,
                            displayHeight: displayHeight,
                          ),
                        ),
                      ),
                    ),

                  // Tap-hint badge (top-right) — visual only; the tap on the
                  // root GestureDetector opens the options bottom sheet.
                  if (!embedContext.readOnly)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: const BorderRadius.only(
                            bottomLeft: Radius.circular(6),
                            topRight:   Radius.circular(4),
                          ),
                        ),
                        child: const Icon(Icons.more_vert,
                            color: Colors.white, size: 14),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Bottom sheet that lets the user enter an image width in pixels.
///
/// Shows a [TextField] (numeric, "px" suffix) and a [Slider] that stay in
/// sync.  An "Apply" button commits the change; "Full width" clears it.
class _ImageSizePicker extends StatefulWidget {
  const _ImageSizePicker({
    required this.initialPixels,
    required this.maxPixels,
    required this.onApply,
  });

  final double?            initialPixels;
  final double             maxPixels;
  final void Function(double?) onApply;

  @override
  State<_ImageSizePicker> createState() => _ImageSizePickerState();
}

class _ImageSizePickerState extends State<_ImageSizePicker> {
  static const double _minPx = 48.0;

  late final TextEditingController _textCtrl;
  late double _sliderValue; // clamped to [_minPx, maxPixels]

  @override
  void initState() {
    super.initState();
    final initial = (widget.initialPixels ?? widget.maxPixels)
        .clamp(_minPx, widget.maxPixels);
    _sliderValue = initial;
    _textCtrl    = TextEditingController(text: initial.round().toString());
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  void _onTextChanged(String v) {
    final parsed = double.tryParse(v);
    if (parsed != null) {
      setState(() {
        _sliderValue = parsed.clamp(_minPx, widget.maxPixels);
      });
    }
  }

  void _onSliderChanged(double v) {
    setState(() {
      _sliderValue = v;
      _textCtrl.text = v.round().toString();
      _textCtrl.selection = TextSelection.collapsed(
          offset: _textCtrl.text.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs     = Theme.of(context).colorScheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Image width', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    suffixText: 'px',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: _onTextChanged,
                ),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  widget.onApply(null); // null = full width
                },
                child: const Text('Full width'),
              ),
            ],
          ),
          Slider(
            min: _minPx,
            max: widget.maxPixels,
            value: _sliderValue,
            onChanged: _onSliderChanged,
          ),
          const SizedBox(height: 4),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              final px = double.tryParse(_textCtrl.text);
              widget.onApply(
                px != null ? px.clamp(_minPx, widget.maxPixels) : _sliderValue,
              );
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}

/// Embed builder for hand-drawn strokes
class DrawingEmbedBuilder extends EmbedBuilder {
  @override
  String get key => 'drawing';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final jsonStr = embedContext.node.value.data as String;
    List<DrawingStroke> strokes = [];
    try {
      final list = jsonDecode(jsonStr) as List;
      strokes = list
          .map((e) => DrawingStroke.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {}

    // Compute bounding box so the embed only takes the height it needs.
    double maxY = 200;
    for (final s in strokes) {
      for (final p in s.points) {
        if (p.dy > maxY) maxY = p.dy;
      }
    }
    final height = maxY + 16;

    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: DrawingPainter(
          strokes: strokes,
          currentPoints: const [],
          currentTool: DrawingTool.pen,
          currentColor: Colors.black,
          currentWidth: 1,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Dialog asking the user for the initial number of rows and columns.
class _InsertTableDialog extends StatefulWidget {
  const _InsertTableDialog();

  @override
  State<_InsertTableDialog> createState() => _InsertTableDialogState();
}

class _InsertTableDialogState extends State<_InsertTableDialog> {
  int _rows = 3;
  int _cols = 3;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Insert Table'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CountRow(
            label: 'Rows',
            value: _rows,
            onDecrement: _rows > 1 ? () => setState(() => _rows--) : null,
            onIncrement: _rows < 20 ? () => setState(() => _rows++) : null,
          ),
          const SizedBox(height: 12),
          _CountRow(
            label: 'Columns',
            value: _cols,
            onDecrement: _cols > 1 ? () => setState(() => _cols--) : null,
            onIncrement: _cols < 10 ? () => setState(() => _cols++) : null,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, (_rows, _cols)),
          child: const Text('Insert'),
        ),
      ],
    );
  }
}

class _CountRow extends StatelessWidget {
  final String label;
  final int value;
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;

  const _CountRow({
    required this.label,
    required this.value,
    required this.onDecrement,
    required this.onIncrement,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 80, child: Text(label)),
        IconButton(icon: const Icon(Icons.remove), onPressed: onDecrement),
        SizedBox(
          width: 32,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
        ),
        IconButton(icon: const Icon(Icons.add), onPressed: onIncrement),
      ],
    );
  }
}

/// Embed builder that renders a table stored as a JSON 2-D list.
class TableEmbedBuilder extends EmbedBuilder {
  @override
  String get key => 'table';

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final jsonStr = embedContext.node.value.data as String;
    List<List<String>> rows;
    try {
      rows = (jsonDecode(jsonStr) as List)
          .map((r) => (r as List).map((c) => c.toString()).toList())
          .toList();
    } catch (_) {
      rows = [['Error']];
    }
    return _InlineTableWidget(initialRows: rows, embedContext: embedContext);
  }
}

// ── Inline table editor ───────────────────────────────────────────────────────

class _InlineTableWidget extends StatefulWidget {
  final List<List<String>> initialRows;
  final EmbedContext embedContext;

  const _InlineTableWidget({
    required this.initialRows,
    required this.embedContext,
  });

  @override
  State<_InlineTableWidget> createState() => _InlineTableWidgetState();
}

class _InlineTableWidgetState extends State<_InlineTableWidget> {
  late List<List<String>> _viewRows;
  int? _sortColumn;
  bool _sortAscending = true;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _viewRows = _deepCopy(widget.initialRows);
  }

  @override
  void didUpdateWidget(_InlineTableWidget old) {
    super.didUpdateWidget(old);
    _viewRows = _deepCopy(widget.initialRows);
    _sortColumn = null;
  }

  static List<List<String>> _deepCopy(List<List<String>> src) =>
      src.map((r) => List<String>.of(r)).toList();

  // ── Edit (navigate to TableEditorScreen) ───────────────────────────────────

  Future<void> _editTable() async {
    if (widget.embedContext.readOnly) return;
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => TableEditorScreen(initialData: _viewRows),
        fullscreenDialog: true,
      ),
    );
    if (result == null) return;
    final updated = (jsonDecode(result) as List)
        .map((r) => (r as List).map((c) => c.toString()).toList())
        .toList();
    final offset = widget.embedContext.node.documentOffset;
    setState(() {
      _viewRows = updated;
      _sortColumn = null;
    });
    widget.embedContext.controller.replaceText(
      offset,
      1,
      CustomBlockEmbed('table', result),
      null,
    );
  }

  // ── Sort ───────────────────────────────────────────────────────────────────

  Future<void> _promptSortByColumn(int colIndex) async {
    bool ascending =
        _sortColumn == colIndex ? !_sortAscending : true; // toggle if same col
    bool hasHeaderRow = true;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Text('Sort by column ${colIndex + 1}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: const Text('Table has a header row'),
                subtitle: const Text('Row 1 stays fixed at the top'),
                value: hasHeaderRow,
                onChanged: (v) => setDlgState(() => hasHeaderRow = v),
                contentPadding: EdgeInsets.zero,
              ),
              const Divider(),
              RadioListTile<bool>(
                title: const Text('A → Z  (ascending)'),
                value: true,
                groupValue: ascending,
                onChanged: (v) => setDlgState(() => ascending = v!),
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<bool>(
                title: const Text('Z → A  (descending)'),
                value: false,
                groupValue: ascending,
                onChanged: (v) => setDlgState(() => ascending = v!),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                _applySortByColumn(colIndex, ascending, hasHeaderRow);
              },
              child: const Text('Sort'),
            ),
          ],
        ),
      ),
    );
  }

  void _applySortByColumn(int colIndex, bool ascending, bool hasHeaderRow) {
    final rows = _deepCopy(_viewRows);
    final header = hasHeaderRow && rows.isNotEmpty ? rows.removeAt(0) : null;

    rows.sort((a, b) {
      final av = colIndex < a.length ? a[colIndex] : '';
      final bv = colIndex < b.length ? b[colIndex] : '';
      // Blank cells always sink to the bottom regardless of sort direction.
      if (av.isEmpty && bv.isEmpty) return 0;
      if (av.isEmpty) return 1;
      if (bv.isEmpty) return -1;
      final an = double.tryParse(av);
      final bn = double.tryParse(bv);
      final cmp = (an != null && bn != null)
          ? an.compareTo(bn)
          : av.toLowerCase().compareTo(bv.toLowerCase());
      return ascending ? cmp : -cmp;
    });

    if (header != null) rows.insert(0, header);

    final json = jsonEncode(rows);
    final offset = widget.embedContext.node.documentOffset;

    setState(() {
      _viewRows = rows;
      _sortColumn = colIndex;
      _sortAscending = ascending;
    });

    widget.embedContext.controller.replaceText(
      offset,
      1,
      CustomBlockEmbed('table', json),
      null,
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_viewRows.isEmpty) return const SizedBox.shrink();
    final maxCols =
        _viewRows.map((r) => r.length).reduce((a, b) => a > b ? a : b);

    return GestureDetector(
      onTap: _editTable,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade400),
          borderRadius: BorderRadius.circular(4),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              border: TableBorder.all(color: Colors.grey.shade400),
              defaultColumnWidth: const FixedColumnWidth(140),
              children: _viewRows.asMap().entries.map((entry) {
                final isHeader = entry.key == 0;
                final row = entry.value;
                return TableRow(
                  decoration: isHeader
                      ? BoxDecoration(color: Colors.grey.shade200)
                      : null,
                  children: List.generate(maxCols, (ci) {
                    final text = ci < row.length ? row[ci] : '';
                    if (isHeader) {
                      // Header cells: tap sorts (absorbs tap so parent
                      // GestureDetector does NOT fire _enterEditMode)
                      return GestureDetector(
                        onTap: () => _promptSortByColumn(ci),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                text,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold),
                              ),
                              if (_sortColumn == ci) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  _sortAscending
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  size: 12,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }
                    // Data cells: no individual tap — parent fires _enterEditMode
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: Text(text),
                    );
                  }),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

}

// ─────────────────────────────────────────────────────────────────────────────
// Page ink painter (persistent overlay, document-space coords)
// ─────────────────────────────────────────────────────────────────────────────

class _PageInkPainter extends CustomPainter {
  final List<DrawingStroke> strokes;
  final List<Offset> currentPoints;
  final DrawingTool currentTool;
  final Color currentColor;
  final double currentWidth;
  final double scrollOffset;

  const _PageInkPainter({
    required this.strokes,
    required this.currentPoints,
    required this.currentTool,
    required this.currentColor,
    required this.currentWidth,
    required this.scrollOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(0, -scrollOffset);
    DrawingPainter(
      strokes: strokes,
      currentPoints: currentPoints,
      currentTool: currentTool,
      currentColor: currentColor,
      currentWidth: currentWidth,
    ).paint(canvas, size);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PageInkPainter old) =>
      old.scrollOffset != scrollOffset ||
      old.strokes != strokes ||
      old.currentPoints != currentPoints;
}

// ─────────────────────────────────────────────────────────────────────────────
// Scaled ink painter (image annotation overlay)
// ─────────────────────────────────────────────────────────────────────────────

class _ScaledInkPainter extends CustomPainter {
  final List<DrawingStroke> strokes;
  final double inkCanvasWidth;
  final double inkCanvasHeight;
  final double displayWidth;
  final double displayHeight;

  const _ScaledInkPainter({
    required this.strokes,
    required this.inkCanvasWidth,
    required this.inkCanvasHeight,
    required this.displayWidth,
    required this.displayHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(displayWidth / inkCanvasWidth, displayHeight / inkCanvasHeight);
    DrawingPainter(
      strokes: strokes,
      currentPoints: const [],
      currentTool: DrawingTool.pen,
      currentColor: Colors.black,
      currentWidth: 1,
    ).paint(canvas, Size(inkCanvasWidth, inkCanvasHeight));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScaledInkPainter old) =>
      old.strokes != strokes ||
      old.displayWidth != displayWidth ||
      old.displayHeight != displayHeight;
}

// ─────────────────────────────────────────────────────────────────────────────
// Page background painter
// ─────────────────────────────────────────────────────────────────────────────

class _PageBackgroundPainter extends CustomPainter {
  final String style;
  final Color  lineColor;
  final double spacing;
  /// Y-offset for the first ruled line, measured from the document origin.
  /// When non-null lines start at [lineStart]; otherwise they start at [spacing].
  final double? lineStart;
  /// Current vertical scroll offset of the editor (pre-zoom pixels).
  /// Used to keep background lines aligned with document content as it scrolls.
  final double scrollOffset;
  /// When non-null, draw a page-break band every [pageBreakInterval] pixels.
  final double? pageBreakInterval;

  const _PageBackgroundPainter({
    required this.style,
    required this.lineColor,
    required this.spacing,
    this.lineStart,
    this.scrollOffset = 0,
    this.pageBreakInterval,
  });

  // Thickness of the gap band between pages (pre-zoom logical px).
  static const _bandH = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (pageBreakInterval != null && pageBreakInterval! > 0) {
      // Clip line/dot drawing to within each page area so background never
      // bleeds into the grey gap bands between pages.
      _paintLinesClipped(canvas, size);
      _paintBreakBands(canvas, size);
    } else {
      _paintLines(canvas, size);
    }
  }

  /// Draw background lines/dots/grid across the full [size] with no clipping.
  void _paintLines(Canvas canvas, Size size) {
    final sp = spacing;
    final scrollMod = scrollOffset % sp;
    final y0 = (lineStart ?? sp) - scrollMod;

    final p = Paint()
      ..color = lineColor
      ..strokeWidth = 0.8;

    switch (style) {
      case 'lined':
        for (var y = y0; y < size.height; y += sp)
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
      case 'dotted':
        final dotY0 = sp - scrollMod;
        for (var x = sp; x < size.width; x += sp)
          for (var y = dotY0; y < size.height; y += sp)
            canvas.drawCircle(Offset(x, y), 1.5, p);
      case 'grid':
        for (var y = y0; y < size.height; y += sp)
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
        for (var x = sp; x < size.width; x += sp)
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      case 'cornell':
        canvas.drawLine(Offset(72, 0), Offset(72, size.height), p);
        canvas.drawLine(Offset(0, y0), Offset(size.width, y0), p);
        for (var y = y0 + sp; y < size.height; y += sp)
          canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  /// Draw lines once per visible page area, clipped to exclude gap bands.
  void _paintLinesClipped(Canvas canvas, Size size) {
    final interval = pageBreakInterval!;
    // First page index that might contribute visible content.
    final nFirst = (scrollOffset / interval).floor() - 1;

    for (var n = nFirst < 0 ? 0 : nFirst; ; n++) {
      // Document-space extent of page n:
      //   top  = 0 for page 0; otherwise the end of the preceding gap band.
      //   bottom = where the gap band of break n+1 begins.
      final docTop    = n == 0 ? 0.0 : n * interval + _bandH;
      final docBottom = (n + 1) * interval; // gap band starts here

      final canvasTop    = docTop    - scrollOffset;
      final canvasBottom = docBottom - scrollOffset;

      if (canvasTop > size.height) break;
      if (canvasBottom <= 0) continue;

      final clipTop    = canvasTop.clamp(0.0, size.height);
      final clipBottom = canvasBottom.clamp(0.0, size.height);
      if (clipBottom <= clipTop) continue;

      canvas.save();
      canvas.clipRect(Rect.fromLTRB(0, clipTop, size.width, clipBottom));
      _paintLines(canvas, size);
      canvas.restore();
    }
  }

  /// Draw the grey gap band (and shadow edges) at each page boundary.
  void _paintBreakBands(Canvas canvas, Size size) {
    final interval = pageBreakInterval!;
    final nStart = ((scrollOffset - _bandH) / interval).ceil();

    for (var n = nStart; ; n++) {
      final breakY = n * interval - scrollOffset;
      if (breakY > size.height) break;
      if (n <= 0) continue;

      // Dark shadow at bottom of the outgoing page.
      canvas.drawRect(
        Rect.fromLTWH(0, breakY - 3, size.width, 3),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.18)
          ..style = PaintingStyle.fill,
      );
      // Grey gap band.
      canvas.drawRect(
        Rect.fromLTWH(0, breakY, size.width, _bandH),
        Paint()
          ..color = Colors.grey.shade400.withValues(alpha: 0.55)
          ..style = PaintingStyle.fill,
      );
      // Subtle shadow at top of the incoming page.
      canvas.drawRect(
        Rect.fromLTWH(0, breakY + _bandH, size.width, 2),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.10)
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(_PageBackgroundPainter old) =>
      old.style             != style             ||
      old.lineColor         != lineColor         ||
      old.spacing           != spacing           ||
      old.lineStart         != lineStart         ||
      old.scrollOffset      != scrollOffset      ||
      old.pageBreakInterval != pageBreakInterval;
}

// ─────────────────────────────────────────────────────────────────────────────
// Page background picker bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _PageBackgroundSheet extends StatefulWidget {
  final String currentStyle;
  final int    currentColor;
  final double currentSpacing;
  final void Function(String style, int color, double spacing) onChanged;

  const _PageBackgroundSheet({
    required this.currentStyle,
    required this.currentColor,
    required this.currentSpacing,
    required this.onChanged,
  });

  @override
  State<_PageBackgroundSheet> createState() => _PageBackgroundSheetState();
}

class _PageBackgroundSheetState extends State<_PageBackgroundSheet> {
  static const _styles = [
    ('none',    'Plain',   Icons.crop_square),
    ('lined',   'Lined',   Icons.table_rows),
    ('dotted',  'Dotted',  Icons.grain),
    ('grid',    'Grid',    Icons.grid_on),
    ('cornell', 'Cornell', Icons.vertical_split),
  ];

  static const _colors = [
    (0,          'Default'),
    (0xFFFFFFFF, 'White'),
    (0xFFFFFBE6, 'Cream'),
    (0xFFFFF9C4, 'Yellow'),
    (0xFFE3F2FD, 'Blue'),
    (0xFFE8F5E9, 'Green'),
    (0xFFF3E5F5, 'Lavender'),
    (0xFF212121, 'Dark'),
  ];

  late String _style;
  late int    _color;
  late double _spacing;
  late TextEditingController _spacingCtrl;

  @override
  void initState() {
    super.initState();
    _style   = widget.currentStyle;
    _color   = widget.currentColor;
    _spacing = widget.currentSpacing;
    _spacingCtrl = TextEditingController(text: _spacing.round().toString());
  }

  @override
  void dispose() {
    _spacingCtrl.dispose();
    super.dispose();
  }

  void _apply({String? style, int? color, double? spacing}) {
    setState(() {
      if (style   != null) _style   = style;
      if (color   != null) _color   = color;
      if (spacing != null) {
        _spacing = spacing;
        // Sync text field when slider drives the change
        final txt = spacing.round().toString();
        if (_spacingCtrl.text != txt) {
          _spacingCtrl.value = _spacingCtrl.value.copyWith(
            text: txt,
            selection: TextSelection.collapsed(offset: txt.length),
          );
        }
      }
    });
    widget.onChanged(_style, _color, _spacing);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Style section ─────────────────────────────────────────────
            Text('Style', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _styles.map((s) {
                final (key, label, icon) = s;
                final selected = _style == key;
                return ChoiceChip(
                  avatar: Icon(icon, size: 16),
                  label: Text(label),
                  selected: selected,
                  onSelected: (_) => _apply(style: key),
                );
              }).toList(),
            ),

            const SizedBox(height: 16),

            // ── Colour section ────────────────────────────────────────────
            Text('Colour', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _colors.map((c) {
                final (value, label) = c;
                final selected = _color == value;
                final bg = value == 0
                    ? cs.surface
                    : Color(value);
                return Tooltip(
                  message: label,
                  child: GestureDetector(
                    onTap: () => _apply(color: value),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: bg,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? cs.primary
                              : cs.outlineVariant,
                          width: selected ? 2.5 : 1,
                        ),
                      ),
                      child: selected
                          ? Icon(Icons.check,
                              size: 16,
                              color: bg.computeLuminance() > 0.5
                                  ? Colors.black
                                  : Colors.white)
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),
            // ── Spacing section ────────────────────────────────────────────
            ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('Line spacing',
                      style: Theme.of(context).textTheme.labelMedium),
                  const Spacer(),
                  SizedBox(
                    width: 64,
                    child: TextField(
                      controller: _spacingCtrl,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(
                        suffixText: 'px',
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      ),
                      onChanged: (v) {
                        final parsed = double.tryParse(v);
                        if (parsed != null) {
                          final clamped = parsed.clamp(16.0, 80.0);
                          _apply(spacing: clamped);
                        }
                      },
                    ),
                  ),
                ],
              ),
              Slider(
                min: 16,
                max: 80,
                divisions: 64,
                value: _spacing.clamp(16.0, 80.0),
                onChanged: (v) => _apply(spacing: v),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page-size picker bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _PageSizeSheet extends StatefulWidget {
  final String currentSize;
  final String currentOrientation;
  final void Function(String size, String orientation) onChanged;

  const _PageSizeSheet({
    required this.currentSize,
    required this.currentOrientation,
    required this.onChanged,
  });

  @override
  State<_PageSizeSheet> createState() => _PageSizeSheetState();
}

class _PageSizeSheetState extends State<_PageSizeSheet> {
  static const _sizes = [
    ('infinite', 'Infinite',  Icons.all_inclusive),
    ('a5',       'A5',        Icons.insert_drive_file_outlined),
    ('a4',       'A4',        Icons.insert_drive_file_outlined),
    ('a3',       'A3',        Icons.insert_drive_file_outlined),
  ];

  late String _size;
  late String _orientation;

  @override
  void initState() {
    super.initState();
    _size        = widget.currentSize;
    _orientation = widget.currentOrientation;
  }

  void _apply({String? size, String? orientation}) {
    setState(() {
      if (size        != null) _size        = size;
      if (orientation != null) _orientation = orientation;
    });
    widget.onChanged(_size, _orientation);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Size chips ────────────────────────────────────────────────
            Text('Page Size', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: _sizes.map((s) {
                final (key, label, icon) = s;
                return ChoiceChip(
                  avatar: Icon(icon, size: 16),
                  label: Text(label),
                  selected: _size == key,
                  onSelected: (_) => _apply(size: key),
                );
              }).toList(),
            ),

            // ── Orientation chips (hidden for Infinite) ───────────────────
            if (_size != 'infinite') ...[
              const SizedBox(height: 16),
              Text('Orientation',
                  style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    avatar: const Icon(Icons.crop_portrait, size: 16),
                    label: const Text('Portrait'),
                    selected: _orientation == 'portrait',
                    onSelected: (_) => _apply(orientation: 'portrait'),
                  ),
                  ChoiceChip(
                    avatar: const Icon(Icons.crop_landscape, size: 16),
                    label: const Text('Landscape'),
                    selected: _orientation == 'landscape',
                    onSelected: (_) => _apply(orientation: 'landscape'),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Tabbed toolbar (phone only) ──────────────────────────────────────────────
// Tabs: Format | Lists | Edit | Page | Table
// Tab strip (scrollable, ~36px) + tool row (~48px) = ~85px total.

class _TabbedToolbar extends StatefulWidget {
  const _TabbedToolbar({
    required this.controller,
    required this.onShowBackground,
    required this.onShowPageSize,
    required this.onInsertTable,
  });

  final QuillController controller;
  final VoidCallback onShowBackground;
  final VoidCallback onShowPageSize;
  final VoidCallback onInsertTable;

  @override
  State<_TabbedToolbar> createState() => _TabbedToolbarState();
}

class _TabbedToolbarState extends State<_TabbedToolbar> {
  int _tab = 0;
  static const _tabLabels = ['Format', 'Lists', 'Edit', 'Page', 'Table'];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Tab strip (horizontally scrollable for 5 tabs) ────────────────
        SizedBox(
          height: 36,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: IntrinsicWidth(
              child: Row(
                children: List.generate(_tabLabels.length, (i) {
                  final selected = _tab == i;
                  return InkWell(
                    onTap: () => setState(() => _tab = i),
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 68),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color:
                                selected ? cs.primary : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        _tabLabels[i],
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color:
                              selected ? cs.primary : cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
        // ── Divider between tab strip and tools ──────────────────────────
        const Divider(height: 1),
        // ── Tool row ─────────────────────────────────────────────────────
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: _buildTools()),
        ),
      ],
    );
  }

  List<Widget> _buildTools() {
    final c = widget.controller;
    switch (_tab) {
      case 0: // Format: B I U | text colour | bg colour | clear
        return [
          QuillToolbarToggleStyleButton(
              controller: c, attribute: Attribute.bold),
          QuillToolbarToggleStyleButton(
              controller: c, attribute: Attribute.italic),
          QuillToolbarToggleStyleButton(
              controller: c, attribute: Attribute.underline),
          QuillToolbarColorButton(controller: c, isBackground: false),
          QuillToolbarColorButton(controller: c, isBackground: true),
          QuillToolbarClearFormatButton(controller: c),
        ];
      case 1: // Lists: heading | OL | UL | checklist | indent +/-
        return [
          QuillToolbarSelectHeaderStyleDropdownButton(controller: c),
          QuillToolbarToggleStyleButton(
              controller: c, attribute: Attribute.ol),
          QuillToolbarToggleStyleButton(
              controller: c, attribute: Attribute.ul),
          QuillToolbarToggleCheckListButton(controller: c),
          QuillToolbarIndentButton(controller: c, isIncrease: true),
          QuillToolbarIndentButton(controller: c, isIncrease: false),
        ];
      case 2: // Edit: undo | redo | cut | copy | paste
        return [
          QuillToolbarHistoryButton(controller: c, isUndo: true),
          QuillToolbarHistoryButton(controller: c, isUndo: false),
          QuillToolbarClipboardButton(
              controller: c, clipboardAction: ClipboardAction.cut),
          QuillToolbarClipboardButton(
              controller: c, clipboardAction: ClipboardAction.copy),
          QuillToolbarClipboardButton(
              controller: c, clipboardAction: ClipboardAction.paste),
        ];
      case 3: // Page: background style | page size
        return [
          _ToolbarActionButton(
            icon: Icons.grid_view_outlined,
            label: 'Background',
            onTap: widget.onShowBackground,
          ),
          _ToolbarActionButton(
            icon: Icons.crop_portrait,
            label: 'Page Size',
            onTap: widget.onShowPageSize,
          ),
        ];
      case 4: // Table: insert table
        return [
          _ToolbarActionButton(
            icon: Icons.table_chart_outlined,
            label: 'Insert Table',
            onTap: widget.onInsertTable,
          ),
        ];
      default:
        return [];
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Background canvas — subscribes directly to scroll controller so it repaints
// every tick without going through the parent's setState (no one-frame lag).
// ─────────────────────────────────────────────────────────────────────────────

class _BackgroundCanvas extends StatefulWidget {
  const _BackgroundCanvas({
    required this.scrollController,
    required this.style,
    required this.lineColor,
    required this.spacing,
    this.lineStart,
    this.pageBreakInterval,
  });

  final ScrollController scrollController;
  final String style;
  final Color lineColor;
  final double spacing;
  final double? lineStart;
  final double? pageBreakInterval;

  @override
  State<_BackgroundCanvas> createState() => _BackgroundCanvasState();
}

class _BackgroundCanvasState extends State<_BackgroundCanvas> {
  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(_BackgroundCanvas old) {
    super.didUpdateWidget(old);
    if (old.scrollController != widget.scrollController) {
      old.scrollController.removeListener(_onScroll);
      widget.scrollController.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final offset = widget.scrollController.hasClients
        ? widget.scrollController.offset
        : 0.0;
    return CustomPaint(
      painter: _PageBackgroundPainter(
        style: widget.style,
        lineColor: widget.lineColor,
        spacing: widget.spacing,
        lineStart: widget.lineStart,
        scrollOffset: offset,
        pageBreakInterval: widget.pageBreakInterval,
      ),
    );
  }
}

/// Icon + label button styled to sit alongside Quill toolbar buttons.
class _ToolbarActionButton extends StatelessWidget {
  const _ToolbarActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: cs.onSurface),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
