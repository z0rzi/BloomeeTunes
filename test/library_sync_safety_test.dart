import 'dart:convert';

import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/isar_test_support.dart';
import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncWorld world;

  setUpAll(initializeTestIsar);
  setUp(() async => world = await SyncWorld.create());
  tearDown(() => world.dispose());

  test(
      'a protection snapshot of the library as it was is taken before a sync that changes it, and none when nothing changes',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2')]);

    await a.sync();
    expect(await a.protectionSnapshots(), 0,
        reason: 'nothing came in from another Device');

    await b.sync();
    expect(await b.protectionSnapshots(), 1);
    expect(await b.latestSnapshotPlaylists(), ['Liked'],
        reason: 'the snapshot holds the library from before the sync');

    world.clock.advance(const Duration(minutes: 2));
    await a.sync();
    await b.sync();
    expect(await a.protectionSnapshots(), 0);
    expect(await b.protectionSnapshots(), 1);
  });

  List<String> ids(int from, int to) =>
      [for (var i = from; i <= to; i++) 'yt::$i'];

  /// Two Devices holding "Road trip" with [songs] songs (by default 20, the
  /// smallest library the quarter rule applies to), the first then taking
  /// [removed] of them out.
  Future<(SyncDevice, SyncDevice)> roadTripLosing(List<String> removed,
      {int songs = 20}) async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip',
        [for (final id in ids(1, songs)) song(id, title: 'Song $id')]);
    await a.sync();
    await b.sync();
    world.clock.advance(const Duration(minutes: 5));
    for (final id in removed) {
      await a.remove('Road trip', id);
    }
    await a.sync();
    return (a, b);
  }

  test(
      'a sync that would remove more than a quarter of the songs is held: nothing is applied, and it tells what and from which Device',
      () async {
    final (_, b) = await roadTripLosing(ids(1, 6));

    final outcome = await b.engine.syncNow();

    expect(outcome, isA<SyncHeld>());
    final hold = (outcome as SyncHeld).hold;
    expect(outcome.declined, isFalse);
    expect(await b.songsOf('Road trip'), ids(1, 20));
    expect(hold.songsRemoved, 6);
    expect(hold.songsInLibrary, 20);
    expect(hold.deviceNames, {'laptop'});
    expect(
        [
          for (final r in hold.removals)
            (r.kind, r.playlistName, r.mediaId, r.title)
        ],
        unorderedEquals([
          for (final id in ids(1, 6))
            (RemovalKind.song, 'Road trip', id, 'Song $id')
        ]));
  });

  test(
      'in a library of fewer than 20 songs, a sync removing more than a quarter of them is applied without being held, after a protection snapshot',
      () async {
    final (_, b) = await roadTripLosing(ids(1, 10), songs: 19);
    final snapshotsBefore = await b.protectionSnapshots();

    final outcome = await b.engine.syncNow();

    expect(outcome, isA<SyncCompleted>());
    expect(await b.songsOf('Road trip'), ids(11, 19));
    expect(await b.protectionSnapshots(), snapshotsBefore + 1);
    expect(await b.latestSnapshotPlaylists(), ['Liked', 'Road trip']);
  });

  test('a sync removing exactly a quarter of the songs is not held', () async {
    final (_, b) = await roadTripLosing(ids(1, 5));

    final outcome = await b.engine.syncNow();

    expect(outcome, isA<SyncCompleted>());
    expect(await b.songsOf('Road trip'), ids(6, 20));
  });

  test('confirming a held sync applies it', () async {
    final (a, b) = await roadTripLosing(ids(1, 6));
    final held = await b.engine.syncNow() as SyncHeld;

    final outcome = await b.engine.answerRemovalGuard(held.hold, confirm: true);

    expect(outcome, isA<SyncCompleted>());
    expect(await b.songsOf('Road trip'), ids(7, 20));
    world.clock.advance(const Duration(minutes: 1));
    await a.sync();
    expect(await a.songsOf('Road trip'), ids(7, 20));
  });

  test(
      'confirming a held sync that has since grown to remove more holds it again',
      () async {
    final (a, b) = await roadTripLosing(ids(1, 6));
    final shown = await b.engine.syncNow() as SyncHeld;
    world.clock.advance(const Duration(minutes: 1));
    await a.remove('Road trip', 'yt::7');
    await a.sync();
    // A scheduled sync while the owner reads what was shown.
    expect(await b.engine.syncNow(), isA<SyncHeld>());

    final outcome =
        await b.engine.answerRemovalGuard(shown.hold, confirm: true);

    expect(outcome, isA<SyncHeld>());
    expect((outcome as SyncHeld).hold.songsRemoved, 7);
    expect(await b.songsOf('Road trip'), ids(1, 20));
  });

  test(
      'declining a held sync leaves the library untouched and sync paused until the owner confirms it',
      () async {
    final (a, b) = await roadTripLosing(ids(1, 6));
    final held = await b.engine.syncNow() as SyncHeld;

    final declined =
        await b.engine.answerRemovalGuard(held.hold, confirm: false);
    expect(
        declined, isA<SyncHeld>().having((h) => h.declined, 'declined', true));

    // Paused: nothing comes in or goes out, even across a restart.
    world.clock.advance(const Duration(minutes: 1));
    await a.add('Road trip', [song('yt::21')]);
    await a.sync();
    await b.add('Focus', [song('yt::30')]);
    final restarted = b.restartedEngine();
    final paused = await restarted.syncNow();
    expect(paused, isA<SyncHeld>().having((h) => h.declined, 'declined', true));
    expect((paused as SyncHeld).hold.songsRemoved, 6);
    expect(await b.songsOf('Road trip'), ids(1, 20));
    await a.sync();
    expect(await a.songsOf('Focus'), isNull);

    final confirmed =
        await restarted.answerRemovalGuard(paused.hold, confirm: true);
    expect(confirmed, isA<SyncCompleted>());
    expect(await b.songsOf('Road trip'), [...ids(7, 20), 'yt::21']);
    await a.sync();
    expect(await a.songsOf('Focus'), ['yt::30']);
  });

  /// Two Devices holding five one-song playlists and, [withArchive], a large
  /// "Archive", the first then deleting [deleted] of the one-song ones.
  Future<SyncDevice> playlistsDeleted(int deleted,
      {bool withArchive = true}) async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    if (withArchive) {
      await a.add('Archive', [for (final id in ids(100, 139)) song(id)]);
    }
    for (var i = 1; i <= 5; i++) {
      await a.add('Mix $i', [song('yt::$i')]);
    }
    await a.sync();
    await b.sync();
    world.clock.advance(const Duration(minutes: 5));
    for (var i = 1; i <= deleted; i++) {
      await a.playlists.deletePlaylistByName('Mix $i');
    }
    await a.sync();
    return b;
  }

  test('a sync that would delete more than three playlists is held', () async {
    final b = await playlistsDeleted(4);

    final outcome = await b.engine.syncNow();

    expect(outcome, isA<SyncHeld>());
    final hold = (outcome as SyncHeld).hold;
    expect(hold.playlistsDeleted, 4);
    expect(hold.deviceNames, {'laptop'});
    expect([
      for (final r in hold.removals)
        if (r.kind == RemovalKind.playlist) r.playlistName
    ], unorderedEquals(['Mix 1', 'Mix 2', 'Mix 3', 'Mix 4']));
    expect(await b.playlistNames(),
        ['Archive', 'Liked', 'Mix 1', 'Mix 2', 'Mix 3', 'Mix 4', 'Mix 5']);
  });

  test(
      'a sync that would delete more than three playlists is held in a library of fewer than 20 songs too',
      () async {
    final b = await playlistsDeleted(4, withArchive: false);

    final outcome = await b.engine.syncNow();

    expect(outcome, isA<SyncHeld>());
    final hold = (outcome as SyncHeld).hold;
    expect(hold.songsInLibrary, 5);
    expect(hold.playlistsDeleted, 4);
    expect(await b.playlistNames(),
        ['Liked', 'Mix 1', 'Mix 2', 'Mix 3', 'Mix 4', 'Mix 5']);
  });

  test('a sync deleting three playlists and few songs is not held', () async {
    final b = await playlistsDeleted(3);

    final outcome = await b.engine.syncNow();

    expect(outcome, isA<SyncCompleted>());
    expect(await b.playlistNames(), ['Archive', 'Liked', 'Mix 4', 'Mix 5']);
  });

  test(
      'a Device State with a change more than a day ahead of this Device\'s clock is not merged, and the Device is named',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    final c = await world.device('desktop');
    a.clockAhead = const Duration(days: 1, minutes: 1);
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    await c.add('Focus', [song('yt::2')]);
    await c.sync();

    final outcome = await b.sync();

    expect(outcome, isA<SyncCompleted>());
    expect(outcome.skipped, [
      isA<DeviceStateFromFuture>()
          .having((s) => s.deviceName, 'deviceName', 'laptop')
          .having((s) => s.deviceId, 'deviceId', a.id)
    ]);
    expect(await b.playlistNames(), ['Focus', 'Liked']);
  });

  test('a Device State a few minutes ahead is merged normally', () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    a.clockAhead = const Duration(minutes: 5);
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();

    final outcome = await b.sync();

    expect(outcome.skipped, isEmpty);
    expect(await b.songsOf('Road trip'), ['yt::1']);
  });

  test(
      'a damaged or unreadable Device State is skipped and reported; the others are still merged',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    final c = await world.device('desktop');
    final d = await world.device('tablet');
    final e = await world.device('old-phone');
    await c.add('Focus', [song('yt::2')]);
    await c.sync();
    await d.add('Party', [song('yt::3')]);
    await d.sync();
    await e.add('Chill', [song('yt::4')]);
    await e.sync();
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    // The laptop's is cut short, the tablet's lacks a song's details, and
    // the old phone's holds a kind of artwork no build knows.
    final cut = await world.stateOf(a).readAsBytes();
    await world.stateOf(a).writeAsBytes(cut.sublist(0, cut.length ~/ 2));
    final tablet = jsonDecode(await world.stateOf(d).readAsString())
        as Map<String, dynamic>;
    (tablet['tracks'] as List).clear();
    await world.stateOf(d).writeAsString(jsonEncode(tablet));
    final oldPhone = jsonDecode(await world.stateOf(e).readAsString())
        as Map<String, dynamic>;
    for (final track in oldPhone['tracks'] as List) {
      (track as Map<String, dynamic>)['thumbnail']['layout'] = 'hexagon';
    }
    await world.stateOf(e).writeAsString(jsonEncode(oldPhone));

    final outcome = await b.sync();

    expect(outcome, isA<SyncCompleted>());
    expect(
        outcome.skipped,
        unorderedEquals([
          isA<DamagedDeviceState>().having((s) => s.deviceId, 'deviceId', a.id),
          isA<DamagedDeviceState>()
              .having((s) => s.deviceId, 'deviceId', d.id)
              .having((s) => s.deviceName, 'deviceName', 'tablet'),
          isA<DamagedDeviceState>().having((s) => s.deviceId, 'deviceId', e.id),
        ]));
    expect(await b.playlistNames(), ['Focus', 'Liked']);
    expect(await b.songsOf('Focus'), ['yt::2']);
  });

  /// [device]'s Device State, rewritten as if in format [version].
  Future<void> publishAsVersion(SyncDevice device, int version) async {
    final state = jsonDecode(await world.stateOf(device).readAsString())
        as Map<String, dynamic>;
    state['formatVersion'] = version;
    await world.stateOf(device).writeAsString(jsonEncode(state));
  }

  test(
      'a Device State in a newer format stops sync and asks for an update; an older one is read',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    final c = await world.device('desktop');
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    await c.add('Focus', [song('yt::2')]);
    await c.sync();
    await b.add('Party', [song('yt::3')]);
    await publishAsVersion(a, DeviceState.formatVersion + 1);

    final stopped = await b.sync();

    expect(
        stopped,
        isA<SyncUpdateNeeded>()
            .having((u) => u.deviceName, 'deviceName', 'laptop')
            .having((u) => u.formatVersion, 'formatVersion',
                DeviceState.formatVersion + 1));
    expect(await b.playlistNames(), ['Liked', 'Party']);
    expect(world.stateOf(b).existsSync(), isFalse,
        reason: 'nothing is published');

    await publishAsVersion(a, DeviceState.formatVersion - 1);
    final resumed = await b.sync();

    expect(resumed, isA<SyncCompleted>());
    expect(await b.playlistNames(), ['Focus', 'Liked', 'Party', 'Road trip']);
  });

  test('a failure while applying a sync leaves the library exactly as before',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [for (final id in ids(1, 8)) song(id)]);
    await a.add('Focus', [song('yt::20')]);
    await a.sync();
    await b.sync();
    world.clock.advance(const Duration(minutes: 5));
    await a.remove('Road trip', 'yt::1');
    await a.rename('Focus', 'Deep focus');
    await a.add('Party', [song('yt::30'), song('yt::31')]);
    await a.arrange('Road trip', ['yt::8', 'yt::2', 'yt::3']);
    await a.playlists.setTrackLiked(song('yt::40'), true);
    await a.sync();
    final before = await b.syncedLibrary();
    final failing =
        b.restartedEngine(beforeCommit: () => throw StateError('interrupted'));

    await expectLater(failing.syncNow(), throwsA(anything));

    expect(await b.syncedLibrary(), before);
    expect(await b.tracks.getTrackByMediaId('yt::30'), isNull);
    await b.sync();
    expect(await b.syncedLibrary(), await a.syncedLibrary());
  });

  group('three Devices changing their libraries apart end identical', () {
    final orders = [
      ['laptop', 'phone', 'desktop'],
      ['laptop', 'desktop', 'phone'],
      ['phone', 'laptop', 'desktop'],
      ['phone', 'desktop', 'laptop'],
      ['desktop', 'laptop', 'phone'],
      ['desktop', 'phone', 'laptop'],
    ];
    for (final order in orders) {
      test('syncing in the order ${order.join(', ')}', () async {
        final a = await world.device('laptop');
        final b = await world.device('phone');
        final c = await world.device('desktop');
        await a.add('Road trip', [for (final id in ids(1, 20)) song(id)]);
        await a.add('Focus', [for (final id in ids(21, 24)) song(id)]);
        await a.add('Old', [song('yt::25'), song('yt::26')]);
        await a.playlists.setTrackLiked(song('yt::27'), true);
        await a.playlists.setTrackLiked(song('yt::28'), true);
        for (final device in [a, b, c, a, b]) {
          await device.sync();
        }

        world.clock.advance(const Duration(minutes: 1));
        await a.remove('Road trip', 'yt::1');
        await a.add('Road trip', [song('yt::50')]);
        await a.rename('Old', 'Older');
        await a.playlists.setTrackLiked(song('yt::60'), true);
        await a.library.saveAlbum(
            const AlbumSummary(id: 'yt::album', title: 'For Emma', artists: []),
            sourceName: 'YouTube');

        world.clock.advance(const Duration(minutes: 1));
        await b.arrange('Road trip', ids(1, 20).reversed.toList());
        await b.add('Road trip', [song('yt::51')]);
        await b.playlists.setTrackLiked(song('yt::27'), false);
        await b.playlists.deletePlaylistByName('Focus');

        world.clock.advance(const Duration(minutes: 1));
        await c.add('Party', [song('yt::70'), song('yt::71')]);
        await c.add('Focus', [song('yt::52')]);
        await c.playlists
            .updatePlaylistMeta(await c.rowId('Old'), description: 'Keepers');
        await c.arrangeLibrary(['Party', 'Road trip', 'Old', 'Focus']);
        await c.library.saveArtist(
            const ArtistSummary(id: 'yt::artist', name: 'Bon Iver'),
            sourceName: 'YouTube');

        final devices = {
          for (final d in [a, b, c]) d.name: d
        };
        for (var round = 0; round < 2; round++) {
          for (final name in order) {
            world.clock.advance(const Duration(seconds: 10));
            await devices[name]!.sync();
          }
        }

        final expected = {
          'playlists': [
            [
              'Party',
              null,
              false,
              ['yt::70', 'yt::71']
            ],
            [
              'Road trip',
              null,
              false,
              [...ids(2, 20).reversed, 'yt::50', 'yt::51']
            ],
            [
              'Older',
              'Keepers',
              false,
              ['yt::25', 'yt::26']
            ],
            [
              'Focus',
              null,
              false,
              [...ids(21, 24), 'yt::52']
            ],
          ],
          'liked': ['yt::28', 'yt::60'],
          'albums': ['yt::album'],
          'artists': ['yt::artist'],
        };
        for (final device in [a, b, c]) {
          expect(await device.syncedLibrary(), expected, reason: device.name);
        }
      });
    }
  });

  test(
      'this Device\'s own Device State, written by a newer build it ran before, stops sync and is kept',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    await b.sync();
    await publishAsVersion(b, DeviceState.formatVersion + 1);
    final published = await world.stateOf(b).readAsString();
    world.clock.advance(const Duration(minutes: 1));
    await b.add('Focus', [song('yt::2')]);

    final outcome = await b.sync();

    expect(
        outcome,
        isA<SyncUpdateNeeded>()
            .having((u) => u.deviceId, 'deviceId', b.id)
            .having((u) => u.formatVersion, 'formatVersion',
                DeviceState.formatVersion + 1));
    expect(await world.stateOf(b).readAsString(), published);
  });
}
