import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_notes/features/license/license_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('LicenseTier ordering', () {
    test('free < pro', () {
      expect(LicenseTier.free >= LicenseTier.pro, isFalse);
      expect(LicenseTier.pro >= LicenseTier.free, isTrue);
      expect(LicenseTier.pro >= LicenseTier.pro, isTrue);
    });
  });

  group('LicenseState.isUnlocked', () {
    test('free tier unlocks free features', () {
      const state = LicenseState(tier: LicenseTier.free);
      expect(state.isUnlocked(Feature.coreEditor), isTrue);
      expect(state.isUnlocked(Feature.search), isTrue);
      expect(state.isUnlocked(Feature.math), isTrue);
    });

    test('free tier does not unlock pro features', () {
      const state = LicenseState(tier: LicenseTier.free);
      expect(state.isUnlocked(Feature.exportFiles), isFalse);
      expect(state.isUnlocked(Feature.cloudSync), isFalse);
      expect(state.isUnlocked(Feature.collections), isFalse);
    });

    test('pro tier unlocks everything', () {
      const state = LicenseState(tier: LicenseTier.pro);
      for (final feature in Feature.values) {
        expect(state.isUnlocked(feature), isTrue,
            reason: '${feature.name} should be unlocked for pro');
      }
    });

    test('isPro is true only for pro tier', () {
      expect(const LicenseState(tier: LicenseTier.pro).isPro, isTrue);
      expect(const LicenseState(tier: LicenseTier.free).isPro, isFalse);
    });
  });

  group('LicenseService key generation and validation', () {
    final service = LicenseService();

    test('generateProKey produces a valid key', () {
      final key = service.generateProKey();
      expect(() => service.activate(key), returnsNormally);
    });

    test('activate with valid pro key returns pro tier', () async {
      final key = service.generateProKey();
      final state = await service.activate(key);
      expect(state.tier, LicenseTier.pro);
      expect(state.key, key);
      expect(state.activatedAt, isNotNull);
    });

    test('activate with invalid key throws LicenseException', () async {
      expect(
        () => service.activate('INVALID-KEY-0000-0000'),
        throwsA(isA<LicenseException>()),
      );
    });

    test('activate with tampered checksum throws LicenseException', () async {
      final key = service.generateProKey();
      final parts = key.split('-');
      // Corrupt the checksum segment
      final tampered = '${parts[0]}-${parts[1]}-${parts[2]}-XXXXXXXX';
      expect(
        () => service.activate(tampered),
        throwsA(isA<LicenseException>()),
      );
    });

    test('activate with wrong prefix throws LicenseException', () async {
      // Build a key with the right structure but wrong prefix
      expect(
        () => service.activate('BADPR-ABCD1234-EFGH5678-CHECKSUM'),
        throwsA(isA<LicenseException>()),
      );
    });
  });

  group('LicenseService persistence (load / deactivate)', () {
    final service = LicenseService();

    test('load returns free state when no key stored', () async {
      final state = await service.load();
      expect(state.tier, LicenseTier.free);
      expect(state.key, isNull);
    });

    test('activate → load round-trip preserves tier and key', () async {
      final key = service.generateProKey();
      await service.activate(key);
      final loaded = await service.load();
      expect(loaded.tier, LicenseTier.pro);
      expect(loaded.key, key);
    });

    test('deactivate clears stored license', () async {
      final key = service.generateProKey();
      await service.activate(key);
      await service.deactivate();
      final loaded = await service.load();
      expect(loaded.tier, LicenseTier.free);
      expect(loaded.key, isNull);
    });
  });
}
