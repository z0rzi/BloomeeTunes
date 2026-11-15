import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A small WebDAV server standing in for the owner's own, started inside a
/// test. It answers the calls Bloomee makes (PROPFIND, GET, PUT, DELETE,
/// MKCOL and MOVE) under basic authentication, for one user, and never
/// reaches a real server.
///
/// Its uploads are as naive as a server may be: a PUT writes into the file
/// as its content arrives, so a reader during an upload sees part of it, and
/// a cut-off upload leaves the part received. Only its MOVE replaces a file
/// in one step.
class WebDavStandIn {
  /// The collection the server shares; it exists from the start.
  static const root = '/dav';

  final String user;

  /// The password the server accepts now; the owner may change it.
  String password;

  final HttpServer _server;

  /// Collections by path (decoded, without a trailing slash).
  final Set<String> _collections = {root};

  /// File content by path (decoded); a file being uploaded grows here.
  final Map<String, BytesBuilder> _files = {};

  final List<Completer<void>> _abortedUploadWaiters = [];

  /// How many requests it received.
  int requests = 0;

  /// How many uploads were cut short before all their content arrived.
  int abortedUploads = 0;

  /// The Authorization header of every request it received.
  final List<String> authorizations = [];

  /// The status every request is answered with instead, while set (such as
  /// 503 while the server is down for maintenance).
  int? answerEverythingWith;

  /// Whether deleting a file fails (with 503), as when the connection drops
  /// again before a cleanup.
  bool failDeletes = false;

  int? _cutNextUploadAfter;

  WebDavStandIn._(this._server, {required this.user, required this.password}) {
    _server.listen(_handle);
  }

  static Future<WebDavStandIn> start(
      {String user = 'owner', String password = 'stand-in password'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return WebDavStandIn._(server, user: user, password: password);
  }

  /// The server's address, `http://localhost:<port>`.
  Uri get base => Uri.parse('http://localhost:${_server.port}');

  /// The address of [path] on the server, such as `/dav/bloomee`.
  Uri address(String path) => base.replace(path: path);

  /// The content of the file at [path], if any.
  Uint8List? file(String path) => _files[path]?.toBytes();

  /// The paths of every file on the server.
  List<String> get paths => _files.keys.toList()..sort();

  bool hasCollection(String path) => _collections.contains(path);

  /// The next upload's connection drops once [bytes] of its content arrived,
  /// leaving that much in the file.
  void cutNextUploadAfter(int bytes) => _cutNextUploadAfter = bytes;

  /// Completes once [count] uploads in all were cut short.
  Future<void> abortedUploadsReach(int count) {
    if (abortedUploads >= count) return Future.value();
    final waiter = Completer<void>();
    _abortedUploadWaiters.add(waiter);
    return waiter.future.then((_) => abortedUploadsReach(count));
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    requests++;
    try {
      authorizations
          .add(request.headers.value(HttpHeaders.authorizationHeader) ?? '');
      if (answerEverythingWith case final status?) {
        await request.drain<void>();
        return _reply(request.response, status);
      }
      if (!_authorised(request)) {
        await request.drain<void>();
        request.response.headers
            .set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="stand-in"');
        return _reply(request.response, 401);
      }
      final path = _pathOf(request.uri);
      if (path != root && !path.startsWith('$root/')) {
        await request.drain<void>();
        return _reply(request.response, 403);
      }
      switch (request.method) {
        case 'PROPFIND':
          return await _propfind(request, path);
        case 'GET':
          await request.drain<void>();
          final found = _files[path];
          if (found == null) return _reply(request.response, 404);
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.binary
            ..add(found.toBytes());
          return await request.response.close();
        case 'PUT':
          return await _put(request, path);
        case 'DELETE':
          await request.drain<void>();
          if (failDeletes) return _reply(request.response, 503);
          if (_files.remove(path) != null) return _reply(request.response, 204);
          if (_collections.contains(path) && path != root) {
            _collections
                .removeWhere((c) => c == path || c.startsWith('$path/'));
            _files.removeWhere((f, _) => f.startsWith('$path/'));
            return _reply(request.response, 204);
          }
          return _reply(request.response, 404);
        case 'MKCOL':
          await request.drain<void>();
          if (_collections.contains(path) || _files.containsKey(path)) {
            return _reply(request.response, 405);
          }
          if (!_collections.contains(_parentOf(path))) {
            return _reply(request.response, 409);
          }
          _collections.add(path);
          return _reply(request.response, 201);
        case 'MOVE':
          await request.drain<void>();
          return _move(request, path);
        default:
          await request.drain<void>();
          return _reply(request.response, 405);
      }
    } catch (error) {
      try {
        _reply(request.response, 500);
      } catch (_) {
        // The connection is gone.
      }
    }
  }

  bool _authorised(HttpRequest request) {
    final header = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!header.startsWith('Basic ')) return false;
    try {
      return utf8.decode(base64.decode(header.substring(6))) ==
          '$user:$password';
    } on FormatException {
      return false;
    }
  }

  static String _pathOf(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty);
    return '/${segments.join('/')}';
  }

  static String _parentOf(String path) =>
      path.substring(0, path.lastIndexOf('/'));

  Future<void> _propfind(HttpRequest request, String path) async {
    await request.drain<void>();
    final depth = request.headers.value('Depth') ?? 'infinity';
    final entries = <(String, bool)>[];
    if (_files.containsKey(path)) {
      entries.add((path, false));
    } else if (_collections.contains(path)) {
      entries.add((path, true));
      if (depth != '0') {
        for (final collection in _collections) {
          if (_parentOf(collection) == path && collection != path) {
            entries.add((collection, true));
          }
        }
        for (final file in _files.keys) {
          if (_parentOf(file) == path) entries.add((file, false));
        }
      }
    } else {
      return _reply(request.response, 404);
    }
    // Hrefs as servers often write them: absolute paths, each segment
    // percent-encoded, collections with a trailing slash.
    String href(String entry, bool collection) => '/${Uri(pathSegments: [
              ...entry.substring(1).split('/'),
              if (collection) ''
            ])}';
    final body = StringBuffer(
        '<?xml version="1.0" encoding="utf-8"?>\n<D:multistatus xmlns:D="DAV:">');
    for (final (entry, collection) in entries) {
      body.write('<D:response><D:href>${href(entry, collection)}</D:href>'
          '<D:propstat><D:prop><D:resourcetype>'
          '${collection ? '<D:collection/>' : ''}'
          '</D:resourcetype></D:prop>'
          '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>');
    }
    body.write('</D:multistatus>');
    request.response
      ..statusCode = 207
      ..headers.contentType =
          ContentType('application', 'xml', charset: 'utf-8')
      ..write(body);
    await request.response.close();
  }

  Future<void> _put(HttpRequest request, String path) async {
    if (!_collections.contains(_parentOf(path))) {
      await request.drain<void>();
      return _reply(request.response, 409);
    }
    if (_collections.contains(path)) {
      await request.drain<void>();
      return _reply(request.response, 405);
    }
    final cutAfter = _cutNextUploadAfter;
    _cutNextUploadAfter = null;
    final content = BytesBuilder();
    _files[path] = content;
    final done = Completer<bool>();
    late final StreamSubscription<List<int>> subscription;
    subscription = request.listen(
      (chunk) {
        if (cutAfter != null && content.length + chunk.length >= cutAfter) {
          content.add(chunk.sublist(0, cutAfter - content.length));
          subscription.cancel();
          if (!done.isCompleted) done.complete(false);
          return;
        }
        content.add(chunk);
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete(false);
      },
      onDone: () {
        if (!done.isCompleted) {
          done.complete(request.contentLength < 0 ||
              content.length == request.contentLength);
        }
      },
      cancelOnError: true,
    );
    if (!await done.future) {
      // The part received stays, as a naive server leaves it.
      if (cutAfter != null) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
      }
      _uploadAborted();
      return;
    }
    return _reply(request.response, 201);
  }

  void _move(HttpRequest request, String path) {
    final destinationHeader = request.headers.value('Destination');
    if (destinationHeader == null) return _reply(request.response, 400);
    final destination = _pathOf(Uri.parse(destinationHeader));
    final overwrite = request.headers.value('Overwrite') != 'F';
    final moved = _files[path];
    if (moved == null) return _reply(request.response, 404);
    if (!_collections.contains(_parentOf(destination))) {
      return _reply(request.response, 409);
    }
    final existed = _files.containsKey(destination);
    if (existed && !overwrite) return _reply(request.response, 412);
    _files.remove(path);
    _files[destination] = moved;
    _reply(request.response, existed ? 204 : 201);
  }

  void _uploadAborted() {
    abortedUploads++;
    for (final waiter in _abortedUploadWaiters) {
      waiter.complete();
    }
    _abortedUploadWaiters.clear();
  }

  static void _reply(HttpResponse response, int status) {
    response.statusCode = status;
    response.close();
  }
}
