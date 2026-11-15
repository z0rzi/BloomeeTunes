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
import 'package:Bloomee/services/sync/machine_name.dart';
import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:Bloomee/services/sync/webdav_sync_location.dart';
import 'package:isar_community/isar.dart';

/// Makes the scheduler that runs [run]; tests shorten its delays.
typedef SyncSchedulerFactory = SyncScheduler Function(
    Future<void> Function() run);

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
/// in again ([SyncSignInNeeded]). Dropbox is signed in to through the
/// owner's own Dropbox app when they entered its key on this Device
/// ([setDropboxAppKey]), or else through the app the build was given.
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
  final DateTime Function() _clock;
  final FutureOr<String> Function() _machineName;
  final SyncSchedulerFactory _schedulerFor;
  final CredentialStore _credentials;

  /// The Dropbox app the build was given, if any.
  final DropboxApp? _builtInDropbox;

  /// Makes the Dropbox app of a key the owner entered.
  final DropboxApp Function(String key) _dropboxWithKey;

  /// The owner's own Dropbox app, as last made.
  DropboxApp? _ownDropbox;

  /// Counts the changes of the Dropbox app this Device signs in through, so
  /// that a sign-in begun through another app is not kept.
  int _dropboxAppChanges = 0;

  /// The kinds of Sync Location this Device offers.
  final List<SyncLocationKind> locationKinds;

  final SerialExecutor _setupChanges = SerialExecutor();
  final StreamController<SyncStatus> _statusChanges =
      StreamController.broadcast();
  final StreamController<SyncOutcome> _outcomes = StreamController.broadcast();

  SyncEngine? _engine;

  /// The kind of Sync Location [_engine] syncs with.
  SyncLocationKind? _engineKind;

  /// The Dropbox sign-in under way, waiting for the owner's code, and the
  /// count of [_dropboxAppChanges] when it began.
  ({DropboxSignIn signIn, int appChanges})? _pendingSignIn;
  SyncScheduler? _scheduler;
  StreamSubscription<void>? _libraryChanges;
  bool _inBackground = false;
  bool _closed = false;
  int _running = 0;
  SyncStatus _status = const SyncStatus();

  SyncRepository({
    required Future<Isar> database,
    required BackupRepository backups,
    DateTime Function()? clock,
    FutureOr<String> Function()? machineName,
    SyncSchedulerFactory? scheduler,
    List<SyncLocationKind>? locationKinds,
    CredentialStore? credentials,
    DropboxApp? dropbox,
    DropboxApp Function(String key)? dropboxWithKey,
  })  : _database = database,
        _backups = backups,
        _settings = SettingsDAO(database),
        _dao = SyncDAO(database),
        _clock = clock ?? DateTime.now,
        _machineName = machineName ?? thisMachineName,
        _schedulerFor = scheduler ?? ((run) => SyncScheduler(run: run)),
        _credentials = credentials ?? const KeyringCredentialStore(),
        _builtInDropbox = dropbox ?? DropboxApp.fromBuild(),
        _dropboxWithKey = dropboxWithKey ?? ((key) => DropboxApp(key: key)),
        locationKinds = locationKinds ??
            SyncLocationKind.offeredOn(Platform.operatingSystem);

  /// Whether the build was given a Dropbox app key; without one, Dropbox
  /// needs the key of the owner's own app ([setDropboxAppKey]).
  bool get hasBuiltInDropboxApp => _builtInDropbox != null;

  SyncStatus get status => _status;
  Stream<SyncStatus> get statusChanges => _statusChanges.stream;

  /// What each sync did, as it finishes.
  Stream<SyncOutcome> get outcomes => _outcomes.stream;

  /// How sync is set up on this Device now.
  Future<SyncSetup> setup() async {
    final identity = await _dao.identity();
    final machine = (await _machineName()).trim();
    return SyncSetup(
      enabled: await _dao.enabled(),
      everEnabled: identity != null,
      locationKind: SyncLocationKind.values.asNameMap()[
          await _settings.getSettingStr(SettingKeys.librarySyncLocationKind)],
      folder: await _settings.getSettingStr(SettingKeys.librarySyncFolder),
      webDavAddress:
          await _settings.getSettingStr(SettingKeys.librarySyncWebDavAddress),
      webDavUser:
          await _settings.getSettingStr(SettingKeys.librarySyncWebDavUser),
      dropboxAppKey: await _ownDropboxKey(),
      deviceName: identity?.deviceName ??
          await _settings.getSettingStr(SettingKeys.librarySyncDeviceName) ??
          (machine.isEmpty || machine == 'localhost' ? 'Bloomee' : machine),
    );
  }

  /// Starts syncing as the app starts, if the owner enabled it; completes
  /// once the startup sync has run.
  Future<void> start() async {
    final scheduler = await _setupChanges.run(() async {
      SyncLocationChoice? chosen;
      try {
        final setup = await this.setup();
        final identity = await _dao.identity();
        _publish(SyncStatus(lastSyncedAt: identity?.lastSyncAt));
        chosen = setup.choice;
        if (_closed || !setup.enabled || chosen == null) return null;
        final engine = _engineWith(await _locationAt(chosen));
        // Sync is on but this Device's bookkeeping is gone, as after running
        // the official build: enabling again makes it a new Device, whose
        // First Sync only adds.
        if (identity == null) {
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

  /// Turns sync on with [choice] as the Sync Location and [deviceName] as
  /// this Device's name, once the Sync Location passes its test (a folder
  /// as [testFolder] tests it); otherwise says why it cannot be used and
  /// changes nothing. Dropbox and WebDAV need this Device signed in
  /// ([finishDropboxSignIn], [signInToWebDav]). The first sync starts at
  /// once.
  Future<SyncLocationProblem?> enable(SyncLocationChoice choice,
      {required String deviceName}) async {
    final scheduler = await _setupChanges.run(() async {
      final SyncLocation location;
      try {
        location = await _locationAt(choice);
      } on SyncLocationException catch (error) {
        return _problemOf(error) ?? SyncLocationProblem.notFound;
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
          SettingKeys.librarySyncLocationKind, choice.kind.name);
      if (choice.folder case final folder?) {
        await _settings.putSettingStr(SettingKeys.librarySyncFolder, folder);
      }
      await _settings.putSettingStr(SettingKeys.librarySyncDeviceName, name);
      return _closed ? null : _begin(engine, choice.kind);
    });
    if (scheduler is SyncLocationProblem) return scheduler;
    if (scheduler is SyncScheduler) unawaited(scheduler.start());
    return null;
  }

  /// Moves sync to [choice], once it passes its test as for [enable]: this
  /// Device's Device State is published there with the sync that starts at
  /// once, and nothing in the old Sync Location is touched. Otherwise says
  /// why [choice] cannot be used, and sync goes on where it was.
  Future<SyncLocationProblem?> moveTo(SyncLocationChoice choice) async =>
      enable(choice, deviceName: (await setup()).deviceName);

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

  /// Starts signing in to Dropbox through the Dropbox app this Device uses
  /// (see [setDropboxAppKey]), returning the Dropbox page the owner opens to
  /// allow Bloomee; they paste back the code it shows, for
  /// [finishDropboxSignIn]. Null when there is no app to sign in through: a
  /// build without a Dropbox app key, where the owner has entered none.
  Future<Uri?> beginDropboxSignIn() async {
    // Counted before the app is read, so that a key changed meanwhile is
    // seen at [finishDropboxSignIn].
    final appChanges = _dropboxAppChanges;
    final signIn = (await _dropboxApp())?.beginSignIn();
    _pendingSignIn =
        signIn == null ? null : (signIn: signIn, appChanges: appChanges);
    return signIn?.page;
  }

  /// Finishes the sign-in [beginDropboxSignIn] started with the [code] the
  /// owner pasted, keeping it in the keyring; otherwise says why it failed.
  /// Sync stopped for want of a sign-in resumes at once.
  Future<SyncLocationProblem?> finishDropboxSignIn(String code) async {
    final pending = _pendingSignIn;
    if (pending == null) return SyncLocationProblem.signInRefused;
    final (:signIn, :appChanges) = pending;
    final String refreshToken;
    try {
      refreshToken = await signIn.finish(code);
    } on SyncLocationException catch (error) {
      log('Dropbox sign-in not finished: $error', name: 'SyncRepository');
      return _problemOf(error) ?? SyncLocationProblem.notFound;
    }
    if (_pendingSignIn == pending) _pendingSignIn = null;
    final resumed = await _setupChanges.run(() async {
      // The app key changed since the sign-in began: it belongs to the old
      // app.
      if (appChanges != _dropboxAppChanges) {
        return SyncLocationProblem.signInRefused;
      }
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
    final chosen = setup.choice;
    if (_closed || !setup.enabled || chosen?.kind != kind) return null;
    try {
      await _end();
      final engine = _engineWith(await _locationAt(chosen!));
      if (!setup.everEnabled) {
        await engine.enable(deviceName: setup.deviceName);
      }
      return _begin(engine, kind);
    } catch (error) {
      // Signed in all the same; the status tells why sync did not resume.
      _publish(_status.copyWith(lastError: _errorFor(error, kind)));
      return null;
    }
  }

  /// Signs this Device out of [kind] (Dropbox, a WebDAV server): its
  /// sign-in is removed from the keyring, and a Dropbox sign-in is ended on
  /// Dropbox when it can be reached. Sync through [kind] is turned off, as
  /// [disable] does; sync through another Sync Location goes on. A WebDAV
  /// server's address and user name stay in the settings, to be offered
  /// when the owner signs in again. A local folder has nothing to sign out
  /// of. Throws [CredentialStoreUnavailable] when the keyring cannot be
  /// read or changed, and then changes nothing.
  Future<void> signOutOf(SyncLocationKind kind) => _setupChanges.run(() async {
        switch (kind) {
          case SyncLocationKind.dropbox:
            await _signOutOfDropbox(await _dropboxApp());
          case SyncLocationKind.webDav:
            await _credentials.delete(webDavCredential);
            await _stopSyncingThrough(kind);
          case SyncLocationKind.localFolder:
            return;
        }
      });

  /// Makes [key] the key of the Dropbox app this Device signs in through:
  /// the owner's own app, which they registered themselves; an empty key
  /// goes back to the app the build was given. The key is kept in this
  /// Device's settings, which never travel in a backup or a Device State.
  ///
  /// When that changes the app, this Device's Dropbox sign-in ends, as
  /// [signOutOf] ends it, for a sign-in belongs to one app: sync through
  /// Dropbox is turned off until the owner signs in again. Throws
  /// [CredentialStoreUnavailable] when the keyring cannot be read or
  /// changed, and then changes nothing.
  Future<void> setDropboxAppKey(String key) => _setupChanges.run(() async {
        final entered = key.trim();
        final previous = await _ownDropboxKey();
        if (entered == (previous ?? '')) return;
        final before = _dropboxAppFor(previous);
        final after = _dropboxAppFor(entered.isEmpty ? null : entered);
        if (before?.key != after?.key) {
          await _signOutOfDropbox(before);
          _dropboxAppChanges++;
          _pendingSignIn = null;
        }
        await _settings.putSettingStr(
            SettingKeys.librarySyncDropboxAppKey, entered);
      });

  /// The key of the owner's own Dropbox app entered on this Device, if any.
  Future<String?> _ownDropboxKey() async {
    final key =
        (await _settings.getSettingStr(SettingKeys.librarySyncDropboxAppKey))
            ?.trim();
    return key == null || key.isEmpty ? null : key;
  }

  /// The Dropbox app this Device signs in through: the owner's own, when
  /// they entered its key, or else the build's; null when there is neither.
  Future<DropboxApp?> _dropboxApp() async =>
      _dropboxAppFor(await _ownDropboxKey());

  /// The Dropbox app of the owner's own key [ownKey], or the build's when
  /// there is none.
  DropboxApp? _dropboxAppFor(String? ownKey) {
    if (ownKey == null) return _builtInDropbox;
    final own = _ownDropbox;
    if (own != null && own.key == ownKey) return own;
    return _ownDropbox = _dropboxWithKey(ownKey);
  }

  /// Ends this Device's Dropbox sign-in, made through [app]: it leaves the
  /// keyring first, so that a keyring refusing the change changes nothing;
  /// then sync through Dropbox is turned off, and the sign-in is ended on
  /// Dropbox when it can be reached.
  Future<void> _signOutOfDropbox(DropboxApp? app) async {
    final refreshToken = await _credentials.read(dropboxCredential);
    await _credentials.delete(dropboxCredential);
    await _stopSyncingThrough(SyncLocationKind.dropbox);
    if (app != null && refreshToken != null) {
      await _endDropboxSignIn(app, refreshToken);
    }
  }

  /// Turns sync off when it is on through a Sync Location of [kind].
  Future<void> _stopSyncingThrough(SyncLocationKind kind) async {
    final setup = await this.setup();
    if (setup.enabled && setup.locationKind == kind) await _stopSyncing();
  }

  /// Ends the Dropbox sign-in [refreshToken], made through [app], on
  /// Dropbox, when it can.
  Future<void> _endDropboxSignIn(DropboxApp app, String refreshToken) async {
    try {
      await DropboxSyncLocation(
              app: app, refreshToken: refreshToken, clock: _clock)
          .signOut();
    } catch (error) {
      // Removing it from this Device is what matters; Dropbox lists the
      // sign-in until the owner removes it there.
      log('Dropbox sign-in not ended on Dropbox: $error',
          name: 'SyncRepository');
    }
  }

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

  /// The Sync Location at [chosen]. Throws [SyncLocationSignInRefused] for
  /// Dropbox or WebDAV when this Device is not signed in.
  Future<SyncLocation> _locationAt(SyncLocationChoice chosen) async {
    switch (chosen.kind) {
      case SyncLocationKind.localFolder:
        return LocalFolderSyncLocation(chosen.folder!);
      case SyncLocationKind.dropbox:
        final app = await _dropboxApp() ??
            (throw const SyncLocationAppRefused(
                'This build has no Dropbox app key, and none was entered on '
                'this Device.'));
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
        CredentialStoreUnavailable(:final message) =>
          SyncKeyringUnavailable(_clock(), message),
        SyncLocationAppRefused(:final message) =>
          SyncAppKeyRefused(_clock(), message),
        _ => SyncFailed(_clock(), '$error'),
      };

  void _publish(SyncStatus status) {
    _status = status;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  /// What [error] means for setting up a Sync Location, when it says more
  /// than the step that met it: a refused sign-in, an app key Dropbox does
  /// not know, or another refusal. Null for a Sync Location that cannot be
  /// reached.
  static SyncLocationProblem? _problemOf(SyncLocationException error) =>
      switch (error) {
        SyncLocationSignInRefused() => SyncLocationProblem.signInRefused,
        SyncLocationAppRefused() => SyncLocationProblem.appKeyRefused,
        SyncLocationFailed() => SyncLocationProblem.refused,
        SyncLocationUnavailable() => null,
      };

  static Future<SyncLocationProblem?> _test(SyncLocation location) async {
    try {
      await location.checkReachable();
    } on SyncLocationException catch (error) {
      return _problemOf(error) ?? SyncLocationProblem.notFound;
    }
    const content = 'Bloomee checks it can write here.';
    try {
      await location.write(probeFile, utf8.encode(content));
      final read = await location.read(probeFile);
      if (read == null || utf8.decode(read, allowMalformed: true) != content) {
        return SyncLocationProblem.notWritable;
      }
      return null;
    } on SyncLocationException catch (error) {
      return _problemOf(error) ?? SyncLocationProblem.notWritable;
    } finally {
      try {
        await location.delete(probeFile);
      } on SyncLocationException {
        // Nothing was written, or it cannot be removed; sync ignores it.
      }
    }
  }
}
