import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_notes/core/database/page_assets_dao.dart';
import 'package:flutter_notes/core/models/page_asset.dart';
import '../helpers/db_helpers.dart';

PageAsset _asset(String id, String pageId, String fileName) => PageAsset(
      id: id,
      pageId: pageId,
      fileName: fileName,
      localPath: '/data/assets/$fileName',
      mimeType: 'image/jpeg',
      createdAt: 1000,
    );

void main() {
  late Database db;
  late PageAssetsDao dao;

  setUp(() async {
    db = await openTestDb();
    dao = PageAssetsDao();
  });

  tearDown(() => closeTestDb(db));

  group('PageAssetsDao', () {
    test('insert and getByPage returns asset', () async {
      await dao.insert(_asset('a1', 'p1', 'photo.jpg'));
      final assets = await dao.getByPage('p1');
      expect(assets.length, 1);
      expect(assets.first.fileName, 'photo.jpg');
    });

    test('getByPage filters by pageId', () async {
      await dao.insert(_asset('a1', 'p1', 'img1.jpg'));
      await dao.insert(_asset('a2', 'p2', 'img2.jpg'));
      final assets = await dao.getByPage('p1');
      expect(assets.length, 1);
      expect(assets.first.id, 'a1');
    });

    test('getById returns the asset', () async {
      await dao.insert(_asset('a1', 'p1', 'photo.jpg'));
      final found = await dao.getById('a1');
      expect(found?.fileName, 'photo.jpg');
      expect(found?.mimeType, 'image/jpeg');
      expect(found?.localPath, '/data/assets/photo.jpg');
    });

    test('getById returns null for unknown id', () async {
      expect(await dao.getById('nope'), isNull);
    });

    test('delete removes asset from getByPage', () async {
      await dao.insert(_asset('a1', 'p1', 'photo.jpg'));
      await dao.delete('a1');
      final assets = await dao.getByPage('p1');
      expect(assets, isEmpty);
    });

    test('delete removes the row entirely (hard delete)', () async {
      await dao.insert(_asset('a1', 'p1', 'photo.jpg'));
      await dao.delete('a1');
      final found = await dao.getById('a1');
      expect(found, isNull);
    });

    test('page can have multiple assets', () async {
      await dao.insert(_asset('a1', 'p1', 'img1.jpg'));
      await dao.insert(_asset('a2', 'p1', 'img2.jpg'));
      await dao.insert(_asset('a3', 'p1', 'img3.png'));
      final assets = await dao.getByPage('p1');
      expect(assets.length, 3);
    });

    test('assets are returned in insertion order (created_at ASC)', () async {
      await dao.insert(_asset('a1', 'p1', 'first.jpg')
          .copyWith(createdAt: 1000));
      await dao.insert(_asset('a2', 'p1', 'second.jpg')
          .copyWith(createdAt: 2000));
      final assets = await dao.getByPage('p1');
      expect(assets.first.id, 'a1');
      expect(assets.last.id, 'a2');
    });
  });
}
