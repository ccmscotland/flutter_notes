import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/page.dart';
import '../models/page_group.dart';
import 'database_helper.dart';

class PageGroupsDao {
  final _db = DatabaseHelper.instance;

  static const _groups   = 'page_groups';
  static const _members  = 'page_group_members';

  // ── Groups ──────────────────────────────────────────────────────────────────

  Future<List<PageGroup>> getAll() async {
    final db   = await _db.database;
    final rows = await db.query(_groups, orderBy: 'created_at ASC');
    return rows.map(_groupFromRow).toList();
  }

  Future<PageGroup?> getById(String id) async {
    final db   = await _db.database;
    final rows = await db.query(_groups, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _groupFromRow(rows.first);
  }

  Future<PageGroup> create(String name) async {
    final db  = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final id  = const Uuid().v4();
    await db.insert(_groups, {
      'id': id,
      'name': name,
      'created_at': now,
    });
    return PageGroup(id: id, name: name, createdAt: now);
  }

  Future<void> rename(String id, String name) async {
    final db = await _db.database;
    await db.update(_groups, {'name': name},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(String id) async {
    final db = await _db.database;
    await db.delete(_groups, where: 'id = ?', whereArgs: [id]);
    await db.delete(_members, where: 'group_id = ?', whereArgs: [id]);
  }

  // ── Membership ───────────────────────────────────────────────────────────────

  Future<void> addPage(String groupId, String pageId) async {
    final db = await _db.database;
    await db.insert(
      _members,
      {'group_id': groupId, 'page_id': pageId},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> removePage(String groupId, String pageId) async {
    final db = await _db.database;
    await db.delete(_members,
        where: 'group_id = ? AND page_id = ?',
        whereArgs: [groupId, pageId]);
  }

  Future<List<String>> getPageIds(String groupId) async {
    final db   = await _db.database;
    final rows = await db.query(_members,
        columns:   ['page_id'],
        where:     'group_id = ?',
        whereArgs: [groupId]);
    return rows.map((r) => r['page_id'] as String).toList();
  }

  Future<List<String>> getGroupIdsForPage(String pageId) async {
    final db   = await _db.database;
    final rows = await db.query(_members,
        columns:   ['group_id'],
        where:     'page_id = ?',
        whereArgs: [pageId]);
    return rows.map((r) => r['group_id'] as String).toList();
  }

  // ── Pages in group (resolved) ────────────────────────────────────────────────

  /// Returns the actual [NotePage] objects for all pages in [groupId].
  /// Pages that have been deleted are silently omitted.
  Future<List<NotePage>> resolvePages(String groupId) async {
    final db    = await _db.database;
    final ids   = await getPageIds(groupId);
    if (ids.isEmpty) return [];
    final placeholders = ids.map((_) => '?').join(', ');
    final rows = await db.rawQuery(
      'SELECT * FROM pages WHERE id IN ($placeholders) AND is_deleted = 0',
      ids,
    );
    return rows.map(_pageFromRow).toList();
  }

  // ── Row mappers ──────────────────────────────────────────────────────────────

  PageGroup _groupFromRow(Map<String, dynamic> r) => PageGroup(
        id:        r['id'] as String,
        name:      r['name'] as String,
        createdAt: r['created_at'] as int,
      );

  NotePage _pageFromRow(Map<String, dynamic> row) => NotePage(
        id:               row['id'] as String,
        sectionId:        row['section_id'] as String,
        parentPageId:     row['parent_page_id'] as String?,
        title:            row['title'] as String? ?? 'Untitled',
        content:          row['content'] as String? ?? '[]',
        createdAt:        row['created_at'] as int,
        updatedAt:        row['updated_at'] as int,
        sortOrder:        row['sort_order'] as int? ?? 0,
        isDeleted:        (row['is_deleted'] as int? ?? 0) == 1,
        backgroundStyle:  row['background_style']   as String? ?? 'none',
        backgroundColor:  row['background_color']   as int?    ?? 0,
        backgroundSpacing:row['background_spacing'] as double? ?? 28.0,
        pageSize:         row['page_size']          as String? ?? 'infinite',
        pageOrientation:  row['page_orientation']   as String? ?? 'portrait',
        inkStrokes:       row['ink_strokes']        as String? ?? '',
      );
}
