import 'dart:convert';

import 'package:Bloomee/repository/sync/sync_engine.dart';
import 'package:Bloomee/services/db/global_db.dart';
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

  Future<void> later() async => world.clock.advance(const Duration(minutes: 5));
  Future<void> monthsLater(int months) async =>
      world.clock.advance(Duration(days: 31 * months));

  Future<void> settle(List<SyncDevice> devices) async {
    for (var round = 0; round < 2; round++) {
      for (final device in devices) {
        await device.sync();
      }
    }
  }

  const artist = ArtistSummary(id: 'yt::artist', name: 'Bon Iver');
  const album = AlbumSummary(
      id: 'yt::album', title: 'For Emma', artists: [artist], year: 2007);
  const other = AlbumSummary(id: 'yt::other', title: 'i,i', artists: []);

  Future<List<String>> albumsOf(SyncDevice device) async =>
      [for (final x in await device.library.getSavedAlbums()) x.id]..sort();
  Future<List<String>> artistsOf(SyncDevice device) async =>
      [for (final x in await device.library.getSavedArtists()) x.id]..sort();
  Future<List<String>?> sortedSongsOf(SyncDevice device, String name) async =>
      (await device.songsOf(name))?..sort();

  group('two Devices that each had a library before their First Sync', () {
    late SyncDevice a;
    late SyncDevice b;

    setUp(() async {
      a = await world.device('laptop', enabled: false);
      b = await world.device('phone', enabled: false);
      await a.add('Road trip', [song('yt::1'), song('yt::2')]);
      await a.add('Focus', [song('yt::4')]);
      await a.playlists.setTrackLiked(song('yt::7'), true);
      await a.library.saveAlbum(album, sourceName: 'YouTube');
      await later();
      await b.add('road TRIP', [song('yt::2'), song('yt::3')]);
      await b.add('Party', [song('yt::5')]);
      await b.playlists.setTrackLiked(song('yt::8'), true);
      await b.library.saveAlbum(other, sourceName: 'YouTube');
      await b.library.saveArtist(artist, sourceName: 'YouTube');
      await a.enable();
      await b.enable();
      await a.sync();
      await b.sync();
      await a.sync();
    });

    test(
        'end with one playlist for the same name, ignoring case, holding the songs of both',
        () async {
      for (final device in [a, b]) {
        final names = await device.libraryOrder();
        expect(
            names.where((n) => n.toLowerCase() == 'road trip').toList().length,
            1,
            reason: device.name);
        final name = names.firstWhere((n) => n.toLowerCase() == 'road trip');
        expect(await sortedSongsOf(device, name), ['yt::1', 'yt::2', 'yt::3'],
            reason: device.name);
      }
    });

    test('keep playlists of different names apart, both on both Devices',
        () async {
      for (final device in [a, b]) {
        expect(await device.songsOf('Focus'), ['yt::4'], reason: device.name);
        expect(await device.songsOf('Party'), ['yt::5'], reason: device.name);
        expect(await device.libraryOrder(), hasLength(3), reason: device.name);
      }
    });

    test('combine their liked songs, as liked songs', () async {
      for (final device in [a, b]) {
        expect(await device.playlists.isTrackLiked('yt::7'), isTrue,
            reason: device.name);
        expect(await device.playlists.isTrackLiked('yt::8'), isTrue,
            reason: device.name);
        expect(await device.libraryOrder(), hasLength(3),
            reason: 'liked songs pair as liked songs, not as a playlist');
      }
    });

    test('combine their saved albums and artists', () async {
      for (final device in [a, b]) {
        expect(await albumsOf(device), ['yt::album', 'yt::other'],
            reason: device.name);
        expect(await artistsOf(device), ['yt::artist'], reason: device.name);
      }
    });
  });

  test(
      'a First Sync removes nothing from any Device, even what other Devices removed after the new Device had it',
      () async {
    final c = await world.device('desktop', enabled: false);
    await c.add('road trip', [song('yt::2')]);
    await c.add('Mix', [song('yt::9')]);
    await c.playlists.setTrackLiked(song('yt::7'), true);
    await c.library.saveAlbum(album, sourceName: 'YouTube');
    await later();

    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
    await a.playlists.setTrackLiked(song('yt::7'), true);
    await a.library.saveAlbum(album, sourceName: 'YouTube');
    await settle([a, b]);
    await later();
    await a.remove('Road trip', 'yt::2');
    await a.playlists.setTrackLiked(song('yt::7'), false);
    await a.library.removeByMediaId('yt::album', PlaylistTypeDB.album);
    await settle([a, b]);
    expect(await b.songsOf('Road trip'), ['yt::1', 'yt::3']);

    await later();
    await c.enable();
    await c.sync();
    expect(await sortedSongsOf(c, 'road trip'), ['yt::1', 'yt::2', 'yt::3'],
        reason: 'the new Device keeps what it had');
    expect(await c.playlists.isTrackLiked('yt::7'), isTrue);
    expect(await albumsOf(c), ['yt::album']);
    expect(await c.songsOf('Mix'), ['yt::9']);

    await settle([a, b, c]);
    for (final device in [a, b, c]) {
      final name = (await device.libraryOrder())
          .firstWhere((n) => n.toLowerCase() == 'road trip');
      expect(await sortedSongsOf(device, name), ['yt::1', 'yt::2', 'yt::3'],
          reason: device.name);
      expect(await device.playlists.isTrackLiked('yt::7'), isTrue,
          reason: device.name);
      expect(await albumsOf(device), ['yt::album'], reason: device.name);
      expect(await device.songsOf('Mix'), ['yt::9'], reason: device.name);
    }
  });

  test(
      'after its First Sync a Device syncs normally: its later removals reach the others',
      () async {
    final a = await world.device('laptop');
    await a.add('Road trip', [song('yt::1'), song('yt::2')]);
    await a.add('Focus', [song('yt::4')]);
    await a.playlists.setTrackLiked(song('yt::7'), true);
    await a.sync();
    await later();
    await a.remove('Road trip', 'yt::2');
    await a.sync();

    final c = await world.device('desktop', enabled: false);
    await c.add('Road trip', [song('yt::2'), song('yt::3')]);
    await c.enable();
    await settle([c, a]);

    await later();
    await c.remove('Road trip', 'yt::2');
    await c.remove('Road trip', 'yt::1');
    await c.playlists.setTrackLiked(song('yt::7'), false);
    await c.playlists.deletePlaylistByName('Focus');
    await settle([c, a]);

    for (final device in [a, c]) {
      expect(await device.songsOf('Road trip'), ['yt::3'], reason: device.name);
      expect(await device.playlists.isTrackLiked('yt::7'), isFalse,
          reason: device.name);
      expect(await device.songsOf('Focus'), isNull, reason: device.name);
    }
  });

  group('a Device whose last sync is more than six months old', () {
    late SyncDevice a;
    late SyncDevice b;

    setUp(() async {
      a = await world.device('laptop');
      b = await world.device('phone');
      await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
      await a.add('Focus', [song('yt::4')]);
      await a.playlists.setTrackLiked(song('yt::7'), true);
      await a.library.saveAlbum(album, sourceName: 'YouTube');
      await settle([a, b]);
    });

    test('performs a First Sync: it only adds, to itself and to the others',
        () async {
      await monthsLater(1);
      // Taken out on the phone while it no longer synced.
      await b.remove('Road trip', 'yt::3');
      await monthsLater(6);
      await a.remove('Road trip', 'yt::2');
      await a.playlists.setTrackLiked(song('yt::7'), false);
      await a.library.removeByMediaId('yt::album', PlaylistTypeDB.album);
      await a.playlists.deletePlaylistByName('Focus');
      await a.sync();
      await later();

      await b.sync();
      expect(await sortedSongsOf(b, 'Road trip'), ['yt::1', 'yt::2', 'yt::3']);
      expect(await b.songsOf('Focus'), ['yt::4']);
      expect(await b.playlists.isTrackLiked('yt::7'), isTrue);
      expect(await albumsOf(b), ['yt::album']);

      await settle([a, b]);
      for (final device in [a, b]) {
        expect(await sortedSongsOf(device, 'Road trip'),
            ['yt::1', 'yt::2', 'yt::3'],
            reason: device.name);
        expect(await device.songsOf('Focus'), ['yt::4'], reason: device.name);
        expect(await device.playlists.isTrackLiked('yt::7'), isTrue,
            reason: device.name);
        expect(await albumsOf(device), ['yt::album'], reason: device.name);
      }

      // And syncs normally afterwards.
      await later();
      await b.remove('Road trip', 'yt::1');
      await settle([b, a]);
      for (final device in [a, b]) {
        expect(await sortedSongsOf(device, 'Road trip'), ['yt::2', 'yt::3'],
            reason: device.name);
      }
    });

    test(
        'keeps the songs of two of its playlists that became one while it was away',
        () async {
      final c = await world.device('desktop');
      await c.add('Mix', [song('yt::5')]);
      await settle([a, b, c]);

      await monthsLater(7);
      await a.rename('Road trip', 'Party');
      await c.rename('Mix', 'Party');
      await settle([a, c]);
      await later();
      await a.remove('Party', 'yt::5');
      await settle([a, c]);
      expect(await sortedSongsOf(c, 'Party'), ['yt::1', 'yt::2', 'yt::3']);

      await b.sync();
      await settle([a, b, c]);
      for (final device in [a, b, c]) {
        expect(await sortedSongsOf(device, 'Party'),
            ['yt::1', 'yt::2', 'yt::3', 'yt::5'],
            reason: device.name);
      }
    });

    test('that synced within six months syncs normally', () async {
      await monthsLater(5);
      await a.remove('Road trip', 'yt::2');
      await a.sync();
      await b.sync();
      expect(await b.songsOf('Road trip'), ['yt::1', 'yt::3']);
    });
  });

  test(
      'a Device that went back to the official build and came back performs a First Sync',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
    await settle([a, b]);

    await later();
    await b.returnFromOfficialBuild();
    await a.remove('Road trip', 'yt::2');
    await a.sync();
    await later();
    await b.enable();
    await b.sync();
    expect(await sortedSongsOf(b, 'Road trip'), ['yt::1', 'yt::2', 'yt::3']);

    await settle([a, b]);
    for (final device in [a, b]) {
      expect(await device.libraryOrder(), ['Road trip'], reason: device.name);
      expect(
          await sortedSongsOf(device, 'Road trip'), ['yt::1', 'yt::2', 'yt::3'],
          reason: device.name);
    }

    await later();
    await b.remove('Road trip', 'yt::3');
    await settle([b, a]);
    for (final device in [a, b]) {
      expect(await sortedSongsOf(device, 'Road trip'), ['yt::1', 'yt::2'],
          reason: device.name);
    }
  });

  test(
      'Removal Markers older than six months are dropped from every Device State',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    final c = await world.device('desktop');
    await a.add('Road trip', [song('yt::1'), song('yt::gone')]);
    await settle([a, b, c]);
    await later();
    await a.remove('Road trip', 'yt::gone');
    await settle([a, b, c]);
    for (final device in [a, b, c]) {
      expect(await world.stateOf(device).readAsString(), contains('yt::gone'),
          reason: 'the Removal Marker is kept while recent');
    }

    // The desktop does not sync again; its Device State keeps the marker.
    await monthsLater(7);
    await settle([a, b]);
    for (final device in [a, b]) {
      expect(await world.stateOf(device).readAsString(),
          isNot(contains('yt::gone')),
          reason: device.name);
      expect(await device.songsOf('Road trip'), ['yt::1'], reason: device.name);
    }
  });

  group('a Device that stopped syncing more than six months ago', () {
    late SyncDevice a;
    late SyncDevice b;
    late SyncDevice drawer;

    setUp(() async {
      a = await world.device('laptop');
      b = await world.device('phone');
      drawer = await world.device('phone in a drawer');
      await a.add('Road trip', [song('yt::1'), song('yt::2')]);
      await a.add('Old', [song('yt::3')]);
      await settle([a, b, drawer]);
    });

    test(
        'is not merged, yet stays listed among the known Devices and its Device State stays',
        () async {
      await later();
      await drawer.add('Party', [song('yt::5')]);
      await drawer.sync();
      final drawerSynced = drawer.clock();

      await monthsLater(7);
      await settle([a, b]);
      for (final device in [a, b]) {
        expect(await device.songsOf('Party'), isNull, reason: device.name);
        expect(device.location.statesDeleted, isEmpty, reason: device.name);
        expect([
          for (final known in await device.engine.knownDevices())
            if (known.deviceName == 'phone in a drawer') known.lastSyncedAt
        ], [
          drawerSynced
        ], reason: device.name);
      }
      expect(world.stateOf(drawer).existsSync(), isTrue);
    });

    test(
        'does not bring back a song or a playlist removed after it stopped, once the removal is six months old',
        () async {
      await later();
      await a.remove('Road trip', 'yt::2');
      await a.playlists.deletePlaylistByName('Old');
      await settle([a, b]);

      await monthsLater(7);
      await settle([a, b]);
      for (final device in [a, b]) {
        expect(await device.songsOf('Road trip'), ['yt::1'],
            reason: device.name);
        expect(await device.songsOf('Old'), isNull, reason: device.name);
      }
    });

    test(
        'performs a First Sync when it syncs again: it only adds, to itself and to the others',
        () async {
      await later();
      await a.remove('Road trip', 'yt::2');
      await a.add('Road trip', [song('yt::9')]);
      await a.playlists.deletePlaylistByName('Old');
      await settle([a, b]);
      await monthsLater(7);
      await settle([a, b]);

      await drawer.sync();
      expect(await sortedSongsOf(drawer, 'Road trip'),
          ['yt::1', 'yt::2', 'yt::9']);
      expect(await drawer.songsOf('Old'), ['yt::3']);
      await settle([a, b, drawer]);
      for (final device in [a, b, drawer]) {
        expect(await sortedSongsOf(device, 'Road trip'),
            ['yt::1', 'yt::2', 'yt::9'],
            reason: device.name);
        expect(await device.songsOf('Old'), ['yt::3'], reason: device.name);
      }
    });

    test(
        'performs a First Sync even when its last sync is a little more recent than its Device State',
        () async {
      // Its unchanged Device State is not rewritten within the hour.
      world.clock.advance(const Duration(minutes: 50));
      await drawer.sync();
      world.clock.advance(const Duration(minutes: 5));
      await a.remove('Road trip', 'yt::2');
      await settle([a, b]);

      world.clock.advance(
          SyncEngine.removalMarkerLifetime - const Duration(minutes: 45));
      await drawer.sync();
      expect(await sortedSongsOf(drawer, 'Road trip'), ['yt::1', 'yt::2']);
      await settle([a, b, drawer]);
      for (final device in [a, b, drawer]) {
        expect(await sortedSongsOf(device, 'Road trip'), ['yt::1', 'yt::2'],
            reason: device.name);
      }
    });
  });

  group('two playlists that came to bear the same name', () {
    late SyncDevice a;
    late SyncDevice b;
    late SyncDevice c;

    /// The pairs of playlists that became one, as [device] publishes them.
    List<dynamic> aliasesOf(SyncDevice device) =>
        (jsonDecode(world.stateOf(device).readAsStringSync())
            as Map<String, dynamic>)['aliases'] as List<dynamic>;

    setUp(() async {
      a = await world.device('laptop');
      b = await world.device('phone');
      c = await world.device('desktop');
      await a.add('Mix', [song('yt::1')]);
      await settle([a, b, c]);
      await later();
      await b.add('Party', [song('yt::2')]);
      await a.rename('Mix', 'Party');
    });

    test(
        'are no longer recorded as one six months later, and a Device that stopped syncing before does not part or join them again',
        () async {
      await settle([a, b]);
      expect(aliasesOf(a), isNotEmpty);

      for (var month = 0; month < 7; month++) {
        await monthsLater(1);
        await settle([a, b]);
      }
      for (final device in [a, b]) {
        expect(await device.libraryOrder(), ['Party'], reason: device.name);
        expect(await sortedSongsOf(device, 'Party'), ['yt::1', 'yt::2'],
            reason: device.name);
        expect(aliasesOf(device), isEmpty, reason: device.name);
      }
    });

    test(
        'stay one, past six months, until a Device that still holds them apart has synced',
        () async {
      // The laptop renamed its playlist, then stopped syncing for seven
      // months; the desktop, which took in the phone's playlist apart, last
      // synced two months before the laptop came back.
      for (var month = 0; month < 5; month++) {
        await monthsLater(1);
        await settle([b, c]);
      }
      await monthsLater(2);
      await settle([a, b]);
      await settle([a, b]);
      await later();
      await settle([c, a, b]);
      for (final device in [a, b, c]) {
        expect(await device.libraryOrder(), ['Party'], reason: device.name);
        expect(await sortedSongsOf(device, 'Party'), ['yt::1', 'yt::2'],
            reason: device.name);
      }
    });
  });
}
