import 'dart:async';
import 'dart:isolate';

import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/synced_library_change.dart';
import 'package:Bloomee/services/db/database_schemas.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/db/global_db.dart';
import 'package:Bloomee/services/db/mappers/track_json_mapper.dart';
import 'package:isar_community/isar.dart';

/// This Device's Synced Library as read from the database.
class LocalSyncedLibrary {
  final SyncedLibrary library;

  /// Sync IDs given to playlists that had none, by database row; they are
  /// stored with the next applied merge.
  final Map<int, String> newIds;

  /// Lower-cased names of playlist rows sync does not cover (liked songs,
  /// Device-only playlists, saved collections).
  final Set<String> unsyncedNames;

  const LocalSyncedLibrary({
    required this.library,
    required this.newIds,
    required this.unsyncedNames,
  });
}

/// Database side of Library Sync: the Device's bookkeeping, reading the
/// Synced Library and applying a merge in one write transaction.
class SyncDAO {
  final Future<Isar> _db;

  const SyncDAO(this._db);

  /// This Device's identity, or null while sync has never been enabled.
  Future<SyncIdentity?> identity() async {
    final isar = await _db;
    final row = await isar.syncDeviceDBs.get(SyncDeviceDB.ownId);
    return row == null
        ? null
        : SyncIdentity(
            deviceId: row.deviceId,
            deviceName: row.deviceName,
            lastSyncAt: row.lastSyncAt?.toUtc());
  }

  /// Stores this Device's identity; an existing permanent ID is kept.
  Future<SyncIdentity> enable(
      {required String deviceName, required String newDeviceId}) async {
    final isar = await _db;
    await isar.writeTxn(() async {
      final row = await isar.syncDeviceDBs.get(SyncDeviceDB.ownId) ??
          SyncDeviceDB(deviceId: newDeviceId, deviceName: deviceName);
      row.deviceName = deviceName;
      await isar.syncDeviceDBs.put(row);
    });
    return (await identity())!;
  }

  Future<void> recordSync(DateTime at) async {
    final isar = await _db;
    await isar.writeTxn(() async {
      final row = await isar.syncDeviceDBs.get(SyncDeviceDB.ownId);
      if (row == null) return;
      row.lastSyncAt = at;
      await isar.syncDeviceDBs.put(row);
    });
  }

  /// Runs [operation] on a worker isolate with its own connection to the
  /// live database, as the backup code does, so sync never blocks the
  /// interface.
  static Future<T> onWorker<T>(
      Future<Isar> database, FutureOr<T> Function(SyncDAO) operation) async {
    final live = await database;
    return _onWorker(live.directory!, live.name, operation);
  }

  static Future<T> _onWorker<T>(String directory, String name,
          FutureOr<T> Function(SyncDAO) operation) =>
      Isolate.run(() async {
        final connection = await Isar.open(databaseSchemas,
            directory: directory, name: name, inspector: false);
        try {
          return await operation(SyncDAO(Future.value(connection)));
        } finally {
          await connection.close();
        }
      });

  static bool _isSynced(PlaylistDB p) =>
      p.type == PlaylistTypeDB.userPlaylist &&
      !DBProvider.standardPlaylists
          .any((name) => name.toLowerCase() == p.name.toLowerCase());

  /// Reads the Synced Library; playlists without a sync ID get one from
  /// [newSyncId]. For a worker connection (see [onWorker]).
  Future<LocalSyncedLibrary> readSyncedLibrary(
      String Function() newSyncId) async {
    final isar = await _db;
    return isar.txnSync(() {
      final playlists = <SyncedPlaylist>[];
      final tracks = <String, Map<String, dynamic>>{};
      final newIds = <int, String>{};
      final unavailable = <String>{};
      for (final row in isar.playlistDBs.where().findAllSync()) {
        if (!_isSynced(row)) {
          unavailable.add(row.name.toLowerCase());
          continue;
        }
        final id = row.syncId ?? (newIds[row.id] = newSyncId());
        final seen = <String>{};
        final songs = <SyncedSong>[];
        for (final entry in isar.playlistEntryDBs
            .where()
            .playlistIdEqualToAnyPosition(row.id)
            .findAllSync()) {
          entry.track.loadSync();
          final track = entry.track.value;
          if (track == null || !seen.add(track.mediaId)) continue;
          songs.add(SyncedSong(
              mediaId: track.mediaId, addedAt: entry.addedAt.toUtc()));
          tracks[track.mediaId] = trackDBToJson(track);
        }
        playlists.add(SyncedPlaylist(
            id: id,
            name: row.name,
            description: row.description,
            createdAt: row.createdAt.toUtc(),
            songs: songs));
      }
      return LocalSyncedLibrary(
          library: SyncedLibrary(playlists: playlists, tracks: tracks),
          newIds: newIds,
          unsyncedNames: unavailable);
    });
  }

  /// Applies [merge] to the library [local] was read from, in one write
  /// transaction: all of it or, on failure, none of it. Returns whether
  /// anything was written. For a worker connection (see [onWorker]).
  Future<bool> apply(
      LocalSyncedLibrary local, SyncedLibraryMerge merge, DateTime now) async {
    if (merge.changes.isEmpty && local.newIds.isEmpty) return false;
    final isar = await _db;
    final tracks = merge.library.tracks;
    isar.writeTxnSync(() {
      local.newIds.forEach((rowId, syncId) {
        final row = isar.playlistDBs.getSync(rowId);
        if (row == null || row.syncId != null) return;
        row.syncId = syncId;
        isar.playlistDBs.putSync(row);
      });
      for (final change in merge.changes) {
        switch (change) {
          case PlaylistGained(:final playlist):
            final row = _bySyncId(isar, playlist.id) ??
                _byName(isar, playlist) ??
                _create(isar, playlist, now);
            if (row != null) _addSongs(isar, row, playlist.songs, tracks, now);
          case SongsGained(:final playlistId, :final songs):
            final row = _bySyncId(isar, playlistId);
            if (row != null) _addSongs(isar, row, songs, tracks, now);
        }
      }
    });
    return true;
  }

  static PlaylistDB? _bySyncId(Isar isar, String syncId) =>
      isar.playlistDBs.filter().syncIdEqualTo(syncId).findFirstSync();

  /// A playlist of that name made since the library was read; null if there
  /// is none. One that has never synced takes the gained playlist's ID. A name
  /// held by something sync does not cover is never joined.
  static PlaylistDB? _byName(Isar isar, SyncedPlaylist playlist) {
    final row = isar.playlistDBs
        .filter()
        .nameEqualTo(playlist.name, caseSensitive: false)
        .findFirstSync();
    if (row == null || !_isSynced(row)) return null;
    if (row.syncId == null) {
      row.syncId = playlist.id;
      isar.playlistDBs.putSync(row);
    }
    return row;
  }

  static PlaylistDB? _create(Isar isar, SyncedPlaylist playlist, DateTime now) {
    if (isar.playlistDBs
            .filter()
            .nameEqualTo(playlist.name, caseSensitive: false)
            .findFirstSync() !=
        null) {
      return null;
    }
    final row = PlaylistDB(
        name: playlist.name,
        description: playlist.description,
        createdat: playlist.createdAt,
        updatedat: now)
      ..syncId = playlist.id;
    row.id = isar.playlistDBs.putSync(row);
    return row;
  }

  static void _addSongs(Isar isar, PlaylistDB playlist, List<SyncedSong> songs,
      Map<String, Map<String, dynamic>> tracks, DateTime now) {
    final seen = <String>{};
    var position = 0;
    for (final entry in isar.playlistEntryDBs
        .where()
        .playlistIdEqualToAnyPosition(playlist.id)
        .findAllSync()) {
      entry.track.loadSync();
      final track = entry.track.value;
      if (track != null) seen.add(track.mediaId);
      if (entry.position >= position) position = entry.position + 1;
    }
    var added = false;
    for (final song in songs) {
      if (!seen.add(song.mediaId)) continue;
      // A song this Device already knows keeps its local details.
      var track =
          isar.trackDBs.filter().mediaIdEqualTo(song.mediaId).findFirstSync();
      if (track == null) {
        track = trackDBFromJson(tracks[song.mediaId]!);
        track.id = isar.trackDBs.putSync(track);
      }
      final entry = PlaylistEntryDB(
          playlistId: playlist.id,
          position: position++,
          addedAtOverride: song.addedAt)
        ..playlist.value = playlist
        ..track.value = track;
      isar.playlistEntryDBs.putSync(entry);
      entry.playlist.saveSync();
      entry.track.saveSync();
      added = true;
    }
    if (added) {
      // Library subscribers watch playlist rows.
      playlist.updatedAt = now;
      isar.playlistDBs.putSync(playlist);
    }
  }
}
