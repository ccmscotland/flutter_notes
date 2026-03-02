import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_notes/core/models/notebook.dart';
import 'package:flutter_notes/core/database/notebooks_dao.dart';
import 'package:flutter_notes/features/notebooks/notebooks_provider.dart';

/// In-memory fake DAO that doesn't touch SQLite, used for provider tests.
class _FakeNotebooksDao implements NotebooksDao {
  final List<Notebook> _store = [];

  @override
  Future<List<Notebook>> getAll() async =>
      _store.where((n) => !n.isDeleted).toList();

  @override
  Future<Notebook?> getById(String id) async =>
      _store.where((n) => n.id == id).firstOrNull;

  @override
  Future<void> insert(Notebook nb) async => _store.add(nb);

  @override
  Future<void> update(Notebook nb) async {
    final idx = _store.indexWhere((n) => n.id == nb.id);
    if (idx != -1) _store[idx] = nb;
  }

  @override
  Future<void> delete(String id) async {
    final idx = _store.indexWhere((n) => n.id == id);
    if (idx != -1) _store[idx] = _store[idx].copyWith(isDeleted: true);
  }

  @override
  Future<void> hardDelete(String id) async =>
      _store.removeWhere((n) => n.id == id);
}

ProviderContainer _makeContainer(_FakeNotebooksDao fakeDao) {
  return ProviderContainer(
    overrides: [
      notebooksDaoProvider.overrideWithValue(fakeDao),
    ],
  );
}

void main() {
  group('NotebooksNotifier', () {
    late _FakeNotebooksDao dao;
    late ProviderContainer container;

    setUp(() {
      dao = _FakeNotebooksDao();
      container = _makeContainer(dao);
      addTearDown(container.dispose);
    });

    test('build() returns empty list when no notebooks', () async {
      final result =
          await container.read(notebooksProvider.future);
      expect(result, isEmpty);
    });

    test('create() adds a notebook and list grows by 1', () async {
      final notifier = container.read(notebooksProvider.notifier);
      await notifier.create('My Notebook', 0xFF1565C0);

      final list = await container.read(notebooksProvider.future);
      expect(list.length, 1);
      expect(list.first.name, 'My Notebook');
    });

    test('create() sets createdAt and updatedAt', () async {
      final before = DateTime.now().millisecondsSinceEpoch;
      final notifier = container.read(notebooksProvider.notifier);
      final nb = await notifier.create('Timed', 0xFF2E7D32);
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(nb.createdAt, greaterThanOrEqualTo(before));
      expect(nb.createdAt, lessThanOrEqualTo(after));
      expect(nb.updatedAt, greaterThanOrEqualTo(before));
    });

    test('edit() updates the notebook name', () async {
      final notifier = container.read(notebooksProvider.notifier);
      final nb = await notifier.create('Original', 0xFF1565C0);

      await notifier.edit(nb.copyWith(name: 'Renamed'));

      final list = await container.read(notebooksProvider.future);
      expect(list.first.name, 'Renamed');
    });

    test('edit() bumps updatedAt', () async {
      final notifier = container.read(notebooksProvider.notifier);
      final nb = await notifier.create('Old', 0xFF1565C0);
      final originalUpdatedAt = nb.updatedAt;

      // Ensure at least 1ms passes
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await notifier.edit(nb.copyWith(name: 'New'));

      final list = await container.read(notebooksProvider.future);
      expect(list.first.updatedAt, greaterThan(originalUpdatedAt));
    });

    test('delete() soft-deletes: notebook disappears from list', () async {
      final notifier = container.read(notebooksProvider.notifier);
      final nb = await notifier.create('ToDelete', 0xFF1565C0);

      await notifier.delete(nb.id);

      final list = await container.read(notebooksProvider.future);
      expect(list, isEmpty);
    });

    test('delete() does not physically remove the record', () async {
      final notifier = container.read(notebooksProvider.notifier);
      final nb = await notifier.create('Soft', 0xFF1565C0);
      await notifier.delete(nb.id);

      // The raw store still has the record, just flagged isDeleted
      final raw = await dao.getById(nb.id);
      expect(raw, isNotNull);
      expect(raw!.isDeleted, isTrue);
    });

    test('multiple creates give unique ids', () async {
      final notifier = container.read(notebooksProvider.notifier);
      final a = await notifier.create('A', 0xFF1565C0);
      final b = await notifier.create('B', 0xFF2E7D32);
      expect(a.id, isNot(b.id));
    });
  });
}
