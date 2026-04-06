/// FlutterNotes Pro — licence key generator
///
/// Usage:
///   dart run tools/keygen.dart          # generate one key
///   dart run tools/keygen.dart 5        # generate five keys
///   dart run tools/keygen.dart verify FNPRO-XXXX-XXXX-XXXX
///
/// Key format:  PREFIX-RANDOM1-RANDOM2-CHECKSUM
///   PREFIX    = FNPRO (Pro tier) or FNFREE (free promotional)
///   RANDOM1/2 = 8 hex chars each (generated with dart:math)
///   CHECKSUM  = first 8 chars of HMAC-SHA256(secret, "PREFIX-R1-R2") uppercased
///
/// The secret MUST match the one in lib/features/license/license_service.dart.

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

// Keep in sync with LicenseService._secret
const _a = 'FlutterNotes';
const _b = 'License';
const _c = 'V1Secret';
String get _secret => '$_a-$_b-$_c';

void main(List<String> args) {
  if (args.isNotEmpty && args[0] == 'verify') {
    if (args.length < 2) {
      print('Usage: dart run tools/keygen.dart verify <key>');
      return;
    }
    final key   = args[1].trim().toUpperCase();
    final valid = _validateKey(key);
    print(valid ? 'VALID — ${_tierLabel(key)}' : 'INVALID key');
    return;
  }

  final count = args.isNotEmpty ? (int.tryParse(args[0]) ?? 1) : 1;
  for (var i = 0; i < count; i++) {
    print(_generateKey('FNPRO'));
  }
}

String _generateKey(String prefix) {
  final rng      = Random.secure();
  final random1  = _randomHex(rng, 8);
  final random2  = _randomHex(rng, 8);
  final payload  = '$prefix-$random1-$random2';
  final checksum = _hmac(payload).substring(0, 8).toUpperCase();
  return '$payload-$checksum';
}

bool _validateKey(String key) {
  final parts = key.split('-');
  if (parts.length != 4) return false;
  final prefix = parts[0];
  if (prefix != 'FNPRO' && prefix != 'FNFREE') return false;
  final payload  = '${parts[0]}-${parts[1]}-${parts[2]}';
  final expected = _hmac(payload).substring(0, 8).toUpperCase();
  return parts[3] == expected;
}

String _tierLabel(String key) {
  return switch (key.split('-').first) {
    'FNPRO'  => 'Pro tier',
    'FNFREE' => 'Free tier',
    _        => 'Unknown tier',
  };
}

String _hmac(String payload) {
  final secretBytes  = utf8.encode(_secret);
  final payloadBytes = utf8.encode(payload);
  final hmac         = Hmac(sha256, secretBytes);
  return hmac.convert(payloadBytes).toString();
}

String _randomHex(Random rng, int length) {
  final buf = StringBuffer();
  for (var i = 0; i < length; i++) {
    buf.write(rng.nextInt(16).toRadixString(16).toUpperCase());
  }
  return buf.toString();
}
