import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A small HTTP server standing in for Dropbox, started inside a test. It
/// answers the few calls Bloomee makes: the token endpoint (the code
/// exchange with PKCE, and renewal with the refresh token), listing, download,
/// upload and delete in one app folder, and token revocation. It never
/// reaches the real Dropbox.
///
/// Like Dropbox, it makes an upload visible only once the whole of it has
/// arrived, so an interrupted upload leaves nothing behind. Like Dropbox, it
/// knows several apps: a sign-in belongs to the app it was made with, and
/// each app has its own app folder.
class DropboxStandIn {
  /// The app key the stand-in knows first.
  final String appKey;

  /// Every app key the stand-in knows, [appKey] included; any other is
  /// refused.
  final Set<String> appKeys;

  /// How long an access token it issues is valid.
  final Duration accessTokenLifetime;

  /// How many entries one listing call returns before asking to continue.
  final int pageSize;

  final HttpServer _server;
  final Random _random = Random();

  /// The app folders, by app key: in each, file content by lower-case path
  /// (Dropbox paths are not case-sensitive), with the path as written.
  final Map<String, Map<String, ({String path, Uint8List bytes})>> _folders =
      {};

  /// Codes shown to the owner on the authorisation page, and what they were
  /// issued for: the app, the PKCE challenge and the scopes asked.
  final Map<String, ({String app, String challenge, List<String> scopes})>
      _codes = {};

  /// Refresh tokens still valid, with the app they belong to and the scopes
  /// granted.
  final Map<String, ({String app, List<String> scopes})> _refreshTokens = {};

  /// How many times an access token was renewed, by app key.
  final Map<String, int> _renewalsBy = {};

  /// Access tokens by value: the app and refresh token they belong to, and
  /// expiry.
  final Map<String, ({String app, String? refreshToken, DateTime expiresAt})>
      _accessTokens = {};

  final Map<String, List<String>> _cursors = {};
  final List<Completer<void>> _abortedUploadWaiters = [];

  /// How many times an access token was renewed with a refresh token.
  int get renewals => _renewalsBy.values.fold(0, (sum, n) => sum + n);

  /// How many requests it received.
  int requests = 0;

  /// How many uploads were cut short before all their content arrived.
  int abortedUploads = 0;

  /// The query of each authorisation page the owner was sent to.
  final List<Map<String, String>> pagesOpened = [];

  DropboxStandIn._(this._server,
      {required this.appKey,
      required Iterable<String> otherAppKeys,
      required this.accessTokenLifetime,
      required this.pageSize})
      : appKeys = {appKey, ...otherAppKeys} {
    _server.listen(_handle);
  }

  /// Starts a stand-in knowing the app [appKey], and the apps
  /// [otherAppKeys] too.
  static Future<DropboxStandIn> start(
      {String appKey = 'stand-in-app-key',
      Iterable<String> otherAppKeys = const [],
      Duration accessTokenLifetime = const Duration(hours: 4),
      int pageSize = 1}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return DropboxStandIn._(server,
        appKey: appKey,
        otherAppKeys: otherAppKeys,
        accessTokenLifetime: accessTokenLifetime,
        pageSize: pageSize);
  }

  /// Where the stand-in answers: the API, content and authorisation hosts
  /// are all this one.
  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  Uri get authorizePage => base.resolve('/oauth2/authorize');

  /// The owner opens [page] and allows the app: the stand-in checks the page
  /// is a well-formed PKCE authorisation request for an app it knows and
  /// returns the code Dropbox would show them to paste back.
  String approve(Uri page) {
    final query = page.queryParameters;
    pagesOpened.add(query);
    if (page.path != authorizePage.path ||
        !appKeys.contains(query['client_id']) ||
        query['response_type'] != 'code' ||
        query['code_challenge_method'] != 'S256' ||
        (query['code_challenge'] ?? '').isEmpty) {
      throw StateError('Not an authorisation page Dropbox would accept: $page');
    }
    final code = _token('code');
    _codes[code] = (
      app: query['client_id']!,
      challenge: query['code_challenge']!,
      scopes:
          (query['scope'] ?? '').split(' ').where((s) => s.isNotEmpty).toList()
    );
    return code;
  }

  /// A refresh token, as signing in on another Device would give, with the
  /// app [app] ([appKey] if not given).
  String signedInRefreshToken({String? app}) {
    final token = _token('refresh');
    _refreshTokens[token] = (app: app ?? appKey, scopes: const []);
    return token;
  }

  /// A valid access token of the app [appKey], for writing to the stand-in
  /// directly.
  String accessToken() {
    final token = _token('access');
    _accessTokens[token] = (
      app: appKey,
      refreshToken: null,
      expiresAt: DateTime.now().add(accessTokenLifetime)
    );
    return token;
  }

  /// Every access token issued so far expires now.
  void expireAccessTokens() {
    for (final MapEntry(:key, :value) in _accessTokens.entries.toList()) {
      _accessTokens[key] = (
        app: value.app,
        refreshToken: value.refreshToken,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(0)
      );
    }
  }

  /// The owner removes the app's access from their Dropbox account: every
  /// token stops working.
  void revokeAll() {
    _refreshTokens.clear();
    _accessTokens.clear();
  }

  /// The owner deletes the app [app] in the Dropbox App Console: Dropbox no
  /// longer knows its key.
  void forgetApp(String app) => appKeys.remove(app);

  /// Whether [refreshToken] still works.
  bool isValid(String refreshToken) => _refreshTokens.containsKey(refreshToken);

  /// Every refresh token still valid.
  Iterable<String> get validRefreshTokens => _refreshTokens.keys;

  /// The key of the app the sign-in [refreshToken] belongs to, while it is
  /// valid.
  String? appOf(String refreshToken) => _refreshTokens[refreshToken]?.app;

  /// How many times an access token was renewed by the app [app].
  int renewalsBy(String app) => _renewalsBy[app] ?? 0;

  /// The content of the file at [path] in the app folder of [app] ([appKey]
  /// if not given), if any.
  Uint8List? file(String path, {String? app}) =>
      _folder(app ?? appKey)[path.toLowerCase()]?.bytes;

  /// The paths of every file in the app folder of [appKey].
  List<String> get paths => pathsOf(appKey);

  /// The paths of every file in the app folder of [app].
  List<String> pathsOf(String app) =>
      [for (final f in _folder(app).values) f.path]..sort();

  Map<String, ({String path, Uint8List bytes})> _folder(String app) =>
      _folders.putIfAbsent(app, () => {});

  /// Completes once [count] uploads in all were cut short.
  Future<void> abortedUploadsReach(int count) {
    if (abortedUploads >= count) return Future.value();
    final waiter = Completer<void>();
    _abortedUploadWaiters.add(waiter);
    return waiter.future.then((_) => abortedUploadsReach(count));
  }

  Future<void> close() => _server.close(force: true);

  String _token(String kind) =>
      '$kind-${List.generate(4, (_) => _random.nextInt(1 << 32).toRadixString(16)).join()}';

  Future<void> _handle(HttpRequest request) async {
    requests++;
    try {
      final path = request.uri.path;
      if (path == '/oauth2/token') return await _tokenEndpoint(request);
      final token = _authorise(request);
      if (token == null) return;
      switch (path) {
        case '/2/files/list_folder':
          return await _listFolder(request, _folder(_accessTokens[token]!.app));
        case '/2/files/list_folder/continue':
          return await _listContinue(request);
        case '/2/files/download':
          return await _download(request, _folder(_accessTokens[token]!.app));
        case '/2/files/upload':
          return await _upload(request, _folder(_accessTokens[token]!.app));
        case '/2/files/delete_v2':
          return await _delete(request, _folder(_accessTokens[token]!.app));
        case '/2/auth/token/revoke':
          await _drain(request);
          final refresh = _accessTokens[token]?.refreshToken;
          if (refresh != null) {
            _refreshTokens.remove(refresh);
            _accessTokens.removeWhere((_, t) => t.refreshToken == refresh);
          }
          _accessTokens.remove(token);
          return _json(request.response, null);
        default:
          await _drain(request);
          return _reply(request.response, 404, 'Unknown endpoint $path');
      }
    } catch (error) {
      try {
        _reply(request.response, 500, '$error');
      } catch (_) {
        // The connection is gone.
      }
    }
  }

  Future<void> _tokenEndpoint(HttpRequest request) async {
    final form = Uri.splitQueryString(await utf8.decodeStream(request));
    void refuse(String error) =>
        _json(request.response, {'error': error, 'error_description': error},
            status: 400);
    final app = form['client_id'] ?? '';
    if (!appKeys.contains(app)) return refuse('invalid_client');
    if (form.containsKey('client_secret')) return refuse('invalid_request');
    switch (form['grant_type']) {
      case 'authorization_code':
        final issued = _codes.remove(form['code']);
        final verifier = form['code_verifier'] ?? '';
        final challenge = base64Url
            .encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', '');
        if (issued == null ||
            issued.app != app ||
            issued.challenge != challenge ||
            form.containsKey('redirect_uri')) {
          return refuse('invalid_grant');
        }
        final refresh = _token('refresh');
        _refreshTokens[refresh] = (app: issued.app, scopes: issued.scopes);
        final access = _issueAccess(refresh, issued.app);
        return _json(request.response, {
          'access_token': access,
          'token_type': 'bearer',
          'expires_in': accessTokenLifetime.inSeconds,
          'refresh_token': refresh,
          'scope': issued.scopes.join(' '),
          'account_id': 'dbid:stand-in',
          'uid': '1',
        });
      case 'refresh_token':
        final refresh = form['refresh_token'];
        // A sign-in renews only through the app it was made with.
        if (refresh == null || _refreshTokens[refresh]?.app != app) {
          return refuse('invalid_grant');
        }
        _renewalsBy[app] = renewalsBy(app) + 1;
        return _json(request.response, {
          'access_token': _issueAccess(refresh, app),
          'token_type': 'bearer',
          'expires_in': accessTokenLifetime.inSeconds,
        });
      default:
        return refuse('unsupported_grant_type');
    }
  }

  String _issueAccess(String refreshToken, String app) {
    final token = _token('access');
    _accessTokens[token] = (
      app: app,
      refreshToken: refreshToken,
      expiresAt: DateTime.now().add(accessTokenLifetime)
    );
    return token;
  }

  /// The access token of [request], or null once refused.
  String? _authorise(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final token = header.startsWith('Bearer ') ? header.substring(7) : '';
    final known = _accessTokens[token];
    String? refusal;
    if (known == null) {
      refusal = 'invalid_access_token';
    } else if (!DateTime.now().isBefore(known.expiresAt)) {
      refusal = 'expired_access_token';
    }
    if (refusal == null) return token;
    request.drain<void>().catchError((_) {});
    _json(
        request.response,
        {
          'error_summary': '$refusal/...',
          'error': {'.tag': refusal}
        },
        status: 401);
    return null;
  }

  Future<void> _listFolder(HttpRequest request,
      Map<String, ({String path, Uint8List bytes})> files) async {
    final arg = await _jsonBody(request);
    final folder = (arg['path'] as String).toLowerCase();
    final prefix = folder.isEmpty ? '/' : '$folder/';
    final children = <String>{};
    final folders = <String>{};
    for (final MapEntry(key: lower, value: entry) in files.entries) {
      if (!lower.startsWith(prefix)) continue;
      final rest = entry.path.substring(prefix.length);
      final slash = rest.indexOf('/');
      if (slash < 0) {
        children.add(rest);
      } else {
        folders.add(rest.substring(0, slash));
      }
    }
    if (folder.isNotEmpty && children.isEmpty && folders.isEmpty) {
      return _conflict(request.response, 'path/not_found/');
    }
    final entries = [
      for (final name in children)
        jsonEncode(
            {'.tag': 'file', 'name': name, 'path_display': '$prefix$name'}),
      for (final name in folders)
        jsonEncode(
            {'.tag': 'folder', 'name': name, 'path_display': '$prefix$name'}),
    ];
    return _page(request.response, entries);
  }

  Future<void> _listContinue(HttpRequest request) async {
    final arg = await _jsonBody(request);
    final rest = _cursors.remove(arg['cursor']);
    if (rest == null) return _conflict(request.response, 'reset/');
    return _page(request.response, rest);
  }

  void _page(HttpResponse response, List<String> entries) {
    final page = entries.take(pageSize).toList();
    final rest = entries.skip(pageSize).toList();
    String? cursor;
    if (rest.isNotEmpty) {
      cursor = _token('cursor');
      _cursors[cursor] = rest;
    }
    _json(response, {
      'entries': [for (final e in page) jsonDecode(e)],
      'cursor': cursor ?? _token('cursor'),
      'has_more': rest.isNotEmpty,
    });
  }

  Future<void> _download(HttpRequest request,
      Map<String, ({String path, Uint8List bytes})> files) async {
    await _drain(request);
    final arg = _headerArg(request);
    final found = files[(arg['path'] as String).toLowerCase()];
    if (found == null) return _conflict(request.response, 'path/not_found/');
    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.binary
      ..headers.set(
          'Dropbox-API-Result',
          jsonEncode(
              {'name': found.path.split('/').last, 'size': found.bytes.length}))
      ..add(found.bytes);
    await request.response.close();
  }

  Future<void> _upload(HttpRequest request,
      Map<String, ({String path, Uint8List bytes})> files) async {
    final arg = _headerArg(request);
    if (arg['mode'] != 'overwrite') {
      await _drain(request);
      return _reply(request.response, 400, 'Bloomee must overwrite.');
    }
    final builder = BytesBuilder(copy: false);
    try {
      await for (final chunk in request) {
        builder.add(chunk);
      }
    } catch (_) {
      _uploadAborted();
      return;
    }
    final expected = request.contentLength;
    if (expected >= 0 && builder.length != expected) {
      _uploadAborted();
      return;
    }
    final path = arg['path'] as String;
    files[path.toLowerCase()] = (path: path, bytes: builder.takeBytes());
    return _json(
        request.response, {'name': path.split('/').last, 'path_display': path});
  }

  void _uploadAborted() {
    abortedUploads++;
    for (final waiter in _abortedUploadWaiters) {
      waiter.complete();
    }
    _abortedUploadWaiters.clear();
  }

  Future<void> _delete(HttpRequest request,
      Map<String, ({String path, Uint8List bytes})> files) async {
    final arg = await _jsonBody(request);
    final removed = files.remove((arg['path'] as String).toLowerCase());
    if (removed == null) {
      return _conflict(request.response, 'path_lookup/not_found/');
    }
    return _json(request.response, {
      'metadata': {'.tag': 'file', 'name': removed.path.split('/').last}
    });
  }

  static Map<String, Object?> _headerArg(HttpRequest request) =>
      jsonDecode(request.headers.value('Dropbox-API-Arg')!)
          as Map<String, Object?>;

  static Future<Map<String, Object?>> _jsonBody(HttpRequest request) async =>
      jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;

  static Future<void> _drain(HttpRequest request) => request.drain<void>();

  static void _conflict(HttpResponse response, String summary) =>
      _json(response, {'error_summary': summary, 'error': {}}, status: 409);

  static void _json(HttpResponse response, Object? body, {int status = 200}) {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    response.close();
  }

  static void _reply(HttpResponse response, int status, String text) {
    response
      ..statusCode = status
      ..write(text);
    response.close();
  }
}
