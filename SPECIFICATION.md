# Flutter Notes — Application Specification

**Version:** 1.4.0  
**Platforms:** Android, Windows, Web  
**Stack:** Flutter 3.27 / Dart, SQLite, Riverpod, flutter_quill

---

## 1. Overview

Flutter Notes is a hierarchical, rich-text note-taking application. Notes are organised in a three-level tree: **Notebooks → Sections → Pages**. Each page is edited in a rich-text editor that also supports ink drawing, tables, and embedded images. Notes can be exported, synced to cloud services, and backed up to local storage or a network share.

---

## 2. Data Model

### 2.1 Hierarchy

```
Notebook
 └── Section  (belongs to one Notebook)
      └── Page  (belongs to one Section)
           └── Page Asset  (image / file embedded in a Page)
```

### 2.2 Entities

| Entity | Key Fields |
|--------|-----------|
| **Notebook** | id, name, color (ARGB int), icon, created_at, updated_at, sort_order, is_deleted |
| **Section** | id, notebook_id, name, color (ARGB int), created_at, updated_at, sort_order, is_deleted |
| **Page** | id, section_id, parent_page_id, title, content (Quill Delta JSON), created_at, updated_at, sort_order, is_deleted, background_style, background_color, background_spacing, page_size, page_orientation, ink_strokes |
| **Page Asset** | id, page_id, file_name, local_path, mime_type, created_at |
| **Page Group** | id, name, created_at |
| **Page Group Member** | group_id, page_id |
| **Sync Record** | id, entity_type, entity_id, last_synced_at, sync_status, remote_path, provider |

### 2.3 Storage

- **Mobile / Desktop:** SQLite via `sqflite` (Android) or `sqflite_common_ffi` (Windows/Web)
- **Database version:** 7
- **Soft deletes:** `is_deleted = 1` flag on Notebooks, Sections, Pages
- **Page content format:** Quill Delta — a JSON array of insert operations with optional attributes

---

## 3. Navigation & Layout

### 3.1 Routes

| Path | Screen |
|------|--------|
| `/` | Notebooks list |
| `/notebook/:nid` | Sections list |
| `/notebook/:nid/section/:sid` | Pages list |
| `/notebook/:nid/section/:sid/page/:pid` | Editor |
| `/search` | Global search |

### 3.2 Responsive Shell

| Breakpoint | Layout |
|------------|--------|
| < 600 dp ("phone") | `_NarrowShell`: tab strip at top + `IndexedStack` (browse / open editor tabs) |
| ≥ 600 dp ("wide") | `_WideShell`: collapsible left rail + browse pane + editor area |

The left rail (wide mode) contains:

- Notebook entries with expand/collapse per notebook
- Footer: **Collections**, **Search**, **Sync** icon buttons

The Notebooks screen app bar (narrow mode) contains the same three icon buttons.

### 3.3 Tab System

Multiple pages can be open simultaneously as tabs. Tabs persist for the session; switching tabs is instant (IndexedStack, no re-render).

---

## 4. Notebooks

- Grid display, one card per notebook
- Color picker on create / rename (Material colour palette)
- Rename and delete via popup menu (delete is soft-delete)
- Notebook color shown as a coloured circle avatar throughout the UI

---

## 5. Sections

- List display within a notebook
- Color coded (left-edge indicator)
- Rename and delete via popup menu
- Navigating to a section opens the Pages list

---

## 6. Pages

### 6.1 Pages List

- Listed in sort order, then most-recently-updated
- **Swipe left** to delete (soft-delete with confirmation)
- Popup menu per page: **Rename**, **Add to collection**, **Export**, **Delete**
- Import button in app bar: pick Markdown / HTML / plain text / PDF file → creates a new page

### 6.2 Auto-save

The editor auto-saves content 800 ms after the last keystroke. The page title is saved inline in the editor app bar.

---

## 7. Editor

### 7.1 Rich Text (flutter_quill)

Full Quill Delta rich-text editing. Supported inline formats:

| Format | Quill Attribute |
|--------|----------------|
| Bold | `bold: true` |
| Italic | `italic: true` |
| Underline | `underline: true` |
| Strikethrough | `strikethrough: true` |
| Inline code | `code: true` |
| Link | `link: url` |
| Text colour | `color: #rrggbb` |
| Background colour | `background: #rrggbb` |
| Font size | `size: value` |

Supported block formats:

| Format | Quill Attribute |
|--------|----------------|
| Heading 1–3 | `header: 1/2/3` |
| Bullet list | `list: bullet` |
| Ordered list | `list: ordered` |
| Check list | `list: checked / unchecked` |
| Block quote | `blockquote: true` |
| Code block | `code-block: true` |
| Indent levels | `indent: n` |
| Text alignment | `align: left/right/center/justify` |

### 7.2 Page Background Styles

| Style key | Description |
|-----------|-------------|
| `none` | Plain white |
| `lined` | Horizontal ruled lines |
| `grid` | Squared grid |
| `cornell` | Cornell note layout (margin line + header) |

Background color and line spacing are configurable per page.

### 7.3 Page Sizes

| Size | Portrait | Landscape |
|------|----------|-----------|
| `infinite` | Scrolls vertically without bound | — |
| `a5` | 148 × 210 mm | 210 × 148 mm |
| `a4` | 210 × 297 mm | 297 × 210 mm |
| `a3` | 297 × 420 mm | 420 × 297 mm |

Fixed-size pages render with a visible page-break separator.

### 7.4 Zoom

Pinch-to-zoom (touch) and +/− buttons (0.5× – 3.0×). Double-tap zoom indicator resets to 1.0×.

### 7.5 Embedded Images

- Insert via device gallery or camera (`image_picker`)
- Images stored as `PageAsset` records (local file path)
- Tap an embedded image to open the annotation screen

### 7.6 Image Annotation

Dedicated full-screen annotation canvas overlaid on the image. Drawing tools (see §7.7) available. On save, the annotated image replaces the original embed in the Delta.

### 7.7 Ink Drawing

Two ink modes:

| Mode | Trigger | Persistence |
|------|---------|-------------|
| **Annotation ink** | "Annotate" button while image is selected | Embedded back into the image embed |
| **Page ink** | "Page Ink" toolbar button | Stored in `pages.ink_strokes` as JSON |

Drawing tools available in both modes:

| Tool | Description |
|------|-------------|
| Pen | Freehand stroke |
| Highlighter | Semi-transparent wide stroke |
| Eraser | Pixel eraser (BlendMode.clear) |
| Stroke eraser | Tap a complete stroke to remove it |
| Line | Straight line (start → end drag) |
| Rectangle | Axis-aligned rectangle |
| Circle | Ellipse |

Controls: colour picker, stroke width slider, undo, redo.

### 7.8 Tables

- Insert table via toolbar button or paste from clipboard (tab-separated)
- Full-screen table editor: add/remove rows and columns, edit cells
- Rendered as a scrollable grid in the editor
- Exported as HTML `<table>` or Markdown pipe table

### 7.9 Keyboard Shortcuts (Desktop/Web)

| Shortcut | Action |
|----------|--------|
| Ctrl+B | Bold |
| Ctrl+I | Italic |
| Ctrl+U | Underline |
| Ctrl+Z | Undo |
| Ctrl+Shift+Z | Redo |
| Ctrl+S | Force save |
| Ctrl+scroll | Zoom in/out |

---

## 8. Search

- Global full-text search across all page titles and content
- Debounced (300 ms) live results
- Results show page title, section context, and a content snippet
- Tap a result to open the page in a new editor tab

---

## 9. Collections

Named groups of pages that span notebooks and sections, used for grouped export.

### 9.1 Management

- Accessible via **Collections** icon button (app bar / rail footer)
- Create, rename, delete collections
- **Manage pages**: checkbox picker across the full notebook/section/page tree
- "Add to collection" available from the page popup menu (multi-select across groups)

### 9.2 Export

Export a collection via the export sheet (same formats as single-page export):

- **Format:** PDF, HTML, Markdown
- **Output:** Merged single file or individual files in a ZIP

---

## 10. Export

### 10.1 Single Page

| Format | Output |
|--------|--------|
| PDF | Rendered via `pdf` package; bold/italic/underline, headings, lists, blockquotes, code blocks, tables, embedded images |
| HTML | Full HTML5 document with inline styles |
| Markdown | GitHub-flavoured Markdown |

Delivered via `share_plus` (share sheet) or saved to Downloads on failure.

### 10.2 Section / Notebook

Additional **output mode** choice:

| Mode | Description |
|------|-------------|
| Merged | All pages in one document (page breaks / `---` separators) |
| ZIP | One file per page, zipped |

### 10.3 Collection

Same format and output mode options as section/notebook export.

---

## 11. Import

Accessible from the Pages list app bar. Supported file types:

| Extension | Parser |
|-----------|--------|
| `.md` | Markdown → Quill Delta (headings, bold/italic/code, lists, blockquotes) |
| `.html` / `.htm` | DOM walker (`html` package) → Quill Delta |
| `.txt` | Plain text → Quill Delta (line-by-line) |
| `.pdf` | Text extraction via `syncfusion_flutter_pdf` → Quill Delta |

On import, a new page is created in the current section with the file's base name as the title and is immediately opened in a tab.

---

## 12. Local Backup

### 12.1 Backup Format

A ZIP archive containing:

```
manifest.json          — version 2 manifest (structure metadata)
settings.json          — all SharedPreferences settings
{NB}/{Sec}/{Page}.md   — one Markdown file per page (human-readable)
assets/{filename}      — embedded image files
```

`manifest.json` structure:

```json
{
  "version": 2,
  "format": "markdown",
  "app": "flutter_notes",
  "exported_at": 1234567890,
  "notebooks": [
    {
      "id": "...", "name": "...", "color": 4278190335,
      "sections": [
        {
          "id": "...", "name": "...", "color": 4278190335,
          "pages": [
            {
              "id": "...", "title": "...", "file": "NB/Sec/Page.md",
              "created_at": 1234567890, "updated_at": 1234567890
            }
          ]
        }
      ]
    }
  ]
}
```

### 12.2 Backup

Triggered from **Sync Settings → Local Backup → Backup Now**. Delivered via share sheet / saved to Downloads.

### 12.3 Restore

Triggered from **Sync Settings → Local Backup → Restore Backup**.

- Picks a `.zip` file via the system file picker
- Reads manifest (v2 required)
- Creates Notebooks and Sections if IDs not already present
- Creates Pages if IDs not already present (skips duplicates)
- Restores `settings.json` to SharedPreferences
- Reports restored / skipped counts

---

## 13. Settings Backup

`SettingsBackup` serialises all app SharedPreferences keys to JSON:

| Key | Description |
|-----|-------------|
| `smb_host` | SMB server hostname / IP |
| `smb_share` | Share name |
| `smb_base` | Base folder within share |
| `smb_user` | Username |
| `smb_pass` | Password |
| `smb_domain` | Domain (optional) |
| `smb_format` | Sync output format (`markdown` / `html`) |
| `smb_backup_path` | Backup folder within base folder |

Settings are included in every local backup ZIP and every SMB backup ZIP. They are restored automatically during any restore operation.

---

## 14. Cloud Sync

Accessible from **Sync Settings** (fullscreen dialog).

### 14.1 Google Drive

- Sign in via `google_sign_in`
- Uploads pages as files to a dedicated Google Drive folder
- OAuth 2.0 / `googleapis` package
- Stores last sync time; shows connected/disconnected status

### 14.2 OneDrive

- Sign in via `msal_flutter`
- Uploads pages via Microsoft Graph API
- OAuth 2.0

---

## 15. SMB / Network Share Sync

Accessible from **Sync Settings → SMB / Network Share → Configure SMB Sync**.

### 15.1 Configuration

| Field | Description | Default |
|-------|-------------|---------|
| Host / IP | SMB server address | — |
| Share name | Top-level share | — |
| Base folder | Folder within share | `flutter_notes` |
| Username | Auth username | — |
| Password | Auth password | — |
| Domain | Windows domain | _(empty)_ |
| Format | `markdown` or `html` | `markdown` |
| Backup folder | Folder for backups (relative to base folder) | `_backups` |

All fields are persisted to `SharedPreferences` and included in settings backup.

### 15.2 Notes Sync

1. **Test Connection** — verifies credentials and lists shares; on success, loads the selection tree
2. **Selection tree** — choose notebooks / sections / pages to sync (granular checkbox tree with "All notebooks" shortcut)
3. **Sync Now** — writes pages to `\\{host}\{share}\{base}\{Notebook}\{Section}\{Page}.{ext}`
4. Missing directories are created automatically

File naming: notebook name / section name / page title, sanitised (characters `<>:"/\|?*` replaced with `_`).

### 15.3 SMB Backup

Writes a full backup ZIP (same format as local backup) to:

```
\\{host}\{share}\{base}\{backup_folder}\flutter_notes_backup_YYYYMMDD_HHmmss.zip
```

### 15.4 SMB Restore

- **List Backups**: reads `_backups` folder on share, shows available ZIPs with timestamps
- **Restore**: downloads chosen ZIP, restores notes and settings (same logic as local restore)

---

## 16. Technology Stack

| Layer | Package | Version |
|-------|---------|---------|
| UI framework | `flutter` | 3.27.x |
| State management | `flutter_riverpod` | ^2.5.1 |
| Navigation | `go_router` | ^14.2.0 |
| Rich text editor | `flutter_quill` | ^11.5.0 |
| Database (mobile) | `sqflite` | ^2.3.3 |
| Database (desktop) | `sqflite_common_ffi` | ^2.3.3 |
| Code generation | `freezed` + `build_runner` | ^2.5.7 |
| Google auth | `google_sign_in` + `googleapis` | ^6.2.1 / ^13.1.0 |
| Microsoft auth | `msal_flutter` | ^2.0.1 |
| SMB client | `smb_connect` | ^0.0.9 |
| PDF export | `pdf` | ^3.11.0 |
| PDF import | `syncfusion_flutter_pdf` | ^27.2.0 |
| HTML import | `html` | ^0.15.0 |
| Backup archive | `archive` | ^3.6.0 |
| File picker | `file_picker` | ^8.0.0 |
| Image picker | `image_picker` | ^1.1.2 |
| Sharing | `share_plus` | ^10.0.0 |
| Localisation | `intl` | ^0.19.0 |
| Unique IDs | `uuid` | ^4.4.0 |
| Colour picker | `flutter_colorpicker` | ^1.1.0 |
| Preferences | `shared_preferences` | ^2.3.2 |
| Connectivity | `connectivity_plus` | ^6.0.3 |
| Cryptography | `crypto` | ^3.0.3 |

---

## 17. Build & Distribution

### 17.1 CI/CD — GitHub Actions

Workflow: `.github/workflows/build.yml`  
Trigger: push to `main` branch or manual `workflow_dispatch`

| Job | Runner | Output |
|-----|--------|--------|
| `build-android` | `ubuntu-latest` | `app-release.apk` |
| `build-windows` | `windows-latest` | `flutter_notes_windows.zip` |
| `release` | `ubuntu-latest` | GitHub Release with both files |

### 17.2 Android

- Min SDK: 21
- Target/Compile SDK: 35
- NDK: 27.0.12077973
- Gradle: 8.11.1
- Java / Kotlin target: 17
- Signing: unsigned release (add keystore for production)

### 17.3 Windows

- Output: `build\windows\x64\runner\Release\`
- Distributed as a ZIP (no installer)
- Requires Windows 10 or later

### 17.4 Known CI Patches

Applied automatically in CI before each build:

| Issue | Fix |
|-------|-----|
| `quill_native_bridge_windows` uses removed `GMEM_MOVEABLE` constant | Replace with numeric value `0x0002` via sed (Linux) / PowerShell (Windows) |
| `msal_flutter` missing Android `namespace` declaration | Inject namespace from `AndroidManifest.xml` into `build.gradle` |
| `google-services.json` not in repo | Write placeholder at build time (real credentials via `GOOGLE_SERVICES_JSON` repo secret) |

---

## 18. File & Folder Structure

```
lib/
├── core/
│   ├── database/        — DAOs (notebooks, sections, pages, assets, groups, sync)
│   └── models/          — Data classes (freezed for pages/notebooks/sections)
├── features/
│   ├── editor/          — Rich text editor, drawing canvas, table editor
│   ├── export/          — ExportService, DeltaConverter, export sheet UI
│   ├── groups/          — Collections (page groups) provider + screen
│   ├── import/          — ImportService (MD/HTML/TXT/PDF → Delta)
│   ├── notebooks/       — Notebooks screen + provider
│   ├── pages/           — Pages screen + provider
│   ├── search/          — Search screen
│   ├── sections/        — Sections screen + provider
│   ├── sync/            — Google/OneDrive sync, SMB sync, local backup, settings backup
│   └── tabs/            — Tab state (open editor tabs)
└── shared/
    ├── providers/       — Nav state
    ├── theme/           — App theme
    ├── utils/           — Responsive breakpoints
    └── widgets/         — AppShell, BrowsePane, confirm dialog, colour picker
```

---

## 19. Known Limitations

- Google Drive and OneDrive sync currently upload pages as raw Delta JSON (not human-readable); only the SMB sync and local backup produce readable Markdown
- SMB `openRead` / `listFiles` API depends on `smb_connect 0.0.9` which is pre-release; behaviour on some NAS devices may vary
- PDF import uses text extraction only; formatting and images in source PDFs are not preserved
- Web platform builds are configured but cloud sync features requiring native auth (Google Sign-In, MSAL) may have limited functionality on web
- Ink strokes are stored as JSON per page and are not vectorised for PDF export (page-level ink is omitted from exported PDFs)
