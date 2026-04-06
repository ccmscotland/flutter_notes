import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'license_service.dart';

export 'license_service.dart' show LicenseTier, Feature, LicenseState, LicenseException;

final licenseServiceProvider =
    Provider<LicenseService>((ref) => LicenseService());

final licenseProvider =
    AsyncNotifierProvider<LicenseNotifier, LicenseState>(
  LicenseNotifier.new,
);

class LicenseNotifier extends AsyncNotifier<LicenseState> {
  LicenseService get _svc => ref.read(licenseServiceProvider);

  @override
  Future<LicenseState> build() => _svc.load();

  Future<void> activate(String key) async {
    final state = await _svc.activate(key);
    this.state = AsyncData(state);
  }

  Future<void> deactivate() async {
    await _svc.deactivate();
    this.state = const AsyncData(LicenseState());
  }

  bool isUnlocked(Feature feature) =>
      state.valueOrNull?.isUnlocked(feature) ?? false;
}

/// Convenience provider — true if the license is Pro.
final isProProvider = Provider<bool>((ref) {
  return ref.watch(licenseProvider).valueOrNull?.isPro ?? false;
});
