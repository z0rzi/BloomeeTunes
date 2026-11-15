
import 'package:flutter_test/flutter_test.dart';

import 'support/isar_test_support.dart';
import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncWorld world;

  setUpAll(initializeTestIsar);
  setUp(() async => world = await SyncWorld.create());
  tearDown(() => world.dispose());

  Future<void> later() async => world.clock.advance(const Duration(minutes: 5));

  /// The known Devices as [device] lists them: name, last sync time and
  /// whether it is [device] itself, by name.
  Future<Map<String, (DateTime?, bool)>> devicesSeenBy(
          SyncDevice device) async =>
      {
        for (final known in await device.engine.knownDevices())
          known.deviceName: (known.lastSyncedAt, known.isThisDevice)
      };

  test('every known Device is listed with its name and last sync time',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    final c = await world.device('desktop');
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    final aPublished = a.clock();
    await later();
    await b.sync();
    final bSynced = b.clock();
    await later();
    await a.sync();
    final aSynced = a.clock();

    expect(await devicesSeenBy(a), {
      'laptop': (aSynced, true),
      'phone': (bSynced, false),
    });
    expect(await devicesSeenBy(c), {
      'laptop': (aPublished, false),
      'phone': (bSynced, false),
      'desktop': (null, true),
    });
  });

  test(
      'a Device that keeps syncing with nothing to change still shows as current, within the hour',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    await b.sync();

    world.clock.advance(const Duration(hours: 5));
    await b.sync();
    final bSynced = b.clock();
    await a.sync();

    final (seen, _) = (await devicesSeenBy(a))['phone']!;
    expect(bSynced.difference(seen!), lessThan(const Duration(hours: 1)));
  });

  /// [device]'s permanent ID as [seenBy] knows it.
  Future<String> idOf(SyncDevice seenBy, SyncDevice device) async =>
      (await seenBy.engine.knownDevices())
          .singleWhere((known) => known.deviceName == device.name)
          .deviceId;

  group('Forget a Device', () {
    late SyncDevice a;
    late SyncDevice b;
    late SyncDevice c;

    setUp(() async {
      a = await world.device('laptop');
      b = await world.device('old phone');
      c = await world.device('desktop');
      await a.add('Road trip', [song('yt::1')]);
      for (final device in [a, b, c]) {
        await device.sync();
      }
      await later();
      await b.add('Road trip', [song('yt::2')]);
      await b.add('Focus', [song('yt::3')]);
      await b.remove('Road trip', 'yt::1');
      await b.playlists.setTrackLiked(song('yt::4'), true);
      await b.sync();
      await c.sync();
      await a.sync();
    });

    test(
        'deletes its Device State from the Sync Location and removes nothing from any library',
        () async {
      final libraries = [
        for (final device in [a, b, c]) await device.syncedLibrary()
      ];
      expect(await a.songsOf('Road trip'), ['yt::2'],
          reason: 'the old phone\'s changes reached the laptop');

      await a.engine.forgetDevice(await idOf(a, b));
      expect(world.stateOf(b).existsSync(), isFalse);
      await later();
      for (final device in [a, c, a, c]) {
        await device.sync();
      }

      expect([
        for (final device in [a, b, c]) await device.syncedLibrary()
      ], libraries);
      expect((await devicesSeenBy(a)).keys,
          unorderedEquals(['laptop', 'desktop']));
      expect((await devicesSeenBy(c)).keys,
          unorderedEquals(['laptop', 'desktop']));
    });

    test('a forgotten Device that syncs again simply reappears', () async {
      await a.engine.forgetDevice(await idOf(a, b));
      await later();
      await a.add('Party', [song('yt::5')]);
      await a.sync();
      await later();
      await b.add('Focus', [song('yt::6')]);
      await b.sync();
      final bSynced = b.clock();
      await a.sync();
      await c.sync();

      expect((await devicesSeenBy(a))['old phone'], (bSynced, false));
      for (final device in [a, b, c]) {
        expect(await device.songsOf('Focus'), ['yt::3', 'yt::6'],
            reason: device.name);
        expect(await device.songsOf('Party'), ['yt::5'], reason: device.name);
        expect(await device.songsOf('Road trip'), ['yt::2'],
            reason: device.name);
      }
    });

    test('is refused for this Device itself', () async {
      await expectLater(
          a.engine.forgetDevice(a.id), throwsA(isA<ArgumentError>()));
      expect(world.stateOf(a).existsSync(), isTrue);
    });
  });

  test('no Device is ever forgotten automatically, however long it is away',
      () async {
    final a = await world.device('laptop');
    final drawer = await world.device('phone in a drawer');
    await drawer.add('Road trip', [song('yt::1')]);
    await drawer.sync();
    final drawerSynced = drawer.clock();
    await a.sync();

    for (var month = 0; month < 24; month++) {
      world.clock.advance(const Duration(days: 31));
      await a.add('Month $month', [song('yt::m$month')]);
      await a.sync();
    }

    expect(world.stateOf(drawer).existsSync(), isTrue);
    expect(a.location.deleted, isEmpty);
    expect(
        (await devicesSeenBy(a))['phone in a drawer'], (drawerSynced, false));
  });

  group('turning sync off', () {
    late SyncDevice a;
    late SyncDevice b;

    setUp(() async {
      a = await world.device('laptop');
      b = await world.device('phone');
      await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
      await a.add('Focus', [song('yt::4')]);
      await a.playlists.setTrackLiked(song('yt::5'), true);
      await a.sync();
      await b.sync();
      await later();
    });

    test(
        'leaves the library and its Device State as they are, and the other Devices unaffected',
        () async {
      final library = await a.syncedLibrary();
      final published = await world.stateOf(a).readAsBytes();

      await a.engine.disable();
      await later();
      await b.add('Road trip', [song('yt::6')]);
      await b.sync();

      expect(await a.syncedLibrary(), library);
      expect(await world.stateOf(a).readAsBytes(), published);
      await expectLater(a.engine.syncNow(), throwsStateError);
      expect(await a.syncedLibrary(), library,
          reason: 'a Device with sync off takes nothing in');
      expect(
          await b.songsOf('Road trip'), ['yt::1', 'yt::2', 'yt::3', 'yt::6']);
      expect(await b.songsOf('Focus'), ['yt::4']);
      expect((await b.syncedLibrary())['liked'], ['yt::5']);
    });

    test(
        'and back on resumes: the changes made while off reach the other Devices, removals included',
        () async {
      await a.engine.disable();
      await a.remove('Road trip', 'yt::1');
      await a.add('Road trip', [song('yt::6')]);
      await a.rename('Road trip', 'Summer');
      await a.playlists.deletePlaylist(await a.rowId('Focus'));
      await a.playlists.setTrackLiked(song('yt::5'), false);
      await later();
      await b.add('Road trip', [song('yt::7')]);
      await b.sync();

      world.clock.advance(const Duration(days: 60));
      await a.enable();
      await a.sync();
      await b.sync();
      await a.sync();

      for (final device in [a, b]) {
        expect(await device.libraryOrder(), ['Summer'], reason: device.name);
        expect(await device.songsOf('Summer'),
            ['yt::2', 'yt::3', 'yt::6', 'yt::7'],
            reason: device.name);
        expect((await device.syncedLibrary())['liked'], isEmpty,
            reason: device.name);
      }
    });

    test('puts a playlist made meanwhile first in the library, as without sync',
        () async {
      await a.add('Party', [song('yt::8')]);
      expect(await a.libraryOrder(), ['Road trip', 'Focus', 'Party'],
          reason: 'with sync on, a new playlist goes last');

      await a.engine.disable();
      await a.add('Running', [song('yt::9')]);

      expect((await a.libraryOrder()).first, 'Running');
    });
  });

  group('changing the Sync Location', () {
    test(
        'publishes the Device State in the new place and leaves every file in the old place untouched',
        () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      await a.add('Road trip', [song('yt::1'), song('yt::2')]);
      await a.sync();
      await b.sync();
      final old = await filesIn(world.locationPath);
      final newPlace = await world.otherLocation('server');

      await later();
      await a.add('Focus', [song('yt::3')]);
      a.moveTo(newPlace);
      await a.sync();
      final c = await world.device('desktop', location: newPlace);
      await c.sync();

      expect(await filesIn(world.locationPath), old);
      expect(await c.songsOf('Road trip'), ['yt::1', 'yt::2']);
      expect(await c.songsOf('Focus'), ['yt::3']);
      expect(a.location.deleted, isEmpty);
      expect(await b.songsOf('Focus'), isNull,
          reason: 'the phone still syncs in the old place');
    });

    test(
        'resumes syncing there with the Devices that moved too, removals included',
        () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
      await a.sync();
      await b.sync();
      final newPlace = await world.otherLocation('server');

      a.moveTo(newPlace);
      await a.sync();
      b.moveTo(newPlace);
      await b.sync();
      await later();
      await a.remove('Road trip', 'yt::1');
      await b.add('Road trip', [song('yt::4')]);
      await a.sync();
      await b.sync();
      await a.sync();

      for (final device in [a, b]) {
        expect(await device.songsOf('Road trip'), ['yt::2', 'yt::3', 'yt::4'],
            reason: device.name);
      }
    });
  });
}
