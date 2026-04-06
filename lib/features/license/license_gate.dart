import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'activation_screen.dart';
import 'license_provider.dart';

/// Set to [false] to enforce licence gating in production.
/// While [true] every feature is treated as unlocked regardless of tier.
const bool kLicensingEnabled = false;

/// Wraps [child] and shows a "locked" placeholder when [feature] is not
/// unlocked by the current license tier.
///
/// Use [compact: true] for inline/icon-sized gates (e.g. a toolbar button).
class LicenseGate extends ConsumerWidget {
  final Feature feature;
  final Widget child;
  final bool compact;

  const LicenseGate({
    super.key,
    required this.feature,
    required this.child,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kLicensingEnabled) return child;

    final unlocked = ref.watch(licenseProvider).whenOrNull(
          data: (s) => s.isUnlocked(feature),
        ) ??
        false;

    if (unlocked) return child;
    return compact
        ? _CompactLock(feature: feature)
        : _FullLock(feature: feature);
  }
}

// ── Full-card lock placeholder ─────────────────────────────────────────────────

class _FullLock extends StatelessWidget {
  final Feature feature;
  const _FullLock({required this.feature});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline,
                size: 40, color: cs.onSurfaceVariant.withOpacity(0.6)),
            const SizedBox(height: 12),
            Text(
              feature.label,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'This feature requires a Pro licence.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant.withOpacity(0.7),
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _openActivation(context),
              icon: const Icon(Icons.vpn_key_outlined, size: 18),
              label: const Text('Activate Pro'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Compact lock (inline, e.g. replacing a button) ────────────────────────────

class _CompactLock extends StatelessWidget {
  final Feature feature;
  const _CompactLock({required this.feature});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message: '${feature.label} — Pro required',
      child: InkWell(
        onTap: () => _openActivation(context),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(Icons.lock_outline, size: 20, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }
}

void _openActivation(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (_) => const Dialog.fullscreen(child: ActivationScreen()),
  );
}

/// Convenience: wraps any [onPressed] callback to check the licence first.
/// If locked, opens the activation screen instead of running the callback.
VoidCallback? guardedCallback(
  BuildContext context,
  WidgetRef ref,
  Feature feature,
  VoidCallback? callback,
) {
  if (callback == null) return null;
  if (!kLicensingEnabled) return callback;
  final unlocked =
      ref.read(licenseProvider).valueOrNull?.isUnlocked(feature) ?? false;
  if (unlocked) return callback;
  return () => _openActivation(context);
}
