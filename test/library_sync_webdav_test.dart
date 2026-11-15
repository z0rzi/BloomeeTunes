import 'dart:convert';
import 'dart:io';

import 'package:Bloomee/blocs/sync/sync_cubit.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/repository/sync/sync_repository.dart';
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

  /// The app on [device], keeping its credentials in [keyring].
  SyncRepository appOn(SyncDevice device, MemoryKeyring keyring) {
    final repository = SyncRepository(
      database: Future.value(device.isar),
      backups: device.backups,
      clock: device.clock,
      machineName: () => device.name,
      credentials: keyring,
      locationKinds: const [SyncLocationKind.webDav],
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
    await cubit.enableWebDav();
    expect(cubit.state.setupProblem, isNull);
    await cubit.syncNow();
    await pumpEventQueue();
    return cubit;
  }

  test('WebDAV is offered on Linux and Android, after Dropbox', () {
    expect(SyncLocationKind.offeredOn('linux', dropbox: true), [
      SyncLocationKind.dropbox,
      SyncLocationKind.webDav,
      SyncLocationKind.localFolder
    ]);
    expect(SyncLocationKind.offeredOn('android', dropbox: false),
        [SyncLocationKind.webDav]);
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
    expect(onPhone.state.locationKind, SyncLocationKind.webDav);
    expect(onPhone.state.webDavAddress, folder());
    expect(onPhone.state.webDavUser, server.user);
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
    expect(cubit.state.enabled, isFalse);
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
    expect(cubit.state.enabled, isFalse);
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
    expect(cubit.state.enabled, isTrue);
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
    expect(cubit.state.enabled, isTrue);

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
    await cubit.chooseWebDav(deviceName: 'Kitchen laptop');
    await cubit.syncNow();

    expect(cubit.state.setupProblem, isNull);
    expect(cubit.state.enabled, isTrue);
    expect(cubit.state.locationKind, SyncLocationKind.webDav);
    expect(cubit.state.deviceName, 'Kitchen laptop');
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
    await cubit.chooseWebDav();

    expect(cubit.state.setupProblem, SyncLocationProblem.notFound);
    expect(cubit.state.enabled, isFalse);
  });

  test(
      'moving from a local folder to WebDAV publishes there and leaves the folder untouched',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final repository = SyncRepository(
      database: Future.value(laptop.isar),
      backups: laptop.backups,
      clock: laptop.clock,
      machineName: () => laptop.name,
      credentials: MemoryKeyring(),
      locationKinds: const [
        SyncLocationKind.webDav,
        SyncLocationKind.localFolder
      ],
    );
    repositories.add(repository);
    final cubit = screenOn(repository);
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.load();
    await cubit.enable(world.locationPath);
    await cubit.syncNow();
    final inFolder = await filesIn(world.locationPath);

    expect(await signIn(cubit), isNull);
    await cubit.chooseWebDav();
    await cubit.syncNow();

    expect(cubit.state.locationKind, SyncLocationKind.webDav);
    expect(await filesIn(world.locationPath), inFolder);
    expect(server.paths.where((p) => p.startsWith('/dav/bloomee/sync/')),
        hasLength(1));
  });
}
