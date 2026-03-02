# FlutterNotes — OneNote-like Android App

A full-featured note-taking app with notebook → section → page hierarchy, rich-text editing, drawing canvas, image insertion, and bi-directional cloud sync to Google Drive and OneDrive.

## Architecture

```
lib/
  core/
    models/          # Freezed data classes (Notebook, Section, NotePage, SyncRecord, PageAsset)
    database/        # SQLite DAOs via sqflite
    services/
  features/
    notebooks/       # Notebook CRUD + grid screen
    sections/        # Section list screen
    pages/           # Page list screen
    editor/          # Quill rich-text editor + drawing canvas
    sync/            # Google Drive + OneDrive sync engine + settings
    search/          # Full-text search
  shared/
    theme/           # Material 3 light/dark theme
    widgets/         # Color picker, confirm dialog
  main.dart
  router.dart        # go_router navigation
```

## Prerequisites

1. **Flutter SDK** ≥ 3.3.0
   ```bash
   flutter --version
   ```

2. **Code generation** (run once after `flutter pub get`):
   ```bash
   flutter pub run build_runner build --delete-conflicting-outputs
   ```

## Google Drive Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a project → enable **Google Drive API**
3. Configure OAuth consent screen (Android)
4. Create Android OAuth client with your SHA-1 fingerprint:
   ```bash
   keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
   ```
5. Download `google-services.json` → place at `android/app/google-services.json`
   (use the template at `android/app/google-services.json.template`)

## OneDrive (Microsoft) Setup

1. Go to [Azure Portal](https://portal.azure.com/) → App registrations → New
2. Platform: Android, Package name: `com.example.flutter_notes`
3. Add Redirect URI: `msauth://com.example.flutter_notes/{BASE64_SHA1}`
4. Grant `Files.ReadWrite.AppFolder` permission
5. Copy your **client_id** into:
   - `android/app/src/main/res/raw/msal_config.json`
   - `lib/features/sync/onedrive_service.dart` (replace `YOUR_CLIENT_ID`)

## Running

```bash
# Install dependencies
flutter pub get

# Generate Freezed/JSON code
flutter pub run build_runner build --delete-conflicting-outputs

# Run on connected device / emulator
flutter run
```

## Features

- **Notebooks** → grid view with custom colors; create/rename/delete
- **Sections** → list view per notebook; create/rename/delete
- **Pages** → list per section; swipe-to-delete; auto-navigate to editor on create
- **Editor** → flutter_quill rich text: bold/italic/underline, H1/H2, bullet/numbered/checklist, color, indent, undo/redo
- **Drawing canvas** → pen/highlighter/eraser, color picker, stroke width, undo/redo; serialized as custom Quill embed
- **Images** → camera or gallery; stored in app documents directory; embedded in page
- **Cloud Sync** → Google Drive and OneDrive; timestamp-based conflict resolution; upload assets
- **Search** → full-text search across all page titles and content with result highlighting

## Database Schema

SQLite via sqflite. Tables: `notebooks`, `sections`, `pages`, `sync_records`, `page_assets`.
All entities use soft-delete (`is_deleted` flag) for sync safety.

## State Management

Riverpod `AsyncNotifierProvider` and `FamilyAsyncNotifierProvider` for all list data.
`StateNotifierProvider` for sync state (sign-in status, progress, errors).
