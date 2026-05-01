import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:smb_connect/smb_connect.dart';

import '../../core/database/notebooks_dao.dart';
import '../../core/database/page_assets_dao.dart';
import '../../core/database/pages_dao.dart';
import '../../core/database/sections_dao.dart';
import '../../core/models/notebook.dart';
import '../../core/models/page.dart';
import '../../core/models/page_asset.dart';
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

/// Counts of work performed during a bidirectional sync.
class SmbBidirSyncStats {
  int notebooksUploaded   = 0;
  int notebooksDownloaded = 0;
  int sectionsUploaded    = 0;
  int sectionsDownloaded  = 0;
  int pagesUploaded       = 0;
  int pagesDownloaded     = 0;
  int assetsUploaded      = 0;
  int assetsDownloaded    = 0;

  int get totalUploaded =>
      notebooksUploaded + sectionsUploaded + pagesUploaded + assetsUploaded;
  int get totalDownloaded =>
      notebooksDownloaded + sectionsDownloaded + pagesDownloaded + assetsDownloaded;

  String summary() =>
      '↑$totalUploaded (nb $notebooksUploaded, sec $sectionsUploaded, pg $pagesUploaded, asset $assetsUploaded)  '
      '↓$totalDownloaded (nb $notebooksDownloaded, sec $sectionsDownloaded, pg $pagesDownloaded, asset $assetsDownloaded)';
}

class SmbBidirSyncResult {
  final bool success;
  final String? error;
  final SmbBidirSyncStats stats;

  SmbBidirSyncResult({
    required this.success,
    this.error,
    required this.stats,
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
  final PageAssetsDao _assetsDao;

  SmbSyncService(
    this.config, {
    NotebooksDao? notebooksDao,
    SectionsDao?  sectionsDao,
    PagesDao?     pagesDao,
    PageAssetsDao? assetsDao,
  })  : _notebooksDao = notebooksDao ?? NotebooksDao(),
        _sectionsDao  = sectionsDao  ?? SectionsDao(),
        _pagesDao     = pagesDao     ?? PagesDao(),
        _assetsDao    = assetsDao    ?? PageAssetsDao();

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
      // Actually exercise the configured share, not just the server.
      // listShares() succeeds with valid creds even if `share` is wrong,
      // which gives a misleading green light before backup/sync fail.
      final root = await smb.file(_root());
      await smb.listFiles(root);
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

  // ── Bi-directional sync ─────────────────────────────────────────────────────

  /// Two-way sync between this device and the share. Last-write-wins per
  /// entity using `updated_at`. Soft-deletes propagate as is_deleted=1 rows.
  ///
  /// Layout on share (under [_syncRoot]):
  ///   manifest.json              — index of all entity ids → updated_at
  ///   notebooks/<id>.json
  ///   sections/<id>.json         — includes is_default flag
  ///   pages/<id>.json            — includes embedded asset metadata
  ///   assets/<pageId>/<file>     — binary asset blobs
  Future<SmbBidirSyncResult> syncBidirectional() async {
    SmbConnect? smb;
    final stats = SmbBidirSyncStats();

    try {
      smb = await _connect();

      // Ensure remote dirs exist before any read/write.
      await _ensureDirs(smb, _syncRoot());
      await _ensureDirs(smb, '${_syncRoot()}/notebooks');
      await _ensureDirs(smb, '${_syncRoot()}/sections');
      await _ensureDirs(smb, '${_syncRoot()}/pages');
      await _ensureDirs(smb, '${_syncRoot()}/assets');

      // 1. Load manifests.
      final remoteManifest = await _readJson(smb, '${_syncRoot()}/manifest.json')
          ?? <String, dynamic>{};
      final remoteNb   = (remoteManifest['notebooks'] as Map?)?.cast<String, dynamic>() ?? {};
      final remoteSec  = (remoteManifest['sections']  as Map?)?.cast<String, dynamic>() ?? {};
      final remotePg   = (remoteManifest['pages']     as Map?)?.cast<String, dynamic>() ?? {};

      // 2. Reconcile notebooks.
      await _reconcileNotebooks(smb, remoteNb, stats);

      // 3. Reconcile sections (raw rows preserve is_default).
      await _reconcileSections(smb, remoteSec, stats);

      // 4. Reconcile pages (and per-page assets via embedded metadata).
      await _reconcilePages(smb, remotePg, stats);

      // 5. Build & upload merged manifest from current local state.
      await _writeJson(smb, '${_syncRoot()}/manifest.json',
          await _buildManifest());

      return SmbBidirSyncResult(success: true, stats: stats);
    } catch (e) {
      return SmbBidirSyncResult(
          success: false, error: e.toString(), stats: stats);
    } finally {
      await smb?.close();
    }
  }

  Future<void> _reconcileNotebooks(
      SmbConnect smb, Map<String, dynamic> remoteIndex,
      SmbBidirSyncStats stats) async {
    final localList = await _notebooksDao.getAllIncludingDeleted();
    final localById = {for (final nb in localList) nb.id: nb};

    final allIds = <String>{...localById.keys, ...remoteIndex.keys};

    for (final id in allIds) {
      final local    = localById[id];
      final remoteTs = (remoteIndex[id] as num?)?.toInt();
      final localTs  = local?.updatedAt;

      if (localTs != null && (remoteTs == null || localTs > remoteTs)) {
        // Local newer or remote-missing → upload.
        await _writeJson(smb, '${_syncRoot()}/notebooks/$id.json',
            local!.toJson());
        stats.notebooksUploaded++;
      } else if (remoteTs != null && (localTs == null || remoteTs > localTs)) {
        // Remote newer or local-missing → download & apply.
        final json = await _readJson(smb, '${_syncRoot()}/notebooks/$id.json');
        if (json == null) continue;
        final nb = Notebook.fromJson(json);
        if (local == null) {
          await _notebooksDao.insert(nb);
        } else {
          await _notebooksDao.update(nb);
        }
        stats.notebooksDownloaded++;
      }
    }
  }

  Future<void> _reconcileSections(
      SmbConnect smb, Map<String, dynamic> remoteIndex,
      SmbBidirSyncStats stats) async {
    final localRows = await _sectionsDao.getAllIncludingDeletedRaw();
    final localById = {for (final r in localRows) r['id'] as String: r};

    final allIds = <String>{...localById.keys, ...remoteIndex.keys};

    for (final id in allIds) {
      final localRow = localById[id];
      final localTs  = (localRow?['updated_at'] as int?);
      final remoteTs = (remoteIndex[id] as num?)?.toInt();

      if (localTs != null && (remoteTs == null || localTs > remoteTs)) {
        await _writeJson(smb, '${_syncRoot()}/sections/$id.json', localRow!);
        stats.sectionsUploaded++;
      } else if (remoteTs != null && (localTs == null || remoteTs > localTs)) {
        final json = await _readJson(smb, '${_syncRoot()}/sections/$id.json');
        if (json == null) continue;
        // sqflite needs ints (1/0) for the boolean columns.
        json['is_deleted'] = (json['is_deleted'] is bool)
            ? ((json['is_deleted'] as bool) ? 1 : 0)
            : (json['is_deleted'] as num?)?.toInt() ?? 0;
        json['is_default'] = (json['is_default'] is bool)
            ? ((json['is_default'] as bool) ? 1 : 0)
            : (json['is_default'] as num?)?.toInt() ?? 0;
        if (localRow == null) {
          await _sectionsDao.insertRaw(Map<String, dynamic>.from(json));
        } else {
          await _sectionsDao.updateRaw(Map<String, dynamic>.from(json));
        }
        stats.sectionsDownloaded++;
      }
    }
  }

  Future<void> _reconcilePages(
      SmbConnect smb, Map<String, dynamic> remoteIndex,
      SmbBidirSyncStats stats) async {
    final localList = await _pagesDao.getAllIncludingDeleted();
    final localById = {for (final p in localList) p.id: p};

    final allIds = <String>{...localById.keys, ...remoteIndex.keys};

    for (final id in allIds) {
      final local    = localById[id];
      final remoteTs = (remoteIndex[id] as num?)?.toInt();
      final localTs  = local?.updatedAt;

      if (localTs != null && (remoteTs == null || localTs > remoteTs)) {
        // Upload page + asset metadata + asset binaries.
        final assets = await _assetsDao.getByPage(id);
        final payload = <String, dynamic>{
          ...local!.toJson(),
          'assets': assets.map((a) => {
                'id':         a.id,
                'page_id':    a.pageId,
                'file_name':  a.fileName,
                'mime_type':  a.mimeType,
                'created_at': a.createdAt,
              }).toList(),
        };
        await _writeJson(smb, '${_syncRoot()}/pages/$id.json', payload);

        // Upload binaries for any assets that have a local file.
        for (final a in assets) {
          final f = File(a.localPath);
          if (await f.exists()) {
            await _ensureDirs(smb, '${_syncRoot()}/assets/$id');
            await _writeFile(smb, '${_syncRoot()}/assets/$id/${a.fileName}',
                await f.readAsBytes());
            stats.assetsUploaded++;
          }
        }
        stats.pagesUploaded++;
      } else if (remoteTs != null && (localTs == null || remoteTs > localTs)) {
        // Download page; reconcile its assets.
        final json = await _readJson(smb, '${_syncRoot()}/pages/$id.json');
        if (json == null) continue;
        final assetMeta = (json.remove('assets') as List?)
                ?.cast<Map<String, dynamic>>() ?? const [];

        final page = NotePage.fromJson(json);
        if (local == null) {
          await _pagesDao.insert(page);
        } else {
          await _pagesDao.update(page);
        }
        stats.pagesDownloaded++;

        await _reconcilePageAssets(smb, page.id, assetMeta, stats);
      }
    }
  }

  Future<void> _reconcilePageAssets(
      SmbConnect smb, String pageId, List<Map<String, dynamic>> remoteAssets,
      SmbBidirSyncStats stats) async {
    final remoteIds   = remoteAssets.map((a) => a['id'] as String).toSet();
    final localAssets = await _assetsDao.getByPage(pageId);
    final localIds    = localAssets.map((a) => a.id).toSet();

    // Drop any local assets that are no longer in the remote list — the
    // page-update path is what propagates asset deletions.
    for (final a in localAssets) {
      if (!remoteIds.contains(a.id)) {
        await _assetsDao.delete(a.id);
        // Best-effort: remove the orphaned file. Failure is non-fatal.
        try { await File(a.localPath).delete(); } catch (_) {}
      }
    }

    // Pull any remote asset binaries we don't yet have locally.
    for (final meta in remoteAssets) {
      final id = meta['id'] as String;
      if (localIds.contains(id)) continue;

      final fileName  = meta['file_name'] as String;
      final mimeType  = meta['mime_type'] as String? ?? 'application/octet-stream';
      final createdAt = (meta['created_at'] as num?)?.toInt()
          ?? DateTime.now().millisecondsSinceEpoch;

      final bytes = await _readBinary(smb, '${_syncRoot()}/assets/$pageId/$fileName');
      if (bytes == null) continue;

      final docs    = await getApplicationDocumentsDirectory();
      final destDir = Directory(p.join(docs.path, 'assets', pageId));
      await destDir.create(recursive: true);
      final destFile = File(p.join(destDir.path, fileName));
      await destFile.writeAsBytes(bytes);

      await _assetsDao.insert(PageAsset(
        id:        id,
        pageId:    pageId,
        fileName:  fileName,
        localPath: destFile.path,
        mimeType:  mimeType,
        createdAt: createdAt,
      ));
      stats.assetsDownloaded++;
    }
  }

  Future<Map<String, dynamic>> _buildManifest() async {
    final notebooks = await _notebooksDao.getAllIncludingDeleted();
    final sections  = await _sectionsDao.getAllIncludingDeletedRaw();
    final pages     = await _pagesDao.getAllIncludingDeleted();

    return {
      'version':    1,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
      'notebooks': {for (final n in notebooks) n.id: n.updatedAt},
      'sections':  {for (final s in sections)  s['id']: s['updated_at']},
      'pages':     {for (final p in pages)     p.id: p.updatedAt},
    };
  }

  String _syncRoot() => '${_root()}/_sync';

  // ── SMB backup / restore ────────────────────────────────────────────────────

  /// Builds a full backup ZIP (notes + settings) and writes it to the share
  /// under `{root}/_backups/flutter_notes_backup_<stamp>.zip`.
  Future<SmbSyncResult> backupToSmb() async {
    SmbConnect? smb;
    try {
      // Build the ZIP entirely before opening the SMB connection so the
      // connection is not left idle during the (potentially slow) DB read +
      // archive creation, which causes "network name no longer available".
      final zipFile = await _buildBackupZip();
      final bytes   = await zipFile.readAsBytes();

      smb = await _connect();

      final backupDir  = _backupDir();
      await _ensureDirs(smb, backupDir);

      final remotePath = '$backupDir/${p.basename(zipFile.path)}';
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

      final backupDir = _backupDir();
      final dirFile   = await smb.file(backupDir);
      final files     = await smb.listFiles(dirFile);
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

      // Download and restore
      final smbFile = await smb.file(remotePath);
      final stream  = await smb.openRead(smbFile);
      final bytes   = <int>[];
      await for (final chunk in stream) bytes.addAll(chunk);

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
      final backupDir = _backupDir();
      final dirFile   = await smb.file(backupDir);
      final files     = await smb.listFiles(dirFile);
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
      final remotePath = '${_backupDir()}/$fileName';
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

      // Include pages added directly to the notebook (no user-section).
      // They live under a hidden default section that getByNotebook filters
      // out, so they would otherwise be silently dropped from the backup.
      final defaultSec = await _sectionsDao.getDefault(nb.id);
      if (defaultSec != null) {
        final pages = await _pagesDao.getBySection(defaultSec.id);
        if (pages.isNotEmpty) {
          final manifestPgs = <Map<String, dynamic>>[];
          for (final pg in pages) {
            final safePath = '${_sanitize(nb.name)}/Unsectioned/${_sanitize(pg.title)}.md';
            final ops = _parseOps(pg.content);
            pageFiles[safePath] =
                '# ${pg.title}\n\n${DeltaConverter.toMarkdown(ops)}\n';
            manifestPgs.add({
              'id': pg.id, 'title': pg.title, 'file': safePath,
              'created_at': pg.createdAt, 'updated_at': pg.updatedAt,
            });
          }
          manifestSecs.add({
            'id': defaultSec.id, 'name': 'Unsectioned', 'color': defaultSec.color,
            'pages': manifestPgs,
          });
        }
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

  String _backupDir() {
    final bp = config.backupPath.trim();
    return bp.isNotEmpty ? '${_root()}/$bp' : '${_root()}/_backups';
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
    SmbFile smbFile;
    try {
      smbFile = await smb.createFile(path);
    } catch (_) {
      smbFile = await smb.file(path);
    }
    final sink = await smb.openWrite(smbFile);
    sink.add(Uint8List.fromList(bytes));
    await sink.flush();
    await sink.close();
  }

  Future<List<int>?> _readBinary(SmbConnect smb, String path) async {
    try {
      final file   = await smb.file(path);
      final stream = await smb.openRead(file);
      final bytes  = <int>[];
      await for (final chunk in stream) bytes.addAll(chunk);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _readJson(SmbConnect smb, String path) async {
    final bytes = await _readBinary(smb, path);
    if (bytes == null) return null;
    try {
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeJson(
      SmbConnect smb, String path, Map<String, dynamic> obj) async {
    await _writeFile(smb, path, utf8.encode(jsonEncode(obj)));
  }
}
