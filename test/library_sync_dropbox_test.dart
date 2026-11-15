import 'dart:convert';
import 'dart:io';

import 'package:Bloomee/blocs/sync/sync_cubit.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/repository/sync/sync_engine.dart';
import 'package:Bloomee/repository/sync/sync_repository.dart';
import 'package:Bloomee/services/sync/dropbox_sync_location.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/dropbox_stand_in.dart';
import 'support/isar_test_support.dart';
import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncWorld world;
  late DropboxStandIn dropbox;
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
    dropbox = await DropboxStandIn.start();
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
    await dropbox.close();
    await world.dispose();
  });

  DropboxApp app() => DropboxApp(
      key: dropbox.appKey,
      authorizePage: dropbox.authorizePage,
      api: dropbox.base,
      content: dropbox.base);

  /// The app on [device], built with a Dropbox app key, keeping its
  /// credentials in [keyring].
  SyncRepository appOn(SyncDevice device, MemoryKeyring keyring) {
    final repository = SyncRepository(
      database: Future.value(device.isar),
      backups: device.backups,
      clock: device.clock,
      machineName: () => device.name,
      credentials: keyring,
      dropbox: app(),
    );
    repositories.add(repository);
    return repository;
  }

  SyncCubit screenOn(SyncRepository repository) {
    final cubit = SyncCubit(repository);
    cubits.add(cubit);
    return cubit;
  }

  /// The owner signs in to Dropbox on [cubit]'s Device: opens the page,
  /// allows Bloomee and pastes the code back.
  Future<SyncLocationProblem?> signIn(SyncCubit cubit) async {
    return cubit
        .finishDropboxSignIn(dropbox.approve(cubit.beginDropboxSignIn()));
  }

  /// [device], set up to sync through Dropbox from its settings screen.
  Future<SyncCubit> syncingThroughDropbox(
      SyncDevice device, MemoryKeyring keyring) async {
    final cubit = screenOn(appOn(device, keyring));
    await cubit.load();
    expect(await signIn(cubit), isNull);
    await cubit.choose(const SyncLocationChoice.dropbox());
    expect(cubit.state.setupProblem, isNull);
    await cubit.syncNow();
    await pumpEventQueue();
    return cubit;
  }

  test('Dropbox is offered first where the build has its app key', () {
    expect(SyncLocationKind.offeredOn('linux', dropbox: true), [
      SyncLocationKind.dropbox,
      SyncLocationKind.webDav,
      SyncLocationKind.localFolder
    ]);
    expect(SyncLocationKind.offeredOn('android', dropbox: true),
        [SyncLocationKind.dropbox, SyncLocationKind.webDav]);
  });

  test('a build without the Dropbox app key does not offer Dropbox', () async {
    expect(SyncLocationKind.offeredOn('linux', dropbox: false),
        [SyncLocationKind.webDav, SyncLocationKind.localFolder]);
    expect(SyncLocationKind.offeredOn('android', dropbox: false),
        [SyncLocationKind.webDav]);
    final laptop = await world.device('laptop', enabled: false);
    final withoutKey = SyncRepository(
        database: Future.value(laptop.isar), backups: laptop.backups);
    repositories.add(withoutKey);
    expect(withoutKey.locationKinds, isNot(contains(SyncLocationKind.dropbox)));
  });

  test(
      'signed in with the pasted code, two Devices sync through Dropbox, each signed in once',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone', enabled: false);
    await laptop.add('Road trip', [song('yt::1'), song('yt::2')]);

    final onLaptop = await syncingThroughDropbox(laptop, MemoryKeyring());
    final onPhone = await syncingThroughDropbox(phone, MemoryKeyring());

    expect(await phone.songsOf('Road trip'), ['yt::1', 'yt::2']);
    expect(onLaptop.state.dropboxSignedIn, isTrue);
    expect(onPhone.state.setup.locationKind, SyncLocationKind.dropbox);
    expect(
        dropbox.paths
            .where((p) => p.startsWith('/${SyncEngine.stateDirectory}/')),
        hasLength(2));
  });

  test('after a restart, the Device still syncs, signed in from the keyring',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone', enabled: false);
    final keyring = MemoryKeyring();
    final onLaptop = await syncingThroughDropbox(laptop, keyring);
    await onLaptop.close();
    await repositories.removeLast().close();
    final onPhone = await syncingThroughDropbox(phone, MemoryKeyring());

    world.clock.advance(const Duration(minutes: 5));
    await phone.add('Focus', [song('yt::3')]);
    await onPhone.syncNow();
    final restarted = appOn(laptop, keyring);
    await restarted.start();

    expect(await laptop.songsOf('Focus'), ['yt::3']);
    expect(restarted.status.lastError, isNull);
  });

  test('a code Dropbox does not accept says so, and sync stays off', () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await cubit.load();

    cubit.beginDropboxSignIn();
    expect(await cubit.finishDropboxSignIn('not the code'),
        SyncLocationProblem.signInRefused);

    expect(cubit.state.dropboxSignedIn, isFalse);
    expect(cubit.state.setup.enabled, isFalse);
  });

  test(
      'Dropbox refusing this app, rather than the code, is told apart from a refused code',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final repository = SyncRepository(
      database: Future.value(laptop.isar),
      backups: laptop.backups,
      machineName: () => laptop.name,
      credentials: MemoryKeyring(),
      dropbox: DropboxApp(
          key: 'another app',
          authorizePage: dropbox.authorizePage,
          api: dropbox.base,
          content: dropbox.base),
    );
    repositories.add(repository);
    final cubit = screenOn(repository);
    await cubit.load();

    cubit.beginDropboxSignIn();
    expect(await cubit.finishDropboxSignIn('the code Dropbox showed'),
        SyncLocationProblem.refused);
    expect(cubit.state.dropboxSignedIn, isFalse);
  });

  test(
      'the sign-in is kept in the keyring, and never in the database, a Device State or a Location Backup',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final keyring = MemoryKeyring();
    await laptop.add('Road trip', [song('yt::1')]);
    await syncingThroughDropbox(laptop, keyring);
    final refreshToken = dropbox.validRefreshTokens.single;

    expect(keyring.values.values, contains(refreshToken));
    final published = dropbox.paths;
    expect(published.where((p) => p.startsWith('/sync/')), hasLength(1));
    expect(published.where((p) => p.startsWith('/backups/')), hasLength(1));
    for (final path in published) {
      expect(utf8.decode(dropbox.file(path)!), isNot(contains(refreshToken)),
          reason: path);
      expect(utf8.decode(dropbox.file(path)!), isNot(contains('access-')),
          reason: '$path holds an access token');
    }
    final database = await File(laptop.isar.path!).readAsBytes();
    expect(latin1.decode(database), isNot(contains(refreshToken)));
  });

  test('an expired access token is renewed during sync, unnoticed', () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = await syncingThroughDropbox(laptop, MemoryKeyring());
    final renewals = dropbox.renewals;

    dropbox.expireAccessTokens();
    world.clock.advance(const Duration(minutes: 5));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.syncNow();
    await pumpEventQueue();

    expect(dropbox.renewals, renewals + 1);
    expect(cubit.state.status.lastError, isNull);
    expect(cubit.state.alerts, isEmpty);
    final state = dropbox.paths.singleWhere((p) => p.startsWith('/sync/'));
    expect(utf8.decode(dropbox.file(state)!), contains('yt::1'));
  });

  test(
      'a revoked sign-in stops sync with an alert to sign in again; signing in resumes it',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone', enabled: false);
    final cubit = await syncingThroughDropbox(laptop, MemoryKeyring());

    dropbox.revokeAll();
    world.clock.advance(const Duration(minutes: 5));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.syncNow();
    await pumpEventQueue();

    expect(cubit.state.status.lastError, isA<SyncSignInNeeded>());
    expect(cubit.state.alerts,
        [const SignInNeededAlert(SyncLocationKind.dropbox)]);
    expect(cubit.state.dropboxSignedIn, isFalse);
    final requests = dropbox.requests;
    await cubit.syncNow();
    await pumpEventQueue();
    expect(dropbox.requests, requests, reason: 'sync stopped');
    expect(
        cubit.state.alerts, [const SignInNeededAlert(SyncLocationKind.dropbox)],
        reason: 'the owner is asked once');

    expect(await signIn(cubit), isNull);
    await pumpEventQueue();
    await syncingThroughDropbox(phone, MemoryKeyring());

    expect(await phone.songsOf('Road trip'), ['yt::1']);
    expect(cubit.state.setup.enabled, isTrue);
  });

  test('signing out removes the sign-in from the Device and ends it on Dropbox',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final keyring = MemoryKeyring();
    final cubit = await syncingThroughDropbox(laptop, keyring);
    final refreshToken = dropbox.validRefreshTokens.single;

    expect(await cubit.signOutOf(SyncLocationKind.dropbox), isTrue);

    expect(keyring.values, isEmpty);
    expect(dropbox.isValid(refreshToken), isFalse);
    expect(cubit.state.dropboxSignedIn, isFalse);
    expect(cubit.state.setup.enabled, isFalse,
        reason: 'sync cannot go on through Dropbox once signed out');
  });

  test(
      'with sync off, signing in to Dropbox from its choice turns sync on with Dropbox',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.load();

    expect(await signIn(cubit), isNull);
    await cubit.choose(const SyncLocationChoice.dropbox(),
        deviceName: 'Kitchen laptop');
    await cubit.syncNow();

    expect(cubit.state.setupProblem, isNull);
    expect(cubit.state.setup.enabled, isTrue);
    expect(cubit.state.setup.locationKind, SyncLocationKind.dropbox);
    expect(cubit.state.setup.deviceName, 'Kitchen laptop');
    final state = dropbox.paths.singleWhere((p) => p.startsWith('/sync/'));
    expect(utf8.decode(dropbox.file(state)!), contains('yt::1'));
  });

  test(
      'with sync off, a Dropbox that cannot be used once signed in says why and leaves sync off',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await cubit.load();

    expect(await signIn(cubit), isNull);
    dropbox.revokeAll();
    await cubit.choose(const SyncLocationChoice.dropbox());

    expect(cubit.state.setupProblem, SyncLocationProblem.signInRefused);
    expect(cubit.state.setup.enabled, isFalse);
    expect(dropbox.paths, isEmpty);
  });

  test(
      'moving from a local folder to Dropbox publishes there and leaves the folder untouched',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await laptop.add('Road trip', [song('yt::1')]);
    await cubit.load();
    await cubit.choose(SyncLocationChoice.folder(world.locationPath));
    await cubit.syncNow();
    final inFolder = await filesIn(world.locationPath);

    expect(await signIn(cubit), isNull);
    await cubit.choose(const SyncLocationChoice.dropbox());
    await cubit.syncNow();

    expect(cubit.state.setup.locationKind, SyncLocationKind.dropbox);
    expect(await filesIn(world.locationPath), inFolder);
    expect(dropbox.paths.where((p) => p.startsWith('/sync/')), hasLength(1));
  });
}
