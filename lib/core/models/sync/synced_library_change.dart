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

/// The Synced Library the merge arrives at, and how it differs from the
/// local one. Applying [changes] to the local library yields [library].
class SyncedLibraryMerge {
  final SyncedLibrary library;
  final List<SyncedLibraryChange> changes;

  const SyncedLibraryMerge({required this.library, required this.changes});
}
