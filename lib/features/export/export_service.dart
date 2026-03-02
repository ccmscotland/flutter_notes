import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../core/database/page_assets_dao.dart';
import '../../core/database/pages_dao.dart';
import '../../core/database/sections_dao.dart';
import '../../core/models/notebook.dart';
import '../../core/models/page.dart';
import '../../core/models/page_asset.dart';
import '../../core/models/section.dart';
import 'delta_converter.dart';

enum ExportFormat { pdf, html, markdown }
enum MultiPageOutput { merged, zip }

extension ExportFormatExt on ExportFormat {
  String get extension => switch (this) {
        ExportFormat.pdf => 'pdf',
        ExportFormat.html => 'html',
        ExportFormat.markdown => 'md',
      };
  String get label => switch (this) {
        ExportFormat.pdf => 'PDF',
        ExportFormat.html => 'HTML',
        ExportFormat.markdown => 'Markdown',
      };
}

class ExportService {
  ExportService({
    PagesDao? pagesDao,
    SectionsDao? sectionsDao,
    PageAssetsDao? assetsDao,
  })  : _pagesDao = pagesDao ?? PagesDao(),
        _sectionsDao = sectionsDao ?? SectionsDao(),
        _assetsDao = assetsDao ?? PageAssetsDao();

  final PagesDao _pagesDao;
  final SectionsDao _sectionsDao;
  final PageAssetsDao _assetsDao;

  // ── Public entry points ──────────────────────────────────────────────────

  Future<void> exportPage(
    BuildContext context,
    NotePage page,
    ExportFormat fmt,
  ) async {
    final assets = await _assetsDao.getByPage(page.id);
    final file = await _pageToFile(page, fmt, assets);
    if (context.mounted) await _deliver(context, file, page.title);
  }

  Future<void> exportSection(
    BuildContext context,
    Section section,
    ExportFormat fmt,
    MultiPageOutput output,
  ) async {
    final pages = await _pagesDao.getBySection(section.id);
    final assetMap = <String, List<PageAsset>>{};
    for (final pg in pages) {
      assetMap[pg.id] = await _assetsDao.getByPage(pg.id);
    }

    final File result;
    if (output == MultiPageOutput.merged) {
      result = await _mergeToFile(
        name: section.name,
        pages: pages,
        assetMap: assetMap,
        fmt: fmt,
        sectionName: null,
      );
    } else {
      final files = [
        for (final pg in pages)
          await _pageToFile(pg, fmt, assetMap[pg.id] ?? []),
      ];
      result = await _buildZip(files, '${_sanitise(section.name)}_export');
    }
    if (context.mounted) await _deliver(context, result, section.name);
  }

  Future<void> exportNotebook(
    BuildContext context,
    Notebook notebook,
    ExportFormat fmt,
    MultiPageOutput output,
  ) async {
    final sections = await _sectionsDao.getByNotebook(notebook.id);
    final allPages = <NotePage>[];
    final assetMap = <String, List<PageAsset>>{};
    final sectionOf = <String, String>{};

    for (final sec in sections) {
      final pages = await _pagesDao.getBySection(sec.id);
      for (final pg in pages) {
        allPages.add(pg);
        assetMap[pg.id] = await _assetsDao.getByPage(pg.id);
        sectionOf[pg.id] = sec.name;
      }
    }

    final File result;
    if (output == MultiPageOutput.merged) {
      result = await _mergeToFile(
        name: notebook.name,
        pages: allPages,
        assetMap: assetMap,
        fmt: fmt,
        sectionName: sectionOf,
      );
    } else {
      final files = [
        for (final pg in allPages)
          await _pageToFile(pg, fmt, assetMap[pg.id] ?? []),
      ];
      result = await _buildZip(files, '${_sanitise(notebook.name)}_export');
    }
    if (context.mounted) await _deliver(context, result, notebook.name);
  }

  // ── File builders ────────────────────────────────────────────────────────

  Future<File> _pageToFile(
    NotePage page,
    ExportFormat fmt,
    List<PageAsset> assets,
  ) async {
    final tmpDir = await getTemporaryDirectory();
    final name = '${_sanitise(page.title)}.${fmt.extension}';
    final file = File(p.join(tmpDir.path, name));

    switch (fmt) {
      case ExportFormat.markdown:
        final ops = _parseOps(page.content);
        await file.writeAsString(
          '# ${page.title}\n\n${DeltaConverter.toMarkdown(ops)}',
          encoding: utf8,
        );
      case ExportFormat.html:
        final ops = _parseOps(page.content);
        await file.writeAsString(
          DeltaConverter.toHtml(ops, title: page.title),
          encoding: utf8,
        );
      case ExportFormat.pdf:
        final bytes = await _buildPdf(page, assets);
        await file.writeAsBytes(bytes);
    }
    return file;
  }

  /// Merge multiple pages into a single document file.
  Future<File> _mergeToFile({
    required String name,
    required List<NotePage> pages,
    required Map<String, List<PageAsset>> assetMap,
    required ExportFormat fmt,
    required Map<String, String>? sectionName, // null = single section
  }) async {
    final tmpDir = await getTemporaryDirectory();
    final file = File(p.join(tmpDir.path, '${_sanitise(name)}.${fmt.extension}'));

    switch (fmt) {
      case ExportFormat.markdown:
        final buf = StringBuffer();
        String? lastSection;
        for (final pg in pages) {
          final sec = sectionName?[pg.id];
          if (sec != null && sec != lastSection) {
            buf.writeln('\n# $sec\n');
            lastSection = sec;
          }
          buf.writeln('## ${pg.title}\n');
          final ops = _parseOps(pg.content);
          buf.writeln(DeltaConverter.toMarkdown(ops));
          buf.writeln('\n---\n');
        }
        await file.writeAsString(buf.toString(), encoding: utf8);

      case ExportFormat.html:
        final buf = StringBuffer();
        String? lastSection;
        for (final pg in pages) {
          final sec = sectionName?[pg.id];
          if (sec != null && sec != lastSection) {
            buf.writeln('<h1>${_esc(sec)}</h1>');
            lastSection = sec;
          }
          final ops = _parseOps(pg.content);
          buf.writeln('<h2>${_esc(pg.title)}</h2>');
          buf.writeln(DeltaConverter.toHtml(ops).replaceAll(
            RegExp(r'<!DOCTYPE.*?</head>', dotAll: true),
            '',
          ).replaceAll('<body>', '').replaceAll('</body>', '').replaceAll('</html>', '').trim());
          buf.writeln('<hr>');
        }
        // Wrap in a full HTML document
        final fullHtml = DeltaConverter.toHtml([], title: name)
            .replaceAll('<body>\n</body>', '<body>\n${buf.toString()}</body>');
        await file.writeAsString(fullHtml, encoding: utf8);

      case ExportFormat.pdf:
        final doc = pw.Document();
        for (final pg in pages) {
          final assets = assetMap[pg.id] ?? [];
          final widgets = await _deltaToPdfWidgets(pg.title, _parseOps(pg.content), assets);
          doc.addPage(pw.MultiPage(
            pageFormat: PdfPageFormat.a4,
            margin: const pw.EdgeInsets.all(40),
            build: (_) => widgets,
          ));
        }
        await file.writeAsBytes(await doc.save());
    }
    return file;
  }

  Future<File> _buildZip(List<File> files, String archiveName) async {
    final tmpDir = await getTemporaryDirectory();
    final zipFile = File(p.join(tmpDir.path, '$archiveName.zip'));
    final encoder = ZipFileEncoder();
    encoder.create(zipFile.path);
    for (final f in files) {
      encoder.addFile(f);
    }
    encoder.close();
    return zipFile;
  }

  Future<Uint8List> _buildPdf(NotePage page, List<PageAsset> assets) async {
    final doc = pw.Document();
    final widgets = await _deltaToPdfWidgets(page.title, _parseOps(page.content), assets);
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (_) => widgets,
    ));
    return doc.save();
  }

  // ── Delta → PDF widgets ──────────────────────────────────────────────────

  Future<List<pw.Widget>> _deltaToPdfWidgets(
    String title,
    List<dynamic> ops,
    List<PageAsset> assets,
  ) async {
    final widgets = <pw.Widget>[
      pw.Text(
        title,
        style: pw.TextStyle(
          fontSize: 20,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
      pw.SizedBox(height: 8),
    ];

    final lineBuffer = <(String, Map<String, dynamic>)>[];

    Future<void> flushLine(Map<String, dynamic> blockAttrs) async {
      if (lineBuffer.isEmpty) return;
      final spans = lineBuffer.map((s) => _pdfSpan(s.$1, s.$2)).toList();
      lineBuffer.clear();

      final header = blockAttrs['header'];
      final list = blockAttrs['list'];
      final codeBlock = blockAttrs['code-block'] == true;
      final blockquote = blockAttrs['blockquote'] == true;

      if (codeBlock) {
        widgets.add(pw.Container(
          color: PdfColors.grey200,
          padding: const pw.EdgeInsets.all(8),
          child: pw.RichText(
            text: pw.TextSpan(
              children: spans,
              style: pw.TextStyle(font: await pw.Font.courier(), fontSize: 10),
            ),
          ),
        ));
      } else if (blockquote) {
        widgets.add(pw.Container(
          decoration: const pw.BoxDecoration(
            border: pw.Border(left: pw.BorderSide(color: PdfColors.grey400, width: 3)),
          ),
          padding: const pw.EdgeInsets.only(left: 8),
          child: pw.RichText(
            text: pw.TextSpan(
              children: spans,
              style: const pw.TextStyle(color: PdfColors.grey700),
            ),
          ),
        ));
      } else if (header != null) {
        final size = switch ((header as int).clamp(1, 3)) {
          1 => 18.0,
          2 => 15.0,
          _ => 13.0,
        };
        widgets.add(pw.RichText(
          text: pw.TextSpan(
            children: spans,
            style: pw.TextStyle(fontSize: size, fontWeight: pw.FontWeight.bold),
          ),
        ));
      } else if (list == 'bullet') {
        widgets.add(pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('•  '),
            pw.Expanded(child: pw.RichText(text: pw.TextSpan(children: spans))),
          ],
        ));
      } else if (list == 'ordered') {
        // Simple: just use a bullet for merged ordered lists (counter lost across flush)
        widgets.add(pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('–  '),
            pw.Expanded(child: pw.RichText(text: pw.TextSpan(children: spans))),
          ],
        ));
      } else {
        widgets.add(pw.RichText(text: pw.TextSpan(children: spans)));
      }
      widgets.add(pw.SizedBox(height: 4));
    }

    for (final op in ops) {
      final insert = op['insert'];
      final attrs = (op['attributes'] as Map?)?.cast<String, dynamic>() ?? {};

      if (insert is String) {
        final parts = insert.split('\n');
        for (var i = 0; i < parts.length; i++) {
          if (parts[i].isNotEmpty) lineBuffer.add((parts[i], attrs));
          if (i < parts.length - 1) await flushLine(attrs);
        }
      } else if (insert is Map) {
        await flushLine({});
        if (insert.containsKey('image')) {
          final path = insert['image'] as String? ?? '';
          try {
            final bytes = await File(path).readAsBytes();
            final img = pw.MemoryImage(bytes);
            widgets.add(pw.Image(img, width: 400));
            widgets.add(pw.SizedBox(height: 8));
          } catch (_) {
            widgets.add(pw.Text('[image: $path]',
                style: const pw.TextStyle(color: PdfColors.grey)));
          }
        } else if (insert.containsKey('table')) {
          widgets.add(_pdfTable(insert['table'] as String));
          widgets.add(pw.SizedBox(height: 8));
        }
        // ink/drawing: skip
      }
    }
    if (lineBuffer.isNotEmpty) await flushLine({});
    return widgets;
  }

  pw.TextSpan _pdfSpan(String text, Map<String, dynamic> attrs) {
    final isBold = attrs['bold'] == true;
    final isItalic = attrs['italic'] == true;
    return pw.TextSpan(
      text: text,
      style: pw.TextStyle(
        fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
        fontStyle: isItalic ? pw.FontStyle.italic : pw.FontStyle.normal,
        decoration: attrs['underline'] == true
            ? pw.TextDecoration.underline
            : attrs['strikethrough'] == true
                ? pw.TextDecoration.lineThrough
                : pw.TextDecoration.none,
      ),
    );
  }

  pw.Widget _pdfTable(String jsonData) {
    late List<List<String>> rows;
    try {
      rows = (jsonDecode(jsonData) as List)
          .map((r) => (r as List).map((c) => c.toString()).toList())
          .toList();
    } catch (_) {
      return pw.SizedBox();
    }
    if (rows.isEmpty) return pw.SizedBox();
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400),
      children: rows.asMap().entries.map((entry) {
        final isHeader = entry.key == 0;
        return pw.TableRow(
          decoration: isHeader
              ? const pw.BoxDecoration(color: PdfColors.grey200)
              : null,
          children: entry.value.map((cell) => pw.Padding(
            padding: const pw.EdgeInsets.all(4),
            child: pw.Text(
              cell,
              style: isHeader
                  ? pw.TextStyle(fontWeight: pw.FontWeight.bold)
                  : null,
            ),
          )).toList(),
        );
      }).toList(),
    );
  }

  // ── Delivery ─────────────────────────────────────────────────────────────

  Future<void> _deliver(
    BuildContext context,
    File file,
    String title,
  ) async {
    try {
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: title,
      );
    } catch (_) {
      // Fallback: save to Downloads / Documents.
      Directory? dir;
      try {
        dir = await getDownloadsDirectory();
      } catch (_) {}
      dir ??= await getApplicationDocumentsDirectory();

      final dest = File(p.join(dir.path, p.basename(file.path)));
      await file.copy(dest.path);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to ${dest.path}'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  List<dynamic> _parseOps(String content) {
    try {
      return (jsonDecode(content) as List);
    } catch (_) {
      return [
        {'insert': content},
        {'insert': '\n'},
      ];
    }
  }

  static String _sanitise(String name) =>
      name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}
