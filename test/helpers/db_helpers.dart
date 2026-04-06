import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_notes/core/database/database_helper.dart';

/// Opens a fresh in-memory SQLite database, runs the full schema creation, and
/// injects it into [DatabaseHelper.instance] for the duration of a test.
///
/// Call this in [setUp] and call [tearDown] with [closeTestDb].
Future<Database> openTestDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) => _createSchema(db),
    ),
  );
  DatabaseHelper.instance.overrideForTesting(db);
  return db;
}

Future<void> closeTestDb(Database db) async {
  await db.close();
  // Reset so the next test gets a fresh singleton state.
  DatabaseHelper.instance.overrideForTesting(
    await databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
  );
}

Future<void> _createSchema(Database db) async {
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
      is_deleted INTEGER DEFAULT 0,
      is_default INTEGER DEFAULT 0
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
    CREATE TABLE page_assets (
      id TEXT PRIMARY KEY,
      page_id TEXT NOT NULL,
      file_name TEXT NOT NULL,
      local_path TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE page_groups (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE page_group_members (
      group_id TEXT NOT NULL,
      page_id TEXT NOT NULL,
      PRIMARY KEY (group_id, page_id)
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
}
