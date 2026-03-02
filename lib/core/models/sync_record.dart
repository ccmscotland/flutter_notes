import 'package:freezed_annotation/freezed_annotation.dart';

part 'sync_record.freezed.dart';
part 'sync_record.g.dart';

@freezed
class SyncRecord with _$SyncRecord {
  const factory SyncRecord({
    required String id,
    required String entityType, // 'notebook'|'section'|'page'|'asset'
    required String entityId,
    int? lastSyncedAt,
    @Default('pending') String syncStatus, // 'pending'|'synced'|'conflict'
    String? remotePath,
    String? provider, // 'google_drive'|'onedrive'
  }) = _SyncRecord;

  factory SyncRecord.fromJson(Map<String, dynamic> json) =>
      _$SyncRecordFromJson(json);
}
