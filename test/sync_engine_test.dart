import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_notes/core/models/notebook.dart';
import 'package:flutter_notes/core/models/page.dart';
import 'package:flutter_notes/core/models/page_asset.dart';
import 'package:flutter_notes/core/models/section.dart';
import 'package:flutter_notes/core/models/sync_record.dart';
import 'package:flutter_notes/core/database/notebooks_dao.dart';
import 'package:flutter_notes/core/database/sections_dao.dart';
import 'package:flutter_notes/core/database/pages_dao.dart';
import 'package:flutter_notes/core/database/page_assets_dao.dart';
import 'package:flutter_notes/core/database/sync_records_dao.dart';
import 'package:flutter_notes/features/sync/sync_engine.dart';
import 'package:flutter_notes/features/sync/google_drive_service.dart';
import 'package:flutter_notes/features/sync/onedrive_service.dart';

// ---------------------------------------------------------------------------
// In-memory fakes (implement the concrete DAO classes as Dart allows)
// ---------------------------------------------------------------------------

class _FakeNotebooksDao implements NotebooksDao {
  final List<Notebook> store = [];

  @override Future<List<Notebook>> getAll() async =>
      store.where((n) => !n.isDeleted).toList();
  @override Future<Notebook?> getById(String id) async =>
      store.where((n) => n.id == id).firstOrNull;
  @override Future<void> insert(Notebook nb) async => store.add(nb);
  @override Future<void> update(Notebook nb) async {
    final i = store.indexWhere((n) => n.id == nb.id);
    if (i != -1) store[i] = nb;
  }
  @override Future<void> delete(String id) async {
    final i = store.indexWhere((n) => n.id == id);
    if (i != -1) store[i] = store[i].copyWith(isDeleted: true);
  }
  @override Future<void> hardDelete(String id) async =>
      store.removeWhere((n) => n.id == id);
}

class _FakeSectionsDao implements SectionsDao {
  final List<Section> store = [];

  @override Future<List<Section>> getAll() async => List.from(store);
  @override Future<List<Section>> getByNotebook(String notebookId) async =>
      store.where((s) => s.notebookId == notebookId && !s.isDeleted).toList();
  @override Future<Section?> getById(String id) async =>
      store.where((s) => s.id == id).firstOrNull;
  @override Future<void> insert(Section s) async => store.add(s);
  @override Future<void> update(Section s) async {
    final i = store.indexWhere((e) => e.id == s.id);
    if (i != -1) store[i] = s;
  }
  @override Future<void> delete(String id) async {
    final i = store.indexWhere((e) => e.id == id);
    if (i != -1) store[i] = store[i].copyWith(isDeleted: true);
  }
}

class _FakePagesDao implements PagesDao {
  final List<NotePage> store = [];

  @override Future<List<NotePage>> getAll() async =>
      store.where((p) => !p.isDeleted).toList();
  @override Future<List<NotePage>> getBySection(String sectionId) async =>
      store.where((p) => p.sectionId == sectionId && !p.isDeleted).toList();
  @override Future<NotePage?> getById(String id) async =>
      store.where((p) => p.id == id).firstOrNull;
  @override Future<void> insert(NotePage p) async => store.add(p);
  @override Future<void> update(NotePage p) async {
    final i = store.indexWhere((e) => e.id == p.id);
    if (i != -1) store[i] = p;
  }
  @override Future<void> delete(String id) async {
    final i = store.indexWhere((e) => e.id == id);
    if (i != -1) store[i] = store[i].copyWith(isDeleted: true);
  }
  @override Future<List<NotePage>> search(String query) async => [];
}

class _FakePageAssetsDao implements PageAssetsDao {
  @override Future<List<PageAsset>> getByPage(String pageId) async => [];
  @override Future<PageAsset?> getById(String id) async => null;
  @override Future<void> insert(PageAsset asset) async {}
  @override Future<void> delete(String id) async {}
}

class _FakeSyncRecordsDao implements SyncRecordsDao {
  final List<SyncRecord> store = [];

  @override
  Future<SyncRecord?> getByEntityAndProvider(
      String entityId, String provider) async =>
      store.where(
          (r) => r.entityId == entityId && r.provider == provider).firstOrNull;

  @override
  Future<List<SyncRecord>> getPendingByProvider(String provider) async =>
      store.where((r) =>
          r.provider == provider &&
          r.syncStatus == SyncStatus.pending).toList();

  @override
  Future<void> upsert(SyncRecord record) async {
    final i = store.indexWhere((r) =>
        r.entityId == record.entityId && r.provider == record.provider);
    if (i != -1) {
      store[i] = record;
    } else {
      store.add(record);
    }
  }

  @override
  Future<void> markSynced(String entityId, String provider) async {
    final i = store.indexWhere(
        (r) => r.entityId == entityId && r.provider == provider);
    if (i != -1) {
      store[i] = store[i].copyWith(
        syncStatus: SyncStatus.synced,
        lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
  }
}

/// Fake cloud storage: in-memory map of path → content.
class _FakeCloud {
  final Map<String, String> texts = {};
  final Map<String, List<int>> binaries = {};

  Future<void> uploadText(String path, String content) async =>
      texts[path] = content;
  Future<String?> downloadText(String path) async => texts[path];
  Future<void> uploadBinary(
          String path, List<int> bytes, String mimeType) async =>
      binaries[path] = bytes;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Notebook _nb(String id, int updatedAt) => Notebook(
      id: id,
      name: 'Notebook $id',
      color: 0xFF1565C0,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

Section _sec(String id, String notebookId, int updatedAt) => Section(
      id: id,
      notebookId: notebookId,
      name: 'Section $id',
      color: 0xFF1565C0,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    );

SyncEngine _engine({
  required _FakeNotebooksDao notebooksDao,
  required _FakeSectionsDao sectionsDao,
  required _FakePagesDao pagesDao,
  required _FakeSyncRecordsDao syncRecordsDao,
}) =>
    SyncEngine(
      notebooksDao: notebooksDao,
      sectionsDao: sectionsDao,
      pagesDao: pagesDao,
      assetsDao: _FakePageAssetsDao(),
      syncRecordsDao: syncRecordsDao,
      googleDrive: GoogleDriveService(),
      oneDrive: OneDriveService(),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('SyncEngine — notebook conflict resolution', () {
    late _FakeNotebooksDao nbDao;
    late _FakeSectionsDao secDao;
    late _FakePagesDao pgDao;
    late _FakeSyncRecordsDao recDao;
    late _FakeCloud cloud;

    setUp(() {
      nbDao  = _FakeNotebooksDao();
      secDao = _FakeSectionsDao();
      pgDao  = _FakePagesDao();
      recDao = _FakeSyncRecordsDao();
      cloud  = _FakeCloud();
    });

    Future<void> runSync() => _engine(
          notebooksDao: nbDao,
          sectionsDao: secDao,
          pagesDao: pgDao,
          syncRecordsDao: recDao,
        ).syncWithCallbacks(
          'google_drive',
          cloud.uploadText,
          cloud.downloadText,
          cloud.uploadBinary,
        );

    test('local notebook is uploaded when no remote manifest exists', () async {
      nbDao.store.add(_nb('nb-1', 1000));
      await runSync();
      expect(cloud.texts.containsKey('nb-1/notebook.json'), isTrue);
    });

    test('notebook is uploaded when local is newer than remote', () async {
      nbDao.store.add(_nb('nb-1', 2000));
      cloud.texts['manifest.json'] =
          jsonEncode({'nb-1': {'name': 'Old', 'updated_at': 1000}});

      await runSync();

      final uploaded =
          jsonDecode(cloud.texts['nb-1/notebook.json']!) as Map;
      expect(uploaded['name'], 'Notebook nb-1');
    });

    test('local notebook is updated when remote is newer', () async {
      final nb = _nb('nb-1', 1000);
      nbDao.store.add(nb);
      final remoteNb = nb.copyWith(name: 'Remote Name', updatedAt: 3000);
      cloud.texts['manifest.json'] =
          jsonEncode({'nb-1': {'name': 'Remote Name', 'updated_at': 3000}});
      cloud.texts['nb-1/notebook.json'] = jsonEncode(remoteNb.toJson());

      await runSync();

      expect(nbDao.store.first.name, 'Remote Name');
    });

    test('notebook with same timestamp is not re-uploaded', () async {
      nbDao.store.add(_nb('nb-1', 1000));
      cloud.texts['manifest.json'] =
          jsonEncode({'nb-1': {'name': 'Notebook nb-1', 'updated_at': 1000}});

      await runSync();

      expect(cloud.texts.containsKey('nb-1/notebook.json'), isFalse);
    });

    test('sync record is written after upload with synced status', () async {
      nbDao.store.add(_nb('nb-1', 1000));
      await runSync();

      final rec =
          await recDao.getByEntityAndProvider('nb-1', 'google_drive');
      expect(rec, isNotNull);
      expect(rec!.syncStatus, SyncStatus.synced);
    });

    test('manifest.json is uploaded at end of sync', () async {
      nbDao.store.add(_nb('nb-1', 1000));
      await runSync();
      expect(cloud.texts.containsKey('manifest.json'), isTrue);
    });
  });

  group('SyncEngine — section conflict resolution', () {
    late _FakeNotebooksDao nbDao;
    late _FakeSectionsDao secDao;
    late _FakePagesDao pgDao;
    late _FakeSyncRecordsDao recDao;
    late _FakeCloud cloud;

    setUp(() {
      nbDao  = _FakeNotebooksDao();
      secDao = _FakeSectionsDao();
      pgDao  = _FakePagesDao();
      recDao = _FakeSyncRecordsDao();
      cloud  = _FakeCloud();
    });

    Future<void> runSync() => _engine(
          notebooksDao: nbDao,
          sectionsDao: secDao,
          pagesDao: pgDao,
          syncRecordsDao: recDao,
        ).syncWithCallbacks(
          'google_drive',
          cloud.uploadText,
          cloud.downloadText,
          cloud.uploadBinary,
        );

    test('section is uploaded when no remote section manifest exists', () async {
      nbDao.store.add(_nb('nb-1', 1000));
      secDao.store.add(_sec('s-1', 'nb-1', 1000));
      await runSync();
      expect(cloud.texts.containsKey('nb-1/s-1/section.json'), isTrue);
    });

    test('section is not re-uploaded when timestamps are equal', () async {
      nbDao.store.add(_nb('nb-1', 1000));
      secDao.store.add(_sec('s-1', 'nb-1', 1000));
      cloud.texts['nb-1/_sections.json'] = jsonEncode(
          {'s-1': {'name': 'Section s-1', 'updated_at': 1000}});

      await runSync();

      expect(cloud.texts.containsKey('nb-1/s-1/section.json'), isFalse);
    });

    test('section is uploaded when local is newer than remote', () async {
      nbDao.store.add(_nb('nb-1', 1000));
      secDao.store.add(_sec('s-1', 'nb-1', 2000));
      cloud.texts['nb-1/_sections.json'] = jsonEncode(
          {'s-1': {'name': 'Section s-1', 'updated_at': 500}});

      await runSync();

      expect(cloud.texts.containsKey('nb-1/s-1/section.json'), isTrue);
    });

    test('local section is updated when remote is newer', () async {
      nbDao.store.add(_nb('nb-1', 1000));
      final section = _sec('s-1', 'nb-1', 1000);
      secDao.store.add(section);
      final remoteSection =
          section.copyWith(name: 'Remote Section', updatedAt: 9000);
      cloud.texts['nb-1/_sections.json'] = jsonEncode(
          {'s-1': {'name': 'Remote Section', 'updated_at': 9000}});
      cloud.texts['nb-1/s-1/section.json'] =
          jsonEncode(remoteSection.toJson());

      await runSync();

      expect(secDao.store.first.name, 'Remote Section');
    });

    test('section manifest is uploaded for each notebook', () async {
      nbDao.store.add(_nb('nb-1', 1000));
      secDao.store.add(_sec('s-1', 'nb-1', 1000));

      await runSync();

      expect(cloud.texts.containsKey('nb-1/_sections.json'), isTrue);
    });
  });
}
