import 'dart:async';
import 'dart:isolate';

import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/synced_library_change.dart';
import 'package:Bloomee/services/db/dao/library_dao.dart';
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
/// Synced Library, applying a merge in one write transaction, and the Removal
/// Markers the other data-access classes leave when they take something out
/// of the Synced Library.
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

  // ── Removal Markers left by the other data-access classes ────────────────

  /// Leaves the Removal Marker for [row] about to be deleted: a synced
  /// playlist, an unsaved album or artist, or (for the liked songs playlist)
  /// every song it holds. Call inside the write transaction that deletes it.
  ///
  /// Nothing is recorded while sync has never been enabled, nor for a
  /// playlist never published (it has no sync ID), since no other Device can
  /// hold it.
  static void recordDeletionInTransaction(
      Isar isar, PlaylistDB row, DateTime at) {
    final me = _ownId(isar);
    if (me == null) return;
    if (_isLiked(row)) {
      for (final entry in isar.playlistEntryDBs
          .where()
          .playlistIdEqualToAnyPosition(row.id)
          .findAllSync()) {
        entry.track.loadSync();
        final mediaId = entry.track.value?.mediaId;
        if (mediaId != null) {
          _record(isar, RemovalKind.like, null, mediaId, ChangeStamp(at, me));
        }
      }
      return;
    }
    if (_savedKind(row) case final kind?) {
      final mediaId = LibraryDAO.mediaIdOf(row);
      if (mediaId.isEmpty) return;
      _record(
          isar, RemovalKind.ofSaved(kind), null, mediaId, ChangeStamp(at, me));
      return;
    }
    if (_isSynced(row) && row.syncId != null) {
      _record(
          isar, RemovalKind.playlist, row.syncId, null, ChangeStamp(at, me));
    }
  }

  /// Leaves the Removal Marker for the song [mediaId] about to be taken out of
  /// [row]: a synced playlist or the liked songs. Call inside the write
  /// transaction that removes it. Recorded on the same terms as
  /// [recordDeletionInTransaction].
  static void recordSongRemovalInTransaction(
      Isar isar, PlaylistDB row, String mediaId, DateTime at) {
    final me = _ownId(isar);
    if (me == null) return;
    if (_isLiked(row)) {
      _record(isar, RemovalKind.like, null, mediaId, ChangeStamp(at, me));
    } else if (_isSynced(row) && row.syncId != null) {
      _record(isar, RemovalKind.song, row.syncId, mediaId, ChangeStamp(at, me));
    }
  }

  /// When and by which Device [entry]'s song was added; [me] is this Device.
  static ChangeStamp _addedStamp(PlaylistEntryDB entry, String me) =>
      ChangeStamp(entry.addedAt, entry.addedBy ?? me);

  /// When and by which Device the saved collection [row] was saved.
  static ChangeStamp _savedStamp(PlaylistDB row, String me) =>
      ChangeStamp(row.updatedAt, row.savedBy ?? me);

  static String? _ownId(Isar isar) =>
      isar.syncDeviceDBs.getSync(SyncDeviceDB.ownId)?.deviceId;

  /// Stores a Removal Marker, keeping the later one when there is already one
  /// for the same thing.
  static void _record(Isar isar, RemovalKind kind, String? playlistId,
      String? mediaId, ChangeStamp removed) {
    final key = RemovalMarker.removalKey(kind, playlistId, mediaId);
    final known = isar.syncRemovalDBs.filter().keyEqualTo(key).findFirstSync();
    if (known != null &&
        !removed.isAfter(ChangeStamp(known.removedAt, known.removedBy))) {
      return;
    }
    isar.syncRemovalDBs.putSync(SyncRemovalDB(
        key: key,
        kind: SyncRemovalKindDB.values.byName(kind.name),
        playlistId: playlistId,
        mediaId: mediaId,
        removedAt: removed.at,
        removedBy: removed.device)
      ..id = known?.id ?? Isar.autoIncrement);
  }

  // ── Syncing ───────────────────────────────────────────────────────────────

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

  static bool _isLiked(PlaylistDB p) =>
      p.type == PlaylistTypeDB.userPlaylist &&
      p.name.toLowerCase() == DBProvider.likedPlaylist.toLowerCase();

  static SavedKind? _savedKind(PlaylistDB p) => switch (p.type) {
        PlaylistTypeDB.album => SavedKind.album,
        PlaylistTypeDB.artist => SavedKind.artist,
        _ => null,
      };

  static PlaylistTypeDB _typeOf(SavedKind kind) => switch (kind) {
        SavedKind.album => PlaylistTypeDB.album,
        SavedKind.artist => PlaylistTypeDB.artist,
      };

  /// A saved collection's details, without what belongs to this Device's
  /// library layout or bookkeeping.
  static Map<String, dynamic> _savedDetails(PlaylistDB row) =>
      playlistDBToJson(row)
        ..remove('isPinned')
        ..remove('sortOrder')
        ..remove('createdAt')
        ..remove('updatedAt');

  /// Reads the Synced Library; playlists without a sync ID get one from
  /// [newSyncId]. For a worker connection (see [onWorker]).
  Future<LocalSyncedLibrary> readSyncedLibrary(
      String Function() newSyncId) async {
    final isar = await _db;
    return isar.txnSync(() {
      final me = _ownId(isar) ?? '';
      final playlists = <SyncedPlaylist>[];
      final liked = <SyncedSong>[];
      final saved = <SavedCollection>[];
      final tracks = <String, Map<String, dynamic>>{};
      final newIds = <int, String>{};
      final unavailable = <String>{};

      List<SyncedSong> songsOf(PlaylistDB row) {
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
              mediaId: track.mediaId, added: _addedStamp(entry, me)));
          tracks[track.mediaId] = trackDBToJson(track);
        }
        return songs;
      }

      for (final row in isar.playlistDBs.where().findAllSync()) {
        if (!_isSynced(row)) {
          unavailable.add(row.name.toLowerCase());
          if (_isLiked(row)) liked.addAll(songsOf(row));
          final kind = _savedKind(row);
          final mediaId = LibraryDAO.mediaIdOf(row);
          if (kind != null && mediaId.isNotEmpty) {
            saved.add(SavedCollection(
                kind: kind,
                mediaId: mediaId,
                saved: _savedStamp(row, me),
                details: _savedDetails(row)));
          }
          continue;
        }
        final id = row.syncId ?? (newIds[row.id] = newSyncId());
        playlists.add(SyncedPlaylist(
            id: id,
            name: row.name,
            description: row.description,
            createdAt: row.createdAt.toUtc(),
            songs: songsOf(row)));
      }
      final removals = [
        for (final row in isar.syncRemovalDBs.where().findAllSync())
          RemovalMarker(
              kind: RemovalKind.values.byName(row.kind.name),
              playlistId: row.playlistId,
              mediaId: row.mediaId,
              removed: ChangeStamp(row.removedAt, row.removedBy))
      ];
      return LocalSyncedLibrary(
          library: SyncedLibrary(
              playlists: playlists,
              liked: liked,
              saved: saved,
              removals: removals,
              tracks: tracks),
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
      final me = _ownId(isar) ?? '';
      local.newIds.forEach((rowId, syncId) {
        final row = isar.playlistDBs.getSync(rowId);
        if (row == null || row.syncId != null) return;
        row.syncId = syncId;
        isar.playlistDBs.putSync(row);
      });
      // Removals first, so a name they free can be taken by an addition.
      int phase(SyncedLibraryChange change) => switch (change) {
            RemovalsLearned() => 0,
            PlaylistLost() ||
            SongsLost() ||
            LikesLost() ||
            CollectionsUnsaved() =>
              1,
            _ => 2,
          };
      final ordered = [
        for (final p in [0, 1, 2])
          ...merge.changes.where((change) => phase(change) == p)
      ];
      for (final change in ordered) {
        switch (change) {
          case RemovalsLearned(:final markers):
            for (final m in markers) {
              _record(isar, m.kind, m.playlistId, m.mediaId, m.removed);
            }
          case PlaylistLost(:final playlistId):
            final row = _bySyncId(isar, playlistId);
            if (row == null || _changedSinceDeletion(isar, row, me)) break;
            isar.playlistEntryDBs
                .filter()
                .playlistIdEqualTo(row.id)
                .deleteAllSync();
            isar.playlistDBs.deleteSync(row.id);
          case SongsLost(:final playlistId, :final mediaIds):
            final row = _bySyncId(isar, playlistId);
            if (row != null) {
              _removeSongs(
                  isar, row, mediaIds, _songRemovals(isar, row), me, now);
            }
          case LikesLost(:final mediaIds):
            final row = _liked(isar);
            if (row != null) {
              _removeSongs(
                  isar, row, mediaIds, _songRemovals(isar, row), me, now);
            }
          case CollectionsUnsaved(:final collections):
            for (final (kind, mediaId) in collections) {
              final row = _savedRow(isar, kind, mediaId);
              final removed =
                  _removedAt(isar, RemovalKind.ofSaved(kind), null, mediaId);
              if (row != null &&
                  removed != null &&
                  removed.isAfter(_savedStamp(row, me))) {
                isar.playlistDBs.deleteSync(row.id);
              }
            }
          case PlaylistGained(:final playlist):
            final row = _bySyncId(isar, playlist.id) ??
                _byName(isar, playlist) ??
                _create(isar, playlist, now);
            if (row != null) {
              _addSongs(isar, row, playlist.songs, _songRemovals(isar, row),
                  tracks, me, now);
            }
          case SongsGained(:final playlistId, :final songs):
            final row = _bySyncId(isar, playlistId);
            if (row != null) {
              _addSongs(
                  isar, row, songs, _songRemovals(isar, row), tracks, me, now);
            }
          case LikesGained(:final songs):
            final row = _liked(isar) ?? _createLiked(isar);
            _addSongs(
                isar, row, songs, _songRemovals(isar, row), tracks, me, now);
          case CollectionsSaved(:final collections):
            for (final collection in collections) {
              _save(isar, collection, me);
            }
        }
      }
    });
    return true;
  }

  static PlaylistDB? _bySyncId(Isar isar, String syncId) =>
      isar.playlistDBs.filter().syncIdEqualTo(syncId).findFirstSync();

  static PlaylistDB? _liked(Isar isar) => isar.playlistDBs
      .filter()
      .nameEqualTo(DBProvider.likedPlaylist, caseSensitive: false)
      .findFirstSync();

  static PlaylistDB _createLiked(Isar isar) {
    final row = PlaylistDB(name: DBProvider.likedPlaylist);
    row.id = isar.playlistDBs.putSync(row);
    return row;
  }

  static PlaylistDB? _savedRow(Isar isar, SavedKind kind, String mediaId) {
    for (final row in isar.playlistDBs
        .filter()
        .typeIndexEqualTo(_typeOf(kind).index)
        .findAllSync()) {
      if (LibraryDAO.mediaIdOf(row) == mediaId) return row;
    }
    return null;
  }

  /// Saves [collection], or gives the one saved here its later saving time.
  /// Nothing is saved when another row holds its storage name.
  static void _save(Isar isar, SavedCollection collection, String me) {
    final removed = _removedAt(
        isar, RemovalKind.ofSaved(collection.kind), null, collection.mediaId);
    if (removed != null && !collection.saved.isAfter(removed)) return;
    final known = _savedRow(isar, collection.kind, collection.mediaId);
    if (known != null) {
      if (collection.saved.isAfter(_savedStamp(known, me))) {
        known
          ..updatedAt = collection.saved.at
          ..savedBy = collection.saved.device;
        isar.playlistDBs.putSync(known);
      }
      return;
    }
    final row = playlistDBFromJson(collection.details)
      ..type = _typeOf(collection.kind)
      ..createdAt = collection.saved.at
      ..updatedAt = collection.saved.at
      ..savedBy = collection.saved.device;
    if (isar.playlistDBs
            .filter()
            .nameEqualTo(row.name, caseSensitive: false)
            .findFirstSync() !=
        null) {
      return;
    }
    isar.playlistDBs.putSync(row);
  }

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

  // The merge was worked out from the library as it was read; what the
  // owner changed since then must survive applying it. So a removal is only
  // applied, and an addition only made, if its stored counterpart (the
  // Removal Marker, or the song or collection as it is now) does not beat it.

  /// The latest removal of [mediaId] from [playlist] (a synced playlist or
  /// the liked songs) stored here, by media ID.
  static ChangeStamp? Function(String mediaId) _songRemovals(
      Isar isar, PlaylistDB playlist) {
    final liked = _isLiked(playlist);
    return (mediaId) => _removedAt(
        isar,
        liked ? RemovalKind.like : RemovalKind.song,
        liked ? null : playlist.syncId,
        mediaId);
  }

  static ChangeStamp? _removedAt(
      Isar isar, RemovalKind kind, String? playlistId, String? mediaId) {
    final row = isar.syncRemovalDBs
        .filter()
        .keyEqualTo(RemovalMarker.removalKey(kind, playlistId, mediaId))
        .findFirstSync();
    return row == null ? null : ChangeStamp(row.removedAt, row.removedBy);
  }

  /// Whether [playlist] had a song added or taken out after its stored
  /// deletion, which brings it back.
  static bool _changedSinceDeletion(Isar isar, PlaylistDB playlist, String me) {
    final deleted =
        _removedAt(isar, RemovalKind.playlist, playlist.syncId, null);
    if (deleted == null) return true;
    final songRemovals = isar.syncRemovalDBs
        .filter()
        .kindEqualTo(SyncRemovalKindDB.song)
        .playlistIdEqualTo(playlist.syncId)
        .findAllSync();
    return songRemovals.any(
            (r) => ChangeStamp(r.removedAt, r.removedBy).isAfter(deleted)) ||
        isar.playlistEntryDBs
            .where()
            .playlistIdEqualToAnyPosition(playlist.id)
            .findAllSync()
            .any((e) => _addedStamp(e, me).isAfter(deleted));
  }

  /// Takes the songs [mediaIds] out of [playlist], each only if its stored
  /// removal is later than its addition here.
  static void _removeSongs(
      Isar isar,
      PlaylistDB playlist,
      List<String> mediaIds,
      ChangeStamp? Function(String) removedAt,
      String me,
      DateTime now) {
    final remove = mediaIds.toSet();
    var removed = false;
    for (final entry in isar.playlistEntryDBs
        .where()
        .playlistIdEqualToAnyPosition(playlist.id)
        .findAllSync()) {
      entry.track.loadSync();
      final mediaId = entry.track.value?.mediaId;
      if (mediaId == null || !remove.contains(mediaId)) continue;
      final removal = removedAt(mediaId);
      if (removal != null && removal.isAfter(_addedStamp(entry, me))) {
        removed = isar.playlistEntryDBs.deleteSync(entry.id) || removed;
      }
    }
    if (removed) {
      // Library subscribers watch playlist rows.
      playlist.updatedAt = now;
      isar.playlistDBs.putSync(playlist);
    }
  }

  /// Appends the [songs] [playlist] lacks; one it holds takes the song's
  /// addition time when that is later. A song removed here later than it was
  /// added is left out.
  static void _addSongs(
      Isar isar,
      PlaylistDB playlist,
      List<SyncedSong> songs,
      ChangeStamp? Function(String) removedAt,
      Map<String, Map<String, dynamic>> tracks,
      String me,
      DateTime now) {
    final held = <String, PlaylistEntryDB>{};
    var position = 0;
    for (final entry in isar.playlistEntryDBs
        .where()
        .playlistIdEqualToAnyPosition(playlist.id)
        .findAllSync()) {
      entry.track.loadSync();
      final track = entry.track.value;
      if (track != null) held.putIfAbsent(track.mediaId, () => entry);
      if (entry.position >= position) position = entry.position + 1;
    }
    var added = false;
    for (final song in songs) {
      final removal = removedAt(song.mediaId);
      if (removal != null && !song.added.isAfter(removal)) continue;
      final entry = held[song.mediaId];
      if (entry != null) {
        if (song.added.isAfter(_addedStamp(entry, me))) {
          entry
            ..addedAt = song.added.at
            ..addedBy = song.added.device;
          isar.playlistEntryDBs.putSync(entry);
        }
        continue;
      }
      // A song this Device already knows keeps its local details.
      var track =
          isar.trackDBs.filter().mediaIdEqualTo(song.mediaId).findFirstSync();
      if (track == null) {
        track = trackDBFromJson(tracks[song.mediaId]!);
        track.id = isar.trackDBs.putSync(track);
      }
      final created = PlaylistEntryDB(
          playlistId: playlist.id,
          position: position++,
          addedAtOverride: song.added.at)
        ..addedBy = song.added.device
        ..playlist.value = playlist
        ..track.value = track;
      isar.playlistEntryDBs.putSync(created);
      created.playlist.saveSync();
      created.track.saveSync();
      held[song.mediaId] = created;
      added = true;
    }
    if (added) {
      // Library subscribers watch playlist rows.
      playlist.updatedAt = now;
      isar.playlistDBs.putSync(playlist);
    }
  }
}
