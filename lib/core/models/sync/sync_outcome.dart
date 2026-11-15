import 'package:Bloomee/core/models/sync/device_state.dart';

/// What one sync did, and what the owner may need to know about it.
sealed class SyncOutcome {
  /// Other Devices' Device States this sync left out, and why. The others
  /// were still taken in.
  final List<SkippedDeviceState> skipped;

  const SyncOutcome({this.skipped = const []});
}

/// The other Devices' changes were taken in and this Device's Device State
/// published.
final class SyncCompleted extends SyncOutcome {
  /// Whether the library changed.
  final bool changed;

  const SyncCompleted({required this.changed, super.skipped});
}

/// The Removal Guard holds the merge: nothing was applied or published.
/// Answering it (see `SyncEngine.answerRemovalGuard`) applies it or keeps sync
/// paused.
final class SyncHeld extends SyncOutcome {
  final RemovalGuardHold hold;

  /// Whether the owner declined it: sync stays paused until they confirm it.
  final bool declined;

  const SyncHeld({required this.hold, required this.declined, super.skipped});
}

/// A Device State is in a newer format than this build reads: sync stopped,
/// nothing was applied or published, until this build is updated.
final class SyncUpdateNeeded extends SyncOutcome {
  final String deviceId;
  final String? deviceName;
  final int formatVersion;

  const SyncUpdateNeeded(
      {required this.deviceId,
      this.deviceName,
      required this.formatVersion,
      super.skipped});
}

/// Another Device's Device State a sync left out.
sealed class SkippedDeviceState {
  /// The Device's permanent ID, from its Device State's name.
  final String deviceId;

  /// Its name, when the Device State told it.
  final String? deviceName;

  const SkippedDeviceState({required this.deviceId, this.deviceName});
}

/// A Device State that could not be read: not a Device State, cut short, or
/// missing what is needed to take it in.
final class DamagedDeviceState extends SkippedDeviceState {
  final String reason;

  const DamagedDeviceState(
      {required super.deviceId, super.deviceName, required this.reason});
}

/// A Device State holding a change dated more than a day after this Device's
/// clock: the other Device's clock is wrong, so its changes are refused.
final class DeviceStateFromFuture extends SkippedDeviceState {
  /// Its latest change.
  final DateTime changedAt;

  const DeviceStateFromFuture(
      {required super.deviceId,
      required String super.deviceName,
      required this.changedAt});
}

/// A merge the Removal Guard holds for the owner's confirmation, because it
/// would remove more than a quarter of the songs of the Synced Library or
/// delete more than three playlists.
class RemovalGuardHold {
  /// The songs of the Synced Library now: each song of each synced playlist,
  /// and each liked song.
  final int songsInLibrary;

  /// Everything the merge would take out, in the order the Device States
  /// gave it.
  final List<HeldRemoval> removals;

  const RemovalGuardHold(
      {required this.songsInLibrary, required this.removals});

  /// Songs the merge would take out, those of deleted playlists included.
  int get songsRemoved => removals.fold(0, (sum, r) => sum + r.songCount);

  int get playlistsDeleted =>
      removals.where((r) => r.kind == RemovalKind.playlist).length;

  /// The Devices the removals come from.
  Set<String> get deviceNames => {for (final r in removals) r.deviceName};

  /// Whether [other] takes out exactly what this does.
  bool sameRemovalsAs(RemovalGuardHold other) {
    final keys = {for (final r in removals) r.key};
    return removals.length == other.removals.length &&
        other.removals.every((r) => keys.contains(r.key));
  }
}

/// One thing a held merge would take out of the Synced Library.
class HeldRemoval {
  /// A playlist deleted with its songs, a song taken out of a playlist, or a
  /// song unliked.
  final RemovalKind kind;

  /// The name of the playlist deleted or the song is taken out of; null for
  /// a like.
  final String? playlistName;

  /// The song taken out or unliked; null for a deleted playlist.
  final String? mediaId;
  final String? title;

  /// How many songs it takes out: those of a deleted playlist, otherwise one.
  final int songCount;

  /// The Device that made the removal.
  final String deviceId;

  /// Its name, or its ID when no Device State names it.
  final String deviceName;

  /// Identifies what is removed, so a confirmation covers exactly it.
  final String key;

  const HeldRemoval({
    required this.kind,
    this.playlistName,
    this.mediaId,
    this.title,
    required this.songCount,
    required this.deviceId,
    required this.deviceName,
    required this.key,
  });
}
