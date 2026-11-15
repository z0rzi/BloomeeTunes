import 'dart:convert';

import 'package:Bloomee/core/models/backup/backup_document.dart';
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

  test(
      'a song removed from a playlist on one Device is gone from it on another',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
    await a.sync();
    await b.sync();

    await later();
    await a.remove('Road trip', 'yt::2');
    await a.sync();
    await b.sync();

    expect(await b.songsOf('Road trip'), ['yt::1', 'yt::3']);
    expect(await a.songsOf('Road trip'), ['yt::1', 'yt::3']);
  });

  test(
      'a song removed on one Device and added back later on another is present on both',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2')]);
    await a.sync();
    await b.sync();

    await later();
    await a.remove('Road trip', 'yt::2');
    await a.sync();
    await b.sync();
    expect(await b.songsOf('Road trip'), ['yt::1']);

    await later();
    await b.add('Road trip', [song('yt::2')]);
    await b.sync();
    await a.sync();

    expect(await a.songsOf('Road trip'), ['yt::1', 'yt::2']);
    expect(await b.songsOf('Road trip'), ['yt::1', 'yt::2']);
  });

  test(
      'a song added on one Device and removed later on another is absent on both',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    await b.sync();

    await later();
    await a.add('Road trip', [song('yt::2')]);
    await a.sync();
    await b.sync();
    await later();
    await b.remove('Road trip', 'yt::2');
    await b.sync();
    await a.sync();

    expect(await a.songsOf('Road trip'), ['yt::1']);
    expect(await b.songsOf('Road trip'), ['yt::1']);
  });

  test(
      'a song removed on one Device while another put it back later, before either synced, is present on both',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2')]);
    await a.sync();
    await b.sync();

    await later();
    await a.remove('Road trip', 'yt::1');
    await later();
    await b.remove('Road trip', 'yt::1');
    await later();
    await b.add('Road trip', [song('yt::1')]);
    await a.sync();
    await b.sync();
    await a.sync();

    expect(await a.songsOf('Road trip'), ['yt::2', 'yt::1']);
    expect(await b.songsOf('Road trip'), ['yt::2', 'yt::1']);
  });

  test(
      'reordering a playlist does not bring back a song removed meanwhile on another Device',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
    await a.sync();
    await b.sync();

    await later();
    await a.remove('Road trip', 'yt::2');
    await later();
    final row = (await b.playlists.getPlaylistByName('Road trip'))!;
    await b.playlists.setPlaylistTracks(
        row.id, [song('yt::3'), song('yt::2'), song('yt::1')]);
    await a.sync();
    await b.sync();
    await a.sync();

    expect(await a.songsOf('Road trip'), isNot(contains('yt::2')));
    expect(await b.songsOf('Road trip'), isNot(contains('yt::2')));
  });

  test('a playlist deleted on one Device is deleted on another', () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.add('Focus', [song('yt::2')]);
    await a.sync();
    await b.sync();

    await later();
    await a.playlists.deletePlaylistByName('Road trip');
    await a.sync();
    await b.sync();

    expect(await b.songsOf('Road trip'), isNull);
    expect(await b.songsOf('Focus'), ['yt::2']);
    expect(await a.playlistNames(), await b.playlistNames());
  });

  test(
      'a playlist deleted on one Device to which another added a song afterwards exists on both, with that song',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    await b.sync();

    await later();
    await a.playlists.deletePlaylistByName('Road trip');
    await later();
    await b.add('Road trip', [song('yt::2')]);
    await a.sync();
    await b.sync();
    await a.sync();

    expect(await a.songsOf('Road trip'), ['yt::1', 'yt::2']);
    expect(await b.songsOf('Road trip'), ['yt::1', 'yt::2']);
  });

  test(
      'a playlist deleted on one Device after the other\'s last change to it stays deleted on both',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    await b.sync();
    await later();
    await b.add('Road trip', [song('yt::2')]);
    await later();
    await b.remove('Road trip', 'yt::1');

    await later();
    await a.playlists.deletePlaylistByName('Road trip');
    await b.sync();
    await a.sync();
    await b.sync();

    expect(await a.songsOf('Road trip'), isNull);
    expect(await b.songsOf('Road trip'), isNull);
  });

  test(
      'unliking a song on one Device unlikes it on another; liking it again later restores it on both',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.playlists.setTrackLiked(song('yt::1'), true);
    await a.playlists.setTrackLiked(song('yt::2'), true);
    await a.sync();
    await b.sync();
    expect(await b.playlists.isTrackLiked('yt::1'), isTrue);

    await later();
    await a.playlists.setTrackLiked(song('yt::1'), false);
    await a.sync();
    await b.sync();
    expect(await b.playlists.isTrackLiked('yt::1'), isFalse);
    expect(await b.playlists.isTrackLiked('yt::2'), isTrue);

    await later();
    await b.playlists.setTrackLiked(song('yt::1'), true);
    await b.sync();
    await a.sync();
    expect(await a.playlists.isTrackLiked('yt::1'), isTrue);
    expect(await b.playlists.isTrackLiked('yt::1'), isTrue);
  });

  test('unsaving an album or an artist on one Device unsaves it on another',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    const artist = ArtistSummary(id: 'yt::artist', name: 'Bon Iver');
    const album = AlbumSummary(
        id: 'yt::album', title: 'For Emma', artists: [artist], year: 2007);
    const other = AlbumSummary(id: 'yt::other', title: 'i,i', artists: []);
    await a.library.saveAlbum(album, sourceName: 'YouTube');
    await a.library.saveAlbum(other, sourceName: 'YouTube');
    await a.library.saveArtist(artist, sourceName: 'YouTube');
    await a.sync();
    await b.sync();
    expect([for (final x in await b.library.getSavedAlbums()) x.title]..sort(),
        ['For Emma', 'i,i']);
    expect([for (final x in await b.library.getSavedArtists()) x.name],
        ['Bon Iver']);

    await later();
    await a.library.removeByMediaId('yt::album', PlaylistTypeDB.album);
    await a.library.removeByMediaId('yt::artist', PlaylistTypeDB.artist);
    await a.sync();
    await b.sync();

    expect([for (final x in await b.library.getSavedAlbums()) x.id],
        ['yt::other']);
    expect(await b.library.getSavedArtists(), isEmpty);
  });

  test(
      'an addition and a removal made at the same time resolve the same way on every Device',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await b.add('Road trip', [song('yt::0')]);
    await b.sync();
    await a.sync();
    await later();
    await b.add('Road trip', [song('yt::1')]);
    await b.playlists.setTrackLiked(song('yt::2'), true);
    await b.sync();

    // At one and the same time, A (not yet synced) adds what B takes out.
    await later();
    await a.add('Road trip', [song('yt::1')]);
    await a.playlists.setTrackLiked(song('yt::2'), true);
    await b.remove('Road trip', 'yt::1');
    await b.playlists.setTrackLiked(song('yt::2'), false);
    await a.sync();
    await b.sync();
    await a.sync();

    // The change of the higher Device ID wins.
    final kept = a.id.compareTo(b.id) > 0;
    for (final device in [a, b]) {
      expect(await device.songsOf('Road trip'),
          kept ? ['yt::0', 'yt::1'] : ['yt::0'],
          reason: device.name);
      expect(await device.playlists.isTrackLiked('yt::2'), kept,
          reason: device.name);
    }
  });

  group(
      'every data-access path that takes something out of the Synced Library reaches the other Device:',
      () {
    const album = AlbumSummary(id: 'yt::album', title: 'For Emma', artists: []);
    const artist = ArtistSummary(id: 'yt::artist', name: 'Bon Iver');
    Future<int> rowId(SyncDevice d, String name) async =>
        (await d.playlists.getPlaylistByName(name))!.id;
    Future<int> entryId(SyncDevice d, String playlist, String mediaId) async =>
        (await d.playlists.getPlaylistEntries(await rowId(d, playlist)))
            .firstWhere((e) => e.track.value!.mediaId == mediaId)
            .id;
    Future<void> inPlaylist(SyncDevice d) =>
        d.add('Road trip', [song('yt::1'), song('yt::2')]);
    Future<bool> songThere(SyncDevice d) async =>
        (await d.songsOf('Road trip'))!.contains('yt::1');
    Future<void> liked(SyncDevice d) async {
      await d.playlists.setTrackLiked(song('yt::1'), true);
      await d.playlists.setTrackLiked(song('yt::2'), true);
    }

    Future<bool> likeThere(SyncDevice d) => d.playlists.isTrackLiked('yt::1');
    Future<bool> albumThere(SyncDevice d) =>
        d.library.isSavedByMediaId(album.id, PlaylistTypeDB.album);
    // Replaces the library with a backup of it lacking [playlist], or only
    // its [song].
    Future<void> restoreWithout(SyncDevice d, String playlist,
        {String? song}) async {
      final data = jsonDecode(jsonEncode((await d.backup()).data))
          as Map<String, dynamic>;
      final playlists = data['playlists'] as List;
      if (song == null) {
        playlists.removeWhere((p) => p['name'] == playlist);
      } else {
        (playlists.firstWhere((p) => p['name'] == playlist)['entries'] as List)
            .remove(song);
      }
      await d.restore(BackupDocument.fromMap(data), replace: true);
    }

    final paths = <String,
        (
      Future<void> Function(SyncDevice),
      Future<void> Function(SyncDevice),
      Future<bool> Function(SyncDevice),
    )>{
      'PlaylistDAO.removeTrackFromPlaylist': (
        inPlaylist,
        (d) async => d.playlists
            .removeTrackFromPlaylist(await rowId(d, 'Road trip'), 'yt::1'),
        songThere,
      ),
      'PlaylistDAO.removeEntry': (
        inPlaylist,
        (d) async =>
            d.playlists.removeEntry(await entryId(d, 'Road trip', 'yt::1')),
        songThere,
      ),
      'PlaylistDAO.setPlaylistTracks': (
        inPlaylist,
        (d) async => d.playlists
            .setPlaylistTracks(await rowId(d, 'Road trip'), [song('yt::2')]),
        songThere,
      ),
      'PlaylistDAO.deletePlaylist': (
        inPlaylist,
        (d) async => d.playlists.deletePlaylist(await rowId(d, 'Road trip')),
        (d) async => await d.songsOf('Road trip') != null,
      ),
      'PlaylistDAO.deletePlaylistByName': (
        inPlaylist,
        (d) => d.playlists.deletePlaylistByName('Road trip'),
        (d) async => await d.songsOf('Road trip') != null,
      ),
      'PlaylistDAO.setTrackLiked': (
        liked,
        (d) => d.playlists.setTrackLiked(song('yt::1'), false),
        likeThere,
      ),
      'PlaylistDAO.removeTrackFromPlaylist on the liked songs': (
        liked,
        (d) async => d.playlists
            .removeTrackFromPlaylist(await rowId(d, 'Liked'), 'yt::1'),
        likeThere,
      ),
      'PlaylistDAO.removeEntry on the liked songs': (
        liked,
        (d) async =>
            d.playlists.removeEntry(await entryId(d, 'Liked', 'yt::1')),
        likeThere,
      ),
      'PlaylistDAO.setPlaylistTracks on the liked songs': (
        liked,
        (d) async => d.playlists
            .setPlaylistTracks(await rowId(d, 'Liked'), [song('yt::2')]),
        likeThere,
      ),
      'PlaylistDAO.deletePlaylist on the liked songs': (
        liked,
        (d) async => d.playlists.deletePlaylist(await rowId(d, 'Liked')),
        likeThere,
      ),
      'LibraryDAO.removeByMediaId for an album': (
        (d) => d.library.saveAlbum(album, sourceName: 'YouTube'),
        (d) => d.library.removeByMediaId(album.id, PlaylistTypeDB.album),
        albumThere,
      ),
      'LibraryDAO.removeByMediaId for an artist': (
        (d) => d.library.saveArtist(artist, sourceName: 'YouTube'),
        (d) => d.library.removeByMediaId(artist.id, PlaylistTypeDB.artist),
        (d) => d.library.isSavedByMediaId(artist.id, PlaylistTypeDB.artist),
      ),
      'LibraryDAO.removeSavedById': (
        (d) => d.library.saveAlbum(album, sourceName: 'YouTube'),
        (d) async => d.library.removeSavedById(await rowId(d, album.id)),
        albumThere,
      ),
      'PlaylistDAO.deletePlaylist on a saved album': (
        (d) => d.library.saveAlbum(album, sourceName: 'YouTube'),
        (d) async => d.playlists.deletePlaylist(await rowId(d, album.id)),
        albumThere,
      ),
      'BackupDAO.apply replacing the library with a backup lacking a song': (
        inPlaylist,
        (d) => restoreWithout(d, 'Road trip', song: 'yt::1'),
        songThere,
      ),
      'BackupDAO.apply replacing the library with a backup lacking a playlist':
          (
        inPlaylist,
        (d) => restoreWithout(d, 'Road trip'),
        (d) async => await d.songsOf('Road trip') != null,
      ),
      'BackupDAO.apply replacing the library with a backup lacking a like': (
        liked,
        (d) => restoreWithout(d, 'Liked', song: 'yt::1'),
        likeThere,
      ),
      'BackupDAO.apply replacing the library with a backup lacking the liked songs':
          (
        liked,
        (d) => restoreWithout(d, 'Liked'),
        likeThere,
      ),
      'BackupDAO.apply replacing the library with a backup lacking a saved album':
          (
        (d) => d.library.saveAlbum(album, sourceName: 'YouTube'),
        (d) => restoreWithout(d, album.id),
        albumThere,
      ),
    };

    for (final MapEntry(key: path, value: (arrange, takeOut, isThere))
        in paths.entries) {
      test(path, () async {
        final a = await world.device('laptop');
        final b = await world.device('phone');
        await arrange(a);
        await a.sync();
        await b.sync();
        expect(await isThere(b), isTrue, reason: 'it reached the phone');

        await later();
        await takeOut(a);
        expect(await isThere(a), isFalse, reason: 'it left the laptop');
        await a.sync();
        await b.sync();

        expect(await isThere(b), isFalse);
      });
    }
  });
}
