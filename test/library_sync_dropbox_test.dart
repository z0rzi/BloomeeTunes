import 'dart:convert';
import 'dart:io';

import 'package:Bloomee/blocs/sync/sync_cubit.dart';
import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/core/models/backup/backup_settings_policy.dart';
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

  /// The key of a Dropbox app the owner registered themselves, which the
  /// stand-in knows besides [DropboxStandIn.appKey].
  const ownKey = 'own-app-key';
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
    dropbox = await DropboxStandIn.start(otherAppKeys: [ownKey]);
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

  /// The Dropbox app with [key] ([DropboxStandIn.appKey], the owner's first
  /// app, if not given), as the stand-in answers it.
  DropboxApp app([String? key]) => DropboxApp(
      key: key ?? dropbox.appKey,
      authorizePage: dropbox.authorizePage,
      api: dropbox.base,
      content: dropbox.base);

  /// The app on [device], keeping its credentials in [keyring].
  SyncRepository appOn(SyncDevice device, MemoryKeyring keyring) {
    final repository = SyncRepository(
      database: Future.value(device.isar),
      backups: device.backups,
      clock: device.clock,
      machineName: () => device.name,
      credentials: keyring,
      dropboxWithKey: app,
    );
    repositories.add(repository);
    return repository;
  }

  SyncCubit screenOn(SyncRepository repository) {
    final cubit = SyncCubit(repository);
    cubits.add(cubit);
    return cubit;
  }

  /// The owner signs in to Dropbox on [cubit]'s Device, as the sign-in
  /// dialog has them: enters the key of their app ([key], else the one
  /// offered, the key saved on this Device, else [DropboxStandIn.appKey]),
  /// opens the page, allows Bloomee and pastes the code back.
  Future<SyncLocationProblem?> signIn(SyncCubit cubit, [String? key]) async {
    final page = await cubit.beginDropboxSignIn(
        key ?? cubit.state.setup.dropboxAppKey ?? dropbox.appKey);
    return cubit.finishDropboxSignIn(dropbox.approve(page!));
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

  test('Dropbox is offered first', () {
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

  test(
      'a code Dropbox does not accept says so; sync stays off and the key is not saved',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await cubit.load();

    expect(await cubit.beginDropboxSignIn(dropbox.appKey), isNotNull);
    expect(await cubit.finishDropboxSignIn('not the code'),
        SyncLocationProblem.signInRefused);

    expect(cubit.state.dropboxSignedIn, isFalse);
    expect(cubit.state.setup.enabled, isFalse);
    expect(cubit.state.setup.dropboxAppKey, isNull);
  });

  test(
      'an app key Dropbox does not know is reported as such at sign-in, not as a refused code',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final cubit = screenOn(appOn(laptop, MemoryKeyring()));
    await cubit.load();

    final page = await cubit.beginDropboxSignIn('mistyped-key');
    expect(page!.queryParameters['client_id'], 'mistyped-key');
    expect(await cubit.finishDropboxSignIn('the code Dropbox showed'),
        SyncLocationProblem.appKeyRefused);
    expect(cubit.state.dropboxSignedIn, isFalse);
    expect(cubit.state.setup.dropboxAppKey, isNull);
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

  test(
      'signing out removes the sign-in from the Device and ends it on Dropbox, keeping the key for the next sign-in',
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
    expect(cubit.state.setup.dropboxAppKey, dropbox.appKey,
        reason: 'the sign-in dialog offers it again');

    expect(await signIn(cubit), isNull);
    expect(dropbox.pagesOpened.last['client_id'], dropbox.appKey);
    expect(cubit.state.dropboxSignedIn, isTrue);
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

  group('the owner\'s own Dropbox app', () {
    test(
        'with its key entered at sign-in, the Device signs in, renews and syncs through that app',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      await laptop.add('Road trip', [song('yt::1')]);
      final cubit = screenOn(appOn(laptop, MemoryKeyring()));
      await cubit.load();

      expect(await signIn(cubit, ' $ownKey '), isNull);
      expect(cubit.state.setup.dropboxAppKey, ownKey);
      await cubit.choose(const SyncLocationChoice.dropbox());
      await cubit.syncNow();
      await pumpEventQueue();

      expect(dropbox.pagesOpened.single['client_id'], ownKey);
      expect(dropbox.appOf(dropbox.validRefreshTokens.single), ownKey);
      expect(dropbox.pathsOf(ownKey).where((p) => p.startsWith('/sync/')),
          hasLength(1));
      expect(dropbox.paths, isEmpty, reason: 'nothing in the other app');

      dropbox.expireAccessTokens();
      world.clock.advance(const Duration(minutes: 5));
      await laptop.add('Focus', [song('yt::2')]);
      await cubit.syncNow();
      await pumpEventQueue();

      expect(dropbox.renewalsBy(ownKey), greaterThan(0));
      expect(dropbox.renewalsBy(dropbox.appKey), 0);
      expect(cubit.state.status.lastError, isNull);
      final state =
          dropbox.pathsOf(ownKey).singleWhere((p) => p.startsWith('/sync/'));
      expect(utf8.decode(dropbox.file(state, app: ownKey)!), contains('yt::2'));
    });

    test(
        'Dropbox is offered with no app of Bloomee\'s own: it signs in through the owner\'s',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      await laptop.add('Road trip', [song('yt::1')]);
      final cubit = screenOn(appOn(laptop, MemoryKeyring()));
      await cubit.load();

      expect(cubit.state.locationKinds, contains(SyncLocationKind.dropbox));
      expect(cubit.state.setup.dropboxAppKey, isNull);
      expect(await cubit.beginDropboxSignIn('   '), isNull,
          reason: 'an empty key is no app to sign in through');
      await cubit.choose(const SyncLocationChoice.dropbox());
      expect(cubit.state.setup.enabled, isFalse);

      expect(await signIn(cubit, ownKey), isNull);
      await cubit.choose(const SyncLocationChoice.dropbox());
      await cubit.syncNow();

      expect(cubit.state.setup.enabled, isTrue);
      final state =
          dropbox.pathsOf(ownKey).singleWhere((p) => p.startsWith('/sync/'));
      expect(utf8.decode(dropbox.file(state, app: ownKey)!), contains('yt::1'));
    });

    test(
        'a sign-in that fails or is given up leaves the saved key and the sign-in as they were',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final keyring = MemoryKeyring();
      final cubit = await syncingThroughDropbox(laptop, keyring);
      final kept = Map.of(keyring.values);
      final refreshToken = dropbox.validRefreshTokens.single;

      void expectUnchanged(String reason) {
        expect(cubit.state.setup.dropboxAppKey, dropbox.appKey, reason: reason);
        expect(keyring.values, kept, reason: reason);
        expect(dropbox.isValid(refreshToken), isTrue, reason: reason);
        expect(cubit.state.dropboxSignedIn, isTrue, reason: reason);
        expect(cubit.state.setup.enabled, isTrue, reason: reason);
      }

      expect(await cubit.beginDropboxSignIn(ownKey), isNotNull);
      expect(await cubit.finishDropboxSignIn('not the code'),
          SyncLocationProblem.signInRefused);
      expectUnchanged('a refused code');

      await cubit.beginDropboxSignIn('mistyped-key');
      expect(await cubit.finishDropboxSignIn('the code Dropbox showed'),
          SyncLocationProblem.appKeyRefused);
      expectUnchanged('an app key Dropbox does not know');

      await cubit.beginDropboxSignIn(ownKey);
      await cubit.load();
      expectUnchanged('a sign-in begun, then cancelled');
    });

    test('a sign-in the keyring cannot keep changes nothing saved, and says so',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final keyring = MemoryKeyring();
      final cubit = screenOn(appOn(laptop, keyring));
      await cubit.load();

      keyring.refusesChanges = true;
      expect(
          await signIn(cubit, ownKey), SyncLocationProblem.keyringUnavailable);

      expect(cubit.state.setup.dropboxAppKey, isNull);
      expect(keyring.values, isEmpty);
      expect(cubit.state.dropboxSignedIn, isFalse);
    });

    test(
        'a sign-in kept without a key, from the app earlier builds had, counts as signed out; signing in replaces it',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final keyring = MemoryKeyring();
      keyring.values[SyncRepository.dropboxCredential] =
          dropbox.signedInRefreshToken();
      final cubit = screenOn(appOn(laptop, keyring));
      await cubit.load();

      expect(cubit.state.dropboxSignedIn, isFalse);
      await cubit.choose(const SyncLocationChoice.dropbox());
      expect(cubit.state.setupProblem, SyncLocationProblem.appKeyRefused);
      expect(cubit.state.setup.enabled, isFalse);

      expect(await signIn(cubit, ownKey), isNull);

      expect(cubit.state.dropboxSignedIn, isTrue);
      expect(cubit.state.setup.dropboxAppKey, ownKey);
      expect(dropbox.appOf(keyring.values[SyncRepository.dropboxCredential]!),
          ownKey);
      await cubit.choose(const SyncLocationChoice.dropbox());
      expect(cubit.state.setup.enabled, isTrue);
    });

    test(
        'signing in again through another app replaces the sign-in and ends the one before on Dropbox',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final keyring = MemoryKeyring();
      final cubit = await syncingThroughDropbox(laptop, keyring);
      final throughFirstApp = dropbox.validRefreshTokens.single;

      expect(await signIn(cubit, ownKey), isNull);
      await pumpEventQueue();

      expect(dropbox.isValid(throughFirstApp), isFalse);
      final throughOwnApp = keyring.values[SyncRepository.dropboxCredential]!;
      expect(dropbox.appOf(throughOwnApp), ownKey);
      expect(cubit.state.setup.dropboxAppKey, ownKey);
      expect(cubit.state.dropboxSignedIn, isTrue);
      expect(cubit.state.setup.enabled, isTrue);
    });

    test('a sign-in begun with a key since changed is not kept', () async {
      final laptop = await world.device('laptop', enabled: false);
      final cubit = screenOn(appOn(laptop, MemoryKeyring()));
      await cubit.load();

      final code =
          dropbox.approve((await cubit.beginDropboxSignIn(dropbox.appKey))!);
      // The key edited, and the page opened again.
      await cubit.beginDropboxSignIn(ownKey);

      expect(await cubit.finishDropboxSignIn(code),
          SyncLocationProblem.signInRefused);
      expect(cubit.state.dropboxSignedIn, isFalse);
      expect(cubit.state.setup.dropboxAppKey, isNull);
    });

    test(
        'an app Dropbox stops knowing is told in the status line, keeping the sign-in',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final keyring = MemoryKeyring();
      final cubit = screenOn(appOn(laptop, keyring));
      await cubit.load();
      expect(await signIn(cubit, ownKey), isNull);
      await cubit.choose(const SyncLocationChoice.dropbox());
      await cubit.syncNow();

      dropbox.forgetApp(ownKey);
      dropbox.expireAccessTokens();
      world.clock.advance(const Duration(minutes: 5));
      await cubit.syncNow();
      await pumpEventQueue();

      expect(cubit.state.status.lastError, isA<SyncAppKeyRefused>());
      expect(cubit.state.dropboxSignedIn, isTrue);
      expect(keyring.values, isNotEmpty);
    });

    test(
        'the entered app key stays on this Device: never in a Device State or a Location Backup',
        () async {
      const distinctKey = 'k3y-0nly-0n-th1s-d3v1c3';
      await dropbox.close();
      dropbox = await DropboxStandIn.start(otherAppKeys: [distinctKey]);
      final laptop = await world.device('laptop', enabled: false);
      await laptop.add('Road trip', [song('yt::1')]);
      final cubit = screenOn(appOn(laptop, MemoryKeyring()));
      await cubit.load();
      expect(await signIn(cubit, distinctKey), isNull);
      await cubit.choose(const SyncLocationChoice.dropbox());
      await cubit.syncNow();

      final published = dropbox.pathsOf(distinctKey);
      expect(published.where((p) => p.startsWith('/sync/')), hasLength(1));
      expect(published.where((p) => p.startsWith('/backups/')), hasLength(1));
      for (final path in published) {
        expect(utf8.decode(dropbox.file(path, app: distinctKey)!),
            isNot(contains(distinctKey)),
            reason: path);
      }
      expect(
          BackupSettingsPolicy.supports(SettingKeys.librarySyncDropboxAppKey),
          isFalse,
          reason: 'an exported backup leaves it out');
    });
  });
}
