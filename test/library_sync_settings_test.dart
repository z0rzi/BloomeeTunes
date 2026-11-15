import 'dart:io';

import 'package:Bloomee/blocs/sync/sync_cubit.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/repository/sync/sync_engine.dart';
import 'package:Bloomee/repository/sync/sync_repository.dart';
import 'package:Bloomee/repository/sync/sync_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/isar_test_support.dart';
import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncWorld world;
  final repositories = <SyncRepository>[];

  setUpAll(initializeTestIsar);
  setUp(() async => world = await SyncWorld.create());
  tearDown(() async {
    for (final repository in repositories) {
      await repository.close();
    }
    repositories.clear();
    await world.dispose();
  });

  /// The app's sync repository on [device], as the app builds it at start.
  SyncRepository appOn(SyncDevice device,
      {Duration debounce = const Duration(seconds: 5)}) {
    final repository = SyncRepository(
      database: Future.value(device.isar),
      backups: device.backups,
      clock: device.clock,
      machineName: () => 'workstation',
      scheduler: (run) => SyncScheduler(run: run, debounce: debounce),
    );
    repositories.add(repository);
    return repository;
  }

  /// Everything in the Sync Location, as paths inside it.
  Future<List<String>> locationFiles() async => [
        await for (final entry in Directory(world.locationPath)
            .list(recursive: true, followLinks: false))
          if (entry is File) p.relative(entry.path, from: world.locationPath)
      ];

  /// The Device States in the Sync Location.
  Future<List<String>> deviceStates() async => [
        for (final path in await locationFiles())
          if (p.split(path).first == SyncEngine.stateDirectory) path
      ];

  /// Waits until [condition] holds, for at most [limit].
  Future<void> eventually(Future<bool> Function() condition,
      {Duration limit = const Duration(seconds: 10)}) async {
    final end = DateTime.now().add(limit);
    while (!await condition()) {
      if (DateTime.now().isAfter(end)) fail('Condition not met in $limit.');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('Library Sync is off by default and writes nothing until it is enabled',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final app = appOn(laptop);
    await laptop.add('Road trip', [song('yt::1')]);

    await app.start();
    await app.syncNow();

    expect((await app.setup()).enabled, isFalse);
    expect(await locationFiles(), isEmpty);
  });

  test(
      'once enabled with a folder, the library is published and another Device takes it in',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone');
    final app = appOn(laptop);
    await laptop.add('Road trip', [song('yt::1'), song('yt::2')]);

    expect(await app.enable(folder: world.locationPath, deviceName: 'laptop'),
        isNull);
    await app.syncNow();
    await phone.sync();

    expect(await phone.songsOf('Road trip'), ['yt::1', 'yt::2']);
    final setup = await app.setup();
    expect(setup.enabled, isTrue);
    expect(setup.folder, world.locationPath);
  });

  test(
      'the Device name defaults to the machine name and can be changed, keeping one Device',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final app = appOn(laptop);
    expect((await app.setup()).deviceName, 'workstation');

    await app.enable(folder: world.locationPath, deviceName: 'workstation');
    await app.syncNow();
    await app.renameDevice('Kitchen laptop');
    await app.syncNow();

    final restarted = appOn(laptop);
    expect((await restarted.setup()).deviceName, 'Kitchen laptop');
    expect(await deviceStates(), hasLength(1),
        reason: 'renaming publishes the same Device State');
  });

  test('setup says plainly when the folder cannot be found, and stays off',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final app = appOn(laptop);

    expect(
        await app.enable(
            folder: p.join(world.root.path, 'unmounted drive'),
            deviceName: 'laptop'),
        SyncLocationProblem.notFound);
    expect((await app.setup()).enabled, isFalse);
  });

  test('setup says plainly when the folder cannot be written, and stays off',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final app = appOn(laptop);
    final readOnly =
        await Directory(p.join(world.root.path, 'read only')).create();
    await Process.run('chmod', ['555', readOnly.path]);
    addTearDown(() => Process.run('chmod', ['755', readOnly.path]));

    expect(await app.enable(folder: readOnly.path, deviceName: 'laptop'),
        SyncLocationProblem.notWritable);
    expect((await app.setup()).enabled, isFalse);
    expect(readOnly.listSync(), isEmpty);
  });

  test('testing a folder leaves nothing in it', () async {
    final laptop = await world.device('laptop', enabled: false);
    final app = appOn(laptop);

    expect(await app.testFolder(world.locationPath), isNull);
    expect(await locationFiles(), isEmpty);
  });

  test('a change to the Synced Library is published by itself, a moment later',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone');
    final app = appOn(laptop, debounce: const Duration(milliseconds: 200));
    await app.enable(folder: world.locationPath, deviceName: 'laptop');
    await app.syncNow();

    world.clock.advance(const Duration(minutes: 1));
    await laptop.add('Road trip', [song('yt::1')]);

    await eventually(() async {
      await phone.sync();
      return await phone.songsOf('Road trip') != null;
    });
  });

  test(
      'a change made just before the app closes is published at the next start',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone');
    final app = appOn(laptop);
    await app.enable(folder: world.locationPath, deviceName: 'laptop');
    await app.syncNow();

    world.clock.advance(const Duration(minutes: 1));
    await laptop.add('Road trip', [song('yt::1')]);
    await app.close();
    await phone.sync();
    expect(await phone.songsOf('Road trip'), isNull,
        reason: 'nothing runs once the app has closed');

    await appOn(laptop).start();
    await phone.sync();
    expect(await phone.songsOf('Road trip'), ['yt::1']);
  });

  test(
      'sync comes back on by itself after the official build dropped its bookkeeping',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone');
    final app = appOn(laptop);
    await app.enable(folder: world.locationPath, deviceName: 'laptop');
    await app.syncNow();
    await app.close();

    await laptop.returnFromOfficialBuild();
    await laptop.add('Road trip', [song('yt::1')]);
    final restarted = appOn(laptop);
    await restarted.start();
    await phone.sync();

    expect(await phone.songsOf('Road trip'), ['yt::1']);
    expect(restarted.status.lastError, isNull);
    expect((await restarted.setup()).deviceName, 'laptop');
  });

  test('the status shows the last successful sync and the last error',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final app = appOn(laptop);
    await app.enable(folder: world.locationPath, deviceName: 'laptop');
    await app.syncNow();
    final syncedAt = laptop.clock();
    expect(app.status.lastSyncedAt, syncedAt);
    expect(app.status.lastError, isNull);

    world.clock.advance(const Duration(minutes: 3));
    await Directory(world.locationPath).delete(recursive: true);
    await app.syncNow();

    expect(app.status.lastSyncedAt, syncedAt);
    expect(app.status.lastError, isA<SyncLocationUnreachable>());
    expect(app.status.lastError!.at, laptop.clock());
    expect(app.status.running, isFalse);
  });

  test('turning sync off stops it and writes nothing more', () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone');
    final app = appOn(laptop, debounce: const Duration(milliseconds: 100));
    await app.enable(folder: world.locationPath, deviceName: 'laptop');
    await app.syncNow();

    await app.disable();
    world.clock.advance(const Duration(minutes: 1));
    await laptop.add('Road trip', [song('yt::1')]);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await app.syncNow();
    await phone.sync();

    expect(await phone.songsOf('Road trip'), isNull);
    expect((await app.setup()).enabled, isFalse);
    expect((await app.setup()).folder, world.locationPath);
  });

  test(
      'the settings list the known Devices and Forget one, deleting only its Device State',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('old phone');
    await phone.add('Road trip', [song('yt::1')]);
    await phone.sync();
    final app = appOn(laptop);
    await app.enable(folder: world.locationPath, deviceName: 'laptop');
    await app.syncNow();

    final devices = await app.knownDevices();
    expect({for (final d in devices) d.deviceName: d.isThisDevice},
        {'laptop': true, 'old phone': false});

    await app.forgetDevice(
        devices.singleWhere((d) => d.deviceName == 'old phone').deviceId);
    await app.syncNow();

    expect(
        [for (final d in await app.knownDevices()) d.deviceName], ['laptop']);
    expect(await laptop.songsOf('Road trip'), ['yt::1']);
    expect(await phone.songsOf('Road trip'), ['yt::1']);
    expect(await deviceStates(), hasLength(1));
  });

  test('turned off and back on in the settings, sync resumes where it left off',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone');
    final app = appOn(laptop);
    await phone.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
    await phone.sync();
    await app.enable(folder: world.locationPath, deviceName: 'laptop');
    await app.syncNow();

    await app.disable();
    world.clock.advance(const Duration(minutes: 5));
    await laptop.remove('Road trip', 'yt::1');
    await laptop.add('Focus', [song('yt::4')]);
    expect(await laptop.libraryOrder(), ['Focus', 'Road trip'],
        reason: 'with sync off, a new playlist goes first, as without sync');
    world.clock.advance(const Duration(days: 30));
    await app.enable(folder: world.locationPath, deviceName: 'laptop');
    await app.syncNow();
    await phone.sync();

    expect(await phone.songsOf('Road trip'), ['yt::2', 'yt::3']);
    expect(await phone.songsOf('Focus'), ['yt::4']);
    expect(await laptop.songsOf('Road trip'), ['yt::2', 'yt::3']);
  });

  group('with sync turned off, a new playlist goes first, as without sync,',
      () {
    late SyncDevice laptop;
    late SyncRepository app;

    setUp(() async {
      laptop = await world.device('laptop', enabled: false);
      final phone = await world.device('phone');
      await phone.add('Road trip', [song('yt::1')]);
      await phone.sync();
      app = appOn(laptop);
      await app.enable(folder: world.locationPath, deviceName: 'laptop');
      await app.syncNow();
      await app.disable();
    });

    test('also after the Device is renamed', () async {
      await app.renameDevice('Kitchen laptop');
      await laptop.add('Focus', [song('yt::2')]);

      expect(await laptop.libraryOrder(), ['Focus', 'Road trip']);
    });

    test('also when a build before this one left sync on in its bookkeeping',
        () async {
      await laptop.enable();
      await app.close();
      await appOn(laptop).start();
      await laptop.add('Focus', [song('yt::2')]);

      expect(await laptop.libraryOrder(), ['Focus', 'Road trip']);
    });
  });

  group('changing the folder while sync is on', () {
    test(
        'moves there: publishes in the new place and leaves the old one untouched',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final phone = await world.device('phone');
      final app = appOn(laptop);
      await laptop.add('Road trip', [song('yt::1')]);
      await app.enable(folder: world.locationPath, deviceName: 'laptop');
      await app.syncNow();
      await phone.sync();
      final old = await filesIn(world.locationPath);
      final server = await world.otherLocation('server');

      expect(await app.moveTo(server), isNull);
      await app.syncNow();
      final desktop = await world.device('desktop', location: server);
      await desktop.sync();

      expect(await filesIn(world.locationPath), old);
      expect(await desktop.songsOf('Road trip'), ['yt::1']);
      final setup = await app.setup();
      expect(setup.enabled, isTrue);
      expect(setup.folder, server);
      expect((await appOn(laptop).setup()).folder, server,
          reason: 'the new place is kept for the next start');
    });

    test(
        'to a folder that cannot be used says why and keeps syncing where it was',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final phone = await world.device('phone');
      final app = appOn(laptop);
      await app.enable(folder: world.locationPath, deviceName: 'laptop');
      await app.syncNow();

      expect(await app.moveTo(p.join(world.root.path, 'unmounted drive')),
          SyncLocationProblem.notFound);
      world.clock.advance(const Duration(minutes: 5));
      await laptop.add('Road trip', [song('yt::1')]);
      await app.syncNow();
      await phone.sync();

      expect(await phone.songsOf('Road trip'), ['yt::1']);
      expect((await app.setup()).folder, world.locationPath);
    });
  });

  group('the settings, as the screen shows them,', () {
    Future<SyncCubit> screenOn(SyncDevice device) async {
      final cubit = SyncCubit(appOn(device));
      addTearDown(cubit.close);
      await cubit.load();
      return cubit;
    }

    List<String> names(SyncCubit cubit) =>
        [for (final d in cubit.state.devices) d.deviceName];

    test(
        'lists the known Devices once sync is on, and again after each sync and Forget',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final phone = await world.device('phone');
      await phone.sync();
      final screen = await screenOn(laptop);
      expect(screen.state.devices, isEmpty);

      await screen.enable(world.locationPath, deviceName: 'laptop');
      await screen.syncNow();
      await eventually(() async => screen.state.devices
          .any((d) => d.isThisDevice && d.lastSyncedAt != null));
      expect(names(screen), unorderedEquals(['laptop', 'phone']));

      final tablet = await world.device('tablet');
      await tablet.sync();
      await screen.syncNow();
      await eventually(() async => names(screen).contains('tablet'));

      await screen.forgetDevice(screen.state.devices
          .singleWhere((d) => d.deviceName == 'phone')
          .deviceId);
      expect(names(screen), unorderedEquals(['laptop', 'tablet']));
    });

    test('say so when a Device cannot be forgotten, and keep listing it',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final phone = await world.device('phone');
      await phone.sync();
      final screen = await screenOn(laptop);
      await screen.enable(world.locationPath, deviceName: 'laptop');
      await screen.syncNow();
      await eventually(() async => names(screen).contains('phone'));
      final states = p.join(world.locationPath, 'sync');
      await Process.run('chmod', ['555', states]);
      addTearDown(() => Process.run('chmod', ['755', states]));

      expect(
          await screen.forgetDevice(screen.state.devices
              .singleWhere((d) => d.deviceName == 'phone')
              .deviceId),
          isFalse);
      expect(names(screen), contains('phone'));
    });

    test('changing the folder while sync is on moves sync there', () async {
      final laptop = await world.device('laptop', enabled: false);
      final screen = await screenOn(laptop);
      await screen.enable(world.locationPath, deviceName: 'laptop');
      final server = await world.otherLocation('server');

      await screen.changeFolder(server);
      await screen.syncNow();

      expect(screen.state.folder, server);
      expect(screen.state.enabled, isTrue);
      expect(Directory(p.join(server, 'sync')).listSync(), isNotEmpty);
    });

    test('with sync off, choosing a folder turns sync on with it', () async {
      final laptop = await world.device('laptop', enabled: false);
      await laptop.add('Road trip', [song('yt::1')]);
      final screen = await screenOn(laptop);
      expect(screen.state.enabled, isFalse);

      await screen.changeFolder(world.locationPath,
          deviceName: 'Kitchen laptop');
      await screen.syncNow();

      expect(screen.state.setupProblem, isNull);
      expect(screen.state.enabled, isTrue);
      expect(screen.state.locationKind, SyncLocationKind.localFolder);
      expect(screen.state.folder, world.locationPath);
      expect(screen.state.deviceName, 'Kitchen laptop');
      final phone = await world.device('phone');
      await phone.sync();
      expect(await phone.songsOf('Road trip'), ['yt::1']);
      expect((await appOn(laptop).setup()).enabled, isTrue,
          reason: 'sync stays on at the next start');
    });

    test(
        'with sync off, choosing a folder that cannot be used says why and leaves sync off',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final screen = await screenOn(laptop);

      await screen.changeFolder(p.join(world.root.path, 'unmounted drive'));

      expect(screen.state.setupProblem, SyncLocationProblem.notFound);
      expect(screen.state.enabled, isFalse);
      expect((await appOn(laptop).setup()).enabled, isFalse);
    });

    test(
        'turned off, sync stays off at the next start, until a Sync Location is set up again',
        () async {
      final laptop = await world.device('laptop', enabled: false);
      final screen = await screenOn(laptop);
      await screen.changeFolder(world.locationPath);
      await screen.disable();
      expect(screen.state.enabled, isFalse);

      final restarted = appOn(laptop);
      await restarted.start();
      final again = SyncCubit(restarted);
      addTearDown(again.close);
      await again.load();
      expect(again.state.enabled, isFalse);

      final server = await world.otherLocation('server');
      await again.changeFolder(server);
      expect(again.state.enabled, isTrue);
      expect(again.state.folder, server);
    });

    test('changing to a folder that cannot be used says why', () async {
      final laptop = await world.device('laptop', enabled: false);
      final screen = await screenOn(laptop);
      await screen.enable(world.locationPath, deviceName: 'laptop');

      await screen.changeFolder(p.join(world.root.path, 'unmounted drive'));

      expect(screen.state.setupProblem, SyncLocationProblem.notFound);
      expect(screen.state.folder, world.locationPath);
      expect(screen.state.enabled, isTrue);
    });
  });
}
