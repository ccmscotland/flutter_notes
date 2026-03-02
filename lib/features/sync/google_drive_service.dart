import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

class GoogleDriveService {
  static const _scopes = [drive.DriveApi.driveFileScope];
  static const _rootFolder = 'FlutterNotes';

  final GoogleSignIn _signIn = GoogleSignIn(scopes: _scopes);
  drive.DriveApi? _api;
  String? _rootFolderId;

  bool get isSignedIn => _signIn.currentUser != null;

  Future<bool> signIn() async {
    try {
      final account = await _signIn.signIn();
      if (account == null) return false;
      await _initApi(account);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> signOut() async {
    await _signIn.signOut();
    _api = null;
    _rootFolderId = null;
  }

  Future<void> _initApi(GoogleSignInAccount account) async {
    final auth = await account.authentication;
    final client = GoogleAuthClient({
      'Authorization': 'Bearer ${auth.accessToken}',
    });
    _api = drive.DriveApi(client);
  }

  Future<drive.DriveApi> _getApi() async {
    if (_api != null) return _api!;
    final account = _signIn.currentUser ?? await _signIn.signInSilently();
    if (account == null) throw Exception('Not signed in to Google Drive');
    await _initApi(account);
    return _api!;
  }

  Future<String> _getRootFolderId() async {
    if (_rootFolderId != null) return _rootFolderId!;
    final api = await _getApi();

    final existing = await api.files.list(
      q: "name = '$_rootFolder' and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
      spaces: 'drive',
      $fields: 'files(id)',
    );

    if (existing.files?.isNotEmpty == true) {
      _rootFolderId = existing.files!.first.id!;
      return _rootFolderId!;
    }

    final folder = drive.File()
      ..name = _rootFolder
      ..mimeType = 'application/vnd.google-apps.folder';
    final created = await api.files.create(folder, $fields: 'id');
    _rootFolderId = created.id!;
    return _rootFolderId!;
  }

  Future<void> uploadText(String remotePath, String content) async {
    final api = await _getApi();
    final rootId = await _getRootFolderId();
    final parts = remotePath.split('/');
    String parentId = rootId;

    // Create intermediate folders
    for (int i = 0; i < parts.length - 1; i++) {
      parentId = await _ensureFolder(api, parts[i], parentId);
    }

    final fileName = parts.last;
    final bytes = utf8.encode(content);

    // Check if file exists
    final existing = await api.files.list(
      q: "name = '$fileName' and '$parentId' in parents and trashed = false",
      $fields: 'files(id)',
    );

    if (existing.files?.isNotEmpty == true) {
      final fileId = existing.files!.first.id!;
      final media = drive.Media(
        Stream.fromIterable([bytes]),
        bytes.length,
        contentType: 'application/json',
      );
      await api.files.update(drive.File(), fileId, uploadMedia: media);
    } else {
      final file = drive.File()
        ..name = fileName
        ..parents = [parentId];
      final media = drive.Media(
        Stream.fromIterable([bytes]),
        bytes.length,
        contentType: 'application/json',
      );
      await api.files.create(file, uploadMedia: media);
    }
  }

  Future<String?> downloadText(String remotePath) async {
    final api = await _getApi();
    final rootId = await _getRootFolderId();
    final parts = remotePath.split('/');
    String parentId = rootId;

    for (int i = 0; i < parts.length - 1; i++) {
      final folderId = await _findFolder(api, parts[i], parentId);
      if (folderId == null) return null;
      parentId = folderId;
    }

    final fileName = parts.last;
    final results = await api.files.list(
      q: "name = '$fileName' and '$parentId' in parents and trashed = false",
      $fields: 'files(id)',
    );

    if (results.files?.isEmpty != false) return null;
    final fileId = results.files!.first.id!;
    final media = await api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
      $fields: 'id',
    ) as drive.Media;

    final chunks = await media.stream.toList();
    return utf8.decode(chunks.expand((e) => e).toList());
  }

  Future<void> uploadBinary(String remotePath, List<int> bytes,
      String mimeType) async {
    final api = await _getApi();
    final rootId = await _getRootFolderId();
    final parts = remotePath.split('/');
    String parentId = rootId;

    for (int i = 0; i < parts.length - 1; i++) {
      parentId = await _ensureFolder(api, parts[i], parentId);
    }

    final fileName = parts.last;
    final file = drive.File()
      ..name = fileName
      ..parents = [parentId];
    final media = drive.Media(
      Stream.fromIterable([bytes]),
      bytes.length,
      contentType: mimeType,
    );
    await api.files.create(file, uploadMedia: media);
  }

  Future<String> _ensureFolder(
      drive.DriveApi api, String name, String parentId) async {
    final existing = await _findFolder(api, name, parentId);
    if (existing != null) return existing;

    final folder = drive.File()
      ..name = name
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = [parentId];
    final created = await api.files.create(folder, $fields: 'id');
    return created.id!;
  }

  Future<String?> _findFolder(
      drive.DriveApi api, String name, String parentId) async {
    final results = await api.files.list(
      q: "name = '$name' and '$parentId' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false",
      $fields: 'files(id)',
    );
    return results.files?.firstOrNull?.id;
  }
}
