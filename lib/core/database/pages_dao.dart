import '../models/page.dart';
import 'database_helper.dart';

class PagesDao {
  final _db = DatabaseHelper.instance;

  static const _table = 'pages';

  Future<List<NotePage>> getAll() async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'is_deleted = 0',
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<List<NotePage>> getBySection(String sectionId) async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'section_id = ? AND is_deleted = 0',
      whereArgs: [sectionId],
      orderBy: 'sort_order ASC, updated_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<NotePage?> getById(String id) async {
    final db = await _db.database;
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<void> insert(NotePage page) async {
    final db = await _db.database;
    await db.insert(_table, _toRow(page));
  }

  Future<void> update(NotePage page) async {
    final db = await _db.database;
    await db.update(
      _table,
      _toRow(page),
      where: 'id = ?',
      whereArgs: [page.id],
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

  Future<List<NotePage>> search(String query) async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'is_deleted = 0 AND (title LIKE ? OR content LIKE ?)',
      whereArgs: ['%$query%', '%$query%'],
      orderBy: 'updated_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  NotePage _fromRow(Map<String, dynamic> row) => NotePage(
        id: row['id'] as String,
        sectionId: row['section_id'] as String,
        parentPageId: row['parent_page_id'] as String?,
        title: row['title'] as String? ?? 'Untitled',
        content: row['content'] as String? ?? '[]',
        createdAt: row['created_at'] as int,
        updatedAt: row['updated_at'] as int,
        sortOrder: row['sort_order'] as int? ?? 0,
        isDeleted: (row['is_deleted'] as int? ?? 0) == 1,
        backgroundStyle:   row['background_style']   as String? ?? 'none',
        backgroundColor:   row['background_color']   as int?    ?? 0,
        backgroundSpacing: row['background_spacing'] as double? ?? 28.0,
        pageSize:          row['page_size']          as String? ?? 'infinite',
        pageOrientation:   row['page_orientation']   as String? ?? 'portrait',
        inkStrokes:        row['ink_strokes']         as String? ?? '',
      );

  Map<String, dynamic> _toRow(NotePage p) => {
        'id': p.id,
        'section_id': p.sectionId,
        'parent_page_id': p.parentPageId,
        'title': p.title,
        'content': p.content,
        'created_at': p.createdAt,
        'updated_at': p.updatedAt,
        'sort_order': p.sortOrder,
        'is_deleted': p.isDeleted ? 1 : 0,
        'background_style':   p.backgroundStyle,
        'background_color':   p.backgroundColor,
        'background_spacing': p.backgroundSpacing,
        'page_size':          p.pageSize,
        'page_orientation':   p.pageOrientation,
        'ink_strokes':        p.inkStrokes,
      };
}
