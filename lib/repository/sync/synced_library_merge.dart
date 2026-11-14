import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/synced_library_change.dart';

/// Combines this Device's Synced Library with other Devices' Device States.
///
/// Pure: the same inputs give the same result whatever order [others] come
/// in. A playlist met for the first time is gained; songs another Device has
/// in a shared playlist are appended in the order they were added. A playlist
/// whose name (ignoring case) is already used here joins the local playlist
/// of that name, unless the name belongs to something sync does not cover
/// ([unsyncedNames], lower-cased), in which case it is left out.
SyncedLibraryMerge mergeSyncedLibraries(
  SyncedLibrary local,
  List<DeviceState> others, {
  Set<String> unsyncedNames = const {},
}) {
  final states = [...others]..sort((a, b) => a.deviceId.compareTo(b.deviceId));
  final playlists = <String, SyncedPlaylist>{
    for (final p in local.playlists) p.id: p
  };
  final byName = <String, String>{
    for (final p in local.playlists) p.name.toLowerCase(): p.id
  };
  final tracks = {...local.tracks};
  final gained = <String>{};
  final appended = <String, List<SyncedSong>>{};

  final copies = <String, List<(DeviceState, SyncedPlaylist)>>{};
  for (final state in states) {
    for (final playlist in state.library.playlists) {
      copies.putIfAbsent(playlist.id, () => []).add((state, playlist));
    }
  }

  void needTrack(DeviceState state, String mediaId) {
    if (tracks.containsKey(mediaId)) return;
    final details = state.library.tracks[mediaId];
    if (details == null) {
      throw FormatException(
          'Device State of ${state.deviceName} lacks details for $mediaId.');
    }
    tracks[mediaId] = details;
  }

  for (final id in copies.keys.toList()..sort()) {
    final versions = copies[id]!;
    final (firstState, first) = versions.first;
    var target =
        playlists.containsKey(id) ? id : byName[first.name.toLowerCase()];
    if (target == null) {
      if (unsyncedNames.contains(first.name.toLowerCase())) continue;
      final seen = <String>{};
      final songs = [
        for (final song in first.songs)
          if (seen.add(song.mediaId)) song
      ];
      for (final song in songs) {
        needTrack(firstState, song.mediaId);
      }
      playlists[id] = first.withSongs(songs);
      byName[first.name.toLowerCase()] = id;
      gained.add(id);
      target = id;
    }

    final present = {for (final s in playlists[target]!.songs) s.mediaId};
    final extra = <String, (DeviceState, SyncedSong)>{};
    for (final (state, version) in versions) {
      for (final song in version.songs) {
        if (present.contains(song.mediaId)) continue;
        final known = extra[song.mediaId];
        if (known == null || song.addedAt.isAfter(known.$2.addedAt)) {
          extra[song.mediaId] = (state, song);
        }
      }
    }
    if (extra.isEmpty) continue;
    final ordered = extra.values.toList()
      ..sort((a, b) {
        final byTime = a.$2.addedAt.compareTo(b.$2.addedAt);
        return byTime != 0 ? byTime : a.$2.mediaId.compareTo(b.$2.mediaId);
      });
    for (final (state, song) in ordered) {
      needTrack(state, song.mediaId);
    }
    final songs = [for (final (_, song) in ordered) song];
    playlists[target] =
        playlists[target]!.withSongs([...playlists[target]!.songs, ...songs]);
    if (!gained.contains(target)) {
      appended.putIfAbsent(target, () => []).addAll(songs);
    }
  }

  return SyncedLibraryMerge(
    library:
        SyncedLibrary(playlists: playlists.values.toList(), tracks: tracks),
    changes: [
      for (final id in gained) PlaylistGained(playlists[id]!),
      for (final entry in appended.entries) SongsGained(entry.key, entry.value),
    ],
  );
}
