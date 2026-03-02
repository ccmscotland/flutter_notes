import '../models/page_asset.dart';
import 'database_helper.dart';

class PageAssetsDao {
  final _db = DatabaseHelper.instance;

  static const _table = 'page_assets';

  Future<List<PageAsset>> getByPage(String pageId) async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'page_id = ?',
      whereArgs: [pageId],
      orderBy: 'created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<PageAsset?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<void> insert(PageAsset asset) async {
    final db = await _db.database;
    await db.insert(_table, _toRow(asset));
  }

  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  PageAsset _fromRow(Map<String, dynamic> row) => PageAsset(
        id: row['id'] as String,
        pageId: row['page_id'] as String,
        fileName: row['file_name'] as String,
        localPath: row['local_path'] as String,
        mimeType: row['mime_type'] as String,
        createdAt: row['created_at'] as int,
      );

  Map<String, dynamic> _toRow(PageAsset a) => {
        'id': a.id,
        'page_id': a.pageId,
        'file_name': a.fileName,
        'local_path': a.localPath,
        'mime_type': a.mimeType,
        'created_at': a.createdAt,
      };
}
