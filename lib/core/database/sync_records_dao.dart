import 'package:sqflite/sqflite.dart';
import '../models/sync_record.dart';
import 'database_helper.dart';

class SyncRecordsDao {
  final _db = DatabaseHelper.instance;

  static const _table = 'sync_records';

  Future<SyncRecord?> getByEntityAndProvider(
      String entityId, String provider) async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'entity_id = ? AND provider = ?',
      whereArgs: [entityId, provider],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<List<SyncRecord>> getPendingByProvider(String provider) async {
    final db = await _db.database;
    final rows = await db.query(
      _table,
      where: 'provider = ? AND sync_status = ?',
      whereArgs: [provider, SyncStatus.pending.name],
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> upsert(SyncRecord record) async {
    final db = await _db.database;
    await db.insert(
      _table,
      _toRow(record),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> markSynced(String entityId, String provider) async {
    final db = await _db.database;
    await db.update(
      _table,
      {
        'sync_status': SyncStatus.synced.name,
        'last_synced_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'entity_id = ? AND provider = ?',
      whereArgs: [entityId, provider],
    );
  }

  SyncRecord _fromRow(Map<String, dynamic> row) => SyncRecord(
        id: row['id'] as String,
        entityType: row['entity_type'] as String,
        entityId: row['entity_id'] as String,
        lastSyncedAt: row['last_synced_at'] as int?,
        syncStatus: SyncStatus.values.byName(
            row['sync_status'] as String? ?? 'pending'),
        remotePath: row['remote_path'] as String?,
        provider: row['provider'] as String?,
      );

  Map<String, dynamic> _toRow(SyncRecord r) => {
        'id': r.id,
        'entity_type': r.entityType,
        'entity_id': r.entityId,
        'last_synced_at': r.lastSyncedAt,
        'sync_status': r.syncStatus.name,
        'remote_path': r.remotePath,
        'provider': r.provider,
      };
}
