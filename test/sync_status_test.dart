import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_notes/core/models/sync_record.dart';

void main() {
  group('SyncStatus enum', () {
    test('byName round-trips for all values', () {
      expect(SyncStatus.values.byName('pending'), SyncStatus.pending);
      expect(SyncStatus.values.byName('synced'), SyncStatus.synced);
      expect(SyncStatus.values.byName('conflict'), SyncStatus.conflict);
    });

    test('.name serialises to the expected string', () {
      expect(SyncStatus.pending.name, 'pending');
      expect(SyncStatus.synced.name, 'synced');
      expect(SyncStatus.conflict.name, 'conflict');
    });

    test('default is SyncStatus.pending', () {
      const record = SyncRecord(
        id: 'test-id',
        entityType: 'notebook',
        entityId: 'nb-1',
      );
      expect(record.syncStatus, SyncStatus.pending);
    });

    test('SyncRecord carries the assigned status', () {
      const record = SyncRecord(
        id: 'test-id',
        entityType: 'page',
        entityId: 'p-1',
        syncStatus: SyncStatus.synced,
      );
      expect(record.syncStatus, SyncStatus.synced);
    });

    test('copyWith preserves status when not overridden', () {
      const record = SyncRecord(
        id: 'test-id',
        entityType: 'section',
        entityId: 's-1',
        syncStatus: SyncStatus.conflict,
      );
      final copy = record.copyWith(remotePath: '/some/path');
      expect(copy.syncStatus, SyncStatus.conflict);
    });

    test('copyWith can update status', () {
      const record = SyncRecord(
        id: 'test-id',
        entityType: 'asset',
        entityId: 'a-1',
        syncStatus: SyncStatus.pending,
      );
      final updated = record.copyWith(syncStatus: SyncStatus.synced);
      expect(updated.syncStatus, SyncStatus.synced);
    });
  });
}
