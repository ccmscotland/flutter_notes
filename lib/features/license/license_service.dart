import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Tiers ─────────────────────────────────────────────────────────────────────

enum LicenseTier {
  free,
  pro;

  bool operator >=(LicenseTier other) => index >= other.index;
}

// ── Features and their minimum required tier ──────────────────────────────────

enum Feature {
  // ── Always free ────────────────────────────────────────────────────────────
  coreEditor(LicenseTier.free, 'Core Editor'),
  search(LicenseTier.free, 'Search'),
  math(LicenseTier.free, 'Math Calculations'),

  // ── Pro ────────────────────────────────────────────────────────────────────
  exportFiles(LicenseTier.pro, 'Export to PDF / HTML / Markdown'),
  importFiles(LicenseTier.pro, 'Import from files'),
  localBackup(LicenseTier.pro, 'Local Backup & Restore'),
  cloudSync(LicenseTier.pro, 'Google Drive & OneDrive Sync'),
  smbSync(LicenseTier.pro, 'SMB / Network Share Sync'),
  collections(LicenseTier.pro, 'Collections');

  const Feature(this.requiredTier, this.label);
  final LicenseTier requiredTier;
  final String label;
}

// ── License state ─────────────────────────────────────────────────────────────

class LicenseState {
  final LicenseTier tier;
  final String? key;
  final DateTime? activatedAt;

  const LicenseState({
    this.tier = LicenseTier.free,
    this.key,
    this.activatedAt,
  });

  bool isUnlocked(Feature feature) => tier >= feature.requiredTier;

  bool get isPro => tier == LicenseTier.pro;
}

// ── Service ───────────────────────────────────────────────────────────────────

class LicenseService {
  static const _kKey         = 'license_key';
  static const _kTier        = 'license_tier';
  static const _kActivatedAt = 'license_activated_at';

  // The validation secret is split to make casual extraction slightly harder.
  // For a production app, move to server-side validation.
  static String get _secret {
    const a = 'FlutterNotes';
    const b = 'License';
    const c = 'V1Secret';
    return '$a-$b-$c';
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<LicenseState> load() async {
    final p   = await SharedPreferences.getInstance();
    final key = p.getString(_kKey);
    if (key == null) return const LicenseState();

    final tier = _parseTier(p.getString(_kTier) ?? 'free');
    final activatedAt = p.getInt(_kActivatedAt) != null
        ? DateTime.fromMillisecondsSinceEpoch(p.getInt(_kActivatedAt)!)
        : null;

    // Re-validate stored key on every load
    final valid = _validateKey(key);
    if (!valid) {
      await _clear(p);
      return const LicenseState();
    }

    return LicenseState(tier: tier, key: key, activatedAt: activatedAt);
  }

  Future<LicenseState> activate(String rawKey) async {
    final key  = rawKey.trim().toUpperCase();
    if (!_validateKey(key)) {
      throw const LicenseException('Invalid license key');
    }
    final tier = _tierFromKey(key);
    final now  = DateTime.now();

    final p = await SharedPreferences.getInstance();
    await p.setString(_kKey, key);
    await p.setString(_kTier, tier.name);
    await p.setInt(_kActivatedAt, now.millisecondsSinceEpoch);

    return LicenseState(tier: tier, key: key, activatedAt: now);
  }

  Future<void> deactivate() async {
    final p = await SharedPreferences.getInstance();
    await _clear(p);
  }

  Future<void> _clear(SharedPreferences p) async {
    await p.remove(_kKey);
    await p.remove(_kTier);
    await p.remove(_kActivatedAt);
  }

  // ── Key validation ────────────────────────────────────────────────────────
  //
  // Key format:  FNPRO-XXXXXXXX-XXXXXXXX-CHECKSUM
  //   FNPRO       = product + tier prefix
  //   XXXXXXXX    = two random 8-char hex groups
  //   CHECKSUM    = first 8 chars of HMAC-SHA256(secret, "FNPRO-XXXXXXXX-XXXXXXXX")
  //
  // Other supported prefix: FNFREE (for future free-tier promotional keys)

  bool _validateKey(String key) {
    final parts = key.split('-');
    if (parts.length != 4) return false;

    final prefix = parts[0];
    if (prefix != 'FNPRO' && prefix != 'FNFREE') return false;

    // Re-derive checksum from the first three segments
    final payload  = '${parts[0]}-${parts[1]}-${parts[2]}';
    final expected = _hmac(payload).substring(0, 8).toUpperCase();
    return parts[3] == expected;
  }

  LicenseTier _tierFromKey(String key) {
    final prefix = key.split('-').first;
    return switch (prefix) {
      'FNPRO'   => LicenseTier.pro,
      _         => LicenseTier.free,
    };
  }

  String _hmac(String payload) {
    final secretBytes  = utf8.encode(_secret);
    final payloadBytes = utf8.encode(payload);
    final hmac         = Hmac(sha256, secretBytes);
    final digest       = hmac.convert(payloadBytes);
    return digest.toString();
  }

  LicenseTier _parseTier(String name) =>
      LicenseTier.values.firstWhere((t) => t.name == name,
          orElse: () => LicenseTier.free);

  // ── Key generation (developer utility, mirrored in tools/keygen.dart) ────

  /// Generates a valid Pro key. Use [tools/keygen.dart] to create keys in bulk.
  String generateProKey() => _generateKey('FNPRO');

  String _generateKey(String prefix) {
    final random = _randomHex(8);
    final salt   = _randomHex(8);
    final payload  = '$prefix-$random-$salt';
    final checksum = _hmac(payload).substring(0, 8).toUpperCase();
    return '$payload-$checksum';
  }

  String _randomHex(int length) {
    final bytes = List<int>.generate(
      length ~/ 2,
      (_) => DateTime.now().microsecondsSinceEpoch % 256,
    );
    // Use current time + loop index for cheap pseudo-randomness without dart:math
    final buf = StringBuffer();
    for (var i = 0; i < length; i++) {
      final val = (DateTime.now().microsecondsSinceEpoch + i * 37) % 16;
      buf.write(val.toRadixString(16).toUpperCase());
    }
    return buf.toString().substring(0, length);
  }
}

class LicenseException implements Exception {
  final String message;
  const LicenseException(this.message);
  @override
  String toString() => message;
}
