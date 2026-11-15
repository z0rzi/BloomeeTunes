import 'dart:async';
import 'dart:io';

import 'package:Bloomee/services/db/global_db.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/isar_test_support.dart';
import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncWorld world;

  setUpAll(initializeTestIsar);
  setUp(() async => world = await SyncWorld.create());
  tearDown(() => world.dispose());

  test(
      'a Device that never turned sync on works as without sync: new playlists first, no Removal Markers, nothing written anywhere',
      () async {
    final laptop = await world.device('laptop', enabled: false);
    final phone = await world.device('phone');
    await phone.add('From the phone', [song('yt::9')]);
    await phone.sync();
    final location = await filesIn(world.locationPath);
    const album = AlbumSummary(id: 'yt::album', title: 'For Emma', artists: []);

    await laptop.add('Road trip', [song('yt::1'), song('yt::2')]);
    await laptop.add('Focus', [song('yt::3')]);
    await laptop.add('Old', [song('yt::4')]);
    await laptop.remove('Road trip', 'yt::1');
    await laptop.rename('Focus', 'Deep focus');
    await laptop.arrange('Road trip', ['yt::2']);
    await laptop.playlists.deletePlaylist(await laptop.rowId('Old'));
    await laptop.playlists.setTrackLiked(song('yt::5'), true);
    await laptop.playlists.setTrackLiked(song('yt::5'), false);
    await laptop.library.saveAlbum(album, sourceName: 'YouTube');
    await laptop.library.removeByMediaId('yt::album', PlaylistTypeDB.album);
    await laptop.arrangeLibrary(['Road trip', 'Deep focus']);
    await laptop.add('Running', [song('yt::6')]);

    // Without sync, a new playlist takes the first place in the library's
    // order, which it shares with the playlist there (with sync on, it
    // would go last).
    expect(await laptop.libraryOrder(), ['Road trip', 'Running', 'Deep focus']);
    expect(await laptop.songsOf('Road trip'), ['yt::2']);
    expect(await laptop.isar.syncRemovalDBs.count(), 0,
        reason: 'no Removal Marker is left');
    expect(await laptop.isar.syncDeviceDBs.count(), 0,
        reason: 'no sync bookkeeping is kept');
    expect(await laptop.protectionSnapshots(), 0);
    expect(await filesIn(world.locationPath), location,
        reason: 'nothing is written to the Sync Location');
    expect(await phone.playlistNames(), ['From the phone', 'Liked']);
  });

  test('a playlist created on one Device exists on another with its songs',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2')]);

    await a.sync();
    await b.sync();

    expect(await b.songsOf('Road trip'), ['yt::1', 'yt::2']);
  });

  test('a song added on the receiving Device reaches the first one', () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2')]);
    await a.sync();
    await b.sync();

    world.clock.advance(const Duration(minutes: 5));
    await b.add('Road trip', [song('yt::3')]);
    await b.sync();
    await a.sync();

    expect(await a.songsOf('Road trip'), ['yt::1', 'yt::2', 'yt::3']);
    expect(await b.songsOf('Road trip'), ['yt::1', 'yt::2', 'yt::3']);
    expect(await a.playlistNames(), await b.playlistNames());
  });

  test('a song the receiving Device never saw keeps its details', () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    const cover = Artwork(
        url: 'https://img.example/cover.jpg',
        urlHigh: 'https://img.example/cover_hd.jpg',
        layout: ImageLayout.square);
    await a.add('Road trip', [
      song('yt::1',
          title: 'Holocene',
          artists: const [ArtistSummary(id: 'yt::artist', name: 'Bon Iver')],
          thumbnail: cover,
          durationMs: 336000)
    ]);

    await a.sync();
    await b.sync();

    final received = (await b.tracks.getTrackByMediaId('yt::1'))!;
    expect(received.title, 'Holocene');
    expect(received.artists.map((artist) => artist.name), ['Bon Iver']);
    expect(received.thumbnail.url, 'https://img.example/cover.jpg');
    expect(received.thumbnail.urlHigh, 'https://img.example/cover_hd.jpg');
    expect(received.durationMs, BigInt.from(336000));
  });

  test('syncing again with nothing changed changes and rewrites nothing',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2')]);
    await a.sync();

    final libraryEvents = <String>[];
    Future<StreamSubscription<void>> watch(SyncDevice device) async {
      final playlists = (await device.playlists.watchAllPlaylists())
          .skip(1)
          .listen((_) => libraryEvents.add('${device.name} playlists'));
      final tracks = (await device.tracks.watchTracks())
          .listen((_) => libraryEvents.add('${device.name} tracks'));
      return playlists..onDone(tracks.cancel);
    }

    final watchB = await watch(b);
    await b.sync();
    await pumpEventQueue();
    expect(libraryEvents, contains('phone playlists'),
        reason: 'watchers see a sync that changes the library');
    await watchB.cancel();
    await a.sync();

    final writes = [
      a.location.statesWritten.length,
      b.location.statesWritten.length
    ];
    libraryEvents.clear();
    final watching = [await watch(a), await watch(b)];
    world.clock.advance(const Duration(minutes: 2));
    await a.sync();
    await b.sync();
    await a.sync();
    await pumpEventQueue();
    for (final subscription in watching) {
      await subscription.cancel();
    }

    expect([a.location.statesWritten.length, b.location.statesWritten.length],
        writes);
    expect(libraryEvents, isEmpty);
    expect(await a.songsOf('Road trip'), ['yt::1', 'yt::2']);
    expect(await b.songsOf('Road trip'), ['yt::1', 'yt::2']);
  });

  test('each Device writes only its own Device State', () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    final c = await world.device('desktop');
    await a.add('Road trip', [song('yt::1')]);
    await b.add('Focus', [song('yt::2')]);
    await c.add('Party', [song('yt::3')]);

    for (final device in [a, b, c, a, b, c]) {
      world.clock.advance(const Duration(minutes: 1));
      await device.add(device.name, [song('yt::${device.name}')]);
      await device.sync();
    }

    final files = <String>{};
    for (final device in [a, b, c]) {
      final own = device.location.statesWritten.toSet();
      expect(own, hasLength(1), reason: '${device.name} wrote $own');
      expect(own.single, startsWith('sync/'));
      expect(device.location.statesDeleted, isEmpty);
      files.addAll(own);
    }
    expect(files, hasLength(3), reason: 'no two Devices share a file');
    expect(await a.playlistNames(), await c.playlistNames());
  });

  test('a library from before Library Sync existed migrates and syncs',
      () async {
    // Made by Bloomee v3.1.0+207 (before the sync schema): playlist
    // "Road trip" holding "Song A" then "Song B", and an empty "Liked".
    final database = File(p.join(world.root.path, 'pre_sync.isar'));
    await database.writeAsBytes(gzip.decode(
        await File('test/fixtures/pre_sync_v3_1_0.isar.gz').readAsBytes()));
    final upgraded = await world.device('old-laptop', database: database);
    final fresh = await world.device('phone');

    expect(await upgraded.songsOf('Road trip'), ['plugin::a', 'plugin::b']);
    await upgraded.sync();
    await fresh.sync();

    expect(await fresh.songsOf('Road trip'), ['plugin::a', 'plugin::b']);
    expect(
        (await fresh.tracks.getTrackByMediaId('plugin::b'))!.title, 'Song B');
  });
}
