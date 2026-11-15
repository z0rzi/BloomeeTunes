import 'dart:io';
import 'dart:typed_data';

import 'package:Bloomee/repository/sync/sync_engine.dart';
import 'package:Bloomee/services/db/dao/library_dao.dart';
import 'package:Bloomee/services/db/dao/playlist_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/db/global_db.dart';
import 'package:Bloomee/services/sync/local_folder_sync_location.dart';
import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

/// A clock the test moves by hand.
class TestClock {
  DateTime _now = DateTime.utc(2026, 3, 1, 12);

  DateTime call() => _now;

  void advance(Duration by) => _now = _now.add(by);
}

/// Passes everything to [inner] and remembers what this Device changed.
class RecordingSyncLocation implements SyncLocation {
  final SyncLocation inner;
  final List<String> written = [];
  final List<String> deleted = [];

  RecordingSyncLocation(this.inner);

  @override
  Future<List<String>> list(String directory) => inner.list(directory);

  @override
  Future<Uint8List?> read(String path) => inner.read(path);

  @override
  Future<void> write(String path, List<int> bytes) {
    written.add(path);
    return inner.write(path, bytes);
  }

  @override
  Future<void> delete(String path) {
    deleted.add(path);
    return inner.delete(path);
  }

  @override
  Future<void> checkReachable() => inner.checkReachable();
}

/// One Bloomee install: a real database, the data-access classes the screens
/// use, and its sync engine.
class SyncDevice {
  final String name;
  final Isar isar;
  final TrackDAO tracks;
  final PlaylistDAO playlists;
  final LibraryDAO library;
  final RecordingSyncLocation location;
  final SyncEngine engine;

  /// This Device's permanent ID, which settles changes made at the same time.
  late final String id;

  SyncDevice._(this.name, this.isar, this.location, this.engine,
      DateTime Function() clock)
      : tracks = TrackDAO(Future.value(isar)),
        playlists = PlaylistDAO(
            Future.value(isar), TrackDAO(Future.value(isar)),
            clock: clock),
        library = LibraryDAO(Future.value(isar), clock: clock);

  Future<void> sync() => engine.syncNow();

  /// Turns Library Sync on.
  Future<void> enable() async =>
      id = (await engine.enable(deviceName: name)).deviceId;

  /// Creates [playlist] if needed, then adds [songs] to it, as the screens do.
  Future<void> add(String playlist, List<Track> songs) async {
    final id = await playlists.createPlaylist(playlist);
    for (final song in songs) {
      await playlists.addTrackToPlaylist(id!, song);
    }
  }

  /// Takes [mediaId] out of [playlist], as the screens do.
  Future<void> remove(String playlist, String mediaId) async {
    final row = (await playlists.getPlaylistByName(playlist))!;
    await playlists.removeTrackFromPlaylist(row.id, mediaId);
  }

  /// Media IDs of [playlist] in order, or null when it does not exist.
  Future<List<String>?> songsOf(String playlist) async {
    final row = await playlists.getPlaylistByName(playlist);
    if (row == null) return null;
    return (await playlists.getPlaylistTracks(row.id))
        .map((t) => t.mediaId)
        .toList();
  }

  Future<List<String>> playlistNames() async =>
      [for (final p in await playlists.getAllPlaylists()) p.name]..sort();

  Future<int> rowId(String playlist) async =>
      (await playlists.getPlaylistByName(playlist))!.id;

  /// Renames [playlist], as the screens do.
  Future<void> rename(String playlist, String to) async =>
      playlists.updatePlaylistMeta(await rowId(playlist), name: to);

  /// Puts the songs of [playlist] in the order of [mediaIds], as the playlist
  /// screen's drag and drop does.
  Future<void> arrange(String playlist, List<String> mediaIds) async {
    final id = await rowId(playlist);
    final position = {
      for (final e in await playlists.getPlaylistEntries(id))
        e.track.value!.mediaId: e.position
    };
    await playlists.setTrackOrder(
        id, [for (final mediaId in mediaIds) position[mediaId]!]);
  }

  /// Puts the playlists of the library in the order of [names], as the
  /// library screen's drag and drop does.
  Future<void> arrangeLibrary(List<String> names) async {
    final all = await playlists.getAllPlaylists();
    final named = {for (final p in all) p.name: p.id};
    await playlists.reorderPlaylists([
      for (final name in names) named[name]!,
      for (final p in all)
        if (!names.contains(p.name)) p.id
    ]);
  }

  /// The user playlists in the order the library shows them, without the
  /// liked songs.
  Future<List<String>> libraryOrder() async => [
        for (final p in await playlists.getAllPlaylists())
          if (p.type == PlaylistTypeDB.userPlaylist &&
              !DBProvider.standardPlaylists.contains(p.name))
            p.name
      ];
}

/// Several Devices of one person sharing a local-folder Sync Location in a
/// temporary directory, with a clock the test controls.
class SyncWorld {
  final Directory root;
  final TestClock clock = TestClock();
  final List<SyncDevice> devices = [];

  SyncWorld._(this.root);

  static Future<SyncWorld> create() async =>
      SyncWorld._(await Directory.systemTemp.createTemp('bloomee_sync_world_'));

  String get locationPath => p.join(root.path, 'location');

  /// A new Device, with sync enabled unless [enabled] is false. [database]
  /// seeds it with an existing database file instead of an empty library.
  Future<SyncDevice> device(String name,
      {File? database, bool enabled = true}) async {
    final directory = await Directory(p.join(root.path, 'devices', name))
        .create(recursive: true);
    await Directory(locationPath).create(recursive: true);
    final instance = 'sync_${name}_${root.path.hashCode.toRadixString(16)}';
    if (database != null) {
      await database.copy(p.join(directory.path, '$instance.isar'));
    }
    final isar = await Isar.open(DBProvider.schemas,
        directory: directory.path, name: instance, inspector: false);
    final location =
        RecordingSyncLocation(LocalFolderSyncLocation(locationPath));
    final engine = SyncEngine(
        database: Future.value(isar), location: location, clock: clock.call);
    final device = SyncDevice._(name, isar, location, engine, clock.call);
    await PlaylistDAO(Future.value(isar), TrackDAO(Future.value(isar)))
        .ensurePlaylist(DBProvider.likedPlaylist);
    if (enabled) await device.enable();
    devices.add(device);
    return device;
  }

  Future<void> dispose() async {
    for (final device in devices) {
      if (device.isar.isOpen) await device.isar.close();
    }
    await root.delete(recursive: true);
  }
}

Track song(String id,
        {String? title,
        List<ArtistSummary> artists = const [],
        Artwork thumbnail = const Artwork(url: '', layout: ImageLayout.square),
        int? durationMs}) =>
    Track(
        id: id,
        title: title ?? id,
        artists: artists,
        thumbnail: thumbnail,
        durationMs: durationMs == null ? null : BigInt.from(durationMs),
        isExplicit: false);
