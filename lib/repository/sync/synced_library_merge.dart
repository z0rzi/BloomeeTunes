import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/synced_library_change.dart';

/// Combines this Device's Synced Library with other Devices' Device States
/// under Latest Change Wins.
///
/// Pure: the same inputs give the same result whatever order [others] come
/// in. A song is in a playlist, a song liked, an album or artist saved, when
/// its latest addition is later than its latest Removal Marker. A playlist is
/// deleted when its Removal Marker is later than every addition and removal of
/// its songs; any later one brings it back. Songs gained by a playlist are
/// appended in the order they were added.
///
/// A playlist met for the first time is gained, unless its name (ignoring
/// case) is already used here: then its songs join the local playlist of that
/// name, and are only ever added to it. A name that belongs to something sync
/// does not cover ([unsyncedNames], lower-cased) is left out.
SyncedLibraryMerge mergeSyncedLibraries(
  SyncedLibrary local,
  List<DeviceState> others, {
  Set<String> unsyncedNames = const {},
}) {
  final states = [...others]..sort((a, b) => a.deviceId.compareTo(b.deviceId));
  final tracks = {...local.tracks};

  void needTrack(DeviceState state, String mediaId) {
    if (tracks.containsKey(mediaId)) return;
    final details = state.library.tracks[mediaId];
    if (details == null) {
      throw FormatException(
          'Device State of ${state.deviceName} lacks details for $mediaId.');
    }
    tracks[mediaId] = details;
  }

  /// [held] as the merge leaves it: what it keeps, in place, then what it
  /// gains, in the order it was added.
  List<SyncedSong> songsAfter(List<SyncedSong> held, _Members<SyncedSong> m) {
    for (final (state, song) in m.fresh) {
      needTrack(state, song.mediaId);
    }
    return [
      for (final s in held)
        if (m.present[s.mediaId] case final song?) song,
      for (final (_, song) in m.fresh) song,
    ];
  }

  // Removal Markers: the latest of each, from every Device.
  final removals = {for (final r in local.removals) r.key: r};
  final learned = <String, RemovalMarker>{};
  for (final state in states) {
    for (final marker in state.library.removals) {
      final known = removals[marker.key];
      if (known == null || marker.removed.isAfter(known.removed)) {
        removals[marker.key] = learned[marker.key] = marker;
      }
    }
  }
  ChangeStamp? removedAt(RemovalKind kind, String? playlistId, String? id) =>
      removals[RemovalMarker.removalKey(kind, playlistId, id)]?.removed;
  final songRemovals = <String, List<ChangeStamp>>{};
  for (final marker in removals.values) {
    if (marker.kind == RemovalKind.song) {
      songRemovals
          .putIfAbsent(marker.playlistId!, () => [])
          .add(marker.removed);
    }
  }

  // Playlists.
  final localPlaylists = {for (final p in local.playlists) p.id: p};
  final copies = <String, List<(DeviceState, SyncedPlaylist)>>{};
  for (final state in states) {
    for (final playlist in state.library.playlists) {
      copies.putIfAbsent(playlist.id, () => []).add((state, playlist));
    }
  }
  final playlists = <String, SyncedPlaylist>{};
  final byName = {for (final p in local.playlists) p.name.toLowerCase(): p.id};
  final gainedPlaylists = <String>{};
  final lostPlaylists = <String>[];
  final songsGained = <String, List<SyncedSong>>{};
  final songsLost = <String, List<String>>{};
  final joining = <(SyncedPlaylist, List<(DeviceState, SyncedSong)>)>[];

  // Local playlists first, so a name freed by a deletion can be taken.
  final ids = [
    ...localPlaylists.keys.toList()..sort(),
    ...copies.keys.where((id) => !localPlaylists.containsKey(id)).toList()
      ..sort(),
  ];
  for (final id in ids) {
    final mine = localPlaylists[id];
    final theirs = copies[id] ?? const [];
    final songs = _mergeMembers<SyncedSong>(
      local: mine?.songs ?? const [],
      others: [
        for (final (state, copy) in theirs)
          for (final song in copy.songs) (state, song)
      ],
      keyOf: (s) => s.mediaId,
      stampOf: (s) => s.added,
      removedAt: (s) => removedAt(RemovalKind.song, id, s.mediaId),
    );

    ChangeStamp? latestChange;
    for (final stamp in [...songs.additions, ...?songRemovals[id]]) {
      latestChange = ChangeStamp.latest(latestChange, stamp);
    }
    final deletion = removedAt(RemovalKind.playlist, id, null);
    if (deletion != null &&
        (latestChange == null || !latestChange.isAfter(deletion))) {
      if (mine != null) {
        lostPlaylists.add(id);
        byName.remove(mine.name.toLowerCase());
      }
      continue;
    }

    if (mine != null) {
      playlists[id] = mine.withSongs(songsAfter(mine.songs, songs));
      if (songs.gained.isNotEmpty) {
        songsGained[id] = [for (final (_, song) in songs.gained) song];
      }
      if (songs.lost.isNotEmpty) songsLost[id] = songs.lost;
      continue;
    }

    final (firstState, first) = theirs.first;
    if (byName.containsKey(first.name.toLowerCase())) {
      joining.add((first, songs.gained));
      continue;
    }
    if (unsyncedNames.contains(first.name.toLowerCase())) continue;
    // Its order is that of the copy of the lowest Device ID; songs only
    // other copies hold follow in the order they were added.
    final inFirst = {for (final s in first.songs) s.mediaId};
    final ordered = [
      for (final s in first.songs)
        if (songs.present[s.mediaId] case final song?) (firstState, song),
      for (final gained in songs.gained)
        if (!inFirst.contains(gained.$2.mediaId)) gained,
    ];
    for (final (state, song) in ordered) {
      needTrack(state, song.mediaId);
    }
    playlists[id] = first.withSongs([for (final (_, song) in ordered) song]);
    byName[first.name.toLowerCase()] = id;
    gainedPlaylists.add(id);
  }

  for (final (playlist, songs) in joining) {
    final target = byName[playlist.name.toLowerCase()]!;
    final present = {for (final s in playlists[target]!.songs) s.mediaId};
    final extra = [
      for (final (state, song) in songs)
        if (present.add(song.mediaId)) (state, song)
    ];
    if (extra.isEmpty) continue;
    for (final (state, song) in extra) {
      needTrack(state, song.mediaId);
    }
    final added = [for (final (_, song) in extra) song];
    playlists[target] =
        playlists[target]!.withSongs([...playlists[target]!.songs, ...added]);
    if (!gainedPlaylists.contains(target)) {
      songsGained.putIfAbsent(target, () => []).addAll(added);
    }
  }

  // Liked songs.
  final likes = _mergeMembers<SyncedSong>(
    local: local.liked,
    others: [
      for (final state in states)
        for (final song in state.library.liked) (state, song)
    ],
    keyOf: (s) => s.mediaId,
    stampOf: (s) => s.added,
    removedAt: (s) => removedAt(RemovalKind.like, null, s.mediaId),
  );
  final liked = songsAfter(local.liked, likes);

  // Saved albums and artists.
  final saved = _mergeMembers<SavedCollection>(
    local: local.saved,
    others: [
      for (final state in states)
        for (final collection in state.library.saved) (state, collection)
    ],
    keyOf: (c) => c.key,
    stampOf: (c) => c.saved,
    removedAt: (c) => removedAt(RemovalKind.ofSaved(c.kind), null, c.mediaId),
  );

  final localSaved = {for (final c in local.saved) c.key: c};
  return SyncedLibraryMerge(
    library: SyncedLibrary(
      playlists: playlists.values.toList(),
      liked: liked,
      saved: saved.present.values.toList(),
      removals: removals.values.toList(),
      tracks: tracks,
    ),
    changes: [
      if (learned.isNotEmpty) RemovalsLearned(learned.values.toList()),
      for (final id in lostPlaylists) PlaylistLost(id),
      for (final entry in songsLost.entries) SongsLost(entry.key, entry.value),
      if (likes.lost.isNotEmpty) LikesLost(likes.lost),
      if (saved.lost.isNotEmpty)
        CollectionsUnsaved([
          for (final key in saved.lost)
            (localSaved[key]!.kind, localSaved[key]!.mediaId)
        ]),
      for (final id in gainedPlaylists) PlaylistGained(playlists[id]!),
      for (final entry in songsGained.entries)
        SongsGained(entry.key, entry.value),
      if (likes.gained.isNotEmpty)
        LikesGained([for (final (_, song) in likes.gained) song]),
      if (saved.gained.isNotEmpty)
        CollectionsSaved([for (final (_, c) in saved.gained) c]),
    ],
  );
}

/// One set of things merged under Latest Change Wins: a playlist's songs,
/// the liked songs, or the saved collections.
class _Members<T> {
  /// What the merge keeps, by key, each with its latest addition.
  final Map<String, T> present;

  /// What another Device added later than this Device did (or at all), and
  /// the merge keeps; in the order it was added.
  final List<(DeviceState, T)> gained;

  /// The part of [gained] this Device does not hold at all.
  final List<(DeviceState, T)> fresh;

  /// Keys of what this Device holds and the merge takes out.
  final List<String> lost;

  /// The latest addition of everything any Device holds.
  final List<ChangeStamp> additions;

  const _Members(
      this.present, this.gained, this.fresh, this.lost, this.additions);
}

_Members<T> _mergeMembers<T>({
  required List<T> local,
  required List<(DeviceState, T)> others,
  required String Function(T) keyOf,
  required ChangeStamp Function(T) stampOf,
  required ChangeStamp? Function(T) removedAt,
}) {
  final latest = <String, (DeviceState?, T)>{
    for (final item in local) keyOf(item): (null, item)
  };
  for (final (state, item) in others) {
    final key = keyOf(item);
    final known = latest[key];
    if (known == null || stampOf(item).isAfter(stampOf(known.$2))) {
      latest[key] = (state, item);
    }
  }
  final mine = {for (final item in local) keyOf(item)};
  final present = <String, T>{};
  final gained = <(DeviceState, T)>[];
  final lost = <String>[];
  for (final MapEntry(:key, value: (state, item)) in latest.entries) {
    final removal = removedAt(item);
    if (removal == null || stampOf(item).isAfter(removal)) {
      present[key] = item;
      if (state != null) gained.add((state, item));
    } else if (mine.contains(key)) {
      lost.add(key);
    }
  }
  gained.sort((a, b) {
    final byStamp = stampOf(a.$2).compareTo(stampOf(b.$2));
    return byStamp != 0 ? byStamp : keyOf(a.$2).compareTo(keyOf(b.$2));
  });
  lost.sort();
  return _Members(
      present,
      gained,
      [
        for (final entry in gained)
          if (!mine.contains(keyOf(entry.$2))) entry
      ],
      lost,
      [for (final (_, item) in latest.values) stampOf(item)]);
}
