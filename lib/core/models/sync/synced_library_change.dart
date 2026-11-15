import 'package:Bloomee/core/models/sync/device_state.dart';

/// One difference the merge would make to this Device's Synced Library.
sealed class SyncedLibraryChange {
  const SyncedLibraryChange();
}

/// A playlist this Device did not have, with its songs.
final class PlaylistGained extends SyncedLibraryChange {
  final SyncedPlaylist playlist;
  const PlaylistGained(this.playlist);
}

/// A playlist this Device has that was deleted on another Device after every
/// change made to it.
final class PlaylistLost extends SyncedLibraryChange {
  final String playlistId;
  const PlaylistLost(this.playlistId);
}

/// Songs added to a playlist this Device already has. A song it lacks is
/// appended, in this order; one it holds takes this later addition time.
final class SongsGained extends SyncedLibraryChange {
  final String playlistId;
  final List<SyncedSong> songs;
  const SongsGained(this.playlistId, this.songs);
}

/// Songs taken out of a playlist this Device has.
final class SongsLost extends SyncedLibraryChange {
  final String playlistId;
  final List<String> mediaIds;
  const SongsLost(this.playlistId, this.mediaIds);
}

/// Songs liked on another Device. A song not liked here is liked, in this
/// order; one liked here takes this later addition time.
final class LikesGained extends SyncedLibraryChange {
  final List<SyncedSong> songs;
  const LikesGained(this.songs);
}

/// Songs unliked on another Device.
final class LikesLost extends SyncedLibraryChange {
  final List<String> mediaIds;
  const LikesLost(this.mediaIds);
}

/// Albums and artists saved on another Device. One not saved here is saved;
/// one saved here takes this later saving time.
final class CollectionsSaved extends SyncedLibraryChange {
  final List<SavedCollection> collections;
  const CollectionsSaved(this.collections);
}

/// Albums and artists unsaved on another Device.
final class CollectionsUnsaved extends SyncedLibraryChange {
  final List<(SavedKind, String)> collections;
  const CollectionsUnsaved(this.collections);
}

/// Removal Markers this Device learned from others, or later ones than it
/// held; kept so it passes the removals on.
final class RemovalsLearned extends SyncedLibraryChange {
  final List<RemovalMarker> markers;
  const RemovalsLearned(this.markers);
}

/// Pairs of playlists this Device learned became one, from the other Devices
/// or because their names met here. Removal Markers recorded under [PlaylistAlias.from]
/// are the playlist [PlaylistAlias.into]'s from then on.
final class AliasesLearned extends SyncedLibraryChange {
  final List<PlaylistAlias> aliases;
  const AliasesLearned(this.aliases);
}

/// A playlist this Device has is known by another sync ID from now on, the
/// one of the playlist it became one with.
final class PlaylistRekeyed extends SyncedLibraryChange {
  final String from;
  final String to;
  const PlaylistRekeyed(this.from, this.to);
}

/// A playlist this Device has became one with another playlist it also has,
/// [into]: its songs go to that playlist, and it goes.
final class PlaylistAbsorbed extends SyncedLibraryChange {
  final String playlistId;
  final String into;
  const PlaylistAbsorbed(this.playlistId, this.into);
}

/// Details of a playlist this Device has (name, description, pinning) that
/// changed later on another Device: each is set when its change time is later
/// than the one here.
final class DetailsChanged extends SyncedLibraryChange {
  final SyncedPlaylist playlist;
  const DetailsChanged(this.playlist);
}

/// A playlist this Device has whose songs go in the order [mediaIds], after
/// the songs it gains and loses; [arrangement] is the latest arrangement of
/// them, kept so it passes it on.
final class SongsArranged extends SyncedLibraryChange {
  final String playlistId;
  final List<String> mediaIds;
  final Arrangement? arrangement;
  const SongsArranged(this.playlistId, this.mediaIds, this.arrangement);
}

/// The synced playlists of the library go in the order [playlistIds] (sync
/// IDs), after the playlists gained and lost; [arrangement] is the latest
/// arrangement of them, kept so it passes it on. Other playlists keep their
/// places.
final class PlaylistsArranged extends SyncedLibraryChange {
  final List<String> playlistIds;
  final Arrangement? arrangement;
  const PlaylistsArranged(this.playlistIds, this.arrangement);
}

/// The Synced Library the merge arrives at, and how it differs from the
/// local one. Applying [changes] to the local library yields [library].
class SyncedLibraryMerge {
  final SyncedLibrary library;
  final List<SyncedLibraryChange> changes;

  const SyncedLibraryMerge({required this.library, required this.changes});
}
