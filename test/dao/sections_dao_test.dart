import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_notes/core/database/sections_dao.dart';
import 'package:flutter_notes/core/models/section.dart';
import '../helpers/db_helpers.dart';

Section _sec(String id, String notebookId, String name) => Section(
      id: id,
      notebookId: notebookId,
      name: name,
      color: 0xFF1565C0,
      createdAt: 1000,
      updatedAt: 1000,
      sortOrder: 0,
      isDeleted: false,
    );

void main() {
  late Database db;
  late SectionsDao dao;

  setUp(() async {
    db = await openTestDb();
    dao = SectionsDao();
  });

  tearDown(() => closeTestDb(db));

  group('SectionsDao — basic CRUD', () {
    test('insert and getByNotebook returns section', () async {
      await dao.insert(_sec('s1', 'nb1', 'Alpha'));
      final sections = await dao.getByNotebook('nb1');
      expect(sections.length, 1);
      expect(sections.first.name, 'Alpha');
    });

    test('getByNotebook filters by notebookId', () async {
      await dao.insert(_sec('s1', 'nb1', 'NB1-Section'));
      await dao.insert(_sec('s2', 'nb2', 'NB2-Section'));
      final sections = await dao.getByNotebook('nb1');
      expect(sections.length, 1);
      expect(sections.first.name, 'NB1-Section');
    });

    test('getById returns the section', () async {
      await dao.insert(_sec('s1', 'nb1', 'Alpha'));
      final found = await dao.getById('s1');
      expect(found?.name, 'Alpha');
    });

    test('getById returns null for unknown id', () async {
      expect(await dao.getById('none'), isNull);
    });

    test('update modifies name', () async {
      await dao.insert(_sec('s1', 'nb1', 'Old'));
      await dao.update(_sec('s1', 'nb1', 'New'));
      final found = await dao.getById('s1');
      expect(found?.name, 'New');
    });

    test('delete hides section from getByNotebook', () async {
      await dao.insert(_sec('s1', 'nb1', 'ToDelete'));
      await dao.delete('s1');
      final sections = await dao.getByNotebook('nb1');
      expect(sections, isEmpty);
    });
  });

  group('SectionsDao — default section logic', () {
    test('getByNotebook excludes default sections', () async {
      // Insert a user section via DAO
      await dao.insert(_sec('s1', 'nb1', 'UserSection'));
      // Insert a default section directly (DAO always sets is_default=0)
      await db.insert('sections', {
        'id': 'def1',
        'notebook_id': 'nb1',
        'name': '',
        'color': 0xFF607D8B,
        'created_at': 1000,
        'updated_at': 1000,
        'sort_order': -1,
        'is_deleted': 0,
        'is_default': 1,
      });

      final sections = await dao.getByNotebook('nb1');
      expect(sections.length, 1);
      expect(sections.first.id, 's1');
    });

    test('hasUserSections returns false when no user sections', () async {
      final result = await dao.hasUserSections('nb1');
      expect(result, isFalse);
    });

    test('hasUserSections returns true after inserting user section', () async {
      await dao.insert(_sec('s1', 'nb1', 'Real Section'));
      final result = await dao.hasUserSections('nb1');
      expect(result, isTrue);
    });

    test('hasUserSections ignores soft-deleted sections', () async {
      await dao.insert(_sec('s1', 'nb1', 'Section'));
      await dao.delete('s1');
      final result = await dao.hasUserSections('nb1');
      expect(result, isFalse);
    });

    test('getOrCreateDefault creates a default section on first call', () async {
      final def = await dao.getOrCreateDefault('nb1');
      expect(def.notebookId, 'nb1');
      expect(def.name, '');
      // Should NOT appear in user sections
      final userSections = await dao.getByNotebook('nb1');
      expect(userSections, isEmpty);
    });

    test('getOrCreateDefault returns the same section on repeated calls', () async {
      final def1 = await dao.getOrCreateDefault('nb1');
      final def2 = await dao.getOrCreateDefault('nb1');
      expect(def1.id, def2.id);
    });

    test('different notebooks get different default sections', () async {
      final def1 = await dao.getOrCreateDefault('nb1');
      final def2 = await dao.getOrCreateDefault('nb2');
      expect(def1.id, isNot(def2.id));
    });
  });
}
