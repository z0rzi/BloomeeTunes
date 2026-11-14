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

/// Songs appended to a playlist this Device already has, in this order.
final class SongsGained extends SyncedLibraryChange {
  final String playlistId;
  final List<SyncedSong> songs;
  const SongsGained(this.playlistId, this.songs);
}

/// The Synced Library the merge arrives at, and how it differs from the
/// local one. Applying [changes] to the local library yields [library].
class SyncedLibraryMerge {
  final SyncedLibrary library;
  final List<SyncedLibraryChange> changes;

  const SyncedLibraryMerge({required this.library, required this.changes});
}
