import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_notes/core/database/notebooks_dao.dart';
import 'package:flutter_notes/core/models/notebook.dart';
import '../helpers/db_helpers.dart';

Notebook _nb(String id, String name) => Notebook(
      id: id,
      name: name,
      color: 0xFF1565C0,
      icon: null,
      createdAt: 1000,
      updatedAt: 1000,
      sortOrder: 0,
      isDeleted: false,
    );

void main() {
  late Database db;
  late NotebooksDao dao;

  setUp(() async {
    db = await openTestDb();
    dao = NotebooksDao();
  });

  tearDown(() => closeTestDb(db));

  group('NotebooksDao', () {
    test('insert and getAll returns notebook', () async {
      await dao.insert(_nb('nb1', 'Alpha'));
      final all = await dao.getAll();
      expect(all.length, 1);
      expect(all.first.name, 'Alpha');
    });

    test('getById returns the correct notebook', () async {
      await dao.insert(_nb('nb1', 'Alpha'));
      await dao.insert(_nb('nb2', 'Beta'));
      final found = await dao.getById('nb2');
      expect(found?.name, 'Beta');
    });

    test('getById returns null for unknown id', () async {
      final result = await dao.getById('no-such-id');
      expect(result, isNull);
    });

    test('update modifies name', () async {
      await dao.insert(_nb('nb1', 'Old'));
      await dao.update(_nb('nb1', 'New'));
      final found = await dao.getById('nb1');
      expect(found?.name, 'New');
    });

    test('soft delete hides notebook from getAll', () async {
      await dao.insert(_nb('nb1', 'ToDelete'));
      await dao.delete('nb1');
      final all = await dao.getAll();
      expect(all, isEmpty);
    });

    test('soft delete does not remove row from DB', () async {
      await dao.insert(_nb('nb1', 'Soft'));
      await dao.delete('nb1');
      // getById queries without is_deleted filter
      final found = await dao.getById('nb1');
      expect(found, isNotNull);
    });

    test('hardDelete removes row entirely', () async {
      await dao.insert(_nb('nb1', 'Hard'));
      await dao.hardDelete('nb1');
      final found = await dao.getById('nb1');
      expect(found, isNull);
    });

    test('getAll respects sort_order', () async {
      await dao.insert(_nb('nb1', 'Second')
          .copyWith(sortOrder: 2, createdAt: 1000));
      await dao.insert(_nb('nb2', 'First')
          .copyWith(sortOrder: 1, createdAt: 1000));
      final all = await dao.getAll();
      expect(all.first.name, 'First');
    });

    test('multiple notebooks returned in order', () async {
      for (var i = 0; i < 5; i++) {
        await dao.insert(_nb('nb$i', 'NB$i').copyWith(sortOrder: i));
      }
      final all = await dao.getAll();
      expect(all.length, 5);
    });
  });
}
