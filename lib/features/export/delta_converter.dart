import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Converts a Quill Delta (list of ops) to Markdown or HTML.
///
/// Delta format recap:
///   • Text op  : {"insert": "some text", "attributes": {...}}
///   • Newline  : {"insert": "\n", "attributes": {"header": 1, ...}}
///               The \n defines the block type for the text preceding it.
///   • Embed    : {"insert": {"image": "/path"}} or {"insert": {"table": "json"}}
class DeltaConverter {
  // ── Public API ─────────────────────────────────────────────────────────────

  static String toMarkdown(List<dynamic> ops) => _DeltaWalker(ops).toMarkdown();

  static String toHtml(List<dynamic> ops, {String? title}) {
    final body = _DeltaWalker(ops).toHtml();
    final t = _DeltaWalker._escape(title ?? 'Note');
    return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$t</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         max-width: 860px; margin: 2rem auto; padding: 0 1rem;
         line-height: 1.6; color: #1a1a1a; }
  h1,h2,h3 { margin-top: 1.4em; }
  img { max-width: 100%; height: auto; border-radius: 4px; }
  table { border-collapse: collapse; width: 100%; margin: 1em 0; }
  td, th { border: 1px solid #ccc; padding: 6px 10px; text-align: left; }
  th { background: #f0f0f0; font-weight: 600; }
  pre { background: #f5f5f5; padding: 1em; border-radius: 4px;
        overflow-x: auto; font-size: .9em; }
  code { background: #f0f0f0; padding: 2px 4px; border-radius: 3px;
         font-size: .9em; }
  pre code { background: none; padding: 0; }
  blockquote { border-left: 4px solid #ccc; margin: 0; padding: 0 1em;
               color: #555; }
  li.checked { list-style: none; }
  li.checked::before { content: "☑ "; }
</style>
</head>
<body>
$body
</body>
</html>''';
  }
}

// ── Internal walker ──────────────────────────────────────────────────────────

class _DeltaWalker {
  _DeltaWalker(this.ops);

  final List<dynamic> ops;

  // Each segment is (text, attrs) accumulated until the terminating \n.
  final List<(String, Map<String, dynamic>)> _lineBuffer = [];
  // For ordered list continuity across consecutive items.
  int _olCounter = 0;
  bool _inOl = false;
  bool _inUl = false;

  // ── Markdown ──────────────────────────────────────────────────────────────

  String toMarkdown() {
    final out = StringBuffer();
    _olCounter = 0;
    _inOl = false;
    _inUl = false;

    for (final op in ops) {
      final insert = op['insert'];
      final attrs = (op['attributes'] as Map?)?.cast<String, dynamic>() ?? {};

      if (insert is String) {
        // Split on newlines — each \n terminates a paragraph.
        final parts = insert.split('\n');
        for (var i = 0; i < parts.length; i++) {
          if (parts[i].isNotEmpty) {
            _lineBuffer.add((parts[i], attrs));
          }
          if (i < parts.length - 1) {
            // Flush current line with these block attrs.
            out.write(_flushLineMd(attrs));
          }
        }
      } else if (insert is Map) {
        _closeListsMd(out);
        out.write(_embedMd(insert));
      }
    }
    // Flush any remaining buffer.
    if (_lineBuffer.isNotEmpty) {
      out.write(_flushLineMd({}));
    }
    _closeListsMd(out);
    return out.toString();
  }

  String _flushLineMd(Map<String, dynamic> blockAttrs) {
    final inline = _lineBuffer.map((s) => _inlineMd(s.$1, s.$2)).join();
    _lineBuffer.clear();
    if (inline.isEmpty && blockAttrs.isEmpty) return '\n';

    final buf = StringBuffer();
    final header = blockAttrs['header'];
    final list = blockAttrs['list'];
    final codeBlock = blockAttrs['code-block'] == true;
    final blockquote = blockAttrs['blockquote'] == true;

    _closeListsMd(buf, desiredList: list as String?);

    if (codeBlock) {
      buf.writeln('```');
      buf.writeln(inline);
      buf.writeln('```');
    } else if (blockquote) {
      buf.writeln('> $inline');
    } else if (header != null) {
      final hashes = '#' * (header as int).clamp(1, 6);
      buf.writeln('$hashes $inline');
    } else if (list == 'bullet') {
      buf.writeln('- $inline');
      _inUl = true;
    } else if (list == 'ordered') {
      _olCounter++;
      buf.writeln('$_olCounter. $inline');
      _inOl = true;
    } else if (list == 'checked') {
      buf.writeln('- [x] $inline');
      _inUl = true;
    } else {
      buf.writeln(inline);
    }
    return buf.toString();
  }

  void _closeListsMd(StringBuffer buf, {String? desiredList}) {
    if (_inOl && desiredList != 'ordered') {
      _inOl = false;
      _olCounter = 0;
      buf.writeln();
    }
    if (_inUl && desiredList != 'bullet' && desiredList != 'checked') {
      _inUl = false;
      buf.writeln();
    }
  }

  String _inlineMd(String text, Map<String, dynamic> attrs) {
    var t = text;
    if (attrs['code'] == true) return '`$t`';
    if (attrs['bold'] == true) t = '**$t**';
    if (attrs['italic'] == true) t = '*$t*';
    if (attrs['strikethrough'] == true) t = '~~$t~~';
    // underline has no standard MD; fall back to HTML inline
    if (attrs['underline'] == true) t = '<u>$t</u>';
    final link = attrs['link'];
    if (link is String) t = '[$t]($link)';
    return t;
  }

  String _embedMd(Map insert) {
    if (insert.containsKey('image')) {
      final path = insert['image'] as String? ?? '';
      return '![image]($path)\n\n';
    }
    if (insert.containsKey('table')) {
      return _tableToMd(insert['table'] as String) + '\n';
    }
    return ''; // ink / drawing — skip
  }

  String _tableToMd(String jsonData) {
    late List<List<String>> rows;
    try {
      rows = (jsonDecode(jsonData) as List)
          .map((r) => (r as List).map((c) => c.toString()).toList())
          .toList();
    } catch (_) {
      return '';
    }
    if (rows.isEmpty) return '';
    final buf = StringBuffer();
    // Header row
    buf.writeln('| ${rows[0].join(' | ')} |');
    buf.writeln('| ${rows[0].map((_) => '---').join(' | ')} |');
    for (var i = 1; i < rows.length; i++) {
      buf.writeln('| ${rows[i].join(' | ')} |');
    }
    return buf.toString();
  }

  // ── HTML ──────────────────────────────────────────────────────────────────

  String toHtml() {
    final out = StringBuffer();
    _inOl = false;
    _inUl = false;

    for (final op in ops) {
      final insert = op['insert'];
      final attrs = (op['attributes'] as Map?)?.cast<String, dynamic>() ?? {};

      if (insert is String) {
        final parts = insert.split('\n');
        for (var i = 0; i < parts.length; i++) {
          if (parts[i].isNotEmpty) {
            _lineBuffer.add((parts[i], attrs));
          }
          if (i < parts.length - 1) {
            out.write(_flushLineHtml(attrs));
          }
        }
      } else if (insert is Map) {
        _closeListsHtml(out);
        out.write(_embedHtml(insert));
      }
    }
    if (_lineBuffer.isNotEmpty) {
      out.write(_flushLineHtml({}));
    }
    _closeListsHtml(out);
    return out.toString();
  }

  String _flushLineHtml(Map<String, dynamic> blockAttrs) {
    final inline = _lineBuffer.map((s) => _inlineHtml(s.$1, s.$2)).join();
    _lineBuffer.clear();
    if (inline.isEmpty && blockAttrs.isEmpty) return '';

    final buf = StringBuffer();
    final header = blockAttrs['header'];
    final list = blockAttrs['list'];
    final codeBlock = blockAttrs['code-block'] == true;
    final blockquote = blockAttrs['blockquote'] == true;
    final align = blockAttrs['align'] as String?;

    _closeListsHtml(buf, desiredList: list as String?);

    final style = align != null ? ' style="text-align:$align"' : '';

    if (codeBlock) {
      buf.writeln('<pre><code>$inline</code></pre>');
    } else if (blockquote) {
      buf.writeln('<blockquote>$inline</blockquote>');
    } else if (header != null) {
      final h = (header as int).clamp(1, 6);
      buf.writeln('<h$h$style>$inline</h$h>');
    } else if (list == 'bullet') {
      if (!_inUl) { buf.writeln('<ul>'); _inUl = true; }
      buf.writeln('<li>$inline</li>');
    } else if (list == 'ordered') {
      if (!_inOl) { buf.writeln('<ol>'); _inOl = true; }
      buf.writeln('<li>$inline</li>');
    } else if (list == 'checked') {
      if (!_inUl) { buf.writeln('<ul>'); _inUl = true; }
      buf.writeln('<li class="checked">$inline</li>');
    } else if (inline.isNotEmpty) {
      buf.writeln('<p$style>$inline</p>');
    }
    return buf.toString();
  }

  void _closeListsHtml(StringBuffer buf, {String? desiredList}) {
    if (_inOl && desiredList != 'ordered') {
      buf.writeln('</ol>');
      _inOl = false;
    }
    if (_inUl &&
        desiredList != 'bullet' &&
        desiredList != 'checked') {
      buf.writeln('</ul>');
      _inUl = false;
    }
  }

  String _inlineHtml(String text, Map<String, dynamic> attrs) {
    var t = _escape(text);
    if (attrs['code'] == true) return '<code>$t</code>';
    if (attrs['bold'] == true) t = '<strong>$t</strong>';
    if (attrs['italic'] == true) t = '<em>$t</em>';
    if (attrs['underline'] == true) t = '<u>$t</u>';
    if (attrs['strikethrough'] == true) t = '<s>$t</s>';
    final link = attrs['link'];
    if (link is String) t = '<a href="${_escape(link)}">$t</a>';
    return t;
  }

  String _embedHtml(Map insert) {
    if (insert.containsKey('image')) {
      final path = insert['image'] as String? ?? '';
      final src = _imageToBase64(path);
      return '<p><img src="$src" alt="image"></p>\n';
    }
    if (insert.containsKey('table')) {
      return _tableToHtml(insert['table'] as String);
    }
    return ''; // ink / drawing — skip
  }

  String _tableToHtml(String jsonData) {
    late List<List<String>> rows;
    try {
      rows = (jsonDecode(jsonData) as List)
          .map((r) => (r as List).map((c) => c.toString()).toList())
          .toList();
    } catch (_) {
      return '';
    }
    if (rows.isEmpty) return '';
    final buf = StringBuffer('<table>\n');
    buf.writeln('<thead><tr>');
    for (final cell in rows[0]) {
      buf.writeln('<th>${_escape(cell)}</th>');
    }
    buf.writeln('</tr></thead>');
    buf.writeln('<tbody>');
    for (var i = 1; i < rows.length; i++) {
      buf.writeln('<tr>');
      for (final cell in rows[i]) {
        buf.writeln('<td>${_escape(cell)}</td>');
      }
      buf.writeln('</tr>');
    }
    buf.writeln('</tbody></table>');
    return buf.toString();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Tries to embed the image as a base64 data URI; falls back to file path.
  static String _imageToBase64(String path) {
    try {
      final bytes = File(path).readAsBytesSync();
      final b64 = base64Encode(bytes);
      final mime = path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
      return 'data:$mime;base64,$b64';
    } catch (_) {
      return path;
    }
  }

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
