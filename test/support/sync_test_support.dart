import 'dart:io';
import 'dart:typed_data';

import 'package:Bloomee/repository/sync/sync_engine.dart';
import 'package:Bloomee/services/db/dao/playlist_dao.dart';
import 'package:Bloomee/services/db/dao/track_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
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
  final RecordingSyncLocation location;
  final SyncEngine engine;

  SyncDevice._(this.name, this.isar, this.location, this.engine)
      : tracks = TrackDAO(Future.value(isar)),
        playlists =
            PlaylistDAO(Future.value(isar), TrackDAO(Future.value(isar)));

  Future<void> sync() => engine.syncNow();

  /// Creates [playlist] if needed, then adds [songs] to it, as the screens do.
  Future<void> add(String playlist, List<Track> songs) async {
    final id = await playlists.createPlaylist(playlist);
    for (final song in songs) {
      await playlists.addTrackToPlaylist(id!, song);
    }
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

  /// A new Device with sync enabled. [database] seeds it with an existing
  /// database file instead of an empty library.
  Future<SyncDevice> device(String name, {File? database}) async {
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
    final device = SyncDevice._(name, isar, location, engine);
    await PlaylistDAO(Future.value(isar), TrackDAO(Future.value(isar)))
        .ensurePlaylist(DBProvider.likedPlaylist);
    await engine.enable(deviceName: name);
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
