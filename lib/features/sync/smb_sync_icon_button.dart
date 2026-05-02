import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'auto_sync_runner.dart';
import 'auto_sync_status.dart';
import 'smb_config.dart';
import 'smb_sync_service.dart';
import 'sync_settings_screen.dart';

/// Sync action for the main app chrome (narrow AppBar + wide app rail).
///
/// - Tap: runs a bidirectional SMB sync if configured, otherwise opens the
///   sync settings dialog so the user can set it up.
/// - Long-press / right-click: opens the sync settings dialog.
/// - Visual state reflects the auto-sync runner's last result so manual
///   and automatic syncs share the same status.
class SmbSyncIconButton extends ConsumerStatefulWidget {
  const SmbSyncIconButton({super.key});

  @override
  ConsumerState<SmbSyncIconButton> createState() => _SmbSyncIconButtonState();
}

class _SmbSyncIconButtonState extends ConsumerState<SmbSyncIconButton> {
  bool _manualSyncing = false;

  Future<void> _runSync() async {
    final cfg = await SmbConfig.load();
    if (!mounted) return;
    if (cfg == null) {
      _openSettings();
      return;
    }
    // Avoid stacking on top of an in-flight auto-sync.
    if (ref.read(autoSyncRunningProvider) || _manualSyncing) return;

    setState(() => _manualSyncing = true);
    ref.read(autoSyncRunningProvider.notifier).state = true;
    SmbBidirSyncResult? result;
    try {
      result = await SmbSyncService(cfg).syncBidirectional();
    } finally {
      if (mounted) setState(() => _manualSyncing = false);
      ref.read(autoSyncRunningProvider.notifier).state = false;
    }
    if (!mounted || result == null) return;

    ref.read(autoSyncStatusProvider.notifier).state = AutoSyncStatus(
      at:         DateTime.now(),
      success:    result.success,
      error:      result.error,
      uploaded:   result.stats.totalUploaded,
      downloaded: result.stats.totalDownloaded,
      trigger:    'manual',
    );

    if (result.success) {
      if (result.stats.totalDownloaded > 0) {
        AutoSyncRunner.invalidateData(ref);
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Sync complete — ↑${result.stats.totalUploaded} ↓${result.stats.totalDownloaded}',
        ),
        duration: const Duration(seconds: 2),
      ));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sync failed: ${result.error ?? 'unknown error'}'),
        backgroundColor: Theme.of(context).colorScheme.errorContainer,
        duration: const Duration(seconds: 4),
      ));
    }
  }

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (_) => const Dialog.fullscreen(child: SyncSettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final running = ref.watch(autoSyncRunningProvider) || _manualSyncing;
    final status  = ref.watch(autoSyncStatusProvider);
    final cs      = Theme.of(context).colorScheme;

    final Widget iconChild;
    if (running) {
      iconChild = const SizedBox(
        width: 18, height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (status != null && !status.success) {
      iconChild = Icon(Icons.sync_problem, size: 24, color: cs.error);
    } else {
      iconChild = const Icon(Icons.sync, size: 24);
    }

    final String tooltip;
    if (running) {
      tooltip = 'Syncing…';
    } else if (status == null) {
      tooltip = 'Sync now (long-press for settings)';
    } else {
      final t = DateFormat('HH:mm').format(status.at);
      if (status.success) {
        tooltip = 'Last sync $t — ↑${status.uploaded} ↓${status.downloaded}\n'
                  'Tap to sync · long-press for settings';
      } else {
        tooltip = 'Last sync $t failed: ${status.error ?? 'unknown error'}\n'
                  'Tap to retry · long-press for settings';
      }
    }

    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 48,
        height: 48,
        child: InkResponse(
          radius: 22,
          onTap: running ? null : _runSync,
          onLongPress: _openSettings,
          onSecondaryTap: _openSettings, // right-click on desktop
          child: Center(child: iconChild),
        ),
      ),
    );
  }
}
