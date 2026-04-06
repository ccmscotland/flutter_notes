import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_notes/core/database/pages_dao.dart';
import 'package:flutter_notes/core/models/page.dart';
import '../helpers/db_helpers.dart';

NotePage _page(String id, String sectionId, String title, {String content = '[]'}) =>
    NotePage(
      id: id,
      sectionId: sectionId,
      parentPageId: null,
      title: title,
      content: content,
      createdAt: 1000,
      updatedAt: 1000,
      sortOrder: 0,
      isDeleted: false,
      backgroundStyle: 'none',
      backgroundColor: 0,
      backgroundSpacing: 28.0,
      pageSize: 'infinite',
      pageOrientation: 'portrait',
      inkStrokes: '',
    );

void main() {
  late Database db;
  late PagesDao dao;

  setUp(() async {
    db = await openTestDb();
    dao = PagesDao();
  });

  tearDown(() => closeTestDb(db));

  group('PagesDao — basic CRUD', () {
    test('insert and getBySection returns page', () async {
      await dao.insert(_page('p1', 'sec1', 'My Page'));
      final pages = await dao.getBySection('sec1');
      expect(pages.length, 1);
      expect(pages.first.title, 'My Page');
    });

    test('getBySection filters by sectionId', () async {
      await dao.insert(_page('p1', 'sec1', 'In Sec1'));
      await dao.insert(_page('p2', 'sec2', 'In Sec2'));
      final pages = await dao.getBySection('sec1');
      expect(pages.length, 1);
      expect(pages.first.title, 'In Sec1');
    });

    test('getById returns the page', () async {
      await dao.insert(_page('p1', 'sec1', 'Alpha'));
      final found = await dao.getById('p1');
      expect(found?.title, 'Alpha');
    });

    test('getById returns null for unknown id', () async {
      expect(await dao.getById('nope'), isNull);
    });

    test('update modifies title', () async {
      await dao.insert(_page('p1', 'sec1', 'Old Title'));
      await dao.update(_page('p1', 'sec1', 'New Title'));
      final found = await dao.getById('p1');
      expect(found?.title, 'New Title');
    });

    test('update preserves content field', () async {
      const content = '[{"insert":"hello"}]';
      await dao.insert(_page('p1', 'sec1', 'Title', content: content));
      await dao.update(_page('p1', 'sec1', 'Title Updated', content: content));
      final found = await dao.getById('p1');
      expect(found?.content, content);
    });

    test('delete hides page from getBySection', () async {
      await dao.insert(_page('p1', 'sec1', 'Gone'));
      await dao.delete('p1');
      final pages = await dao.getBySection('sec1');
      expect(pages, isEmpty);
    });

    test('delete does not hard-delete (getById still returns row)', () async {
      await dao.insert(_page('p1', 'sec1', 'Soft'));
      await dao.delete('p1');
      final found = await dao.getById('p1');
      expect(found, isNotNull);
    });

    test('getAll returns all non-deleted pages', () async {
      await dao.insert(_page('p1', 'sec1', 'One'));
      await dao.insert(_page('p2', 'sec1', 'Two'));
      await dao.insert(_page('p3', 'sec1', 'Three'));
      await dao.delete('p2');
      final all = await dao.getAll();
      expect(all.length, 2);
    });
  });

  group('PagesDao — search', () {
    test('search matches title', () async {
      await dao.insert(_page('p1', 'sec1', 'Flutter Notes App'));
      await dao.insert(_page('p2', 'sec1', 'Other Page'));
      final results = await dao.search('Flutter');
      expect(results.length, 1);
      expect(results.first.title, 'Flutter Notes App');
    });

    test('search matches content', () async {
      await dao.insert(_page('p1', 'sec1', 'Title', content: '[{"insert":"searchable text\\n"}]'));
      final results = await dao.search('searchable');
      expect(results.length, 1);
    });

    test('search is case-insensitive (LIKE)', () async {
      await dao.insert(_page('p1', 'sec1', 'CamelCaseTitle'));
      final results = await dao.search('camelcase');
      expect(results, isNotEmpty);
    });

    test('search excludes soft-deleted pages', () async {
      await dao.insert(_page('p1', 'sec1', 'Deleted Page'));
      await dao.delete('p1');
      final results = await dao.search('Deleted');
      expect(results, isEmpty);
    });

    test('search with no match returns empty list', () async {
      await dao.insert(_page('p1', 'sec1', 'Something'));
      final results = await dao.search('xyzzy_no_match');
      expect(results, isEmpty);
    });
  });
}
