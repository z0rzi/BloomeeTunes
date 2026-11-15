import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:Bloomee/services/sync/sync_location_http.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// A folder on a WebDAV server as a Sync Location, signed in to with a user
/// name and password (basic authentication).
///
/// The password is only ever sent protected: the address must be `https`,
/// except on this machine (`localhost`). The folder, and the folders inside
/// it, are created when missing.
///
/// A WebDAV server may show an upload while it arrives, so a write goes to a
/// hidden temporary file beside its target (see [SyncTemporaryFiles]) and is
/// then moved into place: a reader sees the previous file or the new one,
/// never part of it. Failures are reported as [SyncLocationHttp] says.
class WebDavSyncLocation implements SyncLocation {
  /// The folder synced in, without a trailing slash.
  final Uri address;
  final String user;
  final String _authorization;
  final SyncLocationHttp _http;

  /// Throws [ArgumentError] for an address the password must not be sent
  /// to (see [isProtected]).
  WebDavSyncLocation({
    required Uri address,
    required this.user,
    required String password,
    Duration requestTimeout = SyncLocationHttp.defaultRequestTimeout,
    http.Client? client,
  })  : address = _normalised(address),
        _authorization =
            'Basic ${base64.encode(utf8.encode('$user:$password'))}',
        _http = SyncLocationHttp('The WebDAV server',
            requestTimeout: requestTimeout, client: client) {
    if (!isProtected(address)) {
      throw ArgumentError.value(address, 'address',
          'Only https, or http on localhost, protects the password');
    }
  }

  /// The address the owner typed, when it is one: `http` or `https`, with a
  /// host. Whether it [isProtected] is another matter.
  static Uri? parseAddress(String text) {
    final address = Uri.tryParse(text.trim());
    if (address == null ||
        !(address.isScheme('https') || address.isScheme('http')) ||
        address.host.isEmpty) {
      return null;
    }
    return address;
  }

  /// Whether a password sent to [address] is protected: it uses `https`, or
  /// plain `http` to this machine (`localhost`, or a loopback address).
  static bool isProtected(Uri address) {
    if (address.isScheme('https')) return true;
    if (!address.isScheme('http')) return false;
    final host = address.host.toLowerCase();
    return host == 'localhost' ||
        (InternetAddress.tryParse(host)?.isLoopback ?? false);
  }

  static Uri _normalised(Uri address) => Uri(
      scheme: address.scheme.toLowerCase(),
      host: address.host,
      port: address.hasPort ? address.port : null,
      pathSegments: address.pathSegments.where((s) => s.isNotEmpty));

  List<String> get _base => address.pathSegments;

  /// The address of the file or folder at [segments] inside [address].
  Uri _url(List<String> segments, {bool folder = false}) =>
      address.replace(pathSegments: [..._base, ...segments, if (folder) '']);

  @override
  Future<List<String>> list(String directory) async {
    final inside = syncPathSegments(directory);
    final folder = [..._base, ...inside];
    final response = await _propfind(inside, depth: 1);
    if (response.statusCode == 404) return [];
    _expect(response, const {207});
    final names = <String>[];
    for (final (segments, isFolder) in _entries(response)) {
      if (isFolder || segments.length != folder.length + 1) continue;
      if (!_startsWith(segments, folder)) continue;
      final name = segments.last;
      if (!SyncTemporaryFiles.isTemporary(name)) names.add(name);
    }
    return names;
  }

  @override
  Future<Uint8List?> read(String path) async {
    final response = await _send('GET', _url(syncPathSegments(path)));
    if (response.statusCode == 404 || response.statusCode == 410) return null;
    return _expect(response, const {200}).bodyBytes;
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    final segments = syncPathSegments(path);
    final directory = segments.sublist(0, segments.length - 1);
    final temporary =
        _url([...directory, SyncTemporaryFiles.nameFor(segments.last)]);
    Future<http.Response> upload() => _send('PUT', temporary,
        headers: {HttpHeaders.contentTypeHeader: 'application/octet-stream'},
        body: bytes);
    try {
      var response = await upload();
      if (response.statusCode == 409 || response.statusCode == 404) {
        await _createFolder([..._base, ...directory]);
        response = await upload();
      }
      _expect(response, const {200, 201, 204});
      _expect(
          await _send('MOVE', temporary, headers: {
            'Destination': _url(segments).toString(),
            'Overwrite': 'T',
          }),
          const {200, 201, 204});
    } catch (_) {
      try {
        await _send('DELETE', temporary);
      } on SyncLocationException {
        // Left behind, but never listed.
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(String path) async {
    final response = await _send('DELETE', _url(syncPathSegments(path)));
    if (response.statusCode == 404) return;
    _expect(response, const {200, 202, 204});
  }

  @override
  Future<void> checkReachable() async {
    final response = await _propfind(const [], depth: 0);
    if (response.statusCode == 404) return _createFolder(_base);
    _expect(response, const {207});
  }

  /// Creates the folder at [segments] (from the server's root), and the
  /// folders above it that are missing.
  Future<void> _createFolder(List<String> segments) async {
    if (segments.isEmpty) {
      throw const SyncLocationFailed(
          'The WebDAV server has no folder to create the Sync Location in.');
    }
    final url = address.replace(pathSegments: [...segments, '']);
    var response = await _send('MKCOL', url);
    if (response.statusCode == 409) {
      await _createFolder(segments.sublist(0, segments.length - 1));
      response = await _send('MKCOL', url);
    }
    // 405: it is there already.
    _expect(response, const {200, 201, 405});
  }

  /// Asks what the folder at [segments] (inside [address]) is, and with
  /// [depth] 1 what it holds: of each, only whether it is a folder.
  Future<http.Response> _propfind(List<String> segments,
          {required int depth}) =>
      _send('PROPFIND', _url(segments, folder: true),
          headers: {
            'Depth': '$depth',
            HttpHeaders.contentTypeHeader: 'application/xml'
          },
          body: utf8.encode('<?xml version="1.0" encoding="utf-8"?>'
              '<D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/></D:prop>'
              '</D:propfind>'));

  /// The entries of a PROPFIND answer: each one's path (decoded segments,
  /// from the server's root) and whether it is a folder.
  static List<(List<String>, bool)> _entries(http.Response response) {
    try {
      final document = XmlDocument.parse(utf8.decode(response.bodyBytes));
      return [
        for (final entry in document.descendantElements.where(
            (e) => e.localName == 'response' && e.namespaceUri == 'DAV:'))
          if (entry.descendantElements
                  .where((e) => e.localName == 'href')
                  .firstOrNull
                  ?.innerText
                  .trim()
              case final href? when href.isNotEmpty)
            (
              Uri.parse(href).pathSegments.where((s) => s.isNotEmpty).toList(),
              entry.descendantElements.any((e) =>
                  e.localName == 'collection' && e.namespaceUri == 'DAV:')
            )
      ];
    } on FormatException catch (error) {
      throw SyncLocationFailed(
          'The WebDAV server gave an unreadable answer: $error');
    } on XmlException catch (error) {
      throw SyncLocationFailed(
          'The WebDAV server gave an unreadable answer: $error');
    }
  }

  static bool _startsWith(List<String> segments, List<String> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (segments[i] != prefix[i]) return false;
    }
    return true;
  }

  /// Sends one call, without following redirects, reporting a refused
  /// password as [SyncLocationSignInRefused].
  Future<http.Response> _send(String method, Uri url,
      {Map<String, String> headers = const {}, List<int>? body}) async {
    final request = http.Request(method, url)
      ..followRedirects = false
      ..headers.addAll(headers)
      ..headers[HttpHeaders.authorizationHeader] = _authorization;
    if (body != null) request.bodyBytes = body;
    final response = await _http.send(request);
    if (response.statusCode == 401) {
      throw SyncLocationSignInRefused(
          'The WebDAV server refused the user name and password of $user.');
    }
    return response;
  }

  /// [response] when its status is one of [expected]; otherwise what it
  /// means as an exception (see [SyncLocationHttp.unexpected]).
  http.Response _expect(http.Response response, Set<int> expected) {
    if (expected.contains(response.statusCode)) return response;
    final request = response.request;
    throw _http.unexpected(response.statusCode,
        request == null ? '' : ' ${request.method} ${request.url.path}');
  }
}
