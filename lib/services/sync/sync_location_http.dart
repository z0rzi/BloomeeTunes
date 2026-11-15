import 'dart:async';
import 'dart:io';

import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// How the Sync Locations reached over HTTP (Dropbox, WebDAV) talk to their
/// server, and what its failures mean, the same way for each:
///
/// - the server cannot be reached, the connection drops, or it does not
///   answer within [requestTimeout]: [SyncLocationUnavailable] (sync tries
///   again later);
/// - the secure connection is refused (an untrusted, self-signed or expired
///   certificate, say), which waiting does not fix: [SyncLocationFailed];
/// - an answer that is not the one expected: see [unexpected].
class SyncLocationHttp {
  /// How long one call may take before the server counts as unreachable.
  static const defaultRequestTimeout = Duration(minutes: 2);

  /// How long connecting may take.
  static const connectionTimeout = Duration(seconds: 20);

  /// The server, as messages name it ("Dropbox", "The WebDAV server").
  final String server;
  final Duration requestTimeout;
  final http.Client client;

  SyncLocationHttp(this.server,
      {this.requestTimeout = defaultRequestTimeout, http.Client? client})
      : client = client ??
            IOClient(HttpClient()..connectionTimeout = connectionTimeout);

  /// Sends [request] and reads its answer, reporting a failure to get one
  /// as described above.
  Future<http.Response> send(http.BaseRequest request) async {
    try {
      return await http.Response.fromStream(
              await client.send(request).timeout(requestTimeout))
          .timeout(requestTimeout);
    } on TimeoutException {
      throw SyncLocationUnavailable('$server did not answer in time.');
    } on TlsException catch (error) {
      throw SyncLocationFailed('$server refused the secure connection: $error');
    } on IOException catch (error) {
      throw SyncLocationUnavailable('$server cannot be reached: $error');
    } on http.ClientException catch (error) {
      throw SyncLocationUnavailable('$server cannot be reached: $error');
    }
  }

  /// Sends a `POST` of [body] (a [String], bytes, or a form as a map) to
  /// [url], as [send] does.
  Future<http.Response> post(Uri url,
      {Map<String, String> headers = const {}, Object? body}) {
    final request = http.Request('POST', url)..headers.addAll(headers);
    switch (body) {
      case null:
        break;
      case String text:
        request.body = text;
      case List<int> bytes:
        request.bodyBytes = bytes;
      case Map<String, String> form:
        request.bodyFields = form;
      default:
        throw ArgumentError.value(body, 'body', 'Not a request body');
    }
    return send(request);
  }

  /// What an answer of [status] that is not the one expected means: the
  /// server is too busy, or down (408, 429, 5xx: [SyncLocationUnavailable],
  /// try again later), or it refused the operation ([SyncLocationFailed]).
  /// [detail] tells which call it was, or what the server said.
  SyncLocationException unexpected(int status, String detail) {
    if (status == 408 || status == 429 || status >= 500) {
      return SyncLocationUnavailable(
          '$server is not available now ($status$detail).');
    }
    return SyncLocationFailed(
        '$server refused the operation ($status$detail).');
  }
}
