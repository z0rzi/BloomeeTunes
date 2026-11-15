import 'dart:io';

import 'package:Bloomee/core/models/sync/sync_setup.dart';
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
    expect(await locationFiles(), hasLength(1),
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
}
