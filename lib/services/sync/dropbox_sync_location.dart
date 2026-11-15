import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:Bloomee/services/sync/sync_location_http.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// The Dropbox app Bloomee signs in to: its app key, supplied at build time
/// (`--dart-define=BLOOMEE_DROPBOX_APP_KEY=...`), and where Dropbox answers.
///
/// The app is registered with the App Folder permission type, so whatever it
/// is granted reaches only its own folder (`Apps/<app name>/`). Its key is
/// not a secret: sign-in uses PKCE and no client secret.
class DropboxApp {
  /// The build-time define holding the app key.
  static const keyDefine = 'BLOOMEE_DROPBOX_APP_KEY';
  static const _keyFromBuild = String.fromEnvironment(keyDefine);

  /// What Bloomee asks Dropbox for: reading and writing files in its app
  /// folder, and nothing about the account.
  static const scopes = [
    'files.metadata.read',
    'files.content.read',
    'files.content.write',
  ];

  final String key;

  /// The page where the owner allows Bloomee and is shown a code.
  final Uri authorizePage;

  /// The hosts of Dropbox's API calls and of its content calls.
  final Uri api;
  final Uri content;

  /// How Dropbox is called, and what its failures mean.
  final SyncLocationHttp _http;

  DropboxApp({
    required this.key,
    Uri? authorizePage,
    Uri? api,
    Uri? content,
    Duration requestTimeout = SyncLocationHttp.defaultRequestTimeout,
    http.Client? client,
  })  : authorizePage = authorizePage ??
            Uri.parse('https://www.dropbox.com/oauth2/authorize'),
        api = api ?? Uri.parse('https://api.dropboxapi.com'),
        content = content ?? Uri.parse('https://content.dropboxapi.com'),
        _http = SyncLocationHttp('Dropbox',
            requestTimeout: requestTimeout, client: client);

  /// The app this build was given a key for, or null for a build without
  /// one, which does not offer Dropbox.
  static DropboxApp? fromBuild() => _fromBuild;

  static final DropboxApp? _fromBuild = _keyFromBuild.trim().isEmpty
      ? null
      : DropboxApp(key: _keyFromBuild.trim());

  /// Starts signing in on this Device: the owner opens [DropboxSignIn.page],
  /// allows Bloomee, and pastes back the code Dropbox shows.
  DropboxSignIn beginSignIn() {
    final verifier = _codeVerifier();
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    return DropboxSignIn._(
        this,
        verifier,
        authorizePage.replace(queryParameters: {
          'client_id': key,
          'response_type': 'code',
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          // A refresh token, so that the sign-in lasts.
          'token_access_type': 'offline',
          'scope': scopes.join(' '),
        }));
  }

  static String _codeVerifier() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    return String.fromCharCodes(List.generate(
        64, (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length))));
  }

  Uri get _tokenEndpoint => api.resolve('/oauth2/token');

  /// Asks the token endpoint with [form]. Only a refused grant (a code or
  /// refresh token Dropbox does not accept, as once revoked) means the owner
  /// must sign in again; any other refusal is reported as it is.
  Future<Map<String, Object?>> _token(Map<String, String> form) async {
    final response = await _http.post(_tokenEndpoint, body: form);
    if (response.statusCode == 200) {
      try {
        if (jsonDecode(response.body) case final Map<String, Object?> answer) {
          return answer;
        }
      } on FormatException {
        // Reported below.
      }
      throw const SyncLocationFailed('Dropbox gave an unreadable answer.');
    }
    if (_summary(response) == 'invalid_grant') {
      throw SyncLocationSignInRefused(
          'Dropbox refused the sign-in: ${_describe(response)}');
    }
    throw _unexpected(response);
  }

  /// What a Dropbox answer that is not a success means (see
  /// [SyncLocationHttp.unexpected]).
  SyncLocationException _unexpected(http.Response response) =>
      _http.unexpected(response.statusCode, ': ${_describe(response)}');
}

/// One sign-in under way on this Device, by the authorisation-code flow with
/// PKCE and no redirect.
class DropboxSignIn {
  final DropboxApp _app;
  final String _verifier;

  /// The Dropbox page the owner opens to allow Bloomee.
  final Uri page;

  DropboxSignIn._(this._app, this._verifier, this.page);

  /// Exchanges the [code] Dropbox showed the owner for a lasting sign-in,
  /// returned as its refresh token. Throws [SyncLocationSignInRefused] for
  /// a code Dropbox did not give for this sign-in, or no longer accepts.
  Future<String> finish(String code) async {
    final answer = await _app._token({
      'grant_type': 'authorization_code',
      'code': code.trim(),
      'client_id': _app.key,
      'code_verifier': _verifier,
    });
    final refreshToken = answer['refresh_token'];
    if (refreshToken is! String || refreshToken.isEmpty) {
      throw const SyncLocationFailed('Dropbox gave no lasting sign-in.');
    }
    return refreshToken;
  }
}

/// The Dropbox app folder as a Sync Location, through the Dropbox HTTP API.
///
/// It holds the sign-in's refresh token and renews the short-lived access
/// token from it as needed, also when Dropbox says it expired. Dropbox makes
/// an uploaded file visible only once the whole upload has arrived, so a
/// reader sees the previous file or the new one, never part of it. Failures
/// are reported as [SyncLocationHttp] says.
class DropboxSyncLocation implements SyncLocation {
  /// How long before its stated expiry an access token is renewed.
  static const renewalMargin = Duration(minutes: 5);

  final DropboxApp app;
  final String _refreshToken;
  final DateTime Function() _clock;

  String? _accessToken;
  DateTime _accessExpiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String>? _renewing;

  DropboxSyncLocation(
      {required this.app,
      required String refreshToken,
      DateTime Function()? clock})
      : _refreshToken = refreshToken,
        _clock = clock ?? DateTime.now;

  @override
  Future<List<String>> list(String directory) async {
    final names = <String>[];
    var response = await _rpc('/2/files/list_folder', {
      'path': _dropboxPath(directory),
      'recursive': false,
      'include_deleted': false,
    });
    while (true) {
      if (response.statusCode == 409 && _isNotFound(response, 'path')) {
        return names;
      }
      final page = _decode(_ok(response));
      for (final entry in page['entries'] as List<Object?>) {
        if (entry case {'.tag': 'file', 'name': final String name}) {
          names.add(name);
        }
      }
      if (page['has_more'] != true) return names;
      response = await _rpc(
          '/2/files/list_folder/continue', {'cursor': page['cursor']});
    }
  }

  @override
  Future<Uint8List?> read(String path) async {
    final response = await _call((token) =>
        app._http.post(app.content.resolve('/2/files/download'), headers: {
          HttpHeaders.authorizationHeader: 'Bearer $token',
          'Dropbox-API-Arg': _headerArg({'path': _dropboxPath(path)}),
        }));
    if (response.statusCode == 409 && _isNotFound(response, 'path')) {
      return null;
    }
    return _ok(response).bodyBytes;
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    _ok(await _call(
        (token) => app._http.post(app.content.resolve('/2/files/upload'),
            headers: {
              HttpHeaders.authorizationHeader: 'Bearer $token',
              HttpHeaders.contentTypeHeader: 'application/octet-stream',
              'Dropbox-API-Arg': _headerArg({
                'path': _dropboxPath(path),
                'mode': 'overwrite',
                'autorename': false,
                'mute': true,
              }),
            },
            body: bytes)));
  }

  @override
  Future<void> delete(String path) async {
    final response =
        await _rpc('/2/files/delete_v2', {'path': _dropboxPath(path)});
    if (response.statusCode == 409 && _isNotFound(response, 'path_lookup')) {
      return;
    }
    _ok(response);
  }

  @override
  Future<void> checkReachable() async {
    // Listing the app folder itself shows Dropbox answers and accepts the
    // sign-in.
    _ok(await _rpc('/2/files/list_folder', {'path': '', 'limit': 1}));
  }

  /// Ends this sign-in on Dropbox, so that its refresh token stops working.
  Future<void> signOut() async {
    _ok(await _call((token) => app._http.post(
        app.api.resolve('/2/auth/token/revoke'),
        headers: {HttpHeaders.authorizationHeader: 'Bearer $token'})));
    _accessToken = null;
  }

  static String _dropboxPath(String path) =>
      '/${syncPathSegments(path).join('/')}';

  Future<http.Response> _rpc(String endpoint, Map<String, Object?> argument) =>
      _call((token) => app._http.post(app.api.resolve(endpoint),
          headers: {
            HttpHeaders.authorizationHeader: 'Bearer $token',
            HttpHeaders.contentTypeHeader: 'application/json',
          },
          body: jsonEncode(argument)));

  /// Makes a call with a valid access token; when Dropbox refuses that
  /// token, renews it once and calls again.
  Future<http.Response> _call(
      Future<http.Response> Function(String token) request) async {
    for (var attempt = 0;; attempt++) {
      final token = await _validAccessToken();
      final response = await request(token);
      if (response.statusCode != 401) return response;
      if (identical(_accessToken, token)) _accessToken = null;
      if (attempt > 0) {
        throw SyncLocationSignInRefused(
            'Dropbox refused the sign-in: ${_describe(response)}');
      }
    }
  }

  Future<String> _validAccessToken() {
    final token = _accessToken;
    if (token != null &&
        _clock().isBefore(_accessExpiresAt.subtract(renewalMargin))) {
      return Future.value(token);
    }
    return _renewing ??= _renew().whenComplete(() => _renewing = null);
  }

  Future<String> _renew() async {
    final answer = await app._token({
      'grant_type': 'refresh_token',
      'refresh_token': _refreshToken,
      'client_id': app.key,
    });
    final token = answer['access_token'];
    final expiresIn = answer['expires_in'];
    if (token is! String || expiresIn is! int) {
      throw const SyncLocationFailed('Dropbox gave no access token.');
    }
    _accessToken = token;
    _accessExpiresAt = _clock().add(Duration(seconds: expiresIn));
    return token;
  }

  /// [response] when it succeeded; otherwise what it means as an exception.
  http.Response _ok(http.Response response) {
    if (response.statusCode == 200) return response;
    throw app._unexpected(response);
  }

  static bool _isNotFound(http.Response response, String tag) =>
      _summary(response).startsWith('$tag/not_found');

  static Map<String, Object?> _decode(http.Response response) =>
      jsonDecode(response.body) as Map<String, Object?>;

  /// The JSON of a `Dropbox-API-Arg` header, which must be printable ASCII:
  /// anything else (0x7F and beyond) is escaped as JSON allows.
  static String _headerArg(Map<String, Object?> argument) =>
      jsonEncode(argument).replaceAllMapped(
          RegExp(r'[^\x00-\x7e]'),
          (match) =>
              '\\u${match[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0')}');
}

/// Dropbox's short description of an error answer.
String _summary(http.Response response) {
  try {
    final body = jsonDecode(response.body);
    if (body case {'error_summary': final String summary}) return summary;
    if (body case {'error': final String error}) return error;
  } on FormatException {
    // Not JSON.
  }
  return '';
}

String _describe(http.Response response) {
  final summary = _summary(response);
  if (summary.isNotEmpty) return summary;
  final body = response.body.trim();
  return body.length > 200 ? '${body.substring(0, 200)}…' : body;
}
