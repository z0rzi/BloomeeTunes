import 'dart:async';
import 'dart:convert';
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
import 'package:Bloomee/services/sync/local_folder_sync_location.dart';
import 'package:Bloomee/services/sync/sync_location.dart';
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
class SyncRepository {
  /// The file written and removed to test a Sync Location, in the area
  /// that holds Device States (which only reads `.json` files).
  static const probeFile = '${SyncEngine.stateDirectory}/.bloomee-write-test';

  final Future<Isar> _database;
  final BackupRepository _backups;
  final SettingsDAO _settings;
  final SyncDAO _dao;
  final SyncClock _clock;
  final String Function() _machineName;
  final SyncSchedulerFactory _schedulerFor;

  /// The kinds of Sync Location this Device offers.
  final List<SyncLocationKind> locationKinds;

  final SerialExecutor _setupChanges = SerialExecutor();
  final StreamController<SyncStatus> _statusChanges =
      StreamController.broadcast();
  final StreamController<SyncOutcome> _outcomes = StreamController.broadcast();

  SyncEngine? _engine;
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
  })  : _database = database,
        _backups = backups,
        _settings = SettingsDAO(database),
        _dao = SyncDAO(database),
        _clock = clock ?? DateTime.now,
        _machineName = machineName ?? (() => Platform.localHostname),
        _schedulerFor = scheduler ?? ((run) => SyncScheduler(run: run)),
        locationKinds = locationKinds ??
            SyncLocationKind.offeredOn(Platform.operatingSystem);

  SyncStatus get status => _status;
  Stream<SyncStatus> get statusChanges => _statusChanges.stream;

  /// What each sync did, as it finishes.
  Stream<SyncOutcome> get outcomes => _outcomes.stream;

  /// How sync is set up on this Device now.
  Future<SyncSetup> setup() async {
    final identity = await _dao.identity();
    final machine = _machineName().trim();
    return SyncSetup(
      enabled: await _settings.getSettingBool(SettingKeys.librarySyncEnabled) ??
          false,
      folder: await _settings.getSettingStr(SettingKeys.librarySyncFolder),
      deviceName: identity?.deviceName ??
          await _settings.getSettingStr(SettingKeys.librarySyncDeviceName) ??
          (machine.isEmpty ? 'Bloomee' : machine),
    );
  }

  /// Starts syncing as the app starts, if the owner enabled it; completes
  /// once the startup sync has run.
  Future<void> start() async {
    final scheduler = await _setupChanges.run(() async {
      try {
        final setup = await this.setup();
        final identity = await _dao.identity();
        _publish(SyncStatus(lastSyncedAt: identity?.lastSyncAt));
        // Sync was turned off by a build that kept that in the settings only.
        if (!setup.enabled && (identity?.enabled ?? false)) {
          await _dao.disable();
        }
        if (_closed || !setup.enabled || setup.folder == null) return null;
        final engine = _engineFor(setup.folder!);
        // Sync is on but this Device's bookkeeping is gone, as after running
        // the official build: enabling again makes it a new Device, whose
        // First Sync only adds.
        // Sync was also turned back on if it was left off in the database
        // only, as when the app stopped while turning it off.
        if (identity == null || !identity.enabled) {
          await engine.enable(deviceName: setup.deviceName);
        }
        return _begin(engine);
      } catch (error) {
        _publish(_status.copyWith(lastError: SyncFailed(_clock(), '$error')));
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
      {required String folder, required String deviceName}) async {
    final scheduler = await _setupChanges.run(() async {
      final problem = await testFolder(folder);
      if (problem != null) return problem;
      final engine = _engineFor(folder);
      final name = deviceName.trim();
      await engine.enable(deviceName: name);
      await _end();
      await _settings.putSettingStr(SettingKeys.librarySyncFolder, folder);
      await _settings.putSettingStr(SettingKeys.librarySyncDeviceName, name);
      await _settings.putSettingBool(SettingKeys.librarySyncEnabled, true);
      return _closed ? null : _begin(engine);
    });
    if (scheduler is SyncLocationProblem) return scheduler;
    if (scheduler is SyncScheduler) unawaited(scheduler.start());
    return null;
  }

  /// Moves sync to [folder], once it passes [testFolder]: this Device's
  /// Device State is published there with the sync that starts at once, and
  /// nothing in the old Sync Location is touched. Otherwise says why
  /// [folder] cannot be used, and sync goes on where it was.
  Future<SyncLocationProblem?> moveTo(String folder) async =>
      enable(folder: folder, deviceName: (await setup()).deviceName);

  /// Stops syncing. The library and the Device State published stay as they
  /// are, and this Device keeps its identity and bookkeeping, so that turning
  /// sync back on resumes where it left off.
  Future<void> disable() => _setupChanges.run(() async {
        final engine = _engine;
        await _end();
        // Through the engine, so that answering the Removal Guard, if it is
        // under way, finishes first.
        await (engine?.disable() ?? _dao.disable());
        await _settings.putSettingBool(SettingKeys.librarySyncEnabled, false);
      });

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
      await _record(() => engine.answerRemovalGuard(hold, confirm: confirm));
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

  SyncEngine _engineFor(String folder) => SyncEngine(
      database: _database,
      location: LocalFolderSyncLocation(folder),
      backups: _backups,
      clock: _clock);

  SyncScheduler _begin(SyncEngine engine) {
    _engine = engine;
    final scheduler = _schedulerFor(() => _record(engine.syncNow));
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
    await _libraryChanges?.cancel();
    _libraryChanges = null;
    await scheduler?.stop();
  }

  /// Runs [sync], reporting what it did; a failure is reported, then
  /// rethrown for the scheduler to retry.
  Future<void> _record(Future<SyncOutcome> Function() sync) async {
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
          lastError: error is SyncLocationUnavailable
              ? SyncLocationUnreachable(_clock(), error.message)
              : SyncFailed(_clock(), '$error')));
      rethrow;
    }
  }

  void _publish(SyncStatus status) {
    _status = status;
    if (!_statusChanges.isClosed) _statusChanges.add(status);
  }

  static Future<SyncLocationProblem?> _test(SyncLocation location) async {
    try {
      await location.checkReachable();
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
