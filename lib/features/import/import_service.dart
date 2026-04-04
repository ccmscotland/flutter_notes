import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:syncfusion_flutter_pdf/pdf.dart';

class ImportResult {
  final String title;
  final String deltaJson;
  const ImportResult({required this.title, required this.deltaJson});
}

class ImportService {
  /// Opens a file picker, parses the chosen file, and returns the result.
  /// Returns null if the user cancelled or the format is unsupported.
  Future<ImportResult?> pickAndParse() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['md', 'html', 'htm', 'txt', 'pdf'],
        withData: true,
      );
    } catch (_) {
      return null;
    }

    if (picked == null || picked.files.isEmpty) return null;

    final file  = picked.files.first;
    final ext   = (file.extension ?? '').toLowerCase();
    final title = file.name.replaceAll(RegExp(r'\.[^.]+$'), '');

    try {
      final deltaJson = switch (ext) {
        'txt'            => _textToDelta(_readString(file)),
        'md'             => _markdownToDelta(_readString(file)),
        'html' || 'htm'  => _htmlToDelta(_readString(file)),
        'pdf'            => _pdfToDelta(file),
        _                => null,
      };
      if (deltaJson == null) return null;
      return ImportResult(title: title, deltaJson: deltaJson);
    } catch (_) {
      return null;
    }
  }

  // ── Readers ────────────────────────────────────────────────────────────────

  String _readString(PlatformFile file) {
    if (file.bytes != null) return utf8.decode(file.bytes!, allowMalformed: true);
    if (file.path  != null) return File(file.path!).readAsStringSync();
    return '';
  }

  // ── Plain text → Delta ─────────────────────────────────────────────────────

  String _textToDelta(String text) {
    final ops = <Map<String, dynamic>>[];
    for (final line in text.split('\n')) {
      ops.add({'insert': '$line\n'});
    }
    if (ops.isEmpty) ops.add({'insert': '\n'});
    return jsonEncode(ops);
  }

  // ── Markdown → Delta ───────────────────────────────────────────────────────

  String _markdownToDelta(String markdown) {
    final ops = <Map<String, dynamic>>[];

    for (final line in markdown.split('\n')) {
      if (line.startsWith('### ')) {
        _inlineOps(ops, line.substring(4));
        ops.add({'insert': '\n', 'attributes': {'header': 3}});
      } else if (line.startsWith('## ')) {
        _inlineOps(ops, line.substring(3));
        ops.add({'insert': '\n', 'attributes': {'header': 2}});
      } else if (line.startsWith('# ')) {
        _inlineOps(ops, line.substring(2));
        ops.add({'insert': '\n', 'attributes': {'header': 1}});
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        _inlineOps(ops, line.substring(2));
        ops.add({'insert': '\n', 'attributes': {'list': 'bullet'}});
      } else if (RegExp(r'^\d+\. ').hasMatch(line)) {
        _inlineOps(ops, line.replaceFirst(RegExp(r'^\d+\. '), ''));
        ops.add({'insert': '\n', 'attributes': {'list': 'ordered'}});
      } else if (line.startsWith('> ')) {
        _inlineOps(ops, line.substring(2));
        ops.add({'insert': '\n', 'attributes': {'blockquote': true}});
      } else if (line.startsWith('```')) {
        final code = line.substring(3);
        if (code.isNotEmpty) ops.add({'insert': code});
        ops.add({'insert': '\n', 'attributes': {'code-block': true}});
      } else {
        _inlineOps(ops, line);
        ops.add({'insert': '\n'});
      }
    }

    if (ops.isEmpty) ops.add({'insert': '\n'});
    return jsonEncode(ops);
  }

  /// Emits inline ops for **bold**, *italic*, `code`, and plain text spans.
  void _inlineOps(List<Map<String, dynamic>> ops, String text) {
    final rx = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*|`(.+?)`');
    int cursor = 0;
    for (final m in rx.allMatches(text)) {
      if (m.start > cursor) ops.add({'insert': text.substring(cursor, m.start)});
      if      (m.group(1) != null) ops.add({'insert': m.group(1)!, 'attributes': {'bold':   true}});
      else if (m.group(2) != null) ops.add({'insert': m.group(2)!, 'attributes': {'italic': true}});
      else if (m.group(3) != null) ops.add({'insert': m.group(3)!, 'attributes': {'code':   true}});
      cursor = m.end;
    }
    if (cursor < text.length) ops.add({'insert': text.substring(cursor)});
  }

  // ── HTML → Delta ───────────────────────────────────────────────────────────

  String _htmlToDelta(String source) {
    final document = html_parser.parse(source);
    final ops = <Map<String, dynamic>>[];

    void walk(dom.Node node, Map<String, dynamic> attrs) {
      if (node is dom.Text) {
        final t = node.text;
        if (t.isNotEmpty) {
          ops.add(attrs.isEmpty
              ? {'insert': t}
              : {'insert': t, 'attributes': Map<String, dynamic>.from(attrs)});
        }
        return;
      }
      if (node is! dom.Element) return;

      final childAttrs = Map<String, dynamic>.from(attrs);
      Map<String, dynamic>? blockAttr;

      switch (node.localName) {
        case 'b': case 'strong':  childAttrs['bold']      = true;
        case 'i': case 'em':      childAttrs['italic']    = true;
        case 'u':                 childAttrs['underline'] = true;
        case 's': case 'del':     childAttrs['strike']    = true;
        case 'code':              childAttrs['code']      = true;
        case 'h1': blockAttr = {'header': 1};
        case 'h2': blockAttr = {'header': 2};
        case 'h3': blockAttr = {'header': 3};
        case 'li':
          blockAttr = {
            'list': node.parent?.localName == 'ul' ? 'bullet' : 'ordered',
          };
        case 'blockquote': blockAttr = {'blockquote': true};
        case 'pre':        blockAttr = {'code-block': true};
        case 'br':
          ops.add({'insert': '\n'});
          return;
      }

      for (final child in node.nodes) walk(child, childAttrs);

      const blockTags = {
        'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
        'li', 'blockquote', 'pre', 'tr',
      };
      if (blockTags.contains(node.localName)) {
        ops.add(blockAttr != null
            ? {'insert': '\n', 'attributes': blockAttr}
            : {'insert': '\n'});
      }
    }

    final body = document.body;
    if (body != null) {
      for (final child in body.nodes) walk(child, {});
    }

    if (ops.isEmpty) ops.add({'insert': '\n'});
    return jsonEncode(ops);
  }

  // ── PDF → Delta ────────────────────────────────────────────────────────────

  String _pdfToDelta(PlatformFile file) {
    final bytes = file.bytes ?? File(file.path!).readAsBytesSync();
    final doc   = PdfDocument(inputBytes: bytes);
    final buf   = StringBuffer();
    final extractor = PdfTextExtractor(doc);

    for (var i = 0; i < doc.pages.count; i++) {
      final text = extractor.extractText(startPageIndex: i, endPageIndex: i);
      if (text.isNotEmpty) buf.writeln(text);
    }
    doc.dispose();

    return _textToDelta(buf.toString().trim());
  }
}
