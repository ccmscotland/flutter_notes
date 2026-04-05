import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:smb_connect/smb_connect.dart';

import '../../core/database/notebooks_dao.dart';
import '../../core/database/pages_dao.dart';
import '../../core/database/sections_dao.dart';
import '../../core/models/notebook.dart';
import '../../core/models/page.dart';
import '../../core/models/section.dart';
import '../export/delta_converter.dart';
import '../export/export_service.dart';
import 'smb_config.dart';
import 'settings_backup.dart';

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

  // ── SMB backup / restore ────────────────────────────────────────────────────

  /// Builds a full backup ZIP (notes + settings) and writes it to the share
  /// under `{root}/_backups/flutter_notes_backup_<stamp>.zip`.
  Future<SmbSyncResult> backupToSmb() async {
    SmbConnect? smb;
    try {
      smb = await _connect();

      // Build the backup ZIP locally using ExportService internals.
      // We create a temporary BuildContext-free version by calling
      // ExportService.buildBackupZip (a non-UI path we add below).
      final zipFile = await _buildBackupZip();

      final backupDir = '${_root()}/_backups';
      await _ensureDirs(smb, backupDir);

      final remotePath = '$backupDir/${p.basename(zipFile.path)}';
      final bytes = await zipFile.readAsBytes();
      await _writeFile(smb, remotePath, bytes);

      return SmbSyncResult(success: true, uploaded: 1);
    } catch (e) {
      return SmbSyncResult(success: false, error: e.toString());
    } finally {
      await smb?.close();
    }
  }

  /// Lists available backup ZIPs on the share and restores the most recent one.
  Future<SmbSyncResult> restoreFromSmb() async {
    SmbConnect? smb;
    try {
      smb = await _connect();

      final backupDir = '${_root()}/_backups';
      final files = await smb.listFiles(backupDir);
      // Find the most recent flutter_notes_backup_*.zip
      final zips = files
          .where((f) =>
              f.name.startsWith('flutter_notes_backup_') &&
              f.name.endsWith('.zip'))
          .toList();
      if (zips.isEmpty) {
        return const SmbSyncResult(
            success: false, error: 'No backups found on share');
      }
      zips.sort((a, b) => b.name.compareTo(a.name)); // most recent first
      final remotePath = '$backupDir/${zips.first.name}';

      // Download to temp file
      final tmpDir = await getTemporaryDirectory();
      final localPath = p.join(tmpDir.path, zips.first.name);
      final smbFile = await smb.file(remotePath);
      final stream  = await smb.openRead(smbFile);
      final bytes   = <int>[];
      await for (final chunk in stream) bytes.addAll(chunk);
      await File(localPath).writeAsBytes(bytes);

      // Decode and restore
      final archive = ZipDecoder().decodeBytes(Uint8List.fromList(bytes));
      final result  = await _restoreArchive(archive);
      return result;
    } catch (e) {
      return SmbSyncResult(success: false, error: e.toString());
    } finally {
      await smb?.close();
    }
  }

  /// Lists backup ZIP names available on the share (for display in UI).
  Future<List<String>> listSmbBackups() async {
    SmbConnect? smb;
    try {
      smb = await _connect();
      final backupDir = '${_root()}/_backups';
      final files = await smb.listFiles(backupDir);
      final zips = files
          .where((f) =>
              f.name.startsWith('flutter_notes_backup_') &&
              f.name.endsWith('.zip'))
          .map((f) => f.name)
          .toList();
      zips.sort((a, b) => b.compareTo(a));
      return zips;
    } catch (_) {
      return [];
    } finally {
      await smb?.close();
    }
  }

  /// Restores a specific backup by filename from the share.
  Future<SmbSyncResult> restoreBackupByName(String fileName) async {
    SmbConnect? smb;
    try {
      smb = await _connect();
      final remotePath = '${_root()}/_backups/$fileName';
      final smbFile = await smb.file(remotePath);
      final stream  = await smb.openRead(smbFile);
      final bytes   = <int>[];
      await for (final chunk in stream) bytes.addAll(chunk);

      final archive = ZipDecoder().decodeBytes(Uint8List.fromList(bytes));
      return _restoreArchive(archive);
    } catch (e) {
      return SmbSyncResult(success: false, error: e.toString());
    } finally {
      await smb?.close();
    }
  }

  // Builds the full backup ZIP (same logic as ExportService.backupAll but
  // without Flutter context dependency).
  Future<File> _buildBackupZip() async {
    final tmpDir   = await getTemporaryDirectory();
    final stamp    = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final zipPath  = p.join(tmpDir.path, 'flutter_notes_backup_$stamp.zip');

    final notebooks = await _notebooksDao.getAll();
    final manifestNotebooks = <Map<String, dynamic>>[];
    final pageFiles         = <String, String>{};

    for (final nb in notebooks) {
      final sections     = await _sectionsDao.getByNotebook(nb.id);
      final manifestSecs = <Map<String, dynamic>>[];
      for (final sec in sections) {
        final pages       = await _pagesDao.getBySection(sec.id);
        final manifestPgs = <Map<String, dynamic>>[];
        for (final pg in pages) {
          final safePath = '${_sanitize(nb.name)}/${_sanitize(sec.name)}/${_sanitize(pg.title)}.md';
          final ops = _parseOps(pg.content);
          pageFiles[safePath] =
              '# ${pg.title}\n\n${DeltaConverter.toMarkdown(ops)}\n';
          manifestPgs.add({
            'id': pg.id, 'title': pg.title, 'file': safePath,
            'created_at': pg.createdAt, 'updated_at': pg.updatedAt,
          });
        }
        manifestSecs.add({
          'id': sec.id, 'name': sec.name, 'color': sec.color,
          'pages': manifestPgs,
        });
      }
      manifestNotebooks.add({
        'id': nb.id, 'name': nb.name, 'color': nb.color,
        'sections': manifestSecs,
      });
    }

    final manifest = jsonEncode({
      'version': 2, 'format': 'markdown', 'app': 'flutter_notes',
      'exported_at': DateTime.now().millisecondsSinceEpoch,
      'notebooks': manifestNotebooks,
    });

    final encoder = ZipFileEncoder();
    encoder.create(zipPath);

    final mFile = File(p.join(tmpDir.path, 'manifest.json'));
    await mFile.writeAsString(manifest, encoding: const Utf8Codec());
    encoder.addFile(mFile, 'manifest.json');

    for (final entry in pageFiles.entries) {
      final f = File(p.join(tmpDir.path, 'pg_${entry.key.hashCode}.md'));
      await f.writeAsString(entry.value, encoding: const Utf8Codec());
      encoder.addFile(f, entry.key);
    }

    final settingsJson = await SettingsBackup.export();
    final sFile = File(p.join(tmpDir.path, 'settings.json'));
    await sFile.writeAsString(settingsJson, encoding: const Utf8Codec());
    encoder.addFile(sFile, 'settings.json');

    encoder.close();
    return File(zipPath);
  }

  // Restores an already-decoded archive (shared between SMB restore paths).
  Future<SmbSyncResult> _restoreArchive(Archive archive) async {
    final result = await ExportService().restoreBackupFromArchive(archive);
    if (result.error != null) {
      return SmbSyncResult(
          success: false, uploaded: result.restored, error: result.error);
    }
    return SmbSyncResult(success: true, uploaded: result.restored);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Future<SmbConnect> _connect() => SmbConnect.connectAuth(
        host:     config.host,
        username: config.username,
        password: config.password,
        domain:   config.domain.isNotEmpty ? config.domain : '',
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
