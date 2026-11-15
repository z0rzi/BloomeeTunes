import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/synced_library_change.dart';
import 'package:Bloomee/services/db/dao/library_dao.dart';
import 'package:Bloomee/services/db/database_schemas.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:Bloomee/services/db/global_db.dart';
import 'package:Bloomee/services/db/mappers/track_json_mapper.dart';
import 'package:flutter/foundation.dart';
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

  /// Orders of songs, by database row, and of the library's playlists that
  /// were arranged before sync could record it (at the first sync, those
  /// that differ from the order sync would give them); they are stored with
  /// the next applied merge.
  final Map<int, Arrangement> newArrangements;
  final Arrangement? newOrder;

  const LocalSyncedLibrary({
    required this.library,
    required this.newIds,
    required this.unsyncedNames,
    this.newArrangements = const {},
    this.newOrder,
  });

  /// Whether reading the library gave it bookkeeping not yet stored.
  bool get hasNewBookkeeping =>
      newIds.isNotEmpty || newArrangements.isNotEmpty || newOrder != null;
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
            lastSyncAt: row.lastSyncAt?.toUtc(),
            paused: row.syncPaused,
            enabled: !row.syncOff);
  }

  /// Stores this Device's identity, with sync on; an existing permanent ID
  /// is kept.
  Future<SyncIdentity> enable(
      {required String deviceName, required String newDeviceId}) async {
    final isar = await _db;
    await isar.writeTxn(() async {
      final row = await isar.syncDeviceDBs.get(SyncDeviceDB.ownId) ??
          SyncDeviceDB(deviceId: newDeviceId, deviceName: deviceName);
      row
        ..deviceName = deviceName
        ..syncOff = false;
      await isar.syncDeviceDBs.put(row);
    });
    return (await identity())!;
  }

  /// Renames this Device, if sync was ever enabled; on or off, it stays.
  Future<void> rename(String deviceName) async {
    final isar = await _db;
    await isar.writeTxn(() async {
      final row = await isar.syncDeviceDBs.get(SyncDeviceDB.ownId);
      if (row == null) return;
      row.deviceName = deviceName;
      await isar.syncDeviceDBs.put(row);
    });
  }

  /// Turns sync off, keeping this Device's identity and bookkeeping, which
  /// go on recording changes until sync is back on.
  Future<void> disable() async {
    final isar = await _db;
    await isar.writeTxn(() async {
      final row = await isar.syncDeviceDBs.get(SyncDeviceDB.ownId);
      if (row == null) return;
      row.syncOff = true;
      await isar.syncDeviceDBs.put(row);
    });
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

  /// Pauses sync after the owner declined a merge the Removal Guard held, or
  /// resumes it once they confirm it.
  Future<void> setPaused(bool paused) async {
    final isar = await _db;
    await isar.writeTxn(() async {
      final row = await isar.syncDeviceDBs.get(SyncDeviceDB.ownId);
      if (row == null) return;
      row.syncPaused = paused;
      await isar.syncDeviceDBs.put(row);
    });
  }

  /// Fires after each write that may change the Synced Library: to
  /// playlists (liked songs and saved collections included) or their songs.
  Stream<void> watchSyncedLibrary() async* {
    final isar = await _db;
    final changes = StreamController<void>();
    final subscriptions = [
      isar.playlistDBs.watchLazy().listen(changes.add),
      isar.playlistEntryDBs.watchLazy().listen(changes.add),
    ];
    changes.onCancel = () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    yield* changes.stream;
  }

  // ── Removal Markers left by the other data-access classes ────────────────

  /// Leaves the Removal Marker for [row] about to be deleted: a synced
  /// playlist, an unsaved album or artist, or (for the liked songs playlist)
  /// every song it holds. Call inside the write transaction that deletes it,
  /// before its songs go: a synced playlist's marker keeps it as it was
  /// ([RemovalMarker.deletedPlaylist]).
  ///
  /// Nothing is recorded while sync has never been enabled, nor for a
  /// playlist never published (it has no sync ID), since no other Device can
  /// hold it.
  static void recordDeletionInTransaction(
          Isar isar, PlaylistDB row, DateTime at) =>
      _recordDeletion(isar, row, at, null);

  /// [recordDeletionInTransaction], the playlist kept as [deletedPlaylist]
  /// (from [_deletedPlaylistJsonOf]) when its songs are gone already.
  static void _recordDeletion(
      Isar isar, PlaylistDB row, DateTime at, String? deletedPlaylist) {
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
      _record(isar, RemovalKind.playlist, row.syncId, null, ChangeStamp(at, me),
          deletedPlaylist:
              deletedPlaylist ?? _deletedPlaylistJsonOf(isar, row, me));
    }
  }

  /// A deleted playlist as its Removal Marker keeps it in the database: the
  /// playlist (without its sync ID, which the marker holds) and the details
  /// of its songs, which may leave the database with it.
  static String _deletedPlaylistJson(SyncedPlaylist playlist,
          Map<String, dynamic>? Function(String mediaId) trackOf) =>
      jsonEncode({
        'playlist': playlist.toJson()..remove('id'),
        'tracks': [
          for (final song in playlist.songs)
            if (trackOf(song.mediaId) case final track?) track
        ],
      });

  /// [row], a synced playlist, as [_deletedPlaylistJson] keeps it; [me] is this Device.
  static String _deletedPlaylistJsonOf(Isar isar, PlaylistDB row, String me) {
    final tracks = <String, Map<String, dynamic>>{};
    final songs = <SyncedSong>[];
    for (final entry in isar.playlistEntryDBs
        .where()
        .playlistIdEqualToAnyPosition(row.id)
        .findAllSync()) {
      final track = (entry..track.loadSync()).track.value;
      if (track == null || tracks.containsKey(track.mediaId)) continue;
      tracks[track.mediaId] = trackDBToJson(track);
      songs.add(
          SyncedSong(mediaId: track.mediaId, added: _addedStamp(entry, me)));
    }
    return _deletedPlaylistJson(
        _playlistOf(row, row.syncId!, songs, me), (id) => tracks[id]);
  }

  /// The deleted playlist [json] (from [_deletedPlaylistJson]) keeps, under
  /// [syncId], with its songs' details put in [tracks] where they lack.
  static SyncedPlaylist _readDeletedPlaylist(
      String json, String syncId, Map<String, Map<String, dynamic>> tracks) {
    final kept = jsonDecode(json) as Map<String, dynamic>;
    for (final track in kept['tracks'] as List<dynamic>) {
      final details = track as Map<String, dynamic>;
      tracks.putIfAbsent(details['mediaId'] as String, () => details);
    }
    return SyncedPlaylist.fromJson(
        {...kept['playlist'] as Map<String, dynamic>, 'id': syncId});
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

  /// What sync knows of the Synced Library a backup restore is about to
  /// replace; read inside the restore's write transaction, before it deletes
  /// anything, for [recordReplaceInTransaction]. Null while sync has never
  /// been enabled: nothing is recorded then.
  static ReplacedSyncedLibrary? readBeforeReplaceInTransaction(Isar isar) {
    final me = _ownId(isar);
    if (me == null) return null;
    return ReplacedSyncedLibrary._({
      for (final row in isar.playlistDBs.where().findAllSync())
        if (_replaceKey(row) case final key?)
          key: (
            row: row,
            songs: _songsInOrder(isar, row),
            deletedPlaylist: _isSynced(row) && row.syncId != null
                ? _deletedPlaylistJsonOf(isar, row, me)
                : null,
          )
    });
  }

  /// Makes the backup restore that replaced [before] the Latest Change at
  /// [at], inside its write transaction once the restored library is in
  /// place: whatever [before] held that the restored library lacks leaves a
  /// Removal Marker, and what the restored library holds counts as changed
  /// at [at] (its songs added, its playlists' details and order and the
  /// library's arrangement set, its collections saved). A playlist restored
  /// under the name of one it replaced keeps that one's sync ID, so it stays
  /// the same playlist on every Device.
  static void recordReplaceInTransaction(
      Isar isar, ReplacedSyncedLibrary before, DateTime at) {
    final replaced = {...before._rows};
    for (final row in isar.playlistDBs.where().findAllSync()) {
      final key = _replaceKey(row);
      if (key == null) continue;
      final old = replaced.remove(key);
      final songs = _songsInOrder(isar, row);
      if (_savedKind(row) != null) {
        row
          ..savedBy = null
          ..updatedAt = at;
      } else if (!_isLiked(row)) {
        row
          ..syncId ??= old?.row.syncId
          ..nameChangedAt = at
          ..nameChangedBy = null
          ..descriptionChangedAt = at
          ..descriptionChangedBy = null
          ..pinnedChangedAt = at
          ..pinnedChangedBy = null;
        recordArrangement(row, songs, at);
      }
      isar.playlistDBs.putSync(row);
      for (final mediaId in old?.songs ?? const <String>[]) {
        if (!songs.contains(mediaId)) {
          recordSongRemovalInTransaction(isar, row, mediaId, at);
        }
      }
    }
    for (final (:row, :songs, :deletedPlaylist) in replaced.values) {
      if (_isLiked(row)) {
        // Its songs went with it: each is unliked.
        for (final mediaId in songs) {
          _record(isar, RemovalKind.like, null, mediaId,
              ChangeStamp(at, _ownId(isar)!));
        }
      } else {
        _recordDeletion(isar, row, at, deletedPlaylist);
      }
    }
    _recordLibraryArrangementSync(isar, at);
  }

  /// What identifies [row] across a replace-restore, for the rows sync
  /// covers: the liked songs, a saved collection by kind and media ID, a
  /// synced playlist by name ignoring case.
  static String? _replaceKey(PlaylistDB row) {
    if (_isLiked(row)) return 'liked';
    if (_savedKind(row) case final kind?) {
      final mediaId = LibraryDAO.mediaIdOf(row);
      return mediaId.isEmpty ? null : '${kind.name}:$mediaId';
    }
    return _isSynced(row) ? 'playlist:${row.name.toLowerCase()}' : null;
  }

  /// The media IDs of the songs [row] holds, in order.
  static List<String> _songsInOrder(Isar isar, PlaylistDB row) => [
        for (final entry in isar.playlistEntryDBs
            .where()
            .playlistIdEqualToAnyPosition(row.id)
            .findAllSync())
          if ((entry..track.loadSync()).track.value?.mediaId
              case final mediaId?)
            mediaId
      ];

  /// When and by which Device [entry]'s song was added; [me] is this Device.
  static ChangeStamp _addedStamp(PlaylistEntryDB entry, String me) =>
      ChangeStamp(entry.addedAt, entry.addedBy ?? me);

  /// When and by which Device the saved collection [row] was saved.
  static ChangeStamp _savedStamp(PlaylistDB row, String me) =>
      ChangeStamp(row.updatedAt, row.savedBy ?? me);

  static String? _ownId(Isar isar) =>
      isar.syncDeviceDBs.getSync(SyncDeviceDB.ownId)?.deviceId;

  /// Stores a Removal Marker, keeping the later one when there is already one
  /// for the same thing; a deleted playlist's keeps it as [deletedPlaylist]
  /// (see [_deletedPlaylistJson]).
  static void _record(Isar isar, RemovalKind kind, String? playlistId,
      String? mediaId, ChangeStamp removed,
      {String? deletedPlaylist}) {
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
        removedBy: removed.device,
        deletedPlaylist: deletedPlaylist)
      ..id = known?.id ?? Isar.autoIncrement);
  }

  // ── Change times left by the other data-access classes ──────────────────

  /// A new permanent sync ID for a playlist.
  static String newSyncId() => [
        for (var i = 0; i < 16; i++)
          _random.nextInt(256).toRadixString(16).padLeft(2, '0')
      ].join();

  static final Random _random = Random.secure();

  /// Records that the songs of [row] were just arranged into the order
  /// [mediaIds]; the caller stores [row] in the transaction that arranges
  /// them.
  static void recordArrangement(
      PlaylistDB row, List<String> mediaIds, DateTime at) {
    row
      ..arrangedAt = at
      ..arrangedBy = null
      ..arrangement = mediaIds;
  }

  /// Records that the playlists of the library were just arranged, in the
  /// order they now have. Call inside the write transaction that arranges
  /// them. Nothing is recorded while sync has never been enabled: the first
  /// sync takes the order as it finds it.
  static Future<void> recordLibraryArrangement(Isar isar, DateTime at) async {
    final device = await isar.syncDeviceDBs.get(SyncDeviceDB.ownId);
    if (device == null) return;
    final rows = await isar.playlistDBs.where().findAll();
    await isar.playlistDBs.putAll(_arrangeLibrary(device, rows, at));
    await isar.syncDeviceDBs.put(device);
  }

  /// [recordLibraryArrangement] for a synchronous write transaction.
  static void _recordLibraryArrangementSync(Isar isar, DateTime at) {
    final device = isar.syncDeviceDBs.getSync(SyncDeviceDB.ownId);
    if (device == null) return;
    final rows = isar.playlistDBs.where().findAllSync();
    isar.playlistDBs.putAllSync(_arrangeLibrary(device, rows, at));
    isar.syncDeviceDBs.putSync(device);
  }

  /// Records on [device] that the playlists [rows] were arranged at [at] in
  /// their library order. Returns the rows given a sync ID for it, to store.
  static List<PlaylistDB> _arrangeLibrary(
      SyncDeviceDB device, List<PlaylistDB> rows, DateTime at) {
    final ids = <String>[];
    final given = <PlaylistDB>[];
    for (final row in rows..sort(_byLibraryOrder)) {
      if (!_isSynced(row)) continue;
      if (row.syncId == null) given.add(row..syncId = newSyncId());
      ids.add(row.syncId!);
    }
    device
      ..libraryArrangedAt = at
      ..libraryArrangedBy = null
      ..libraryArrangement = ids;
    return given;
  }

  /// Where a playlist made now goes in the library: after the others while
  /// sync is on, so it stays where sync will put it; at the start, as
  /// before sync existed, otherwise.
  static int sortOrderForNewPlaylist(Isar isar) {
    final device = isar.syncDeviceDBs.getSync(SyncDeviceDB.ownId);
    if (device == null || device.syncOff) return 0;
    final last = isar.playlistDBs.where().sortBySortOrderDesc().findFirstSync();
    return last == null ? 0 : last.sortOrder + 1;
  }

  /// Every playlist row in the library's order (pinning aside).
  static List<PlaylistDB> _inLibraryOrder(Isar isar) =>
      isar.playlistDBs.where().findAllSync()..sort(_byLibraryOrder);

  static int _byLibraryOrder(PlaylistDB a, PlaylistDB b) {
    final bySortOrder = a.sortOrder.compareTo(b.sortOrder);
    return bySortOrder != 0 ? bySortOrder : a.id.compareTo(b.id);
  }

  /// The synced playlist [row] under the sync ID [id], holding [songs];
  /// [me] is this Device.
  static SyncedPlaylist _playlistOf(
          PlaylistDB row, String id, List<SyncedSong> songs, String me,
          {Arrangement? arrangement}) =>
      SyncedPlaylist(
          id: id,
          name: row.name,
          nameChanged: _nameStamp(row, me),
          description: row.description,
          descriptionChanged: _descriptionStamp(row, me),
          pinned: row.isPinned,
          pinnedChanged: _pinnedStamp(row, me),
          createdAt: row.createdAt.toUtc(),
          arrangement: arrangement ?? _arrangementOf(row, me),
          songs: songs);

  static ChangeStamp _nameStamp(PlaylistDB row, String me) =>
      ChangeStamp(row.nameChangedAt ?? row.createdAt, row.nameChangedBy ?? me);

  static ChangeStamp _descriptionStamp(PlaylistDB row, String me) =>
      ChangeStamp(row.descriptionChangedAt ?? row.createdAt,
          row.descriptionChangedBy ?? me);

  static ChangeStamp _pinnedStamp(PlaylistDB row, String me) => ChangeStamp(
      row.pinnedChangedAt ?? row.createdAt, row.pinnedChangedBy ?? me);

  static Arrangement? _arrangementOf(PlaylistDB row, String me) =>
      row.arrangedAt == null
          ? null
          : Arrangement(ChangeStamp(row.arrangedAt!, row.arrangedBy ?? me),
              row.arrangement ?? const []);

  static Arrangement? _libraryArrangementOf(SyncDeviceDB? device, String me) =>
      device?.libraryArrangedAt == null
          ? null
          : Arrangement(
              ChangeStamp(
                  device!.libraryArrangedAt!, device.libraryArrangedBy ?? me),
              device.libraryArrangement ?? const []);

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

  /// Reads the Synced Library, its playlists in the library's order;
  /// playlists without a sync ID get one from [newSyncId]. For a worker
  /// connection (see [onWorker]).
  Future<LocalSyncedLibrary> readSyncedLibrary(
      String Function() newSyncId) async {
    final isar = await _db;
    return isar.txnSync(() {
      final me = _ownId(isar) ?? '';
      final device = isar.syncDeviceDBs.getSync(SyncDeviceDB.ownId);
      // Orders arranged before sync could record them are taken as they are
      // at this Device's first sync; afterwards every arrangement is recorded.
      final firstSync = device?.lastSyncAt == null;
      final playlists = <SyncedPlaylist>[];
      final liked = <SyncedSong>[];
      final saved = <SavedCollection>[];
      final tracks = <String, Map<String, dynamic>>{};
      final newIds = <int, String>{};
      final newArrangements = <int, Arrangement>{};
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

      for (final row in _inLibraryOrder(isar)) {
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
        final songs = songsOf(row);
        var arrangement = _arrangementOf(row, me);
        if (firstSync &&
            arrangement == null &&
            !listEquals([
              for (final s in Arrangement.arrangeSongs(null, songs)) s.mediaId
            ], [
              for (final s in songs) s.mediaId
            ])) {
          // Arranged before sync recorded it: that order is kept, as of the
          // latest addition, so any later arrangement beats it.
          arrangement = newArrangements[row.id] = Arrangement(
              songs
                  .map((s) => s.added)
                  .reduce((a, b) => ChangeStamp.latest(a, b)),
              [for (final s in songs) s.mediaId]);
        }
        playlists
            .add(_playlistOf(row, id, songs, me, arrangement: arrangement));
      }
      var order = _libraryArrangementOf(device, me);
      Arrangement? newOrder;
      if (firstSync &&
          order == null &&
          playlists.isNotEmpty &&
          !listEquals([
            for (final p in Arrangement.arrangePlaylists(null, playlists)) p.id
          ], [
            for (final p in playlists) p.id
          ])) {
        // Likewise for the library, as of the latest playlist made.
        final latest = playlists
            .map((p) => p.createdAt)
            .reduce((a, b) => b.isAfter(a) ? b : a);
        order = newOrder = Arrangement(
            ChangeStamp(latest, me), [for (final p in playlists) p.id]);
      }
      final removals = [
        for (final row in isar.syncRemovalDBs.where().findAllSync())
          RemovalMarker(
              kind: RemovalKind.values.byName(row.kind.name),
              playlistId: row.playlistId,
              mediaId: row.mediaId,
              removed: ChangeStamp(row.removedAt, row.removedBy),
              deletedPlaylist:
                  row.deletedPlaylist != null && row.playlistId != null
                      ? _readDeletedPlaylist(
                          row.deletedPlaylist!, row.playlistId!, tracks)
                      : null)
      ];
      final aliases = [
        for (final row in isar.syncAliasDBs.where().findAllSync())
          PlaylistAlias(
              from: row.fromId,
              into: row.intoId,
              merged: ChangeStamp(row.mergedAt, row.mergedBy))
      ];
      return LocalSyncedLibrary(
          library: SyncedLibrary(
              playlists: playlists,
              liked: liked,
              saved: saved,
              removals: removals,
              tracks: tracks,
              order: order,
              aliases: aliases),
          newIds: newIds,
          unsyncedNames: unavailable,
          newArrangements: newArrangements,
          newOrder: newOrder);
    });
  }

  /// Applies [merge] to the library [local] was read from, in one write
  /// transaction: all of it or, on failure, none of it. Returns whether
  /// anything was written. For a worker connection (see [onWorker]).
  ///
  /// [beforeCommit] runs inside the transaction once everything is written;
  /// tests throw from it to fail the apply at its last moment.
  Future<bool> apply(
      LocalSyncedLibrary local, SyncedLibraryMerge merge, DateTime now,
      {void Function()? beforeCommit}) async {
    if (merge.changes.isEmpty && !local.hasNewBookkeeping) return false;
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
      local.newArrangements.forEach((rowId, arrangement) {
        final row = isar.playlistDBs.getSync(rowId);
        if (row == null || row.arrangedAt != null) return;
        _storeArrangement(isar, row, arrangement);
      });
      if (local.newOrder case final order?) {
        final device = isar.syncDeviceDBs.getSync(SyncDeviceDB.ownId);
        if (device != null && device.libraryArrangedAt == null) {
          _storeLibraryArrangement(isar, device, order);
        }
      }
      // Identities first, then removals, so a name they free can be taken by
      // a rename or an addition; orders last, once every song and playlist
      // is in place.
      int phase(SyncedLibraryChange change) => switch (change) {
            AliasesDropped() ||
            RemovalsDropped() ||
            AliasesLearned() ||
            RemovalsLearned() ||
            PlaylistRekeyed() =>
              0,
            PlaylistAbsorbed() ||
            DeletedPlaylistsKept() ||
            PlaylistLost() ||
            SongsLost() ||
            LikesLost() ||
            CollectionsUnsaved() =>
              1,
            DetailsChanged() => 2,
            SongsArranged() || PlaylistsArranged() => 4,
            _ => 3,
          };
      final ordered = [
        for (final p in [0, 1, 2, 3, 4])
          ...merge.changes.where((change) => phase(change) == p)
      ];
      final details = [
        for (final change in ordered)
          if (change is DetailsChanged) change.playlist
      ];
      for (final change in ordered) {
        switch (change) {
          case RemovalsDropped(:final markers):
            for (final m in markers) {
              final row = isar.syncRemovalDBs.getByKeySync(m.key);
              if (row != null &&
                  !ChangeStamp(row.removedAt, row.removedBy)
                      .isAfter(m.removed)) {
                isar.syncRemovalDBs.deleteSync(row.id);
              }
            }
          case AliasesDropped(:final aliases):
            for (final alias in aliases) {
              final row = isar.syncAliasDBs.getByFromIdSync(alias.from);
              if (row != null &&
                  row.intoId == alias.into &&
                  ChangeStamp(row.mergedAt, row.mergedBy) == alias.merged) {
                isar.syncAliasDBs.deleteSync(row.id);
              }
            }
          case AliasesLearned(:final aliases):
            for (final alias in aliases) {
              isar.syncAliasDBs.putSync(SyncAliasDB(
                  fromId: alias.from,
                  intoId: alias.into,
                  mergedAt: alias.merged.at,
                  mergedBy: alias.merged.device));
              _rekeyMarkers(isar, alias.from, alias.into);
            }
          case RemovalsLearned(:final markers):
            for (final m in markers) {
              _record(isar, m.kind, m.playlistId, m.mediaId, m.removed);
            }
          case DeletedPlaylistsKept(:final markers):
            for (final m in markers) {
              final row = isar.syncRemovalDBs.getByKeySync(m.key);
              if (row == null ||
                  ChangeStamp(row.removedAt, row.removedBy) != m.removed) {
                continue; // Deleted again here since the library was read.
              }
              row.deletedPlaylist = m.deletedPlaylist == null
                  ? null
                  : _deletedPlaylistJson(
                      m.deletedPlaylist!,
                      (mediaId) =>
                          tracks[mediaId] ??
                          switch (_storedTrack(isar, mediaId)) {
                            final track? => trackDBToJson(track),
                            null => null,
                          });
              isar.syncRemovalDBs.putSync(row);
            }
          case PlaylistRekeyed(:final from, :final to):
            final row = _bySyncId(isar, from);
            if (row != null && _bySyncId(isar, to) == null) {
              row.syncId = to;
              isar.playlistDBs.putSync(row);
            }
            _rekeyMarkers(isar, from, to);
          case PlaylistAbsorbed(:final playlistId, :final into):
            final row = _bySyncId(isar, playlistId);
            if (row == null) break;
            final target = _bySyncId(isar, into);
            if (target == null) {
              row.syncId = into;
              isar.playlistDBs.putSync(row);
              break;
            }
            // Whatever it holds that the other lacks moves over, even a song
            // added since the library was read.
            _addSongs(isar, target, _entrySongs(isar, row, me),
                _songRemovals(isar, target), tracks, me, now);
            isar.playlistEntryDBs
                .filter()
                .playlistIdEqualTo(row.id)
                .deleteAllSync();
            isar.playlistDBs.deleteSync(row.id);
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
          case DetailsChanged(:final playlist):
            // All together, at the first.
            if (playlist == details.first) _changeDetails(isar, details, me);
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
          case PlaylistKept(:final playlistId, :final kept):
            final row = _bySyncId(isar, playlistId);
            if (row != null && kept.isAfter(_nameStamp(row, me))) {
              row
                ..nameChangedAt = kept.at
                ..nameChangedBy = kept.device;
              isar.playlistDBs.putSync(row);
            }
          case SongsArranged(
              :final playlistId,
              :final mediaIds,
              :final arrangement
            ):
            final row = _bySyncId(isar, playlistId);
            if (row == null) break;
            final held = _arrangementOf(row, me);
            if (held != null &&
                (arrangement == null ||
                    held.arranged.isAfter(arrangement.arranged))) {
              break; // Arranged here since the library was read.
            }
            if (arrangement != null) _storeArrangement(isar, row, arrangement);
            _putSongsInOrder(isar, row, mediaIds);
          case PlaylistsArranged(:final playlistIds, :final arrangement):
            final device = isar.syncDeviceDBs.getSync(SyncDeviceDB.ownId);
            if (device == null) break;
            final held = _libraryArrangementOf(device, me);
            if (held != null &&
                (arrangement == null ||
                    held.arranged.isAfter(arrangement.arranged))) {
              break; // Arranged here since the library was read.
            }
            if (arrangement != null) {
              _storeLibraryArrangement(isar, device, arrangement);
            }
            _putPlaylistsInOrder(isar, playlistIds);
        }
      }
      beforeCommit?.call();
    });
    return true;
  }

  static void _storeArrangement(
      Isar isar, PlaylistDB row, Arrangement arrangement) {
    row
      ..arrangedAt = arrangement.arranged.at
      ..arrangedBy = arrangement.arranged.device
      ..arrangement = arrangement.ids;
    isar.playlistDBs.putSync(row);
  }

  static void _storeLibraryArrangement(
      Isar isar, SyncDeviceDB device, Arrangement arrangement) {
    device
      ..libraryArrangedAt = arrangement.arranged.at
      ..libraryArrangedBy = arrangement.arranged.device
      ..libraryArrangement = arrangement.ids;
    isar.syncDeviceDBs.putSync(device);
  }

  /// Moves the Removal Markers of songs taken out of the playlist [from] to
  /// the playlist [to] it is known as now, and its deletion with them.
  static void _rekeyMarkers(Isar isar, String from, String to) {
    for (final marker
        in isar.syncRemovalDBs.filter().playlistIdEqualTo(from).findAllSync()) {
      isar.syncRemovalDBs.deleteSync(marker.id);
      final kind = RemovalKind.values.byName(marker.kind.name);
      _record(isar, kind, to, marker.mediaId,
          ChangeStamp(marker.removedAt, marker.removedBy),
          deletedPlaylist: marker.deletedPlaylist);
    }
  }

  /// The songs [row] holds, with when they were added.
  static List<SyncedSong> _entrySongs(Isar isar, PlaylistDB row, String me) => [
        for (final entry in isar.playlistEntryDBs
            .where()
            .playlistIdEqualToAnyPosition(row.id)
            .findAllSync())
          if ((entry..track.loadSync()).track.value case final track?)
            SyncedSong(mediaId: track.mediaId, added: _addedStamp(entry, me))
      ];

  /// Sets each detail of [playlists] whose change here is older. Names are
  /// changed together, through names no playlist bears, so two playlists can
  /// swap theirs; a name another playlist took since the library was read is
  /// not taken.
  static void _changeDetails(
      Isar isar, List<SyncedPlaylist> playlists, String me) {
    final renamed = <(PlaylistDB, String, SyncedPlaylist)>[];
    for (final playlist in playlists) {
      final row = _bySyncId(isar, playlist.id);
      if (row == null) continue;
      if (playlist.descriptionChanged.isAfter(_descriptionStamp(row, me))) {
        row
          ..description = playlist.description
          ..descriptionChangedAt = playlist.descriptionChanged.at
          ..descriptionChangedBy = playlist.descriptionChanged.device;
      }
      if (playlist.pinnedChanged.isAfter(_pinnedStamp(row, me))) {
        row
          ..isPinned = playlist.pinned
          ..pinnedChangedAt = playlist.pinnedChanged.at
          ..pinnedChangedBy = playlist.pinnedChanged.device;
      }
      if (playlist.nameChanged.isAfter(_nameStamp(row, me))) {
        if (playlist.name == row.name) {
          row
            ..nameChangedAt = playlist.nameChanged.at
            ..nameChangedBy = playlist.nameChanged.device;
        } else {
          renamed.add((row, row.name, playlist));
          row.name = '\u0000${row.syncId}';
        }
      }
      isar.playlistDBs.putSync(row);
    }
    for (final (row, previous, playlist) in renamed) {
      final taken = isar.playlistDBs
          .filter()
          .nameEqualTo(playlist.name, caseSensitive: false)
          .findFirstSync();
      if (taken != null && taken.id != row.id) {
        row.name = previous;
      } else {
        row
          ..name = playlist.name
          ..nameChangedAt = playlist.nameChanged.at
          ..nameChangedBy = playlist.nameChanged.device;
      }
      isar.playlistDBs.putSync(row);
    }
  }

  /// Puts the songs of [row] in the order [mediaIds]; any it holds beyond
  /// them (added since the library was read) follow, in their order.
  static void _putSongsInOrder(
      Isar isar, PlaylistDB row, List<String> mediaIds) {
    final entries = isar.playlistEntryDBs
        .where()
        .playlistIdEqualToAnyPosition(row.id)
        .findAllSync();
    final byMediaId = <String, PlaylistEntryDB>{};
    for (final entry in entries) {
      entry.track.loadSync();
      if (entry.track.value case final track?) {
        byMediaId.putIfAbsent(track.mediaId, () => entry);
      }
    }
    final placed = <PlaylistEntryDB>{};
    final ordered = [
      for (final mediaId in mediaIds)
        if (byMediaId[mediaId] case final entry? when placed.add(entry)) entry,
      for (final entry in entries)
        if (!placed.contains(entry)) entry,
    ];
    final moved = <PlaylistEntryDB>[];
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].position != i) moved.add(ordered[i]..position = i);
    }
    if (moved.isNotEmpty) isar.playlistEntryDBs.putAllSync(moved);
  }

  /// Puts the synced playlists in the order [syncIds], in the places synced
  /// playlists hold in the library; other playlists keep theirs. Synced
  /// playlists beyond them (made since the library was read) follow.
  static void _putPlaylistsInOrder(Isar isar, List<String> syncIds) {
    final rows = _inLibraryOrder(isar);
    final synced = {
      for (final row in rows)
        if (_isSynced(row) && row.syncId != null) row.syncId!: row
    };
    final placed = <PlaylistDB>{};
    final queue = [
      for (final id in syncIds)
        if (synced[id] case final row? when placed.add(row)) row,
      for (final row in rows)
        if (synced[row.syncId] == row && !placed.contains(row)) row,
    ].iterator;
    final ordered = [
      for (final row in rows)
        if (synced[row.syncId] == row) (queue..moveNext()).current else row
    ];
    final moved = <PlaylistDB>[];
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].sortOrder != i) moved.add(ordered[i]..sortOrder = i);
    }
    if (moved.isNotEmpty) isar.playlistDBs.putAllSync(moved);
  }

  static TrackDB? _storedTrack(Isar isar, String mediaId) =>
      isar.trackDBs.filter().mediaIdEqualTo(mediaId).findFirstSync();

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
        isPinned: playlist.pinned,
        sortOrder: sortOrderForNewPlaylist(isar),
        createdat: playlist.createdAt,
        updatedat: now)
      ..syncId = playlist.id
      ..nameChangedAt = playlist.nameChanged.at
      ..nameChangedBy = playlist.nameChanged.device
      ..descriptionChangedAt = playlist.descriptionChanged.at
      ..descriptionChangedBy = playlist.descriptionChanged.device
      ..pinnedChangedAt = playlist.pinnedChanged.at
      ..pinnedChangedBy = playlist.pinnedChanged.device;
    if (playlist.arrangement case final arrangement?) {
      row
        ..arrangedAt = arrangement.arranged.at
        ..arrangedBy = arrangement.arranged.device
        ..arrangement = arrangement.ids;
    }
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

  /// Whether [playlist] had a song added or taken out, or its details or
  /// order changed, after its stored deletion, which brings it back.
  static bool _changedSinceDeletion(Isar isar, PlaylistDB playlist, String me) {
    final deleted =
        _removedAt(isar, RemovalKind.playlist, playlist.syncId, null);
    if (deleted == null) return true;
    if ([
      _nameStamp(playlist, me),
      _descriptionStamp(playlist, me),
      _pinnedStamp(playlist, me),
      if (_arrangementOf(playlist, me) case final a?) a.arranged,
    ].any((stamp) => stamp.isAfter(deleted))) {
      return true;
    }
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
      var track = _storedTrack(isar, song.mediaId);
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

/// The Synced Library a backup restore replaces, as sync knew it (see
/// [SyncDAO.readBeforeReplaceInTransaction]).
class ReplacedSyncedLibrary {
  /// Each row sync covers, by what identifies it across the restore, with
  /// the media IDs of its songs and, for a synced playlist, the playlist as
  /// a Removal Marker keeps it should the restore delete it.
  final Map<String,
      ({PlaylistDB row, List<String> songs, String? deletedPlaylist})> _rows;

  const ReplacedSyncedLibrary._(this._rows);
}
