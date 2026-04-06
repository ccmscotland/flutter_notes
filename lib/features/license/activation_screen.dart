import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'license_provider.dart';

class ActivationScreen extends ConsumerStatefulWidget {
  const ActivationScreen({super.key});

  @override
  ConsumerState<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends ConsumerState<ActivationScreen> {
  final _ctrl   = TextEditingController();
  bool _loading = false;
  String? _errorMsg;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    final key = _ctrl.text.trim();
    if (key.isEmpty) return;

    setState(() { _loading = true; _errorMsg = null; });
    try {
      await ref.read(licenseProvider.notifier).activate(key);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pro licence activated!')),
        );
        Navigator.of(context).pop();
      }
    } on LicenseException catch (e) {
      setState(() => _errorMsg = e.message);
    } catch (e) {
      setState(() => _errorMsg = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _deactivate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Deactivate licence'),
        content: const Text(
            'This will remove the Pro licence from this device. '
            'You can re-activate at any time with the same key.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(licenseProvider.notifier).deactivate();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs           = Theme.of(context).colorScheme;
    final licenseAsync = ref.watch(licenseProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Licence')),
      body: licenseAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (license) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // ── Status card ────────────────────────────────────────────────
            _StatusCard(license: license),
            const SizedBox(height: 24),

            if (license.isPro) ...[
              // ── Deactivate ────────────────────────────────────────────────
              OutlinedButton.icon(
                onPressed: _deactivate,
                icon: const Icon(Icons.lock_open_outlined),
                label: const Text('Deactivate licence'),
              ),
            ] else ...[
              // ── Activation form ───────────────────────────────────────────
              Text('Enter licence key',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _ctrl,
                autocorrect: false,
                enableSuggestions: false,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: 'FNPRO-XXXXXXXX-XXXXXXXX-XXXXXXXX',
                  border: const OutlineInputBorder(),
                  errorText: _errorMsg,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.content_paste_outlined),
                    tooltip: 'Paste from clipboard',
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        _ctrl.text = data!.text!.trim().toUpperCase();
                      }
                    },
                  ),
                ),
                onSubmitted: (_) => _activate(),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loading ? null : _activate,
                icon: _loading
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.vpn_key_outlined),
                label: Text(_loading ? 'Activating…' : 'Activate'),
              ),
            ],

            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),

            // ── Feature comparison ─────────────────────────────────────────
            Text('What\'s included',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _FeatureTable(currentTier: license.tier),
          ],
        ),
      ),
    );
  }
}

// ── Status card ───────────────────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final LicenseState license;
  const _StatusCard({required this.license});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final (color, icon, title, subtitle) = license.isPro
        ? (
            Colors.green.shade50,
            Icon(Icons.verified_outlined,
                color: Colors.green.shade700, size: 32),
            'Pro — Activated',
            license.activatedAt != null
                ? 'Activated ${DateFormat('MMM d, yyyy').format(license.activatedAt!)}'
                : 'All Pro features unlocked',
          )
        : (
            cs.surfaceContainerLow,
            Icon(Icons.lock_outline,
                color: cs.onSurfaceVariant, size: 32),
            'Free',
            'Upgrade to Pro to unlock all features',
          );

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: license.isPro
                ? Colors.green.shade200
                : cs.outlineVariant),
      ),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: license.isPro
                              ? Colors.green.shade800
                              : cs.onSurface,
                        )),
                Text(subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: license.isPro
                              ? Colors.green.shade700
                              : cs.onSurfaceVariant,
                        )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Feature comparison table ──────────────────────────────────────────────────

class _FeatureTable extends StatelessWidget {
  final LicenseTier currentTier;
  const _FeatureTable({required this.currentTier});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: Feature.values.map((f) {
        final unlocked = currentTier >= f.requiredTier;
        final isPro    = f.requiredTier == LicenseTier.pro;
        final cs       = Theme.of(context).colorScheme;
        return ListTile(
          dense: true,
          leading: Icon(
            unlocked ? Icons.check_circle_outline : Icons.lock_outline,
            size: 20,
            color: unlocked ? Colors.green.shade600 : cs.onSurfaceVariant,
          ),
          title: Text(f.label,
              style: TextStyle(
                color: unlocked ? cs.onSurface : cs.onSurfaceVariant,
              )),
          trailing: isPro
              ? Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: unlocked
                        ? Colors.green.shade100
                        : cs.primaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('PRO',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: unlocked
                            ? Colors.green.shade700
                            : cs.onPrimaryContainer,
                      )),
                )
              : null,
        );
      }).toList(),
    );
  }
}
