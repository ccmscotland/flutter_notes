import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'smb_sync_screen.dart';
import 'sync_provider.dart';
import '../export/export_service.dart';
import '../license/license_gate.dart';
import '../license/license_provider.dart';

class SyncSettingsScreen extends ConsumerWidget {
  const SyncSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncStateProvider);
    final notifier = ref.read(syncStateProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Cloud Sync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- Google Drive ---
          LicenseGate(
            feature: Feature.cloudSync,
            child: _ProviderCard(
              icon: Icons.storage,
              title: 'Google Drive',
              color: const Color(0xFF4285F4),
              isSignedIn: sync.googleSignedIn,
              isSyncing: sync.isSyncing,
              lastSyncTime: sync.lastSyncTime,
              lastError: sync.lastError,
              onSignIn: notifier.signInGoogle,
              onSignOut: notifier.signOutGoogle,
              onSync: sync.googleSignedIn ? notifier.syncGoogle : null,
            ),
          ),
          const SizedBox(height: 16),
          // --- OneDrive ---
          LicenseGate(
            feature: Feature.cloudSync,
            child: _ProviderCard(
              icon: Icons.cloud,
              title: 'OneDrive',
              color: const Color(0xFF0078D4),
              isSignedIn: sync.oneDriveSignedIn,
              isSyncing: sync.isSyncing,
              lastSyncTime: sync.lastSyncTime,
              lastError: sync.lastError,
              onSignIn: notifier.signInOneDrive,
              onSignOut: notifier.signOutOneDrive,
              onSync: sync.oneDriveSignedIn ? notifier.syncOneDrive : null,
            ),
          ),
          const SizedBox(height: 16),
          const LicenseGate(
            feature: Feature.smbSync,
            child: _SmbSyncCard(),
          ),
          const SizedBox(height: 16),
          const LicenseGate(
            feature: Feature.localBackup,
            child: _LocalBackupCard(),
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 16),
            const _DevSettingsCard(),
          ],
          const SizedBox(height: 24),
          if (sync.lastError != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: Theme.of(context).colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        sync.lastError!,
                        style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SmbSyncCard extends StatelessWidget {
  const _SmbSyncCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.storage_outlined, size: 28),
                const SizedBox(width: 12),
                Text('SMB / Network Share',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Sync notes to a Windows share, NAS, or Samba server.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const Dialog.fullscreen(child: SmbSyncScreen()),
              ),
              icon: const Icon(Icons.lan_outlined),
              label: const Text('Configure SMB Sync'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalBackupCard extends StatefulWidget {
  const _LocalBackupCard();

  @override
  State<_LocalBackupCard> createState() => _LocalBackupCardState();
}

class _LocalBackupCardState extends State<_LocalBackupCard> {
  bool _backing   = false;
  bool _restoring = false;

  Future<void> _backup() async {
    setState(() => _backing = true);
    try {
      await ExportService().backupAll(context);
    } finally {
      if (mounted) setState(() => _backing = false);
    }
  }

  Future<void> _restore() async {
    setState(() => _restoring = true);
    try {
      final result = await ExportService().restoreBackup(context);
      if (!mounted) return;
      final msg = result.error != null
          ? 'Restore failed: ${result.error}'
          : 'Restored ${result.restored} page${result.restored == 1 ? '' : 's'}'
              '${result.skipped > 0 ? ' (${result.skipped} skipped)' : ''}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _backing || _restoring;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.backup_outlined, size: 28),
                const SizedBox(width: 12),
                Text('Local Backup',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Export all notes to a ZIP file (Markdown + manifest). '
              'The backup can be fully restored from this screen.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: busy ? null : _backup,
                  icon: _backing
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined),
                  label: Text(_backing ? 'Backing up…' : 'Backup Now'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : _restore,
                  icon: _restoring
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.restore_outlined),
                  label: Text(_restoring ? 'Restoring…' : 'Restore Backup'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color color;
  final bool isSignedIn;
  final bool isSyncing;
  final DateTime? lastSyncTime;
  final String? lastError;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  final VoidCallback? onSync;

  const _ProviderCard({
    required this.icon,
    required this.title,
    required this.color,
    required this.isSignedIn,
    required this.isSyncing,
    required this.lastSyncTime,
    required this.lastError,
    required this.onSignIn,
    required this.onSignOut,
    required this.onSync,
  });

  @override
  Widget build(BuildContext context) {
    final lastSync = lastSyncTime != null
        ? DateFormat('MMM d, HH:mm').format(lastSyncTime!)
        : 'Never';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(width: 12),
                Text(title,
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSignedIn
                        ? Colors.green.shade100
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isSignedIn ? 'Connected' : 'Disconnected',
                    style: TextStyle(
                      color: isSignedIn
                          ? Colors.green.shade700
                          : Colors.grey.shade600,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Last sync: $lastSync',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Row(
              children: [
                if (!isSignedIn)
                  FilledButton.icon(
                    onPressed: onSignIn,
                    icon: const Icon(Icons.login),
                    label: const Text('Sign In'),
                    style: FilledButton.styleFrom(backgroundColor: color),
                  )
                else ...[
                  OutlinedButton.icon(
                    onPressed: onSignOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign Out'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: isSyncing ? null : onSync,
                    icon: isSyncing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync),
                    label: Text(isSyncing ? 'Syncing...' : 'Sync Now'),
                    style: FilledButton.styleFrom(backgroundColor: color),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Developer settings card (debug builds only) ───────────────────────────────

class _DevSettingsCard extends ConsumerWidget {
  const _DevSettingsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);
    final cs    = Theme.of(context).colorScheme;

    return Card(
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bug_report_outlined,
                    size: 20, color: cs.onTertiaryContainer),
                const SizedBox(width: 8),
                Text(
                  'Developer',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: cs.onTertiaryContainer,
                      ),
                ),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.tertiary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'DEBUG',
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: cs.onTertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Pro mode',
                style: TextStyle(color: cs.onTertiaryContainer),
              ),
              subtitle: Text(
                isPro ? 'All Pro features unlocked' : 'Running as Free tier',
                style: TextStyle(
                    color: cs.onTertiaryContainer.withOpacity(0.7),
                    fontSize: 12),
              ),
              secondary: Icon(
                isPro ? Icons.verified_outlined : Icons.lock_outline,
                color: isPro ? Colors.green.shade600 : cs.onTertiaryContainer,
              ),
              value: isPro,
              onChanged: (enable) async {
                final notifier = ref.read(licenseProvider.notifier);
                if (enable) {
                  final key = LicenseService().generateProKey();
                  await notifier.activate(key);
                } else {
                  await notifier.deactivate();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
