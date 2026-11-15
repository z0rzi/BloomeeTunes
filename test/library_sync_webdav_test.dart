import 'dart:convert';
import 'dart:io';

import 'package:Bloomee/blocs/sync/sync_cubit.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/repository/sync/sync_repository.dart';
import 'package:Bloomee/services/sync/credential_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/isar_test_support.dart';
import 'support/sync_test_support.dart';
import 'support/webdav_stand_in.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncWorld world;
  late WebDavStandIn server;
  final cubits = <SyncCubit>[];
  final repositories = <SyncRepository>[];

  setUpAll(() async {
    await initializeTestIsar();
    // The test binding answers every HTTP request with an error; these
    // tests talk to the stand-in on this machine.
    HttpOverrides.global = null;
  });
  setUp(() async {
    world = await SyncWorld.create();
    server = await WebDavStandIn.start();
  });
  tearDown(() async {
    for (final cubit in cubits) {
      await cubit.close();
    }
    for (final repository in repositories) {
      await repository.close();
    }
    cubits.clear();
    repositories.clear();
    await server.close();
    await world.dispose();
  });

  /// The folder on the server the owner syncs in.
  String folder() => server.address('/dav/bloomee').toString();

  /// The app on [device], keeping its credentials in [keyring], offering
  /// WebDAV and, [withFolder], a local folder as well.
  SyncRepository appOn(SyncDevice device, CredentialStore keyring,
      {bool withFolder = false}) {
    final repository = SyncRepository(
      database: Future.value(device.isar),
      backups: device.backups,
      clock: device.clock,
      machineName: () => device.name,
      credentials: keyring,
      locationKinds: [
        SyncLocationKind.webDav,
        if (withFolder) SyncLocationKind.localFolder
      ],
    );
    repositories.add(repository);
    return repository;
  }

  SyncCubit screenOn(SyncRepository repository) {
    final cubit = SyncCubit(repository);
    cubits.add(cubit);
    return cubit;
  }

  /// The owner enters the server's address, their user name and [password]
  /// on [cubit]'s Device.
  Future<SyncLocationProblem?> signIn(SyncCubit cubit,
          {String? address, String? password}) =>
      cubit.signInToWebDav(
          address: address ?? folder(),
          user: server.user,
          password: password ?? server.password);

  /// [device], set up to sync through the WebDAV server from its settings
  /// screen.
  Future<SyncCubit> syncingThroughWebDav(
      SyncDevice device, MemoryKeyring keyring) async {
    final cubit = screenOn(appOn(device, keyring));
    await cubit.load();
    expect(await signIn(cubit), isNull);
    await cubit.choose(const SyncLocationChoice.webDav());
    expect(cubit.state.setupProblem, isNull);
    await cubit.syncNow();
    await pumpEventQueue();
    return cubit;
  }

  test('WebDAV is offered on Linux and Android, after Dropbox', () {
    expect(SyncLocationKind.offeredOn('linux'), [
      SyncLocationKind.dropbox,
      SyncLocationKind.webDav,
      SyncLocationKind.localFolder
    ]);
    expect(SyncLocationKind.offeredOn('android'), [
      SyncLocationKind.dropbox,
      SyncLocationKind.webDav,
      SyncLocationKind.localFolder
    ]);
  });

  test(
      'two Devices sync through one WebDAV server, each given its address, user name and password',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone', enabled: false);
    await laptop.add('Road trip', [song('yt::1'), song('yt::2')]);

    final onLaptop = await syncingThroughWebDav(laptop, MemoryKeyring());
    final onPhone = await syncingThroughWebDav(phone, MemoryKeyring());

    expect(await phone.songsOf('Road trip'), ['yt::1', 'yt::2']);
    expect(onLaptop.state.webDavSignedIn, isTrue);
    expect(onPhone.state.setup.locationKind, SyncLocationKind.webDav);
    expect(onPhone.state.setup.webDavAddress, folder());
    expect(onPhone.state.setup.webDavUser, server.user);
    expect(server.paths.where((p) => p.startsWith('/dav/bloomee/sync/')),
        hasLength(2));
  });

  test('after a restart, the Device still syncs, its password from the keyring',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone', enabled: false);
    final keyring = MemoryKeyring();
    final onLaptop = await syncingThroughWebDav(laptop, keyring);
    await onLaptop.close();
    await repositories.removeLast().close();
    final onPhone = await syncingThroughWebDav(phone, MemoryKeyring());

    world.clock.advance(const Duration(minutes: 5));
    await phone.add('Focus', [song('yt::3')]);
    await onPhone.syncNow();
    final restarted = appOn(laptop, keyring);
    await restarted.start();

    expect(await laptop.songsOf('Focus'), ['yt::3']);
    expect(restarted.status.lastError, isNull);
  });

  test(
      'a keyring that cannot be read at startup raises an alert, as well as the status line',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final onLaptop = await syncingThroughWebDav(laptop, MemoryKeyring());
    await onLaptop.close();
    await repositories.removeLast().close();

    final restarted = appOn(laptop, LockedKeyring());
    final screen = screenOn(restarted);
    await restarted.start();
    await pumpEventQueue();

    expect(restarted.status.lastError, isA<SyncKeyringUnavailable>());
    expect(screen.state.alerts, [const KeyringUnavailableAlert()]);
  });

  test(
      'a plain http address on another machine is refused before the password is sent anywhere',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final keyring = MemoryKeyring();
    final cubit = screenOn(appOn(laptop, keyring));
    await cubit.load();

    expect(await signIn(cubit, address: 'http://cloud.example.com/dav'),
        SyncLocationProblem.insecureAddress);
    expect(await signIn(cubit, address: 'cloud.example.com/dav'),
        SyncLocationProblem.invalidAddress);

    expect(keyring.values, isEmpty);
    expect(cubit.state.webDavSignedIn, isFalse);
    expect(cubit.state.setup.enabled, isFalse);
  });

  test('a wrong password is refused at setup, and sync stays off', () async {
    final laptop = await world.device('laptop', enabled: false);
    final keyring = MemoryKeyring();
    final cubit = screenOn(appOn(laptop, keyring));
    await cubit.load();

    expect(await signIn(cubit, password: 'not the password'),
        SyncLocationProblem.signInRefused);

    expect(keyring.values, isEmpty);
    expect(cubit.state.webDavSignedIn, isFalse);
    expect(cubit.state.setup.enabled, isFalse);
  });

  test(
      'a server whose secure connection is refused at setup says so, apart from one that cannot be reached',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await cubit.load();

    // Speaking TLS to the plain stand-in fails the handshake, as an
    // untrusted or expired certificate does.
    final https = server.base.replace(scheme: 'https', path: '/dav/bloomee');
    expect(await signIn(cubit, address: https.toString()),
        SyncLocationProblem.refused);
    expect(cubit.state.webDavSignedIn, isFalse);
  });

  test('a server that cannot be reached at setup says so', () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await cubit.load();
    server.answerEverythingWith = 503;

    expect(await signIn(cubit), SyncLocationProblem.notFound);
    expect(cubit.state.webDavSignedIn, isFalse);
  });

  test(
      'the password is kept in the keyring, and never in the database, a Device State or a Location Backup',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final keyring = MemoryKeyring();
    await laptop.add('Road trip', [song('yt::1')]);
    await syncingThroughWebDav(laptop, keyring);
    final credentials =
        base64.encode(utf8.encode('${server.user}:${server.password}'));

    expect(keyring.values.values, contains(server.password));
    final published = server.paths;
    expect(published.where((p) => p.startsWith('/dav/bloomee/sync/')),
        hasLength(1));
    expect(published.where((p) => p.startsWith('/dav/bloomee/backups/')),
        hasLength(1));
    for (final path in published) {
      final content = utf8.decode(server.file(path)!);
      expect(content, isNot(contains(server.password)), reason: path);
      expect(content, isNot(contains(credentials)), reason: path);
    }
    final database = latin1.decode(await File(laptop.isar.path!).readAsBytes());
    expect(database, isNot(contains(server.password)));
    expect(database, isNot(contains(credentials)));
  });

  test(
      'a password the server no longer accepts stops sync with an alert; entering it again resumes it',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone', enabled: false);
    final cubit = await syncingThroughWebDav(laptop, MemoryKeyring());

    server.password = 'changed on the server';
    world.clock.advance(const Duration(minutes: 5));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.syncNow();
    await pumpEventQueue();

    expect(cubit.state.status.lastError, isA<SyncSignInNeeded>());
    expect(
        cubit.state.alerts, [const SignInNeededAlert(SyncLocationKind.webDav)]);
    final requests = server.requests;
    await cubit.syncNow();
    await pumpEventQueue();
    expect(server.requests, requests, reason: 'sync stopped');
    expect(
        cubit.state.alerts, [const SignInNeededAlert(SyncLocationKind.webDav)],
        reason: 'the owner is asked once');

    expect(await signIn(cubit), isNull);
    await pumpEventQueue();
    await syncingThroughWebDav(phone, MemoryKeyring());

    expect(await phone.songsOf('Road trip'), ['yt::1']);
    expect(cubit.state.setup.enabled, isTrue);
  });

  test('a server that cannot be reached for now is retried quietly', () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone', enabled: false);
    final cubit = await syncingThroughWebDav(laptop, MemoryKeyring());

    server.answerEverythingWith = 503;
    world.clock.advance(const Duration(minutes: 5));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.syncNow();
    await pumpEventQueue();

    expect(cubit.state.status.lastError, isA<SyncLocationUnreachable>());
    expect(cubit.state.alerts, isEmpty);
    expect(cubit.state.setup.enabled, isTrue);

    server.answerEverythingWith = null;
    await cubit.syncNow();
    await syncingThroughWebDav(phone, MemoryKeyring());
    expect(await phone.songsOf('Road trip'), ['yt::1']);
    expect(cubit.state.alerts, isEmpty);
  });

  test(
      'with sync off, setting up a WebDAV server from its choice turns sync on with it',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.load();

    expect(await signIn(cubit), isNull);
    await cubit.choose(const SyncLocationChoice.webDav(),
        deviceName: 'Kitchen laptop');
    await cubit.syncNow();

    expect(cubit.state.setupProblem, isNull);
    expect(cubit.state.setup.enabled, isTrue);
    expect(cubit.state.setup.locationKind, SyncLocationKind.webDav);
    expect(cubit.state.setup.deviceName, 'Kitchen laptop');
    final state =
        server.paths.singleWhere((p) => p.startsWith('/dav/bloomee/sync/'));
    expect(utf8.decode(server.file(state)!), contains('yt::1'));
  });

  test(
      'with sync off, a WebDAV server that cannot be used once signed in says why and leaves sync off',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await cubit.load();

    expect(await signIn(cubit), isNull);
    server.answerEverythingWith = 503;
    await cubit.choose(const SyncLocationChoice.webDav());

    expect(cubit.state.setupProblem, SyncLocationProblem.notFound);
    expect(cubit.state.setup.enabled, isFalse);
  });

  test(
      'signing out removes the password from the Device and turns off sync through WebDAV, as turning off does',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final keyring = MemoryKeyring();
    await laptop.add('Road trip', [song('yt::1')]);
    final cubit = await syncingThroughWebDav(laptop, keyring);
    final published = {for (final p in server.paths) p: server.file(p)};
    final requests = server.requests;

    expect(await cubit.signOutOf(SyncLocationKind.webDav), isTrue);

    expect(keyring.values, isEmpty);
    expect(cubit.state.webDavSignedIn, isFalse);
    expect(cubit.state.setup.enabled, isFalse,
        reason: 'sync cannot go on through WebDAV once signed out');
    expect(cubit.state.setup.everEnabled, isTrue,
        reason: 'this Device keeps its identity, as when turned off');
    expect(await laptop.songsOf('Road trip'), ['yt::1']);
    expect({for (final p in server.paths) p: server.file(p)}, published,
        reason: 'the Device State is left as it is');
    await laptop.add('Focus', [song('yt::2')]);
    await cubit.syncNow();
    await pumpEventQueue();
    expect(server.requests, requests, reason: 'nothing more is sent');
  });

  test(
      'a sign-out the keyring refuses says so and changes nothing: sync goes on through WebDAV',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final keyring = MemoryKeyring();
    final cubit = await syncingThroughWebDav(laptop, keyring);
    keyring.refusesChanges = true;

    expect(await cubit.signOutOf(SyncLocationKind.webDav), isFalse);

    expect(keyring.values.values, contains(server.password));
    expect(cubit.state.webDavSignedIn, isTrue);
    expect(cubit.state.setup.enabled, isTrue);
    world.clock.advance(const Duration(minutes: 5));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.syncNow();
    expect(cubit.state.status.lastError, isNull);
    final state =
        server.paths.singleWhere((p) => p.startsWith('/dav/bloomee/sync/'));
    expect(utf8.decode(server.file(state)!), contains('yt::1'));
  });

  test(
      'signing out of WebDAV while a local folder is the Sync Location only removes the password; sync goes on',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final keyring = MemoryKeyring();
    final cubit = screenOn(appOn(laptop, keyring, withFolder: true));
    await cubit.load();
    expect(await signIn(cubit), isNull);
    await cubit.choose(SyncLocationChoice.folder(world.locationPath));
    await cubit.syncNow();

    expect(await cubit.signOutOf(SyncLocationKind.webDav), isTrue);

    expect(keyring.values, isEmpty);
    expect(cubit.state.webDavSignedIn, isFalse);
    expect(cubit.state.setup.enabled, isTrue);
    expect(cubit.state.setup.locationKind, SyncLocationKind.localFolder);
    world.clock.advance(const Duration(minutes: 5));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.syncNow();
    expect(cubit.state.status.lastError, isNull);
    final state = (await filesIn(world.locationPath))
        .entries
        .singleWhere((file) => file.key.startsWith('sync/'));
    expect(utf8.decode(state.value), contains('yt::1'),
        reason: 'the folder still gets this Device\'s changes');
  });

  test(
      'moving from a local folder to WebDAV publishes there and leaves the folder untouched',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring(), withFolder: true));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.load();
    await cubit.choose(SyncLocationChoice.folder(world.locationPath));
    await cubit.syncNow();
    final inFolder = await filesIn(world.locationPath);

    expect(await signIn(cubit), isNull);
    await cubit.choose(const SyncLocationChoice.webDav());
    await cubit.syncNow();

    expect(cubit.state.setup.locationKind, SyncLocationKind.webDav);
    expect(await filesIn(world.locationPath), inFolder);
    expect(server.paths.where((p) => p.startsWith('/dav/bloomee/sync/')),
        hasLength(1));
  });
}
