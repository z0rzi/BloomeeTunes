import 'dart:convert';
import 'dart:io';

import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:Bloomee/services/sync/webdav_sync_location.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sync_location_contract.dart';
import 'support/webdav_stand_in.dart';

/// Bloomee's WebDAV Sync Location at [path] on [standIn], signed in with
/// [password] (the right one by default).
WebDavSyncLocation webDavOn(WebDavStandIn standIn,
        {String path = '/dav/bloomee', String? password}) =>
    WebDavSyncLocation(
        address: standIn.address(path),
        user: standIn.user,
        password: password ?? standIn.password);

/// What a writer whose connection dropped mid-upload leaves: the server
/// keeps the [partial] content it received.
Future<void> interruptUpload(WebDavStandIn standIn, SyncLocation location,
    String path, List<int> partial) async {
  final aborted = standIn.abortedUploads;
  standIn.cutNextUploadAfter(partial.length);
  try {
    await location.write(path, [...partial, ...List.filled(64, 0x2e)]);
    fail('The upload was meant to be cut off.');
  } on SyncLocationException {
    // The connection dropped.
  }
  await standIn.abortedUploadsReach(aborted + 1);
}

void main() {
  syncLocationContract('WebDAV', () async {
    final standIn = await WebDavStandIn.start();
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final location = webDavOn(standIn);
    return SyncLocationFixture(
      location: location,
      unreachable: WebDavSyncLocation(
          address: Uri.parse('http://localhost:$port/dav/bloomee'),
          user: standIn.user,
          password: standIn.password),
      signInRefused: webDavOn(standIn, password: 'not the password'),
      interruptWrite: (path, partial) =>
          interruptUpload(standIn, location, path, partial),
      dispose: standIn.close,
    );
  }, signsIn: true);

  group('WebDAV', () {
    late WebDavStandIn standIn;
    setUp(() async => standIn = await WebDavStandIn.start());
    tearDown(() => standIn.close());

    test('the folders it needs are created when they are missing', () async {
      final webDav = webDavOn(standIn, path: '/dav/music/bloomee');

      await webDav.checkReachable();
      expect(standIn.hasCollection('/dav/music/bloomee'), isTrue);

      await webDav.write('backups/today.json', utf8.encode('backup'));
      expect(
          utf8.decode(standIn.file('/dav/music/bloomee/backups/today.json')!),
          'backup');
    });

    test('names with spaces and accents travel intact', () async {
      final webDav = webDavOn(standIn, path: '/dav/Bloomée sync');
      const name = '2026-11-15 Téléphone #2.json';

      await webDav.write('backups/$name', utf8.encode('backup'));

      expect(await webDav.list('backups'), [name]);
      expect(utf8.decode((await webDav.read('backups/$name'))!), 'backup');
      expect(standIn.paths, ['/dav/Bloomée sync/backups/$name']);
    });

    test('a partial upload the server kept is never listed nor read', () async {
      final webDav = webDavOn(standIn);
      await webDav.write('sync/a.json', utf8.encode('complete'));
      standIn.failDeletes = true;

      await interruptUpload(
          standIn, webDav, 'sync/a.json', utf8.encode('half'));

      expect(standIn.paths.where((p) => p.startsWith('/dav/bloomee/sync/')),
          hasLength(2),
          reason: 'the server kept the part it received');
      expect(await webDav.list('sync'), ['a.json']);
      expect(utf8.decode((await webDav.read('sync/a.json'))!), 'complete');
    });

    test('a server that is down for now is unreachable, not refusing',
        () async {
      final webDav = webDavOn(standIn);
      standIn.answerEverythingWith = 503;

      await expectLater(
          webDav.list('sync'), throwsA(isA<SyncLocationUnavailable>()));
      await expectLater(
          webDav.checkReachable(), throwsA(isA<SyncLocationUnavailable>()));
    });

    test(
        'a server whose certificate is refused is reported as failing, not as away for now',
        () async {
      // Speaking TLS to the plain stand-in fails the handshake, as an
      // untrusted or expired certificate does.
      final webDav = WebDavSyncLocation(
          address: standIn.base.replace(scheme: 'https', path: '/dav/bloomee'),
          user: standIn.user,
          password: standIn.password);

      await expectLater(
          webDav.list('sync'), throwsA(isA<SyncLocationFailed>()));
    });

    test('the password is never sent to a plain http address on another host',
        () {
      for (final address in [
        'http://example.com/dav',
        'http://192.168.1.20/dav',
        'http://localhost.example.com/dav',
      ]) {
        expect(WebDavSyncLocation.isProtected(Uri.parse(address)), isFalse,
            reason: address);
        expect(
            () => WebDavSyncLocation(
                address: Uri.parse(address), user: 'owner', password: 'secret'),
            throwsArgumentError,
            reason: address);
      }
    });

    test('https addresses, and plain http on localhost, are accepted', () {
      for (final address in [
        'https://cloud.example.com/remote.php/dav/files/owner/Bloomee',
        'http://localhost:8080/dav',
        'http://127.0.0.1/dav',
      ]) {
        final parsed = WebDavSyncLocation.parseAddress(address);
        expect(parsed, isNotNull, reason: address);
        expect(WebDavSyncLocation.isProtected(parsed!), isTrue,
            reason: address);
        WebDavSyncLocation(address: parsed, user: 'owner', password: 'secret');
      }
    });

    test('what is not a server address is not taken for one', () {
      for (final text in [
        '',
        'cloud.example.com/dav',
        'ftp://example.com',
        'https://'
      ]) {
        expect(WebDavSyncLocation.parseAddress(text), isNull, reason: text);
      }
    });
  });
}
