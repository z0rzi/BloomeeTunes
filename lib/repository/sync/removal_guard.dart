import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/core/models/sync/synced_library_change.dart';

/// What [merge] would take out of [local], each removal with the Device that
/// made it. [deviceNames] names the Devices by permanent ID.
RemovalGuardHold removalsOf(SyncedLibrary local, SyncedLibraryMerge merge,
    Map<String, String> deviceNames) {
  final aliases = {for (final a in merge.library.aliases) a.from: a.into};
  String canon(String id) {
    final seen = <String>{};
    var current = id;
    while (seen.add(current)) {
      current = aliases[current] ?? current;
    }
    return current;
  }

  // This Device's playlists by the sync ID the merge knows them by.
  final playlists = <String, SyncedPlaylist>{};
  for (final playlist in local.playlists) {
    final id = canon(playlist.id);
    if (playlist.id == id || !playlists.containsKey(id)) {
      playlists[id] = playlist;
    }
  }
  final markers = {for (final m in merge.library.removals) m.key: m};
  String? titleOf(String mediaId) => local.tracks[mediaId]?['title'] as String?;
  HeldRemoval removal(RemovalKind kind,
      {String? playlistId, String? mediaId, int songCount = 1}) {
    final key = RemovalMarker.removalKey(kind, playlistId, mediaId);
    final device = markers[key]?.removed.device ?? '';
    return HeldRemoval(
        kind: kind,
        playlistName: playlistId == null ? null : playlists[playlistId]?.name,
        mediaId: mediaId,
        title: mediaId == null ? null : titleOf(mediaId),
        songCount: songCount,
        deviceId: device,
        deviceName: deviceNames[device] ?? device,
        key: key);
  }

  return RemovalGuardHold(
    songsInLibrary: local.playlists.fold(0, (n, p) => n + p.songs.length) +
        local.liked.length,
    removals: [
      for (final change in merge.changes)
        ...switch (change) {
          PlaylistLost(:final playlistId) => [
              removal(RemovalKind.playlist,
                  playlistId: playlistId,
                  songCount: playlists[playlistId]?.songs.length ?? 0)
            ],
          SongsLost(:final playlistId, :final mediaIds) => [
              for (final mediaId in mediaIds)
                removal(RemovalKind.song,
                    playlistId: playlistId, mediaId: mediaId)
            ],
          LikesLost(:final mediaIds) => [
              for (final mediaId in mediaIds)
                removal(RemovalKind.like, mediaId: mediaId)
            ],
          _ => const <HeldRemoval>[],
        }
    ],
  );
}

/// Whether the Removal Guard holds a merge taking out [what]: more than a
/// quarter of the songs of the Synced Library, or more than three playlists.
bool removalGuardHolds(RemovalGuardHold what) =>
    what.songsRemoved * 4 > what.songsInLibrary || what.playlistsDeleted > 3;
