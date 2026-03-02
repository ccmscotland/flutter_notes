import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/page_assets_dao.dart';
import '../../core/database/sync_records_dao.dart';
import '../notebooks/notebooks_provider.dart';
import '../sections/sections_provider.dart';
import '../pages/pages_provider.dart';
import 'google_drive_service.dart';
import 'onedrive_service.dart';
import 'sync_engine.dart';

final googleDriveServiceProvider =
    Provider<GoogleDriveService>((ref) => GoogleDriveService());

final oneDriveServiceProvider =
    Provider<OneDriveService>((ref) => OneDriveService());

final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(
    notebooksDao: ref.read(notebooksDaoProvider),
    sectionsDao: ref.read(sectionsDaoProvider),
    pagesDao: ref.read(pagesDaoProvider),
    assetsDao: PageAssetsDao(),
    syncRecordsDao: SyncRecordsDao(),
    googleDrive: ref.read(googleDriveServiceProvider),
    oneDrive: ref.read(oneDriveServiceProvider),
  );
});

// Re-export DAO providers so sync_provider doesn't need direct instantiation
// (these are already defined in their feature providers)

// Tracks last sync time + status per provider
class SyncState {
  final bool isSyncing;
  final DateTime? lastSyncTime;
  final String? lastError;
  final bool googleSignedIn;
  final bool oneDriveSignedIn;

  const SyncState({
    this.isSyncing = false,
    this.lastSyncTime,
    this.lastError,
    this.googleSignedIn = false,
    this.oneDriveSignedIn = false,
  });

  SyncState copyWith({
    bool? isSyncing,
    DateTime? lastSyncTime,
    String? lastError,
    bool? googleSignedIn,
    bool? oneDriveSignedIn,
  }) =>
      SyncState(
        isSyncing: isSyncing ?? this.isSyncing,
        lastSyncTime: lastSyncTime ?? this.lastSyncTime,
        lastError: lastError,
        googleSignedIn: googleSignedIn ?? this.googleSignedIn,
        oneDriveSignedIn: oneDriveSignedIn ?? this.oneDriveSignedIn,
      );
}

final syncStateProvider =
    NotifierProvider<SyncStateNotifier, SyncState>(
  SyncStateNotifier.new,
);

class SyncStateNotifier extends Notifier<SyncState> {
  @override
  SyncState build() {
    _checkSignInStatus();
    return const SyncState();
  }

  void _checkSignInStatus() {
    final googleDrive = ref.read(googleDriveServiceProvider);
    final oneDrive = ref.read(oneDriveServiceProvider);
    state = state.copyWith(
      googleSignedIn: googleDrive.isSignedIn,
      oneDriveSignedIn: oneDrive.isSignedIn,
    );
  }

  Future<void> signInGoogle() async {
    final service = ref.read(googleDriveServiceProvider);
    final ok = await service.signIn();
    state = state.copyWith(googleSignedIn: ok);
  }

  Future<void> signOutGoogle() async {
    final service = ref.read(googleDriveServiceProvider);
    await service.signOut();
    state = state.copyWith(googleSignedIn: false);
  }

  Future<void> signInOneDrive() async {
    final service = ref.read(oneDriveServiceProvider);
    final ok = await service.signIn();
    state = state.copyWith(oneDriveSignedIn: ok);
  }

  Future<void> signOutOneDrive() async {
    final service = ref.read(oneDriveServiceProvider);
    await service.signOut();
    state = state.copyWith(oneDriveSignedIn: false);
  }

  Future<void> syncGoogle() async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, lastError: null);
    try {
      final engine = ref.read(syncEngineProvider);
      final result = await engine.syncAll(SyncProvider.googleDrive);
      state = state.copyWith(
        isSyncing: false,
        lastSyncTime: result.timestamp,
        lastError: result.errors.isEmpty ? null : result.errors.join('; '),
      );
    } catch (e) {
      state = state.copyWith(isSyncing: false, lastError: e.toString());
    }
  }

  Future<void> syncOneDrive() async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, lastError: null);
    try {
      final engine = ref.read(syncEngineProvider);
      final result = await engine.syncAll(SyncProvider.oneDrive);
      state = state.copyWith(
        isSyncing: false,
        lastSyncTime: result.timestamp,
        lastError: result.errors.isEmpty ? null : result.errors.join('; '),
      );
    } catch (e) {
      state = state.copyWith(isSyncing: false, lastError: e.toString());
    }
  }
}
