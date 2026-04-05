import 'package:shared_preferences/shared_preferences.dart';

/// Persisted SMB connection settings.
class SmbConfig {
  final String host;
  final String share;
  final String basePath;
  final String username;
  final String password;
  final String domain;
  final String format;      // 'markdown' | 'html'
  final String backupPath;  // relative to basePath, default '_backups'

  const SmbConfig({
    required this.host,
    required this.share,
    this.basePath = 'flutter_notes',
    required this.username,
    required this.password,
    this.domain = '',
    this.format = 'markdown',
    this.backupPath = '_backups',
  });

  static const _kHost       = 'smb_host';
  static const _kShare      = 'smb_share';
  static const _kBase       = 'smb_base';
  static const _kUser       = 'smb_user';
  static const _kPass       = 'smb_pass';
  static const _kDomain     = 'smb_domain';
  static const _kFormat     = 'smb_format';
  static const _kBackupPath = 'smb_backup_path';

  static Future<SmbConfig?> load() async {
    final p = await SharedPreferences.getInstance();
    final host = p.getString(_kHost) ?? '';
    if (host.isEmpty) return null;
    return SmbConfig(
      host:       host,
      share:      p.getString(_kShare)      ?? '',
      basePath:   p.getString(_kBase)       ?? 'flutter_notes',
      username:   p.getString(_kUser)       ?? '',
      password:   p.getString(_kPass)       ?? '',
      domain:     p.getString(_kDomain)     ?? '',
      format:     p.getString(_kFormat)     ?? 'markdown',
      backupPath: p.getString(_kBackupPath) ?? '_backups',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kHost,       host);
    await p.setString(_kShare,      share);
    await p.setString(_kBase,       basePath);
    await p.setString(_kUser,       username);
    await p.setString(_kPass,       password);
    await p.setString(_kDomain,     domain);
    await p.setString(_kFormat,     format);
    await p.setString(_kBackupPath, backupPath);
  }

  SmbConfig copyWith({
    String? host, String? share, String? basePath,
    String? username, String? password, String? domain,
    String? format, String? backupPath,
  }) => SmbConfig(
    host:       host       ?? this.host,
    share:      share      ?? this.share,
    basePath:   basePath   ?? this.basePath,
    username:   username   ?? this.username,
    password:   password   ?? this.password,
    domain:     domain     ?? this.domain,
    format:     format     ?? this.format,
    backupPath: backupPath ?? this.backupPath,
  );
}
