import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-memory result of the most recent SMB auto-sync attempt.
/// Reset every app launch (not persisted) so the UI always reflects what
/// the AutoSyncRunner actually did this session.
class AutoSyncStatus {
  final DateTime at;
  final bool     success;
  final String?  error;
  final int      uploaded;
  final int      downloaded;
  final String   trigger;   // 'launch' | 'resume'

  const AutoSyncStatus({
    required this.at,
    required this.success,
    this.error,
    this.uploaded = 0,
    this.downloaded = 0,
    required this.trigger,
  });
}

final autoSyncStatusProvider = StateProvider<AutoSyncStatus?>((_) => null);

/// True while a sync triggered by AutoSyncRunner is currently in flight.
final autoSyncRunningProvider = StateProvider<bool>((_) => false);
