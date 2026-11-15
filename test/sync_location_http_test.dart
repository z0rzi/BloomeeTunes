import 'dart:async';
import 'dart:io';

import 'package:Bloomee/services/sync/dropbox_sync_location.dart';
import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:Bloomee/services/sync/webdav_sync_location.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The Sync Locations reached over HTTP, each through [client], as the
/// owner would have them set up.
Map<String, SyncLocation> httpLocations(http.Client client,
        {Duration requestTimeout = const Duration(minutes: 2)}) =>
    {
      'Dropbox': DropboxSyncLocation(
          app: DropboxApp(
              key: 'app key',
              api: Uri.parse('https://api.example.com'),
              content: Uri.parse('https://content.example.com'),
              requestTimeout: requestTimeout,
              client: client),
          refreshToken: 'signed in'),
      'WebDAV': WebDavSyncLocation(
          address: Uri.parse('https://cloud.example.com/dav/bloomee'),
          user: 'owner',
          password: 'secret',
          requestTimeout: requestTimeout,
          client: client),
    };

/// Dropbox's answer to renewing the access token, so that the calls that
/// follow it are the ones put to the test.
http.Response? renewedToken(http.Request request) =>
    request.url.path == '/oauth2/token'
        ? http.Response('{"access_token": "token", "expires_in": 14400}', 200)
        : null;

/// A server answering every call with [status].
http.Client answering(int status) => MockClient(
    (request) async => renewedToken(request) ?? http.Response('', status));

/// A connection failing every call with [error].
http.Client failingWith(Object error) =>
    MockClient((request) async => renewedToken(request) ?? (throw error));

void main() {
  void each(
      String what, http.Client Function() client, Matcher Function() expected,
      {Duration requestTimeout = const Duration(minutes: 2)}) {
    for (final MapEntry(key: adapter, value: location)
        in httpLocations(client(), requestTimeout: requestTimeout).entries) {
      test('$adapter: $what', () async {
        await expectLater(location.list('sync'), expected());
        await expectLater(location.read('sync/a.json'), expected());
        await expectLater(location.write('sync/a.json', [1]), expected());
      });
    }
  }

  Matcher unavailable() => throwsA(isA<SyncLocationUnavailable>());
  Matcher failed() => throwsA(isA<SyncLocationFailed>());

  group('Every Sync Location reached over HTTP, alike:', () {
    each(
        'a server too busy (408) for every call, renewing the sign-in included, is away for now',
        () => MockClient((_) async => http.Response('', 408)),
        unavailable);
    each('a server too busy to answer in time (408) is away for now',
        () => answering(408), unavailable);
    each('a server asking to wait (429) is away for now', () => answering(429),
        unavailable);
    each('a server that is down (5xx) is away for now', () => answering(503),
        unavailable);
    each('a server refusing the request (403) refuses it', () => answering(403),
        failed);
    each(
        'a network that cannot reach it is away for now',
        () => failingWith(const SocketException('No route to host')),
        unavailable);
    each(
        'a dropped connection is away for now',
        () => failingWith(http.ClientException('Connection closed')),
        unavailable);
    each(
        'a refused secure connection (an untrusted certificate, say) refuses it',
        () =>
            failingWith(const HandshakeException('CERTIFICATE_VERIFY_FAILED')),
        failed);
    each(
        'a server that does not answer in time is away for now',
        () => MockClient((request) async =>
            renewedToken(request) ?? await Completer<http.Response>().future),
        unavailable,
        requestTimeout: const Duration(milliseconds: 50));
  });
}
