import 'package:Bloomee/core/models/sync/sync_outcome.dart';

/// The kinds of Sync Location a Device can choose.
enum SyncLocationKind {
  /// A folder on this machine that another tool carries between machines.
  /// Offered on Linux only, as an advanced choice.
  localFolder;

  /// The kinds offered on [operatingSystem] (as `Platform.operatingSystem`
  /// names it), in the order the settings show them.
  static List<SyncLocationKind> offeredOn(String operatingSystem) => [
        if (operatingSystem == 'linux') localFolder,
      ];
}

/// How Library Sync is set up on this Device.
class SyncSetup {
  final bool enabled;

  /// The local folder chosen as the Sync Location, if one was.
  final String? folder;

  /// This Device's name: the one chosen, or the machine's name until then.
  final String deviceName;

  const SyncSetup(
      {required this.enabled, this.folder, required this.deviceName});
}

/// Why a chosen Sync Location cannot be used.
enum SyncLocationProblem {
  /// It cannot be found or reached.
  notFound,

  /// It can be reached, but Bloomee cannot write into it.
  notWritable,
}

/// Where Library Sync stands, for the status line.
class SyncStatus {
  /// Whether a sync is running now.
  final bool running;

  /// When this Device last completed a sync.
  final DateTime? lastSyncedAt;

  /// The latest sync that failed or needs the owner, since the app started.
  final SyncError? lastError;

  const SyncStatus({this.running = false, this.lastSyncedAt, this.lastError});

  SyncStatus copyWith(
          {bool? running, DateTime? lastSyncedAt, SyncError? lastError}) =>
      SyncStatus(
          running: running ?? this.running,
          lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
          lastError: lastError ?? this.lastError);
}

/// A sync that failed or needs the owner.
sealed class SyncError {
  final DateTime at;
  const SyncError(this.at);
}

/// The Sync Location could not be reached; sync retries by itself.
final class SyncLocationUnreachable extends SyncError {
  final String detail;
  const SyncLocationUnreachable(super.at, this.detail);
}

/// The sync failed for another reason; sync retries by itself.
final class SyncFailed extends SyncError {
  final String detail;
  const SyncFailed(super.at, this.detail);
}

/// The sync ran but needs the owner: the Removal Guard holds it, an update is
/// needed, or another Device's Device State was left out.
final class SyncNeedsOwner extends SyncError {
  final SyncOutcome outcome;
  const SyncNeedsOwner(super.at, this.outcome);
}
