import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:msal_flutter/msal_flutter.dart';

bool get _msalSupported => Platform.isAndroid || Platform.isIOS;

class OneDriveService {
  static const _graphBase =
      'https://graph.microsoft.com/v1.0/me/drive/special/approot';
  static const _scopes = ['Files.ReadWrite.AppFolder', 'offline_access'];

  PublicClientApplication? _pca;
  String? _accessToken;
  bool _initialized = false;

  bool get isSignedIn => _accessToken != null;

  Future<void> _init() async {
    if (_initialized) return;
    if (!_msalSupported) { _initialized = true; return; }
    _pca = await PublicClientApplication.createPublicClientApplication(
      'YOUR_CLIENT_ID', // Replace with actual client ID from Azure
      authority:
          'https://login.microsoftonline.com/common',
    );
    _initialized = true;
  }

  Future<bool> signIn() async {
    if (!_msalSupported) return false;
    await _init();
    try {
      _accessToken = await _pca!.acquireToken(_scopes);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> signOut() async {
    await _init();
    try {
      await _pca!.logout();
    } catch (_) {}
    _accessToken = null;
  }

  Future<String> _freshToken() async {
    try {
      _accessToken = await _pca!.acquireTokenSilent(_scopes);
      return _accessToken!;
    } catch (_) {
      _accessToken = await _pca!.acquireToken(_scopes);
      return _accessToken!;
    }
  }

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer $_accessToken',
        'Content-Type': 'application/json',
      };

  /// remotePath is relative to the AppFolder root, e.g. "notebookId/section.json"
  Future<void> uploadText(String remotePath, String content) async {
    final token = await _freshToken();
    final url = '$_graphBase:/$remotePath:/content';
    final response = await http.put(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/octet-stream',
      },
      body: utf8.encode(content),
    );
    if (response.statusCode >= 300) {
      throw Exception(
          'OneDrive upload failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<String?> downloadText(String remotePath) async {
    final token = await _freshToken();
    final metaUrl = '$_graphBase:/$remotePath';
    final metaResponse = await http.get(
      Uri.parse(metaUrl),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (metaResponse.statusCode == 404) return null;
    if (metaResponse.statusCode >= 300) {
      throw Exception(
          'OneDrive meta failed: ${metaResponse.statusCode}');
    }

    final meta = jsonDecode(metaResponse.body) as Map<String, dynamic>;
    final downloadUrl = meta['@microsoft.graph.downloadUrl'] as String?;
    if (downloadUrl == null) return null;

    final contentResponse = await http.get(Uri.parse(downloadUrl));
    if (contentResponse.statusCode >= 300) return null;
    return utf8.decode(contentResponse.bodyBytes);
  }

  Future<void> uploadBinary(
      String remotePath, List<int> bytes, String mimeType) async {
    final token = await _freshToken();
    final url = '$_graphBase:/$remotePath:/content';
    final response = await http.put(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': mimeType,
      },
      body: bytes,
    );
    if (response.statusCode >= 300) {
      throw Exception(
          'OneDrive upload failed: ${response.statusCode} ${response.body}');
    }
  }
}
