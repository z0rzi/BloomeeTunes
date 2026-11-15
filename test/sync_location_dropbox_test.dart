import 'dart:convert';
import 'dart:io';

import 'package:Bloomee/services/sync/dropbox_sync_location.dart';
import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dropbox_stand_in.dart';
import 'support/sync_location_contract.dart';

/// The Dropbox app as Bloomee would be built for [standIn].
DropboxApp appFor(DropboxStandIn standIn) => DropboxApp(
    key: standIn.appKey,
    authorizePage: standIn.authorizePage,
    api: standIn.base,
    content: standIn.base);

/// What a writer cut off mid-upload leaves: the request's headers and part of
/// its content, then a closed connection.
Future<void> interruptUpload(
    DropboxStandIn standIn, String path, List<int> partial) async {
  final aborted = standIn.abortedUploads;
  final socket = await Socket.connect(standIn.base.host, standIn.base.port);
  socket.write('POST /2/files/upload HTTP/1.1\r\n'
      'Host: ${standIn.base.authority}\r\n'
      'Authorization: Bearer ${standIn.accessToken()}\r\n'
      'Dropbox-API-Arg: ${jsonEncode({
        'path': '/$path',
        'mode': 'overwrite'
      })}\r\n'
      'Content-Type: application/octet-stream\r\n'
      'Content-Length: ${partial.length * 2 + 10}\r\n'
      '\r\n');
  socket.add(partial);
  await socket.flush();
  socket.destroy();
  await standIn.abortedUploadsReach(aborted + 1);
}

void main() {
  syncLocationContract('Dropbox', () async {
    final standIn = await DropboxStandIn.start();
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final nowhere = Uri.parse('http://127.0.0.1:$port');
    return SyncLocationFixture(
      location: DropboxSyncLocation(
          app: appFor(standIn), refreshToken: standIn.signedInRefreshToken()),
      unreachable: DropboxSyncLocation(
          app: DropboxApp(
              key: standIn.appKey,
              authorizePage: nowhere,
              api: nowhere,
              content: nowhere),
          refreshToken: 'any'),
      signInRefused: DropboxSyncLocation(
          app: appFor(standIn), refreshToken: 'revoked-or-never-issued'),
      interruptWrite: (path, partial) =>
          interruptUpload(standIn, path, partial),
      dispose: standIn.close,
    );
  }, signsIn: true);

  group('Dropbox sign-in', () {
    late DropboxStandIn standIn;
    setUp(() async => standIn = await DropboxStandIn.start());
    tearDown(() => standIn.close());

    test('an expired access token is renewed with the refresh token, unnoticed',
        () async {
      final dropbox = DropboxSyncLocation(
          app: appFor(standIn), refreshToken: standIn.signedInRefreshToken());
      await dropbox.write('sync/a.json', utf8.encode('first'));
      expect(standIn.renewals, 1);

      standIn.expireAccessTokens();

      expect(utf8.decode((await dropbox.read('sync/a.json'))!), 'first');
      expect(standIn.renewals, 2);
    });

    test('an access token about to expire is renewed before it is used',
        () async {
      var now = DateTime.utc(2026, 11, 15, 10);
      final dropbox = DropboxSyncLocation(
          app: appFor(standIn),
          refreshToken: standIn.signedInRefreshToken(),
          clock: () => now);
      await dropbox.list('sync');
      await dropbox.list('sync');
      expect(standIn.renewals, 1);

      now = now.add(standIn.accessTokenLifetime);
      await dropbox.list('sync');

      expect(standIn.renewals, 2);
    });

    test('a revoked sign-in is refused as one the owner must renew', () async {
      final dropbox = DropboxSyncLocation(
          app: appFor(standIn), refreshToken: standIn.signedInRefreshToken());
      await dropbox.list('sync');

      standIn.revokeAll();

      await expectLater(
          dropbox.list('sync'), throwsA(isA<SyncLocationSignInRefused>()));
    });

    test(
        'Dropbox refusing the app rather than the sign-in is not taken for a lost sign-in',
        () async {
      final wrongKey = DropboxApp(
          key: 'another app',
          authorizePage: standIn.authorizePage,
          api: standIn.base,
          content: standIn.base);
      final dropbox = DropboxSyncLocation(
          app: wrongKey, refreshToken: standIn.signedInRefreshToken());

      await expectLater(
          dropbox.list('sync'), throwsA(isA<SyncLocationAppRefused>()));
    });

    test('the pasted code from the Dropbox page gives a lasting sign-in',
        () async {
      final signIn = appFor(standIn).beginSignIn();
      final code = standIn.approve(signIn.page);

      final refreshToken = await signIn.finish(code);
      final dropbox =
          DropboxSyncLocation(app: appFor(standIn), refreshToken: refreshToken);
      await dropbox.write('sync/a.json', utf8.encode('signed in'));

      expect(utf8.decode(standIn.file('/sync/a.json')!), 'signed in');
    });

    test('a code Dropbox did not give, or gave for another sign-in, is refused',
        () async {
      final first = appFor(standIn).beginSignIn();
      final second = appFor(standIn).beginSignIn();
      final code = standIn.approve(first.page);

      await expectLater(
          second.finish(code), throwsA(isA<SyncLocationSignInRefused>()));
      await expectLater(first.finish('made-up code'),
          throwsA(isA<SyncLocationSignInRefused>()));
    });

    test(
        'Bloomee asks only for its app folder files, for lasting access, with no redirect',
        () {
      final page = appFor(standIn).beginSignIn().page;

      expect(page.queryParameters['scope']!.split(' ').toSet(),
          {'files.metadata.read', 'files.content.read', 'files.content.write'});
      expect(page.queryParameters['token_access_type'], 'offline');
      expect(page.queryParameters.containsKey('redirect_uri'), isFalse);
    });

    test('signing out ends the sign-in on Dropbox', () async {
      final refreshToken = standIn.signedInRefreshToken();
      final dropbox =
          DropboxSyncLocation(app: appFor(standIn), refreshToken: refreshToken);

      await dropbox.signOut();

      expect(standIn.isValid(refreshToken), isFalse);
    });
  });

  test('a build without an app key has no Dropbox app', () {
    expect(DropboxApp.fromBuild(), isNull);
  });
}
