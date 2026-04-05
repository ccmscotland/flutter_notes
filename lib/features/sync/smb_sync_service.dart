import 'dart:convert';
import 'dart:typed_data';

import 'package:smb_connect/smb_connect.dart';

import '../../core/database/notebooks_dao.dart';
import '../../core/database/pages_dao.dart';
import '../../core/database/sections_dao.dart';
import '../../core/models/notebook.dart';
import '../../core/models/page.dart';
import '../../core/models/section.dart';
import '../export/delta_converter.dart';
import 'smb_config.dart';

class SmbSyncResult {
  final bool success;
  final String? error;
  final int uploaded;

  const SmbSyncResult({
    required this.success,
    this.error,
    this.uploaded = 0,
  });
}

/// Represents the full tree of data available for sync selection.
class SmbSyncTree {
  final List<SmbNotebookNode> notebooks;
  const SmbSyncTree(this.notebooks);
}

class SmbNotebookNode {
  final Notebook notebook;
  final List<SmbSectionNode> sections;
  const SmbNotebookNode(this.notebook, this.sections);
}

class SmbSectionNode {
  final Section section;
  final List<NotePage> pages;
  const SmbSectionNode(this.section, this.pages);
}

class SmbSyncService {
  final SmbConfig config;
  final NotebooksDao _notebooksDao;
  final SectionsDao  _sectionsDao;
  final PagesDao     _pagesDao;

  SmbSyncService(
    this.config, {
    NotebooksDao? notebooksDao,
    SectionsDao?  sectionsDao,
    PagesDao?     pagesDao,
  })  : _notebooksDao = notebooksDao ?? NotebooksDao(),
        _sectionsDao  = sectionsDao  ?? SectionsDao(),
        _pagesDao     = pagesDao     ?? PagesDao();

  // ── Tree loader ─────────────────────────────────────────────────────────────

  Future<SmbSyncTree> loadTree() async {
    final notebooks = await _notebooksDao.getAll();
    final nodes = <SmbNotebookNode>[];
    for (final nb in notebooks) {
      final sections = await _sectionsDao.getByNotebook(nb.id);
      final sectionNodes = <SmbSectionNode>[];
      for (final sec in sections) {
        final pages = await _pagesDao.getBySection(sec.id);
        sectionNodes.add(SmbSectionNode(sec, pages));
      }
      nodes.add(SmbNotebookNode(nb, sectionNodes));
    }
    return SmbSyncTree(nodes);
  }

  // ── Connection test ─────────────────────────────────────────────────────────

  Future<bool> testConnection() async {
    SmbConnect? smb;
    try {
      smb = await _connect();
      await smb.listShares();
      return true;
    } catch (_) {
      return false;
    } finally {
      await smb?.close();
    }
  }

  // ── Sync ────────────────────────────────────────────────────────────────────

  /// Syncs selected items to the SMB share.
  /// Pass empty sets to sync everything.
  Future<SmbSyncResult> syncSelected({
    required Set<String> notebookIds,
    required Set<String> sectionIds,
    required Set<String> pageIds,
  }) async {
    SmbConnect? smb;
    int uploaded = 0;

    try {
      smb = await _connect();

      final notebooks = await _notebooksDao.getAll();

      for (final nb in notebooks) {
        if (notebookIds.isNotEmpty && !notebookIds.contains(nb.id)) continue;

        final sections = await _sectionsDao.getByNotebook(nb.id);
        for (final sec in sections) {
          if (sectionIds.isNotEmpty && !sectionIds.contains(sec.id)) continue;

          // Ensure directory exists
          final dir = _dirPath(nb.name, sec.name);
          await _ensureDirs(smb, dir);

          final pages = await _pagesDao.getBySection(sec.id);
          for (final page in pages) {
            if (pageIds.isNotEmpty && !pageIds.contains(page.id)) continue;

            final content  = _pageToText(page);
            final filePath = _filePath(nb.name, sec.name, page.title);
            await _writeFile(smb, filePath, utf8.encode(content));
            uploaded++;
          }
        }
      }

      return SmbSyncResult(success: true, uploaded: uploaded);
    } catch (e) {
      return SmbSyncResult(success: false, error: e.toString());
    } finally {
      await smb?.close();
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<SmbConnect> _connect() => SmbConnect.connectAuth(
        host:     config.host,
        username: config.username,
        password: config.password,
        domain:   config.domain.isNotEmpty ? config.domain : null,
      );

  String _sanitize(String s) =>
      s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();

  String _root() {
    final base = config.basePath.isNotEmpty ? '/${config.basePath}' : '';
    return '/${config.share}$base';
  }

  String _dirPath(String notebook, String section) =>
      '${_root()}/${_sanitize(notebook)}/${_sanitize(section)}';

  String _filePath(String notebook, String section, String page) {
    final ext = config.format == 'html' ? 'html' : 'md';
    return '${_dirPath(notebook, section)}/${_sanitize(page)}.$ext';
  }

  String _pageToText(NotePage page) {
    final ops = _parseOps(page.content);
    if (config.format == 'html') {
      return DeltaConverter.toHtml(ops, title: page.title);
    }
    return '# ${page.title}\n\n${DeltaConverter.toMarkdown(ops)}';
  }

  List<dynamic> _parseOps(String content) {
    try {
      return jsonDecode(content) as List;
    } catch (_) {
      return [
        {'insert': content},
        {'insert': '\n'},
      ];
    }
  }

  Future<void> _ensureDirs(SmbConnect smb, String path) async {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    var current = '';
    for (final part in parts) {
      current = '$current/$part';
      try { await smb.createFolder(current); } catch (_) {}
    }
  }

  Future<void> _writeFile(
      SmbConnect smb, String path, List<int> bytes) async {
    try { await smb.createFile(path); } catch (_) {}
    final smbFile = await smb.file(path);
    final sink    = await smb.openWrite(smbFile);
    sink.add(Uint8List.fromList(bytes));
    await sink.close();
  }
}
