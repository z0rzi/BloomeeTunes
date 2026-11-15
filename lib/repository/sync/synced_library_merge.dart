import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/synced_library_change.dart';
import 'package:flutter/foundation.dart';

/// Combines this Device's Synced Library with other Devices' Device States
/// under Latest Change Wins.
///
/// Pure: the same inputs give the same result whatever order [others] come
/// in. A song is in a playlist, a song liked, an album or artist saved, when
/// its latest addition is later than its latest Removal Marker. A playlist is
/// deleted when its Removal Marker is later than every change made to it (to
/// its songs, details or order); any later one brings it back.
///
/// Each detail of a playlist (name, description, pinning) follows its own
/// latest change. The latest arrangement of a playlist's songs wins as a
/// whole: the songs it mentions follow its order, unless added again after
/// it, and the others come after, in the order they were added. The latest
/// arrangement of the library's playlists wins the same way; playlists it
/// does not mention come after, in the order they were created.
///
/// Playlist names are unique ignoring case, so two synced playlists that come
/// to bear the same name, whether made apart or by a rename, become one: the
/// playlist with the larger sync ID is the one with the smaller from then on
/// (a [PlaylistAlias], passed on to every Device), and the two are merged
/// under the same rules as two copies of one playlist. [local] lists its
/// playlists in the library's order. A name that belongs to something sync
/// does not cover ([unsyncedNames], lower-cased) is never taken.
///
/// Removal Markers made before [expireBefore] are no longer kept, whichever
/// Device holds them. A First Sync ([firstSyncAt], when it is made and by
/// this Device) takes nothing out of any Device: this Device's own Removal
/// Markers are dropped, and whatever it holds that the others' would take out
/// counts as added again by it then (or just after the removal, if that is
/// later), so it stays and reaches the others.
SyncedLibraryMerge mergeSyncedLibraries(
  SyncedLibrary local,
  List<DeviceState> others, {
  Set<String> unsyncedNames = const {},
  DateTime? expireBefore,
  ChangeStamp? firstSyncAt,
}) {
  bool live(RemovalMarker m) =>
      expireBefore == null || !m.removed.at.isBefore(expireBefore);
  final kept = [
    if (firstSyncAt == null)
      for (final m in local.removals)
        if (live(m)) m
  ];
  final dropped = [
    for (final m in local.removals)
      if (!kept.contains(m)) m
  ]..sort((a, b) => a.key.compareTo(b.key));
  final mine = _withRemovals(local, kept);
  final states = [
    for (final state in others)
      DeviceState(
          deviceId: state.deviceId,
          deviceName: state.deviceName,
          writtenAt: state.writtenAt,
          library: _withRemovals(
              state.library, state.library.removals.where(live).toList()))
  ]..sort((a, b) => a.deviceId.compareTo(b.deviceId));

  final readded =
      firstSyncAt == null ? null : _AddedAgainAtFirstSync(firstSyncAt);
  var merge = _mergeUnderAliases(mine, states, unsyncedNames);
  while (readded != null && readded.takeIn(mine, merge.library)) {
    merge = _mergeUnderAliases(readded.applyTo(mine), states, unsyncedNames);
  }
  return SyncedLibraryMerge(library: merge.library, changes: [
    if (dropped.isNotEmpty) RemovalsDropped(dropped),
    ...merge.changes,
    ...?readded?.changes(),
  ]);
}

SyncedLibrary _withRemovals(
        SyncedLibrary library, List<RemovalMarker> removals) =>
    SyncedLibrary(
        playlists: library.playlists,
        liked: library.liked,
        saved: library.saved,
        removals: removals,
        tracks: library.tracks,
        order: library.order,
        aliases: library.aliases);

/// The sync ID [id] is known by once every alias [into] gives is followed.
String _followAliases(String id, String? Function(String) into) {
  final seen = <String>{};
  var current = id;
  while (seen.add(current)) {
    current = into(current) ?? current;
  }
  return current;
}

/// What a First Sync keeps of this Device's library against the removals
/// the other Devices made: each thing counts as added again by this Device,
/// at [at] or just after the removal when that is later.
class _AddedAgainAtFirstSync {
  final ChangeStamp at;

  /// Songs, by the sync ID of their playlist, then by media ID.
  final songs = <String, Map<String, SyncedSong>>{};
  final liked = <String, SyncedSong>{};
  final saved = <String, SavedCollection>{};

  /// Playlists deleted elsewhere, by sync ID: each counts as renamed, to its
  /// own name, at the time given.
  final playlists = <String, ChangeStamp>{};

  /// The aliases of the latest merge, larger sync ID to smaller.
  Map<String, String> _aliases = const {};

  _AddedAgainAtFirstSync(this.at);

  String _canon(String id) => _followAliases(id, (from) => _aliases[from]);

  /// Takes in what [local] holds and [merged] lacks. Returns whether there
  /// was anything new, so the merge must be made again.
  bool takeIn(SyncedLibrary local, SyncedLibrary merged) {
    _aliases = {for (final a in merged.aliases) a.from: a.into};
    final markers = {for (final m in merged.removals) m.key: m.removed};
    ChangeStamp after(RemovalKind kind, String? playlistId, String? mediaId) {
      final removed =
          markers[RemovalMarker.removalKey(kind, playlistId, mediaId)];
      return removed == null || at.isAfter(removed)
          ? at
          : ChangeStamp(
              removed.at.add(const Duration(milliseconds: 1)), at.device);
    }

    var added = false;
    final playlistsMerged = {for (final p in merged.playlists) p.id: p};
    for (final playlist in local.playlists) {
      final id = _canon(playlist.id);
      final result = playlistsMerged[id];
      if (result == null) {
        if (playlists.containsKey(id)) continue;
        playlists[id] = after(RemovalKind.playlist, id, null);
        added = true;
        continue;
      }
      final present = {for (final s in result.songs) s.mediaId};
      final kept = songs.putIfAbsent(id, () => {});
      for (final song in playlist.songs) {
        if (present.contains(song.mediaId) || kept.containsKey(song.mediaId)) {
          continue;
        }
        kept[song.mediaId] = SyncedSong(
            mediaId: song.mediaId,
            added: after(RemovalKind.song, id, song.mediaId));
        added = true;
      }
      if (kept.isEmpty) songs.remove(id);
    }
    final likedMerged = {for (final s in merged.liked) s.mediaId};
    for (final song in local.liked) {
      if (likedMerged.contains(song.mediaId) ||
          liked.containsKey(song.mediaId)) {
        continue;
      }
      liked[song.mediaId] = SyncedSong(
          mediaId: song.mediaId,
          added: after(RemovalKind.like, null, song.mediaId));
      added = true;
    }
    final savedMerged = {for (final c in merged.saved) c.key};
    for (final collection in local.saved) {
      if (savedMerged.contains(collection.key) ||
          saved.containsKey(collection.key)) {
        continue;
      }
      saved[collection.key] = SavedCollection(
          kind: collection.kind,
          mediaId: collection.mediaId,
          saved: after(
              RemovalKind.ofSaved(collection.kind), null, collection.mediaId),
          details: collection.details);
      added = true;
    }
    return added;
  }

  /// [local] with what was taken in counted as added again.
  SyncedLibrary applyTo(SyncedLibrary local) {
    SyncedPlaylist again(SyncedPlaylist p) {
      final id = _canon(p.id);
      final renamed = playlists[id];
      final readded = songs[id] ?? const {};
      if (renamed == null && readded.isEmpty) return p;
      return SyncedPlaylist(
        id: p.id,
        name: p.name,
        nameChanged: renamed ?? p.nameChanged,
        description: p.description,
        descriptionChanged: p.descriptionChanged,
        pinned: p.pinned,
        pinnedChanged: p.pinnedChanged,
        createdAt: p.createdAt,
        arrangement: p.arrangement,
        songs: [for (final s in p.songs) readded[s.mediaId] ?? s],
      );
    }

    return SyncedLibrary(
      playlists: local.playlists.map(again).toList(),
      liked: [for (final s in local.liked) liked[s.mediaId] ?? s],
      saved: [for (final c in local.saved) saved[c.key] ?? c],
      removals: local.removals,
      tracks: local.tracks,
      order: local.order,
      aliases: local.aliases,
    );
  }

  /// How the library this Device holds records being added again.
  List<SyncedLibraryChange> changes() => [
        for (final MapEntry(:key, :value) in playlists.entries)
          PlaylistKept(key, value),
        for (final MapEntry(:key, :value) in songs.entries)
          SongsGained(key, value.values.toList()),
        if (liked.isNotEmpty) LikesGained(liked.values.toList()),
        if (saved.isNotEmpty) CollectionsSaved(saved.values.toList()),
      ];
}

/// The merge, once every pair of playlists whose names meet is one.
SyncedLibraryMerge _mergeUnderAliases(
    SyncedLibrary local, List<DeviceState> states, Set<String> unsyncedNames) {
  final aliases = <String, PlaylistAlias>{};
  void addAlias(PlaylistAlias alias) {
    // Always into the smaller ID, so following aliases ends; any other
    // could only come from a damaged Device State.
    if (alias.into.compareTo(alias.from) >= 0) return;
    final known = aliases[alias.from];
    if (known == null ||
        alias.into.compareTo(known.into) < 0 ||
        (alias.into == known.into && alias.merged.isAfter(known.merged))) {
      aliases[alias.from] = alias;
    }
  }

  for (final alias in local.aliases) {
    addAlias(alias);
  }
  final known = {...aliases};
  for (final state in states) {
    for (final alias in state.library.aliases) {
      addAlias(alias);
    }
  }
  while (true) {
    final pass = _MergePass(local, states, aliases, unsyncedNames);
    final merge = pass.run();
    if (merge != null) {
      final learned = [
        for (final alias in aliases.values)
          if (known[alias.from] case final had
              when had == null ||
                  had.into != alias.into ||
                  had.merged != alias.merged)
            alias
      ]..sort((a, b) => a.from.compareTo(b.from));
      return SyncedLibraryMerge(library: merge.library, changes: [
        if (learned.isNotEmpty) AliasesLearned(learned),
        ...merge.changes,
      ]);
    }
    pass.collisions.forEach(addAlias);
  }
}

/// One attempt at the merge under a set of aliases. It fails, listing the
/// aliases it found missing, when two playlists end with the same name.
class _MergePass {
  final SyncedLibrary local;
  final List<DeviceState> states;
  final Map<String, PlaylistAlias> aliases;
  final Set<String> unsyncedNames;
  final List<PlaylistAlias> collisions = [];

  _MergePass(this.local, this.states, this.aliases, this.unsyncedNames);

  /// The sync ID [id] is known by once every alias is followed.
  String canon(String id) => _followAliases(id, (from) => aliases[from]?.into);

  RemovalMarker canonMarker(RemovalMarker m) => m.playlistId == null
      ? m
      : RemovalMarker(
          kind: m.kind,
          playlistId: canon(m.playlistId!),
          mediaId: m.mediaId,
          removed: m.removed);

  Arrangement? canonOrder(Arrangement? order) {
    if (order == null) return null;
    final seen = <String>{};
    return Arrangement(order.arranged, [
      for (final id in order.ids.map(canon))
        if (seen.add(id)) id
    ]);
  }

  SyncedLibraryMerge? run() {
    final tracks = {...local.tracks};
    // Songs from this Device's own playlists that became one with another.
    final self = DeviceState(
        deviceId: '',
        deviceName: 'this Device',
        writtenAt: DateTime.utc(1970),
        library: local);

    void needTrack(DeviceState state, String mediaId) {
      if (tracks.containsKey(mediaId)) return;
      final details = state.library.tracks[mediaId];
      if (details == null) {
        throw FormatException(
            'Device State of ${state.deviceName} lacks details for $mediaId.');
      }
      tracks[mediaId] = details;
    }

    /// [held] as adding and removing songs leaves it: what it keeps, in
    /// place, then what it gains, in the order it was added.
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
    final removals = <String, RemovalMarker>{};
    for (final marker in local.removals.map(canonMarker)) {
      final known = removals[marker.key];
      if (known == null || marker.removed.isAfter(known.removed)) {
        removals[marker.key] = marker;
      }
    }
    final learned = <String, RemovalMarker>{};
    for (final state in states) {
      for (final marker in state.library.removals.map(canonMarker)) {
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

    // Playlists, by the sync ID they are known by.
    final localGroups = <String, List<SyncedPlaylist>>{};
    for (final playlist in local.playlists) {
      localGroups.putIfAbsent(canon(playlist.id), () => []).add(playlist);
    }
    final copies = <String, List<(DeviceState, SyncedPlaylist)>>{};
    final mine = <String, SyncedPlaylist>{};
    final rekeyed = <PlaylistRekeyed>[];
    final absorbed = <(String, String)>[];
    localGroups.forEach((id, group) {
      group.sort((a, b) => a.id == id
          ? -1
          : b.id == id
              ? 1
              : a.id.compareTo(b.id));
      mine[id] = group.first;
      if (group.first.id != id) {
        rekeyed.add(PlaylistRekeyed(group.first.id, id));
      }
      for (final other in group.skip(1)) {
        absorbed.add((other.id, id));
        copies.putIfAbsent(id, () => []).add((self, other));
      }
    });
    for (final state in states) {
      for (final playlist in state.library.playlists) {
        copies.putIfAbsent(canon(playlist.id), () => []).add((state, playlist));
      }
    }

    final playlists = <String, SyncedPlaylist>{};
    final gainedPlaylists = <String>[];
    final lostPlaylists = <String>[];
    final songsGained = <String, List<SyncedSong>>{};
    final songsLost = <String, List<String>>{};
    final detailsChanged = <String>[];
    final songsArranged = <String>[];

    for (final id in {...mine.keys, ...copies.keys}.toList()..sort()) {
      final held = mine[id];
      final theirs = copies[id] ?? const [];
      final songs = _mergeMembers<SyncedSong>(
        local: held?.songs ?? const [],
        others: [
          for (final (state, copy) in theirs)
            for (final song in copy.songs) (state, song)
        ],
        keyOf: (s) => s.mediaId,
        stampOf: (s) => s.added,
        removedAt: (s) => removedAt(RemovalKind.song, id, s.mediaId),
      );

      // Each detail, and the arrangement, from the copy that changed it last;
      // this Device's own copy first, so it keeps what no one changed later.
      final all = [if (held != null) held, for (final (_, c) in theirs) c];
      SyncedPlaylist latestBy(ChangeStamp Function(SyncedPlaylist) stamp) =>
          all.reduce((a, b) => stamp(b).isAfter(stamp(a)) ? b : a);
      var named = latestBy((p) => p.nameChanged);
      final described = latestBy((p) => p.descriptionChanged);
      final pinned = latestBy((p) => p.pinnedChanged);
      Arrangement? arrangement;
      for (final copy in all) {
        if (copy.arrangement case final a?
            when arrangement == null ||
                a.arranged.isAfter(arrangement.arranged)) {
          arrangement = a;
        }
      }
      // A name sync does not cover here is not taken; the rename still
      // counts as a change to the playlist.
      final renamed = named.nameChanged;
      if (unsyncedNames.contains(named.name.toLowerCase())) {
        if (held == null) continue;
        named = held;
      }

      ChangeStamp? latestChange;
      for (final stamp in [
        ...songs.additions,
        ...?songRemovals[id],
        renamed,
        described.descriptionChanged,
        pinned.pinnedChanged,
        if (arrangement != null) arrangement.arranged,
      ]) {
        latestChange = ChangeStamp.latest(latestChange, stamp);
      }
      final deletion = removedAt(RemovalKind.playlist, id, null);
      if (deletion != null &&
          (latestChange == null || !latestChange.isAfter(deletion))) {
        if (held != null) lostPlaylists.add(id);
        continue;
      }

      final natural = songsAfter(held?.songs ?? const [], songs);
      final ordered =
          Arrangement.arrangeSongs(arrangement, songs.present.values);
      DateTime createdAt = all.first.createdAt;
      for (final copy in all) {
        if (copy.createdAt.isBefore(createdAt)) createdAt = copy.createdAt;
      }
      final result = SyncedPlaylist(
          id: id,
          name: named.name,
          nameChanged: named.nameChanged,
          description: described.description,
          descriptionChanged: described.descriptionChanged,
          pinned: pinned.pinned,
          pinnedChanged: pinned.pinnedChanged,
          createdAt: createdAt,
          arrangement: arrangement,
          songs: ordered);
      playlists[id] = result;

      if (held == null) {
        gainedPlaylists.add(id);
        continue;
      }
      if (songs.gained.isNotEmpty) {
        songsGained[id] = [for (final (_, song) in songs.gained) song];
      }
      if (songs.lost.isNotEmpty) songsLost[id] = songs.lost;
      if (result.name != held.name ||
          result.nameChanged != held.nameChanged ||
          result.description != held.description ||
          result.descriptionChanged != held.descriptionChanged ||
          result.pinned != held.pinned ||
          result.pinnedChanged != held.pinnedChanged) {
        detailsChanged.add(id);
      }
      if (!listEquals(_mediaIds(ordered), _mediaIds(natural)) ||
          arrangement != held.arrangement) {
        songsArranged.add(id);
      }
    }

    // Two playlists that end with the same name become one.
    final byName = <String, List<SyncedPlaylist>>{};
    for (final playlist in playlists.values) {
      byName.putIfAbsent(playlist.name.toLowerCase(), () => []).add(playlist);
    }
    for (final group in byName.values) {
      if (group.length < 2) continue;
      group.sort((a, b) => a.id.compareTo(b.id));
      final merged = group
          .map((p) => p.nameChanged)
          .reduce((a, b) => ChangeStamp.latest(a, b));
      for (final other in group.skip(1)) {
        collisions.add(PlaylistAlias(
            from: other.id, into: group.first.id, merged: merged));
      }
    }
    if (collisions.isNotEmpty) return null;

    // The order of the playlists in the library.
    Arrangement? order = canonOrder(local.order);
    for (final state in states) {
      if (canonOrder(state.library.order) case final theirs?
          when order == null || theirs.arranged.isAfter(order.arranged)) {
        order = theirs;
      }
    }
    final arranged = Arrangement.arrangePlaylists(order, playlists.values);
    final seen = <String>{};
    final heldOrder = [
      for (final p in local.playlists)
        if (playlists.containsKey(canon(p.id)) && seen.add(canon(p.id)))
          canon(p.id)
    ];
    final orderIds = [for (final p in arranged) p.id];
    final orderChanged =
        order != local.order || !listEquals(orderIds, heldOrder);

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
        playlists: arranged,
        liked: liked,
        saved: saved.present.values.toList(),
        removals: removals.values.toList(),
        tracks: tracks,
        order: order,
        aliases: aliases.values.toList(),
      ),
      changes: [
        if (learned.isNotEmpty) RemovalsLearned(learned.values.toList()),
        ...rekeyed,
        for (final (from, into) in absorbed) PlaylistAbsorbed(from, into),
        for (final id in lostPlaylists) PlaylistLost(id),
        for (final entry in songsLost.entries)
          SongsLost(entry.key, entry.value),
        if (likes.lost.isNotEmpty) LikesLost(likes.lost),
        if (saved.lost.isNotEmpty)
          CollectionsUnsaved([
            for (final key in saved.lost)
              (localSaved[key]!.kind, localSaved[key]!.mediaId)
          ]),
        for (final id in detailsChanged) DetailsChanged(playlists[id]!),
        for (final id in gainedPlaylists) PlaylistGained(playlists[id]!),
        for (final entry in songsGained.entries)
          SongsGained(entry.key, entry.value),
        if (likes.gained.isNotEmpty)
          LikesGained([for (final (_, song) in likes.gained) song]),
        if (saved.gained.isNotEmpty)
          CollectionsSaved([for (final (_, c) in saved.gained) c]),
        for (final id in songsArranged)
          SongsArranged(id, [for (final s in playlists[id]!.songs) s.mediaId],
              playlists[id]!.arrangement),
        if (orderChanged) PlaylistsArranged(orderIds, order),
      ],
    );
  }
}

List<String> _mediaIds(List<SyncedSong> songs) =>
    [for (final s in songs) s.mediaId];

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
