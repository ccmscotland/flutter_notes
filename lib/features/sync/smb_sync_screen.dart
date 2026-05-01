import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'smb_config.dart';
import 'smb_sync_service.dart';

class SmbSyncScreen extends StatefulWidget {
  const SmbSyncScreen({super.key});

  @override
  State<SmbSyncScreen> createState() => _SmbSyncScreenState();
}

class _SmbSyncScreenState extends State<SmbSyncScreen> {
  // ── Connection form ─────────────────────────────────────────────────────────
  late final TextEditingController _host;
  late final TextEditingController _share;
  late final TextEditingController _base;
  late final TextEditingController _user;
  late final TextEditingController _pass;
  late final TextEditingController _domain;
  late final TextEditingController _backupPath;
  String _format = 'markdown';
  bool _passVisible = false;

  // ── State ───────────────────────────────────────────────────────────────────
  bool _loadingTree    = false;
  bool _syncing        = false;
  bool _bidirSyncing   = false;
  bool _testingConn    = false;
  bool _backingUp      = false;
  bool _loadingBackups = false;
  String? _statusMsg;
  bool _statusOk = true;
  SmbSyncTree? _tree;
  List<String> _remoteBackups = [];

  // ── Selection ───────────────────────────────────────────────────────────────
  // null entry means "all children selected"
  final Set<String> _selNotebooks = {};
  final Set<String> _selSections  = {};
  final Set<String> _selPages     = {};
  bool _selectAll = true;

  @override
  void initState() {
    super.initState();
    _host       = TextEditingController();
    _share      = TextEditingController();
    _base       = TextEditingController(text: 'flutter_notes');
    _user       = TextEditingController();
    _pass       = TextEditingController();
    _domain     = TextEditingController();
    _backupPath = TextEditingController(text: '_backups');
    _loadConfig();
  }

  @override
  void dispose() {
    for (final c in [_host, _share, _base, _user, _pass, _domain, _backupPath]) c.dispose();
    super.dispose();
  }

  // ── Config persistence ───────────────────────────────────────────────────────

  Future<void> _loadConfig() async {
    final cfg = await SmbConfig.load();
    if (cfg != null && mounted) {
      setState(() {
        _host.text       = cfg.host;
        _share.text      = cfg.share;
        _base.text       = cfg.basePath;
        _user.text       = cfg.username;
        _pass.text       = cfg.password;
        _domain.text     = cfg.domain;
        _format          = cfg.format;
        _backupPath.text = cfg.backupPath;
      });
    }
  }

  SmbConfig _currentConfig() => SmbConfig(
        host:       _host.text.trim(),
        share:      _share.text.trim(),
        basePath:   _base.text.trim(),
        username:   _user.text.trim(),
        password:   _pass.text,
        domain:     _domain.text.trim(),
        format:     _format,
        backupPath: _backupPath.text.trim(),
      );

  Future<void> _saveConfig() => _currentConfig().save();

  // ── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _testConnection() async {
    await _saveConfig();
    setState(() { _testingConn = true; _statusMsg = null; });
    final ok = await SmbSyncService(_currentConfig()).testConnection();
    if (!mounted) return;
    setState(() {
      _testingConn = false;
      _statusOk    = ok;
      _statusMsg   = ok ? 'Connection successful' : 'Connection failed — check settings';
    });
    if (ok) _loadTree();
  }

  Future<void> _loadTree() async {
    setState(() { _loadingTree = true; });
    final tree = await SmbSyncService(_currentConfig()).loadTree();
    if (!mounted) return;
    setState(() {
      _tree        = tree;
      _loadingTree = false;
      // Default: select all
      _selectAll = true;
      _selNotebooks.clear();
      _selSections.clear();
      _selPages.clear();
    });
  }

  Future<void> _sync() async {
    await _saveConfig();
    setState(() { _syncing = true; _statusMsg = null; });

    final result = await SmbSyncService(_currentConfig()).syncSelected(
      notebookIds: _selectAll ? {} : _selNotebooks,
      sectionIds:  _selectAll ? {} : _selSections,
      pageIds:     _selectAll ? {} : _selPages,
    );

    if (!mounted) return;
    setState(() {
      _syncing   = false;
      _statusOk  = result.success;
      _statusMsg = result.success
          ? 'Exported ${result.uploaded} page${result.uploaded == 1 ? '' : 's'} successfully'
          : 'Export failed: ${result.error}';
    });
  }

  /// Two-way merge with the share so multiple devices stay in sync.
  Future<void> _bidirSync() async {
    await _saveConfig();
    setState(() { _bidirSyncing = true; _statusMsg = null; });

    final result =
        await SmbSyncService(_currentConfig()).syncBidirectional();

    if (!mounted) return;
    setState(() {
      _bidirSyncing = false;
      _statusOk     = result.success;
      _statusMsg    = result.success
          ? 'Sync complete — ${result.stats.summary()}'
          : 'Sync failed: ${result.error}';
    });
  }

  // ── Backup / restore ────────────────────────────────────────────────────────

  Future<void> _backupToSmb() async {
    await _saveConfig();
    setState(() { _backingUp = true; _statusMsg = null; });
    final result = await SmbSyncService(_currentConfig()).backupToSmb();
    if (!mounted) return;
    setState(() {
      _backingUp = false;
      _statusOk  = result.success;
      _statusMsg = result.success
          ? 'Backup saved to share successfully'
          : 'Backup failed: ${result.error}';
    });
    if (result.success) _loadRemoteBackups();
  }

  Future<void> _loadRemoteBackups() async {
    setState(() => _loadingBackups = true);
    final names = await SmbSyncService(_currentConfig()).listSmbBackups();
    if (!mounted) return;
    setState(() { _remoteBackups = names; _loadingBackups = false; });
  }

  Future<void> _restoreFromSmb(String fileName) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restore Backup'),
        content: Text('Restore "$fileName"?\n\nExisting pages with the same ID '
            'will be skipped. Settings will be overwritten.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() { _syncing = true; _statusMsg = null; });
    final result =
        await SmbSyncService(_currentConfig()).restoreBackupByName(fileName);
    if (!mounted) return;
    setState(() {
      _syncing   = false;
      _statusOk  = result.success;
      _statusMsg = result.success
          ? 'Restored ${result.uploaded} page${result.uploaded == 1 ? '' : 's'}'
          : 'Restore failed: ${result.error}';
    });
  }

  // ── Selection helpers ────────────────────────────────────────────────────────

  void _toggleSelectAll(bool? v) {
    setState(() {
      _selectAll = v ?? true;
      if (_selectAll) {
        _selNotebooks.clear();
        _selSections.clear();
        _selPages.clear();
      }
    });
  }

  bool _notebookSelected(String id) =>
      _selectAll || _selNotebooks.contains(id);

  bool _sectionSelected(String id) =>
      _selectAll || _selSections.contains(id);

  bool _pageSelected(String id) =>
      _selectAll || _selPages.contains(id);

  void _toggleNotebook(String id, bool? v) {
    setState(() {
      _selectAll = false;
      if (v == true) {
        _selNotebooks.add(id);
        // Select all its sections/pages automatically
        final nb = _tree!.notebooks.firstWhere((n) => n.notebook.id == id);
        for (final s in nb.sections) {
          _selSections.add(s.section.id);
          for (final p in s.pages) _selPages.add(p.id);
        }
      } else {
        _selNotebooks.remove(id);
        final nb = _tree!.notebooks.firstWhere((n) => n.notebook.id == id);
        for (final s in nb.sections) {
          _selSections.remove(s.section.id);
          for (final p in s.pages) _selPages.remove(p.id);
        }
      }
    });
  }

  void _toggleSection(String nbId, String secId, bool? v) {
    setState(() {
      _selectAll = false;
      if (v == true) {
        _selSections.add(secId);
        _selNotebooks.add(nbId);
        final nb  = _tree!.notebooks.firstWhere((n) => n.notebook.id == nbId);
        final sec = nb.sections.firstWhere((s) => s.section.id == secId);
        for (final p in sec.pages) _selPages.add(p.id);
      } else {
        _selSections.remove(secId);
        final nb  = _tree!.notebooks.firstWhere((n) => n.notebook.id == nbId);
        final sec = nb.sections.firstWhere((s) => s.section.id == secId);
        for (final p in sec.pages) _selPages.remove(p.id);
        // Deselect notebook if no sections remain selected
        if (!nb.sections.any((s) => _selSections.contains(s.section.id))) {
          _selNotebooks.remove(nbId);
        }
      }
    });
  }

  void _togglePage(String nbId, String secId, String pgId, bool? v) {
    setState(() {
      _selectAll = false;
      if (v == true) {
        _selPages.add(pgId);
        _selSections.add(secId);
        _selNotebooks.add(nbId);
      } else {
        _selPages.remove(pgId);
        final nb  = _tree!.notebooks.firstWhere((n) => n.notebook.id == nbId);
        final sec = nb.sections.firstWhere((s) => s.section.id == secId);
        if (!sec.pages.any((p) => _selPages.contains(p.id))) {
          _selSections.remove(secId);
        }
        if (!nb.sections.any((s) => _selSections.contains(s.section.id))) {
          _selNotebooks.remove(nbId);
        }
      }
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SMB Sync'),
        actions: [
          if (_tree != null)
            FilledButton.icon(
              onPressed: _syncing ? null : _sync,
              icon: _syncing
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file, size: 18),
              label: Text(_syncing ? 'Exporting…' : 'Export Selected'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Connection card ────────────────────────────────────────────────
          _SectionCard(
            title: 'Connection',
            icon: Icons.lan_outlined,
            child: Column(
              children: [
                _field(_host,   'Host / IP address',     hint: '192.168.1.100'),
                _field(_share,  'Share name',            hint: 'Documents'),
                _field(_base,   'Base folder on share',  hint: 'flutter_notes'),
                _field(_user,   'Username'),
                _field(_pass,   'Password', obscure: true),
                _field(_domain, 'Domain (optional)'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testingConn ? null : _testConnection,
                      icon: _testingConn
                          ? const SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.network_check, size: 16),
                      label: const Text('Test Connection'),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── Multi-device sync card ────────────────────────────────────────
          _SectionCard(
            title: 'Multi-device Sync',
            icon: Icons.sync_alt,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Two-way merge with the share so every device using this '
                  'sync location stays in sync. Last edit wins per page.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: _bidirSyncing ? null : _bidirSync,
                  icon: _bidirSyncing
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync, size: 18),
                  label: Text(_bidirSyncing ? 'Syncing…' : 'Sync Now'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── Format card ───────────────────────────────────────────────────
          _SectionCard(
            title: 'Export Format',
            icon: Icons.description_outlined,
            child: Column(
              children: [
                RadioListTile<String>(
                  value: 'markdown',
                  groupValue: _format,
                  title: const Text('Markdown (.md)'),
                  subtitle: const Text('Readable in any text editor'),
                  onChanged: (v) => setState(() => _format = v!),
                  dense: true,
                ),
                RadioListTile<String>(
                  value: 'html',
                  groupValue: _format,
                  title: const Text('HTML (.html)'),
                  subtitle: const Text('Readable in any browser'),
                  onChanged: (v) => setState(() => _format = v!),
                  dense: true,
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── Status banner ─────────────────────────────────────────────────
          if (_statusMsg != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _statusOk
                    ? Colors.green.shade50
                    : cs.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    _statusOk ? Icons.check_circle_outline : Icons.error_outline,
                    color: _statusOk ? Colors.green.shade700 : cs.onErrorContainer,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusMsg!,
                      style: TextStyle(
                        color: _statusOk
                            ? Colors.green.shade800
                            : cs.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Backup card ───────────────────────────────────────────────────
          _SectionCard(
            title: 'Backup to Share',
            icon: Icons.backup_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saves a ZIP (notes + settings) to the folder below '
                  'on the share.',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 10),
                _field(
                  _backupPath,
                  'Backup folder (relative to base folder)',
                  hint: '_backups',
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: (_backingUp || _tree == null)
                          ? null
                          : _backupToSmb,
                      icon: _backingUp
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cloud_upload_outlined, size: 18),
                      label: Text(_backingUp ? 'Backing up…' : 'Backup Now'),
                    ),
                    OutlinedButton.icon(
                      onPressed: (_loadingBackups || _tree == null)
                          ? null
                          : _loadRemoteBackups,
                      icon: _loadingBackups
                          ? const SizedBox(
                              width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh, size: 18),
                      label: const Text('List Backups'),
                    ),
                  ],
                ),
                if (_remoteBackups.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Available backups:',
                      style: Theme.of(context).textTheme.labelSmall),
                  const SizedBox(height: 4),
                  ..._remoteBackups.map((name) {
                    // Parse stamp from flutter_notes_backup_YYYYMMDD_HHmmss.zip
                    final stamp = name
                        .replaceFirst('flutter_notes_backup_', '')
                        .replaceFirst('.zip', '');
                    String label = stamp;
                    try {
                      final dt = DateFormat('yyyyMMdd_HHmmss').parse(stamp);
                      label = DateFormat('MMM d yyyy, HH:mm').format(dt);
                    } catch (_) {}
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.archive_outlined, size: 18),
                      title: Text(label, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(name,
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant)),
                      trailing: TextButton(
                        onPressed: () => _restoreFromSmb(name),
                        child: const Text('Restore'),
                      ),
                    );
                  }),
                ],
                if (_tree == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Test connection first to enable backup.',
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ── Selection card ────────────────────────────────────────────────
          _SectionCard(
            title: 'What to Export',
            icon: Icons.checklist_outlined,
            child: _loadingTree
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : _tree == null
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          'Test a connection first to select items.',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      )
                    : _buildSelectionTree(cs),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label, {
    String? hint,
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: ctrl,
        obscureText: obscure && !_passVisible,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          suffixIcon: obscure
              ? IconButton(
                  icon: Icon(
                    _passVisible ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _passVisible = !_passVisible),
                )
              : null,
        ),
      ),
    );
  }

  Widget _buildSelectionTree(ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          value: _selectAll,
          onChanged: _toggleSelectAll,
          title: const Text('All notebooks',
              style: TextStyle(fontWeight: FontWeight.w600)),
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const Divider(height: 1),
        if (!_selectAll)
          ..._tree!.notebooks.map((nb) => _notebookTile(nb, cs)),
      ],
    );
  }

  Widget _notebookTile(SmbNotebookNode nb, ColorScheme cs) {
    final nbId     = nb.notebook.id;
    final selected = _notebookSelected(nbId);

    return ExpansionTile(
      leading: Checkbox(
        value: selected,
        onChanged: (v) => _toggleNotebook(nbId, v),
      ),
      title: Row(
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: Color(nb.notebook.color),
            child: const Icon(Icons.menu_book, size: 10, color: Colors.white),
          ),
          const SizedBox(width: 8),
          Text(nb.notebook.name,
              style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
      childrenPadding: const EdgeInsets.only(left: 32),
      children: nb.sections
          .map((sec) => _sectionTile(nb.notebook.id, sec, cs))
          .toList(),
    );
  }

  Widget _sectionTile(String nbId, SmbSectionNode sec, ColorScheme cs) {
    final secId    = sec.section.id;
    final selected = _sectionSelected(secId);

    return ExpansionTile(
      leading: Checkbox(
        value: selected,
        onChanged: (v) => _toggleSection(nbId, secId, v),
      ),
      title: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Color(sec.section.color),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(sec.section.name,
              style: const TextStyle(fontWeight: FontWeight.w400)),
        ],
      ),
      childrenPadding: const EdgeInsets.only(left: 32),
      children: sec.pages
          .map((pg) => CheckboxListTile(
                value: _pageSelected(pg.id),
                onChanged: (v) => _togglePage(nbId, secId, pg.id, v),
                title: Text(pg.title, style: const TextStyle(fontSize: 13)),
                secondary:
                    const Icon(Icons.article_outlined, size: 16),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
              ))
          .toList(),
    );
  }
}

// ── Helper card widget ─────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 8),
                Text(title,
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: child,
          ),
        ],
      ),
    );
  }
}
