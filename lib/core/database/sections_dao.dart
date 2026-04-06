import 'package:uuid/uuid.dart';
import '../models/section.dart';
import 'database_helper.dart';

class SectionsDao {
  final _db = DatabaseHelper.instance;

  static const _table = 'sections';

  Future<List<Section>> getAll() async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'is_deleted = 0',
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Returns only user-created sections (excludes the hidden default section).
  Future<List<Section>> getByNotebook(String notebookId) async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'notebook_id = ? AND is_deleted = 0 AND is_default = 0',
      whereArgs: [notebookId],
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Returns true if the notebook has at least one user-created section.
  Future<bool> hasUserSections(String notebookId) async {
    final db = await _db.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM $_table '
      'WHERE notebook_id = ? AND is_deleted = 0 AND is_default = 0',
      [notebookId],
    );
    return (result.first['cnt'] as int) > 0;
  }

  /// Gets the hidden default section for [notebookId], creating it if absent.
  Future<Section> getOrCreateDefault(String notebookId) async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'notebook_id = ? AND is_default = 1 AND is_deleted = 0',
      whereArgs: [notebookId],
      limit: 1,
    );
    if (rows.isNotEmpty) return _fromRow(rows.first);

    // Create the default section (name is empty — never shown to user).
    final now = DateTime.now().millisecondsSinceEpoch;
    final s = {
      'id': const Uuid().v4(),
      'notebook_id': notebookId,
      'name': '',
      'color': 0xFF607D8B, // blue-grey — never shown
      'created_at': now,
      'updated_at': now,
      'sort_order': -1,
      'is_deleted': 0,
      'is_default': 1,
    };
    await db.insert(_table, s);
    return _fromRow(s);
  }

  Future<Section?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<void> insert(Section section) async {
    final db = await _db.database;
    await db.insert(_table, _toRow(section));
  }

  Future<void> update(Section section) async {
    final db = await _db.database;
    await db.update(
      _table,
      _toRow(section),
      where: 'id = ?',
      whereArgs: [section.id],
    );
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

  Section _fromRow(Map<String, dynamic> row) => Section(
        id: row['id'] as String,
        notebookId: row['notebook_id'] as String,
        name: row['name'] as String,
        color: row['color'] as int,
        createdAt: row['created_at'] as int,
        updatedAt: row['updated_at'] as int,
        sortOrder: row['sort_order'] as int? ?? 0,
        isDeleted: (row['is_deleted'] as int? ?? 0) == 1,
      );

  Map<String, dynamic> _toRow(Section s) => {
        'id': s.id,
        'notebook_id': s.notebookId,
        'name': s.name,
        'color': s.color,
        'created_at': s.createdAt,
        'updated_at': s.updatedAt,
        'sort_order': s.sortOrder,
        'is_deleted': s.isDeleted ? 1 : 0,
        'is_default': 0, // DAO-created sections are always user sections
      };
}
