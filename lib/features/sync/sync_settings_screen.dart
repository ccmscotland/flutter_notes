import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'sync_provider.dart';

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
          _ProviderCard(
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
          const SizedBox(height: 16),
          // --- OneDrive ---
          _ProviderCard(
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
