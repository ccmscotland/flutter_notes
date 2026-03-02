import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static const _dbName = 'flutter_notes.db';
  static const _dbVersion = 6;

  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  Database? _db;

  Future<Database> get database async {
    _db ??= await _openDb();
    return _db!;
  }

  Future<Database> _openDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE notebooks (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        color INTEGER NOT NULL,
        icon TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        sort_order INTEGER DEFAULT 0,
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE sections (
        id TEXT PRIMARY KEY,
        notebook_id TEXT NOT NULL,
        name TEXT NOT NULL,
        color INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        sort_order INTEGER DEFAULT 0,
        is_deleted INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE pages (
        id TEXT PRIMARY KEY,
        section_id TEXT NOT NULL,
        parent_page_id TEXT,
        title TEXT NOT NULL DEFAULT 'Untitled',
        content TEXT NOT NULL DEFAULT '[]',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        sort_order INTEGER DEFAULT 0,
        is_deleted INTEGER DEFAULT 0,
        background_style TEXT DEFAULT 'none',
        background_color INTEGER DEFAULT 0,
        background_spacing REAL DEFAULT 28.0,
        page_size TEXT DEFAULT 'infinite',
        page_orientation TEXT DEFAULT 'portrait',
        ink_strokes TEXT DEFAULT ''
      )
    ''');

    await db.execute('''
      CREATE TABLE sync_records (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        last_synced_at INTEGER,
        sync_status TEXT DEFAULT 'pending',
        remote_path TEXT,
        provider TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE page_assets (
        id TEXT PRIMARY KEY,
        page_id TEXT NOT NULL,
        file_name TEXT NOT NULL,
        local_path TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    // Indexes for common queries
    await db.execute('CREATE INDEX idx_sections_notebook ON sections(notebook_id)');
    await db.execute('CREATE INDEX idx_pages_section ON pages(section_id)');
    await db.execute('CREATE INDEX idx_sync_entity ON sync_records(entity_id, provider)');
    await db.execute('CREATE INDEX idx_assets_page ON page_assets(page_id)');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
          "ALTER TABLE pages ADD COLUMN background_style TEXT DEFAULT 'none'");
      await db.execute(
          'ALTER TABLE pages ADD COLUMN background_color INTEGER DEFAULT 0');
    }
    if (oldVersion < 3) {
      await db.execute(
          'ALTER TABLE pages ADD COLUMN background_spacing REAL DEFAULT 28.0');
    }
    if (oldVersion < 4) {
      await db.execute(
          "ALTER TABLE pages ADD COLUMN page_size TEXT DEFAULT 'infinite'");
      await db.execute(
          "ALTER TABLE pages ADD COLUMN page_orientation TEXT DEFAULT 'portrait'");
    }
    if (oldVersion < 5) {
      // Repair: add missing columns for DBs created fresh at v4 with
      // incomplete _onCreate (background/page columns were omitted).
      final cols = await db.rawQuery('PRAGMA table_info(pages)');
      final names = cols.map((c) => c['name'] as String).toSet();
      if (!names.contains('background_style'))
        await db.execute(
            "ALTER TABLE pages ADD COLUMN background_style TEXT DEFAULT 'none'");
      if (!names.contains('background_color'))
        await db.execute(
            'ALTER TABLE pages ADD COLUMN background_color INTEGER DEFAULT 0');
      if (!names.contains('background_spacing'))
        await db.execute(
            'ALTER TABLE pages ADD COLUMN background_spacing REAL DEFAULT 28.0');
      if (!names.contains('page_size'))
        await db.execute(
            "ALTER TABLE pages ADD COLUMN page_size TEXT DEFAULT 'infinite'");
      if (!names.contains('page_orientation'))
        await db.execute(
            "ALTER TABLE pages ADD COLUMN page_orientation TEXT DEFAULT 'portrait'");
    }
    if (oldVersion < 6) {
      await db.execute(
          "ALTER TABLE pages ADD COLUMN ink_strokes TEXT DEFAULT ''");
    }
  }
}
