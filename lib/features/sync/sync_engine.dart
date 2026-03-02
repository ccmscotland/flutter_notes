import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:uuid/uuid.dart';
import '../../core/database/notebooks_dao.dart';
import '../../core/database/sections_dao.dart';
import '../../core/database/pages_dao.dart';
import '../../core/database/page_assets_dao.dart';
import '../../core/database/sync_records_dao.dart';
import '../../core/models/notebook.dart';
import '../../core/models/page.dart';
import '../../core/models/section.dart';
import '../../core/models/sync_record.dart';
import 'google_drive_service.dart';
import 'onedrive_service.dart';

enum SyncProvider { googleDrive, oneDrive }

class SyncEngine {
  final NotebooksDao _notebooksDao;
  final SectionsDao _sectionsDao;
  final PagesDao _pagesDao;
  final PageAssetsDao _assetsDao;
  final SyncRecordsDao _syncRecordsDao;
  final GoogleDriveService _googleDrive;
  final OneDriveService _oneDrive;

  SyncEngine({
    required NotebooksDao notebooksDao,
    required SectionsDao sectionsDao,
    required PagesDao pagesDao,
    required PageAssetsDao assetsDao,
    required SyncRecordsDao syncRecordsDao,
    required GoogleDriveService googleDrive,
    required OneDriveService oneDrive,
  })  : _notebooksDao = notebooksDao,
        _sectionsDao = sectionsDao,
        _pagesDao = pagesDao,
        _assetsDao = assetsDao,
        _syncRecordsDao = syncRecordsDao,
        _googleDrive = googleDrive,
        _oneDrive = oneDrive;

  // ---- Public entry points ----

  /// Exposed for unit testing: runs the full sync logic with caller-supplied
  /// upload/download callbacks, bypassing the real cloud service instances.
  @visibleForTesting
  Future<void> syncWithCallbacks(
    String providerKey,
    Future<void> Function(String, String) uploadText,
    Future<String?> Function(String) downloadText,
    Future<void> Function(String, List<int>, String) uploadBinary,
  ) => _syncWithService(providerKey, uploadText, downloadText, uploadBinary);

  Future<SyncResult> syncAll(SyncProvider provider) async {
    final errors = <String>[];
    try {
      if (provider == SyncProvider.googleDrive) {
        await _syncWithService(
          'google_drive',
          _googleDrive.uploadText,
          _googleDrive.downloadText,
          _googleDrive.uploadBinary,
        );
      } else {
        await _syncWithService(
          'onedrive',
          _oneDrive.uploadText,
          _oneDrive.downloadText,
          _oneDrive.uploadBinary,
        );
      }
    } catch (e) {
      errors.add(e.toString());
    }
    return SyncResult(
      success: errors.isEmpty,
      errors: errors,
      timestamp: DateTime.now(),
    );
  }

  Future<void> _syncWithService(
    String providerKey,
    Future<void> Function(String, String) uploadText,
    Future<String?> Function(String) downloadText,
    Future<void> Function(String, List<int>, String) uploadBinary,
  ) async {
    // 1. Download remote manifest
    Map<String, dynamic> remoteManifest = {};
    final manifestJson = await downloadText('manifest.json');
    if (manifestJson != null) {
      try {
        remoteManifest = jsonDecode(manifestJson) as Map<String, dynamic>;
      } catch (_) {}
    }

    final localNotebooks = await _notebooksDao.getAll();

    // 2. Sync notebooks
    for (final nb in localNotebooks) {
      final remotePath = '${nb.id}/notebook.json';

      final remoteEntry = remoteManifest[nb.id] as Map<String, dynamic>?;
      final remoteTs = remoteEntry?['updated_at'] as int?;

      if (remoteTs == null || nb.updatedAt > (remoteTs)) {
        // Local is newer → upload
        await uploadText(remotePath, jsonEncode(nb.toJson()));
        await _syncRecordsDao.upsert(SyncRecord(
          id: const Uuid().v4(),
          entityType: 'notebook',
          entityId: nb.id,
          lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
          syncStatus: SyncStatus.synced,
          remotePath: remotePath,
          provider: providerKey,
        ));
      } else if (remoteTs > nb.updatedAt) {
        // Remote is newer → download
        final remoteJson = await downloadText(remotePath);
        if (remoteJson != null) {
          final remoteNb = Notebook.fromJson(
              jsonDecode(remoteJson) as Map<String, dynamic>);
          await _notebooksDao.update(remoteNb);
        }
      }

      // Sync sections under this notebook
      await _syncSections(
          nb.id, providerKey, uploadText, downloadText, uploadBinary);
    }

    // 3. Check remote notebooks not in local (new from another device)
    for (final entry in remoteManifest.entries) {
      final nbId = entry.key;
      final local = await _notebooksDao.getById(nbId);
      if (local == null) {
        final remoteJson = await downloadText('$nbId/notebook.json');
        if (remoteJson != null) {
          final remoteNb = Notebook.fromJson(
              jsonDecode(remoteJson) as Map<String, dynamic>);
          await _notebooksDao.insert(remoteNb);
          await _syncSections(
              nbId, providerKey, uploadText, downloadText, uploadBinary);
        }
      }
    }

    // 4. Upload updated manifest
    final allNotebooks = await _notebooksDao.getAll();
    final manifest = {
      for (final nb in allNotebooks)
        nb.id: {'name': nb.name, 'updated_at': nb.updatedAt}
    };
    await uploadText('manifest.json', jsonEncode(manifest));
  }

  Future<void> _syncSections(
    String notebookId,
    String providerKey,
    Future<void> Function(String, String) uploadText,
    Future<String?> Function(String) downloadText,
    Future<void> Function(String, List<int>, String) uploadBinary,
  ) async {
    // Download remote section manifest for this notebook to enable
    // timestamp-based conflict resolution (mirrors notebook sync behaviour).
    Map<String, dynamic> remoteSectionManifest = {};
    final sectionManifestJson =
        await downloadText('$notebookId/_sections.json');
    if (sectionManifestJson != null) {
      try {
        remoteSectionManifest =
            jsonDecode(sectionManifestJson) as Map<String, dynamic>;
      } catch (_) {}
    }

    final sections = await _sectionsDao.getByNotebook(notebookId);
    for (final section in sections) {
      final remotePath = '$notebookId/${section.id}/section.json';

      final remoteEntry =
          remoteSectionManifest[section.id] as Map<String, dynamic>?;
      final remoteTs = remoteEntry?['updated_at'] as int?;

      if (remoteTs == null || section.updatedAt > remoteTs) {
        // Local is newer (or never synced) → upload
        await uploadText(remotePath, jsonEncode(section.toJson()));
        await _syncRecordsDao.upsert(SyncRecord(
          id: const Uuid().v4(),
          entityType: 'section',
          entityId: section.id,
          lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
          syncStatus: SyncStatus.synced,
          remotePath: remotePath,
          provider: providerKey,
        ));
      } else if (remoteTs > section.updatedAt) {
        // Remote is newer → download
        final remoteJson = await downloadText(remotePath);
        if (remoteJson != null) {
          final remoteSection = Section.fromJson(
              jsonDecode(remoteJson) as Map<String, dynamic>);
          await _sectionsDao.update(remoteSection);
        }
      }

      // Sync pages under this section
      await _syncPages(notebookId, section.id, providerKey, uploadText,
          downloadText, uploadBinary);
    }

    // Upload updated section manifest for this notebook
    final allSections = await _sectionsDao.getByNotebook(notebookId);
    final sectionManifest = {
      for (final s in allSections)
        s.id: {'name': s.name, 'updated_at': s.updatedAt}
    };
    await uploadText(
        '$notebookId/_sections.json', jsonEncode(sectionManifest));
  }

  Future<void> _syncPages(
    String notebookId,
    String sectionId,
    String providerKey,
    Future<void> Function(String, String) uploadText,
    Future<String?> Function(String) downloadText,
    Future<void> Function(String, List<int>, String) uploadBinary,
  ) async {
    // Download remote page manifest for this section for conflict resolution.
    Map<String, dynamic> remotePageManifest = {};
    final pageManifestJson =
        await downloadText('$notebookId/$sectionId/_pages.json');
    if (pageManifestJson != null) {
      try {
        remotePageManifest =
            jsonDecode(pageManifestJson) as Map<String, dynamic>;
      } catch (_) {}
    }

    final pages = await _pagesDao.getBySection(sectionId);
    for (final page in pages) {
      final remotePath = '$notebookId/$sectionId/${page.id}/page.json';

      final remoteEntry =
          remotePageManifest[page.id] as Map<String, dynamic>?;
      final remoteTs = remoteEntry?['updated_at'] as int?;

      if (remoteTs == null || page.updatedAt > remoteTs) {
        // Local is newer (or never synced) → upload
        await uploadText(remotePath, jsonEncode(page.toJson()));
        await _syncRecordsDao.upsert(SyncRecord(
          id: const Uuid().v4(),
          entityType: 'page',
          entityId: page.id,
          lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
          syncStatus: SyncStatus.synced,
          remotePath: remotePath,
          provider: providerKey,
        ));
      } else if (remoteTs > page.updatedAt) {
        // Remote is newer → download
        final remoteJson = await downloadText(remotePath);
        if (remoteJson != null) {
          final remotePage = NotePage.fromJson(
              jsonDecode(remoteJson) as Map<String, dynamic>);
          await _pagesDao.update(remotePage);
        }
      }

      // Upload assets (always upload if not yet synced)
      final assets = await _assetsDao.getByPage(page.id);
      for (final asset in assets) {
        final assetPath =
            '$notebookId/$sectionId/${page.id}/assets/${asset.fileName}';
        final existing = await _syncRecordsDao.getByEntityAndProvider(
            asset.id, providerKey);
        if (existing?.syncStatus != SyncStatus.synced) {
          final file = File(asset.localPath);
          if (file.existsSync()) {
            final bytes = await file.readAsBytes();
            await uploadBinary(assetPath, bytes, asset.mimeType);
            await _syncRecordsDao.upsert(SyncRecord(
              id: const Uuid().v4(),
              entityType: 'asset',
              entityId: asset.id,
              lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
              syncStatus: SyncStatus.synced,
              remotePath: assetPath,
              provider: providerKey,
            ));
          }
        }
      }
    }

    // Upload updated page manifest for this section
    final allPages = await _pagesDao.getBySection(sectionId);
    final pageManifest = {
      for (final p in allPages)
        p.id: {'title': p.title, 'updated_at': p.updatedAt}
    };
    await uploadText(
        '$notebookId/$sectionId/_pages.json', jsonEncode(pageManifest));
  }
}

class SyncResult {
  final bool success;
  final List<String> errors;
  final DateTime timestamp;

  const SyncResult({
    required this.success,
    required this.errors,
    required this.timestamp,
  });
}
