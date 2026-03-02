import '../models/notebook.dart';
import 'database_helper.dart';

class NotebooksDao {
  final _db = DatabaseHelper.instance;

  static const _table = 'notebooks';

  Future<List<Notebook>> getAll() async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'is_deleted = 0',
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<Notebook?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<void> insert(Notebook nb) async {
    final db = await _db.database;
    await db.insert(_table, _toRow(nb));
  }

  Future<void> update(Notebook nb) async {
    final db = await _db.database;
    await db.update(_table, _toRow(nb), where: 'id = ?', whereArgs: [nb.id]);
  }

  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.update(
      _table,
      {'is_deleted': 1, 'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> hardDelete(String id) async {
    final db = await _db.database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  Notebook _fromRow(Map<String, dynamic> row) => Notebook(
        id: row['id'] as String,
        name: row['name'] as String,
        color: row['color'] as int,
        icon: row['icon'] as String?,
        createdAt: row['created_at'] as int,
        updatedAt: row['updated_at'] as int,
        sortOrder: row['sort_order'] as int? ?? 0,
        isDeleted: (row['is_deleted'] as int? ?? 0) == 1,
      );

  Map<String, dynamic> _toRow(Notebook nb) => {
        'id': nb.id,
        'name': nb.name,
        'color': nb.color,
        'icon': nb.icon,
        'created_at': nb.createdAt,
        'updated_at': nb.updatedAt,
        'sort_order': nb.sortOrder,
        'is_deleted': nb.isDeleted ? 1 : 0,
      };
}
