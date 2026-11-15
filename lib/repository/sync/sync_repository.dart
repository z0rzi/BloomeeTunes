import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/core/models/sync/known_device.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/core/models/sync/sync_setup.dart';
import 'package:Bloomee/repository/backup/backup_repository.dart';
import 'package:Bloomee/repository/sync/sync_engine.dart';
import 'package:Bloomee/repository/sync/sync_scheduler.dart';
import 'package:Bloomee/services/backup/serial_executor.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/dao/sync_dao.dart';
import 'package:Bloomee/services/sync/credential_store.dart';
import 'package:Bloomee/services/sync/dropbox_sync_location.dart';
import 'package:Bloomee/services/sync/local_folder_sync_location.dart';
import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:Bloomee/services/sync/webdav_sync_location.dart';
import 'package:isar_community/isar.dart';

/// Makes the scheduler that runs [run]; tests shorten its delays.
typedef SyncSchedulerFactory = SyncScheduler Function(
    Future<void> Function() run);

/// The Sync Location sync is set up to use: its kind and, for a local
/// folder, which one.
class _ChosenLocation {
  final SyncLocationKind kind;
  final String? folder;

  const _ChosenLocation.folder(String this.folder)
      : kind = SyncLocationKind.localFolder;
  const _ChosenLocation.dropbox()
      : kind = SyncLocationKind.dropbox,
        folder = null;
  const _ChosenLocation.webDav()
      : kind = SyncLocationKind.webDav,
        folder = null;
}

/// Library Sync as the app uses it: its setup on this Device, the sync
/// engine and Sync Location it implies, and when syncs run.
///
/// Sync is off until the owner enables it with a Sync Location, which is
/// tested first; nothing is written to a Sync Location before that. Once on,
/// syncs run by themselves while the app is open (see [SyncScheduler]), and
/// what each did is reported through [status] and [outcomes].
///
/// Dropbox and WebDAV are signed in to once per Device; the Dropbox sign-in
/// and the WebDAV password are kept in the system keyring
/// ([CredentialStore]), never in the database or anything published. When
/// the Sync Location stops accepting them, sync stops until the owner signs
/// in again ([SyncSignInNeeded]).
class SyncRepository {
  /// The file written and removed to test a Sync Location, in the area
  /// that holds Device States (which only reads `.json` files).
  static const probeFile = '${SyncEngine.stateDirectory}/.bloomee-write-test';

  /// The keyring entry holding the Dropbox sign-in's refresh token.
  static const dropboxCredential = 'library_sync.dropbox.refresh_token';

  /// The keyring entry holding the WebDAV password.
  static const webDavCredential = 'library_sync.webdav.password';

  final Future<Isar> _database;
  final BackupRepository _backups;
  final SettingsDAO _settings;
  final SyncDAO _dao;
  final SyncClock _clock;
  final String Function() _machineName;
  final SyncSchedulerFactory _schedulerFor;
  final CredentialStore _credentials;
  final DropboxApp? _dropbox;

  /// The kinds of Sync Location this Device offers.
  final List<SyncLocationKind> locationKinds;

  final SerialExecutor _setupChanges = SerialExecutor();
  final StreamController<SyncStatus> _statusChanges =
      StreamController.broadcast();
  final StreamController<SyncOutcome> _outcomes = StreamController.broadcast();

  SyncEngine? _engine;

  /// The kind of Sync Location [_engine] syncs with.
  SyncLocationKind? _engineKind;

  /// The Dropbox sign-in under way, waiting for the owner's code.
  DropboxSignIn? _pendingSignIn;
  SyncScheduler? _scheduler;
  StreamSubscription<void>? _libraryChanges;
  bool _inBackground = false;
  bool _closed = false;
  int _running = 0;
  SyncStatus _status = const SyncStatus();

  SyncRepository({
    required Future<Isar> database,
    required BackupRepository backups,
    SyncClock? clock,
    String Function()? machineName,
    SyncSchedulerFactory? scheduler,
    List<SyncLocationKind>? locationKinds,
    CredentialStore? credentials,
    DropboxApp? dropbox,
  })  : _database = database,
        _backups = backups,
        _settings = SettingsDAO(database),
        _dao = SyncDAO(database),
        _clock = clock ?? DateTime.now,
        _machineName = machineName ?? (() => Platform.localHostname),
        _schedulerFor = scheduler ?? ((run) => SyncScheduler(run: run)),
        _credentials = credentials ?? const KeyringCredentialStore(),
        _dropbox = dropbox ?? DropboxApp.fromBuild(),
        locationKinds = locationKinds ??
            SyncLocationKind.offeredOn(Platform.operatingSystem,
                dropbox: (dropbox ?? DropboxApp.fromBuild()) != null);

  SyncStatus get status => _status;
  Stream<SyncStatus> get statusChanges => _statusChanges.stream;

  /// What each sync did, as it finishes.
  Stream<SyncOutcome> get outcomes => _outcomes.stream;

  /// How sync is set up on this Device now.
  Future<SyncSetup> setup() async {
    final identity = await _dao.identity();
    final machine = _machineName().trim();
    final folder = await _settings.getSettingStr(SettingKeys.librarySyncFolder);
    final kind = SyncLocationKind.values.asNameMap()[
        await _settings.getSettingStr(SettingKeys.librarySyncLocationKind)];
    return SyncSetup(
      enabled: await _settings.getSettingBool(SettingKeys.librarySyncEnabled) ??
          false,
      locationKind:
          kind ?? (folder != null ? SyncLocationKind.localFolder : null),
      folder: folder,
      webDavAddress:
          await _settings.getSettingStr(SettingKeys.librarySyncWebDavAddress),
      webDavUser:
          await _settings.getSettingStr(SettingKeys.librarySyncWebDavUser),
      deviceName: identity?.deviceName ??
          await _settings.getSettingStr(SettingKeys.librarySyncDeviceName) ??
          (machine.isEmpty ? 'Bloomee' : machine),
    );
  }

  /// Starts syncing as the app starts, if the owner enabled it; completes
  /// once the startup sync has run.
  Future<void> start() async {
    final scheduler = await _setupChanges.run(() async {
      _ChosenLocation? chosen;
      try {
        final setup = await this.setup();
        final identity = await _dao.identity();
        _publish(SyncStatus(lastSyncedAt: identity?.lastSyncAt));
        // Sync was turned off by a build that kept that in the settings only.
        if (!setup.enabled && (identity?.enabled ?? false)) {
          await _dao.disable();
        }
        chosen = _chosenLocationOf(setup);
        if (_closed || !setup.enabled || chosen == null) return null;
        final engine = _engineWith(await _locationAt(chosen));
        // Sync is on but this Device's bookkeeping is gone, as after running
        // the official build: enabling again makes it a new Device, whose
        // First Sync only adds.
        // Sync was also turned back on if it was left off in the database
        // only, as when the app stopped while turning it off.
        if (identity == null || !identity.enabled) {
          await engine.enable(deviceName: setup.deviceName);
        }
        return _begin(engine, chosen.kind);
      } catch (error) {
        _publish(_status.copyWith(lastError: _errorFor(error, chosen?.kind)));
        return null;
      }
    });
    await scheduler?.start();
  }

  /// Tests [folder] as a Sync Location: that it is there and that Bloomee
  /// can write into it. Leaves nothing behind.
  Future<SyncLocationProblem?> testFolder(String folder) =>
      _test(LocalFolderSyncLocation(folder));

  /// Turns sync on with [folder] as the Sync Location and [deviceName] as
  /// this Device's name, once the folder passes [testFolder]; otherwise
  /// says why it cannot be used and changes nothing. The first sync starts
  /// at once.
  Future<SyncLocationProblem?> enable(
          {required String folder, required String deviceName}) =>
      _enableAt(_ChosenLocation.folder(folder), deviceName);

  /// Turns sync on with Dropbox as the Sync Location, as [enable] does with
  /// a folder. This Device must be signed in ([finishDropboxSignIn]).
  Future<SyncLocationProblem?> enableDropbox({required String deviceName}) =>
      _enableAt(const _ChosenLocation.dropbox(), deviceName);

  /// Moves sync to [folder], once it passes [testFolder]: this Device's
  /// Device State is published there with the sync that starts at once, and
  /// nothing in the old Sync Location is touched. Otherwise says why
  /// [folder] cannot be used, and sync goes on where it was.
  Future<SyncLocationProblem?> moveTo(String folder) async =>
      enable(folder: folder, deviceName: (await setup()).deviceName);

  /// Moves sync to Dropbox, as [moveTo] does to a folder.
  Future<SyncLocationProblem?> moveToDropbox() async =>
      enableDropbox(deviceName: (await setup()).deviceName);

  /// Turns sync on with the WebDAV server as the Sync Location, as [enable]
  /// does with a folder. This Device must be signed in ([signInToWebDav]).
  Future<SyncLocationProblem?> enableWebDav({required String deviceName}) =>
      _enableAt(const _ChosenLocation.webDav(), deviceName);

  /// Moves sync to the WebDAV server, as [moveTo] does to a folder.
  Future<SyncLocationProblem?> moveToWebDav() async =>
      enableWebDav(deviceName: (await setup()).deviceName);

  Future<SyncLocationProblem?> _enableAt(
      _ChosenLocation chosen, String deviceName) async {
    final scheduler = await _setupChanges.run(() async {
      final SyncLocation location;
      try {
        location = await _locationAt(chosen);
      } on SyncLocationSignInRefused {
        return SyncLocationProblem.signInRefused;
      } on CredentialStoreUnavailable {
        return SyncLocationProblem.keyringUnavailable;
      }
      final problem = await _test(location);
      if (problem != null) return problem;
      final engine = _engineWith(location);
      final name = deviceName.trim();
      await engine.enable(deviceName: name);
      await _end();
      await _settings.putSettingStr(
          SettingKeys.librarySyncLocationKind, chosen.kind.name);
      if (chosen.folder case final folder?) {
        await _settings.putSettingStr(SettingKeys.librarySyncFolder, folder);
      }
      await _settings.putSettingStr(SettingKeys.librarySyncDeviceName, name);
      await _settings.putSettingBool(SettingKeys.librarySyncEnabled, true);
      return _closed ? null : _begin(engine, chosen.kind);
    });
    if (scheduler is SyncLocationProblem) return scheduler;
    if (scheduler is SyncScheduler) unawaited(scheduler.start());
    return null;
  }

  /// Whether this Device is signed in to Dropbox: its sign-in is in the
  /// keyring. False when the keyring cannot be read.
  Future<bool> dropboxSignedIn() async {
    try {
      return await _credentials.read(dropboxCredential) != null;
    } on CredentialStoreUnavailable catch (error) {
      log('$error', name: 'SyncRepository');
      return false;
    }
  }

  /// Starts signing in to Dropbox, returning the Dropbox page the owner
  /// opens to allow Bloomee; they paste back the code it shows, for
  /// [finishDropboxSignIn]. Only for a build that offers Dropbox.
  Uri beginDropboxSignIn() => (_pendingSignIn = _dropboxApp.beginSignIn()).page;

  /// Finishes the sign-in [beginDropboxSignIn] started with the [code] the
  /// owner pasted, keeping it in the keyring; otherwise says why it failed.
  /// Sync stopped for want of a sign-in resumes at once.
  Future<SyncLocationProblem?> finishDropboxSignIn(String code) async {
    final signIn = _pendingSignIn;
    if (signIn == null) return SyncLocationProblem.signInRefused;
    final String refreshToken;
    try {
      refreshToken = await signIn.finish(code);
    } on SyncLocationUnavailable {
      return SyncLocationProblem.notFound;
    } on SyncLocationException {
      return SyncLocationProblem.signInRefused;
    }
    if (identical(_pendingSignIn, signIn)) _pendingSignIn = null;
    final resumed = await _setupChanges.run(() async {
      try {
        await _credentials.write(dropboxCredential, refreshToken);
      } on CredentialStoreUnavailable {
        return SyncLocationProblem.keyringUnavailable;
      }
      return _resumeSignedIn(SyncLocationKind.dropbox);
    });
    if (resumed is SyncLocationProblem) return resumed;
    if (resumed is SyncScheduler) unawaited(resumed.start());
    return null;
  }

  /// Whether this Device is signed in to a WebDAV server: its address and
  /// user name are set up and its password is in the keyring. False when
  /// the keyring cannot be read.
  Future<bool> webDavSignedIn() async {
    if (await _settings.getSettingStr(SettingKeys.librarySyncWebDavAddress) ==
        null) {
      return false;
    }
    try {
      return await _credentials.read(webDavCredential) != null;
    } on CredentialStoreUnavailable catch (error) {
      log('$error', name: 'SyncRepository');
      return false;
    }
  }

  /// Signs this Device in to the WebDAV folder at [address] as [user] with
  /// [password], once the folder passes its test (it is created when
  /// missing): the password is kept in the keyring, the address and user
  /// name in this Device's settings. Otherwise says why it cannot be used,
  /// and keeps nothing; an address that would send the password unprotected
  /// is refused before anything is sent. Sync through WebDAV, if on, goes on
  /// at once with this server and password.
  Future<SyncLocationProblem?> signInToWebDav(
      {required String address,
      required String user,
      required String password}) async {
    final url = WebDavSyncLocation.parseAddress(address);
    if (url == null) return SyncLocationProblem.invalidAddress;
    if (!WebDavSyncLocation.isProtected(url)) {
      return SyncLocationProblem.insecureAddress;
    }
    final name = user.trim();
    final location =
        WebDavSyncLocation(address: url, user: name, password: password);
    final problem = await _test(location);
    if (problem != null) return problem;
    final resumed = await _setupChanges.run(() async {
      try {
        await _credentials.write(webDavCredential, password);
      } on CredentialStoreUnavailable {
        return SyncLocationProblem.keyringUnavailable;
      }
      await _settings.putSettingStr(
          SettingKeys.librarySyncWebDavAddress, location.address.toString());
      await _settings.putSettingStr(SettingKeys.librarySyncWebDavUser, name);
      return _resumeSignedIn(SyncLocationKind.webDav);
    });
    if (resumed is SyncLocationProblem) return resumed;
    if (resumed is SyncScheduler) unawaited(resumed.start());
    return null;
  }

  /// After signing in to [kind]: when sync is on through it, sync goes on
  /// with the new sign-in, returning its scheduler to start.
  Future<SyncScheduler?> _resumeSignedIn(SyncLocationKind kind) async {
    final setup = await this.setup();
    final chosen = _chosenLocationOf(setup);
    if (_closed || !setup.enabled || setup.locationKind != kind) return null;
    try {
      await _end();
      final engine = _engineWith(await _locationAt(chosen!));
      if ((await _dao.identity())?.enabled != true) {
        await engine.enable(deviceName: setup.deviceName);
      }
      return _begin(engine, kind);
    } catch (error) {
      // Signed in all the same; the status tells why sync did not resume.
      _publish(_status.copyWith(lastError: _errorFor(error, kind)));
      return null;
    }
  }

  /// Signs this Device out of Dropbox: the sign-in is ended on Dropbox when
  /// it can be reached, and removed from the keyring in any case. Sync
  /// through Dropbox is turned off, as [disable] does. Throws
  /// [CredentialStoreUnavailable] when the keyring cannot be changed.
  Future<void> signOutOfDropbox() => _setupChanges.run(() async {
        final setup = await this.setup();
        if (setup.enabled && setup.locationKind == SyncLocationKind.dropbox) {
          await _stopSyncing();
        }
        try {
          final refreshToken = await _credentials.read(dropboxCredential);
          if (refreshToken != null && _dropbox != null) {
            await DropboxSyncLocation(
                    app: _dropbox, refreshToken: refreshToken, clock: _clock)
                .signOut();
          }
        } catch (error) {
          // Removing it from this Device is what matters; Dropbox lists
          // the sign-in until the owner removes it there.
          log('Dropbox sign-in not ended on Dropbox: $error',
              name: 'SyncRepository');
        }
        await _credentials.delete(dropboxCredential);
      });

  /// Stops syncing. The library and the Device State published stay as they
  /// are, and this Device keeps its identity and bookkeeping, so that turning
  /// sync back on resumes where it left off.
  Future<void> disable() => _setupChanges.run(_stopSyncing);

  Future<void> _stopSyncing() async {
    final engine = _engine;
    await _end();
    // Through the engine, so that answering the Removal Guard, if it is
    // under way, finishes first.
    await (engine?.disable() ?? _dao.disable());
    await _settings.putSettingBool(SettingKeys.librarySyncEnabled, false);
  }

  /// The Devices known in the Sync Location, this one included; none while
  /// sync is off. See [SyncEngine.knownDevices].
  Future<List<KnownDevice>> knownDevices() async =>
      await _engine?.knownDevices() ?? const [];

  /// Forgets the Device [deviceId], which the owner confirmed: see
  /// [SyncEngine.forgetDevice]. Does nothing while sync is off. Throws
  /// [SyncLocationException] when the Sync Location cannot be changed.
  Future<void> forgetDevice(String deviceId) => _setupChanges.run(() async {
        await _engine?.forgetDevice(deviceId);
      });

  /// Renames this Device; it stays the same Device, publishing under its
  /// new name with the next sync.
  Future<void> renameDevice(String name) => _setupChanges.run(() async {
        final trimmed = name.trim();
        if (trimmed.isEmpty) return;
        await _settings.putSettingStr(
            SettingKeys.librarySyncDeviceName, trimmed);
        await _dao.rename(trimmed);
        _scheduler?.libraryChanged();
      });

  /// Syncs now, if sync is on; completes when that sync has run.
  Future<void> syncNow() async => _scheduler?.syncNow();

  /// Answers the merge the Removal Guard held, as [hold] showed it: see
  /// [SyncEngine.answerRemovalGuard].
  Future<void> answerRemovalGuard(RemovalGuardHold hold,
      {required bool confirm}) async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await _record(engine, _engineKind,
          () => engine.answerRemovalGuard(hold, confirm: confirm));
    } catch (_) {
      // Reported in the status; the next scheduled sync tries again.
    }
  }

  /// The app left the foreground.
  void moveToBackground() {
    _inBackground = true;
    _scheduler?.moveToBackground();
  }

  /// The app came back to the foreground.
  void returnToForeground() {
    _inBackground = false;
    _scheduler?.returnToForeground();
  }

  /// Stops everything, as the app closes; a sync already running finishes.
  Future<void> close() async {
    _closed = true;
    await _setupChanges.run(_end);
    await _statusChanges.close();
    await _outcomes.close();
  }

  static _ChosenLocation? _chosenLocationOf(SyncSetup setup) =>
      switch (setup.locationKind) {
        SyncLocationKind.dropbox => const _ChosenLocation.dropbox(),
        SyncLocationKind.webDav => const _ChosenLocation.webDav(),
        SyncLocationKind.localFolder when setup.folder != null =>
          _ChosenLocation.folder(setup.folder!),
        _ => null,
      };

  /// The Sync Location at [chosen]. Throws [SyncLocationSignInRefused] for
  /// Dropbox or WebDAV when this Device is not signed in.
  Future<SyncLocation> _locationAt(_ChosenLocation chosen) async {
    switch (chosen.kind) {
      case SyncLocationKind.localFolder:
        return LocalFolderSyncLocation(chosen.folder!);
      case SyncLocationKind.dropbox:
        final app = _dropboxApp;
        final refreshToken = await _credentials.read(dropboxCredential) ??
            (throw const SyncLocationSignInRefused(
                'This Device is not signed in to Dropbox.'));
        return DropboxSyncLocation(
            app: app, refreshToken: refreshToken, clock: _clock);
      case SyncLocationKind.webDav:
        final address = WebDavSyncLocation.parseAddress(await _settings
                .getSettingStr(SettingKeys.librarySyncWebDavAddress) ??
            '');
        final user =
            await _settings.getSettingStr(SettingKeys.librarySyncWebDavUser);
        final password = await _credentials.read(webDavCredential);
        if (address == null ||
            !WebDavSyncLocation.isProtected(address) ||
            user == null ||
            password == null) {
          throw const SyncLocationSignInRefused(
              'This Device is not signed in to a WebDAV server.');
        }
        return WebDavSyncLocation(
            address: address, user: user, password: password);
    }
  }

  DropboxApp get _dropboxApp =>
      _dropbox ?? (throw StateError('This build has no Dropbox app key.'));

  SyncEngine _engineWith(SyncLocation location) => SyncEngine(
      database: _database,
      location: location,
      backups: _backups,
      clock: _clock);

  SyncScheduler _begin(SyncEngine engine, SyncLocationKind kind) {
    _engine = engine;
    _engineKind = kind;
    final scheduler =
        _schedulerFor(() => _record(engine, kind, engine.syncNow));
    if (_inBackground) scheduler.moveToBackground();
    _scheduler = scheduler;
    _libraryChanges =
        _dao.watchSyncedLibrary().listen((_) => scheduler.libraryChanged());
    return scheduler;
  }

  Future<void> _end() async {
    final scheduler = _scheduler;
    _scheduler = null;
    _engine = null;
    _engineKind = null;
    await _libraryChanges?.cancel();
    _libraryChanges = null;
    await scheduler?.stop();
  }

  /// Runs [sync] with [engine], syncing with a Sync Location of [kind],
  /// reporting what it did; a failure is
  /// reported, then rethrown for the scheduler to retry. A refused sign-in
  /// stops sync instead until the owner signs in again (see
  /// [_signInRefused]).
  Future<void> _record(SyncEngine engine, SyncLocationKind? kind,
      Future<SyncOutcome> Function() sync) async {
    _running++;
    _publish(_status.copyWith(running: true));
    try {
      final outcome = await sync();
      final needsOwner =
          outcome is! SyncCompleted || outcome.skipped.isNotEmpty;
      _running--;
      _publish(SyncStatus(
          running: _running > 0,
          lastSyncedAt: (await _dao.identity())?.lastSyncAt,
          lastError: needsOwner
              ? SyncNeedsOwner(_clock(), outcome)
              : _status.lastError));
      if (!_outcomes.isClosed) _outcomes.add(outcome);
    } catch (error) {
      _running--;
      _publish(SyncStatus(
          running: _running > 0,
          lastSyncedAt: _status.lastSyncedAt,
          lastError: _errorFor(error, kind)));
      if (error is SyncLocationSignInRefused) unawaited(_signInRefused(engine));
      rethrow;
    }
  }

  /// [engine]'s Sync Location refused this Device's sign-in: its syncs stop,
  /// unless the owner meanwhile set sync up anew. A refused Dropbox sign-in
  /// is forgotten, as it can never work again; a WebDAV password is kept,
  /// for the server may accept it again (an account unlocked, say), until
  /// the owner enters another.
  Future<void> _signInRefused(SyncEngine engine) => _setupChanges.run(() async {
        if (!identical(_engine, engine)) return;
        await _end();
        if ((await setup()).locationKind != SyncLocationKind.dropbox) return;
        try {
          await _credentials.delete(dropboxCredential);
        } on CredentialStoreUnavailable catch (error) {
          log('$error', name: 'SyncRepository');
        }
      });

  /// What [error], met syncing with a Sync Location of [kind], means for
  /// the status.
  SyncError _errorFor(Object error, SyncLocationKind? kind) => switch (error) {
        SyncLocationSignInRefused(:final message) =>
          SyncSignInNeeded(_clock(), message, kind),
        SyncLocationUnavailable(:final message) =>
          SyncLocationUnreachable(_clock(), message),
        _ => SyncFailed(_clock(), '$error'),
      };

  void _publish(SyncStatus status) {
    _status = status;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  static Future<SyncLocationProblem?> _test(SyncLocation location) async {
    try {
      await location.checkReachable();
    } on SyncLocationSignInRefused {
      return SyncLocationProblem.signInRefused;
    } on SyncLocationException {
      return SyncLocationProblem.notFound;
    }
    const content = 'Bloomee checks it can write here.';
    try {
      await location.write(probeFile, utf8.encode(content));
      final read = await location.read(probeFile);
      if (read == null || utf8.decode(read, allowMalformed: true) != content) {
        return SyncLocationProblem.notWritable;
      }
      return null;
    } on SyncLocationSignInRefused {
      return SyncLocationProblem.signInRefused;
    } on SyncLocationException {
      return SyncLocationProblem.notWritable;
    } finally {
      try {
        await location.delete(probeFile);
      } on SyncLocationException {
        // Nothing was written, or it cannot be removed; sync ignores it.
      }
    }
  }
}
