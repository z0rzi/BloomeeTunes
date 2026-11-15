import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:equatable/equatable.dart';

/// The kinds of Sync Location a Device can choose.
enum SyncLocationKind {
  /// The owner's Dropbox, in the app folder of the Dropbox app Bloomee signs
  /// in through: the owner's own, or the one the build was given. Offered on
  /// Linux and Android.
  dropbox,

  /// A folder on the owner's own WebDAV server, signed in to with a user
  /// name and password. Offered on Linux and Android.
  webDav,

  /// A folder on this machine that another tool carries between machines.
  /// Offered on Linux and Android, as an advanced choice. On Android it is
  /// the folder's tree URI the system folder picker gave, not a path.
  localFolder;

  /// The kinds offered on [operatingSystem] (as `Platform.operatingSystem`
  /// names it), in the order the settings show them. A build without a
  /// Dropbox app key offers [dropbox] too, through the owner's own app.
  static List<SyncLocationKind> offeredOn(String operatingSystem) {
    final linuxOrAndroid =
        operatingSystem == 'linux' || operatingSystem == 'android';
    return [
      if (linuxOrAndroid) SyncLocationKind.dropbox,
      if (linuxOrAndroid) webDav,
      if (linuxOrAndroid) localFolder,
    ];
  }
}

/// A Sync Location the owner chooses: its kind and, for a local folder,
/// which one. Dropbox and WebDAV are the ones this Device is signed in to.
class SyncLocationChoice extends Equatable {
  final SyncLocationKind kind;

  /// The folder, for [SyncLocationKind.localFolder]: a path, or on Android
  /// a tree URI; null otherwise.
  final String? folder;

  const SyncLocationChoice.folder(String this.folder)
      : kind = SyncLocationKind.localFolder;
  const SyncLocationChoice.dropbox()
      : kind = SyncLocationKind.dropbox,
        folder = null;
  const SyncLocationChoice.webDav()
      : kind = SyncLocationKind.webDav,
        folder = null;

  @override
  List<Object?> get props => [kind, folder];
}

/// How Library Sync is set up on this Device.
class SyncSetup extends Equatable {
  final bool enabled;

  /// Whether sync was ever turned on here: this Device then keeps its sync
  /// bookkeeping, on or off, so that what changes while sync is off still
  /// reaches the other Devices once it is back on.
  final bool everEnabled;

  /// The kind of Sync Location chosen, if one was.
  final SyncLocationKind? locationKind;

  /// The local folder chosen, if one was; it is the Sync Location when
  /// [locationKind] is [SyncLocationKind.localFolder].
  final String? folder;

  /// The WebDAV folder's address and the user name signed in with, if a
  /// WebDAV server was set up; it is the Sync Location when [locationKind]
  /// is [SyncLocationKind.webDav]. The password is in the keyring only.
  final String? webDavAddress;
  final String? webDavUser;

  /// The key of the owner's own Dropbox app, entered on this Device; null
  /// when Bloomee signs in to Dropbox through the app the build was given.
  final String? dropboxAppKey;

  /// This Device's name: the one chosen, or the machine's name until then.
  final String deviceName;

  const SyncSetup(
      {this.enabled = false,
      this.everEnabled = false,
      this.locationKind,
      this.folder,
      this.webDavAddress,
      this.webDavUser,
      this.dropboxAppKey,
      this.deviceName = ''});

  /// The Sync Location this setup syncs with, if one was chosen.
  SyncLocationChoice? get choice => switch (locationKind) {
        SyncLocationKind.dropbox => const SyncLocationChoice.dropbox(),
        SyncLocationKind.webDav => const SyncLocationChoice.webDav(),
        SyncLocationKind.localFolder when folder != null =>
          SyncLocationChoice.folder(folder!),
        _ => null,
      };

  @override
  List<Object?> get props => [
        enabled,
        everEnabled,
        locationKind,
        folder,
        webDavAddress,
        webDavUser,
        dropboxAppKey,
        deviceName
      ];
}

/// Why a chosen Sync Location cannot be used.
enum SyncLocationProblem {
  /// It cannot be found or reached.
  notFound,

  /// It can be reached, but Bloomee cannot write into it.
  notWritable,

  /// It refused the sign-in: the code pasted was not the one shown, the
  /// sign-in expired or was revoked, or the user name and password are
  /// wrong. Signing in again helps.
  signInRefused,

  /// The sign-in could not be kept in the system keyring.
  keyringUnavailable,

  /// Dropbox does not know the app Bloomee signs in through (`invalid_client`):
  /// the app key is wrong.
  appKeyRefused,

  /// The address given is not a server address.
  invalidAddress,

  /// The address given would send the password unprotected: plain `http`
  /// to another machine than this one.
  insecureAddress,

  /// It was reached but refused what Bloomee asked for another reason than
  /// the sign-in: a secure connection it would not make (an untrusted
  /// certificate, say), a request Dropbox does not accept from this app, a
  /// full storage.
  refused,
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

  /// What went wrong, as the error told it; empty when the error is all
  /// there is to say.
  final String detail;
  const SyncError(this.at, this.detail);
}

/// The Sync Location could not be reached; sync retries by itself.
final class SyncLocationUnreachable extends SyncError {
  const SyncLocationUnreachable(super.at, super.detail);
}

/// The Sync Location no longer accepts this Device's sign-in: sync is stopped
/// until the owner signs in again.
final class SyncSignInNeeded extends SyncError {
  /// The kind of Sync Location that refused the sign-in.
  final SyncLocationKind? kind;
  const SyncSignInNeeded(super.at, super.detail, [this.kind]);
}

/// The system keyring, which holds this Device's sign-in, cannot be read
/// (it is locked, say): sync does not start until it can.
final class SyncKeyringUnavailable extends SyncError {
  const SyncKeyringUnavailable(super.at, super.detail);
}

/// Dropbox does not know the app this Device signs in through (a wrong app
/// key, or an app its owner deleted), or this build has no Dropbox app and
/// none was entered: only the owner correcting the app key helps. The
/// sign-in is kept, and sync tries again by itself.
final class SyncAppKeyRefused extends SyncError {
  const SyncAppKeyRefused(super.at, super.detail);
}

/// The sync failed for another reason; sync retries by itself.
final class SyncFailed extends SyncError {
  const SyncFailed(super.at, super.detail);
}

/// The sync ran but needs the owner: the Removal Guard holds it, an update is
/// needed, or another Device's Device State was left out.
final class SyncNeedsOwner extends SyncError {
  final SyncOutcome outcome;
  const SyncNeedsOwner(DateTime at, this.outcome) : super(at, '');
}
