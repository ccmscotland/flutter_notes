import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Serialises and restores all app settings stored in [SharedPreferences].
///
/// Only keys managed by this app are included (prefixed `smb_`).
/// Extend [_keys] if new preference keys are added elsewhere.
class SettingsBackup {
  // All known preference keys across the app.
  static const _keys = [
    'smb_host',
    'smb_share',
    'smb_base',
    'smb_user',
    'smb_pass',
    'smb_domain',
    'smb_format',
  ];

  /// Exports current settings as a JSON string.
  static Future<String> export() async {
    final p    = await SharedPreferences.getInstance();
    final data = <String, dynamic>{};
    for (final key in _keys) {
      final v = p.get(key);
      if (v != null) data[key] = v;
    }
    return jsonEncode({'version': 1, 'settings': data});
  }

  /// Imports settings from a JSON string produced by [export].
  /// Existing values are overwritten; unknown keys are ignored.
  static Future<void> import(String json) async {
    final p    = await SharedPreferences.getInstance();
    final root = jsonDecode(json) as Map<String, dynamic>;
    final data = (root['settings'] as Map<String, dynamic>?) ?? {};
    for (final entry in data.entries) {
      if (!_keys.contains(entry.key)) continue;
      final v = entry.value;
      if (v is String)  await p.setString(entry.key, v);
      if (v is int)     await p.setInt(entry.key, v);
      if (v is double)  await p.setDouble(entry.key, v);
      if (v is bool)    await p.setBool(entry.key, v);
    }
  }
}
