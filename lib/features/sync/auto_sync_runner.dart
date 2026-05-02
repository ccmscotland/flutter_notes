import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notebooks/notebooks_provider.dart';
import '../sections/sections_provider.dart';
import '../pages/pages_provider.dart';
import 'auto_sync_status.dart';
import 'smb_config.dart';
import 'smb_sync_service.dart';

/// Runs SMB bidirectional sync in the background on app launch and on
/// foreground resume, when the user has enabled auto-sync in SMB settings.
///
/// After a successful sync, invalidates the notebook/section/page providers
/// so the UI picks up downloaded changes without an app restart.
class AutoSyncRunner extends ConsumerStatefulWidget {
  final Widget child;
  const AutoSyncRunner({super.key, required this.child});

  /// Invalidate the data providers that mirror the SMB-synced tables.
  /// Exposed so the manual sync screen can reuse the same refresh logic.
  static void invalidateData(WidgetRef ref) {
    ref.invalidate(notebooksProvider);
    ref.invalidate(sectionsProvider);
    ref.invalidate(pagesProvider);
    ref.invalidate(pageProvider);
    ref.invalidate(defaultSectionIdProvider);
  }

  @override
  ConsumerState<AutoSyncRunner> createState() => _AutoSyncRunnerState();
}

class _AutoSyncRunnerState extends ConsumerState<AutoSyncRunner>
    with WidgetsBindingObserver {
  // Guard against overlapping runs (e.g. resume firing while launch sync
  // is still in flight, or the user manually syncing at the same time).
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Defer to first frame so providers are ready before we invalidate them.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeSync('launch'));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _maybeSync('resume');
  }

  Future<void> _maybeSync(String trigger) async {
    if (_running) return;
    final cfg = await SmbConfig.load();
    if (cfg == null || !cfg.autoSync) return;

    _running = true;
    if (mounted) ref.read(autoSyncRunningProvider.notifier).state = true;
    try {
      final result = await SmbSyncService(cfg).syncBidirectional();
      if (!mounted) return;
      ref.read(autoSyncStatusProvider.notifier).state = AutoSyncStatus(
        at:         DateTime.now(),
        success:    result.success,
        error:      result.error,
        uploaded:   result.stats.totalUploaded,
        downloaded: result.stats.totalDownloaded,
        trigger:    trigger,
      );
      if (result.success) {
        if (result.stats.totalDownloaded > 0) {
          AutoSyncRunner.invalidateData(ref);
        }
      } else if (kDebugMode) {
        debugPrint('SMB auto-sync failed: ${result.error}');
      }
    } finally {
      _running = false;
      if (mounted) ref.read(autoSyncRunningProvider.notifier).state = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
