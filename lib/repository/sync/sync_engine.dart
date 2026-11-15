import 'dart:convert';
import 'dart:developer';

import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/known_device.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/core/models/sync/synced_library_change.dart';
import 'package:Bloomee/repository/backup/backup_repository.dart';
import 'package:Bloomee/repository/sync/removal_guard.dart';
import 'package:Bloomee/repository/sync/synced_library_merge.dart';
import 'package:Bloomee/services/backup/serial_executor.dart';
import 'package:Bloomee/services/db/dao/sync_dao.dart';
import 'package:Bloomee/services/db/mappers/track_json_mapper.dart';
import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:flutter/foundation.dart';
import 'package:isar_community/isar.dart';

typedef SyncClock = DateTime Function();

/// Keeps this Device's Synced Library in step with the other Devices that
/// share its Sync Location (see `docs/adr/0001-one-device-state-per-device.md`).
///
/// It only ever writes this Device's own Device State, and knows nothing about
/// which kind of Sync Location it has. A sync never quietly damages the
/// library: a protection snapshot is taken before any merge that changes it,
/// the Removal Guard holds a merge that would remove much of it, and a
/// Device State that is damaged, dated in the future or in a newer format is
/// never merged.
class SyncEngine {
  /// Where Device States live in the Sync Location.
  static const stateDirectory = 'sync';

  /// Where Location Backups live in the Sync Location.
  static const backupDirectory = 'backups';

  /// How many Location Backups each Device keeps of its own.
  static const locationBackupsKept = 7;

  /// The reason protection snapshots taken before a sync are kept under.
  static const snapshotReason = 'before_sync';

  /// How far ahead of this Device's clock a change may be dated.
  static const clockTolerance = Duration(days: 1);

  /// How long a Removal Marker is kept: six months. A Device whose last
  /// sync is older performs a First Sync, as one that never synced does.
  static const removalMarkerLifetime = Duration(days: 183);

  /// How old this Device's published Device State may grow before a sync
  /// rewrites it unchanged, so that the other Devices see when it last
  /// synced without it being rewritten at every sync.
  static const stateRefreshInterval = Duration(hours: 1);

  final Future<Isar> _database;
  final SyncLocation _location;
  final BackupRepository _backups;
  final SyncClock _clock;
  final SyncDAO _dao;
  final void Function()? _beforeCommit;
  final SerialExecutor _runs = SerialExecutor();

  /// The other Devices whose Device State the latest sync read, by ID.
  Map<String, DeviceStateSummary>? _othersSeen;

  /// [beforeCommit] runs as a merge's write transaction is about to commit;
  /// tests throw from it to make applying fail.
  SyncEngine({
    required Future<Isar> database,
    required SyncLocation location,
    required BackupRepository backups,
    SyncClock? clock,
    @visibleForTesting void Function()? beforeCommit,
  })  : _database = database,
        _location = location,
        _backups = backups,
        _clock = clock ?? DateTime.now,
        _dao = SyncDAO(database),
        _beforeCommit = beforeCommit;

  /// Turns Library Sync on for this Device under [deviceName]. The Device's
  /// permanent ID is made the first time and kept afterwards.
  Future<SyncIdentity> enable({required String deviceName}) =>
      _dao.enable(deviceName: deviceName, newDeviceId: SyncDAO.newSyncId());

  /// Every Device known in the Sync Location: this one, and each one whose
  /// Device State is there, readable or not, as this Device's latest sync
  /// found them (read now if it has not synced since starting). Other
  /// Devices are listed with the time their Device State was last written.
  Future<List<KnownDevice>> knownDevices() => _runs.run(() async {
        final me = await _identity();
        final others = _othersSeen ??
            {
              for (final (deviceId, bytes) in await _readStates())
                if (deviceId != me.deviceId)
                  deviceId: DeviceState.summaryOf(bytes)
            };
        return [
          KnownDevice(
              deviceId: me.deviceId,
              deviceName: me.deviceName,
              lastSyncedAt: me.lastSyncAt,
              isThisDevice: true),
          for (final MapEntry(key: deviceId, value: summary) in others.entries)
            KnownDevice(
                deviceId: deviceId,
                deviceName: summary.deviceName ?? deviceId,
                lastSyncedAt: summary.writtenAt,
                isThisDevice: false),
        ];
      });

  /// Forgets the Device [deviceId], at the owner's explicit request: deletes
  /// its Device State from the Sync Location. Nothing leaves any library,
  /// since every Device keeps what it took in; should that Device sync
  /// again, it publishes again and is known once more. This Device cannot
  /// forget itself.
  Future<void> forgetDevice(String deviceId) => _runs.run(() async {
        if (deviceId == (await _identity()).deviceId) {
          throw ArgumentError.value(
              deviceId, 'deviceId', 'This Device cannot forget itself');
        }
        await _location.delete(_statePath(deviceId));
        _othersSeen?.remove(deviceId);
      });

  /// Turns Library Sync off for this Device, once a sync running now has
  /// finished. The library and the Device State published stay as they are,
  /// and this Device's identity and bookkeeping are kept: what changes
  /// while sync is off syncs when [enable] turns it back on, normally
  /// unless that is more than [removalMarkerLifetime] after its last sync.
  Future<void> disable() => _runs.run(_dao.disable);

  /// Takes in what the other Devices published, then publishes this Device's
  /// Synced Library. One sync runs at a time. While sync is paused, only
  /// reports the merge held, as it now stands.
  Future<SyncOutcome> syncNow() => _runs.run(() => _sync(const {}));

  /// Answers [hold], a merge the Removal Guard held, as the owner was shown
  /// it. [confirm] resumes sync and applies the merge, unless it now removes
  /// more than [hold] does, in which case it is held again. Otherwise sync
  /// stays paused, the library untouched, until the owner confirms.
  Future<SyncOutcome> answerRemovalGuard(RemovalGuardHold hold,
          {required bool confirm}) =>
      _runs.run(() async {
        if (!confirm) {
          await _dao.setPaused(true);
          return SyncHeld(hold: hold, declined: true);
        }
        await _dao.setPaused(false);
        return _sync({for (final r in hold.removals) r.key});
      });

  /// Syncs, applying a merge the Removal Guard would hold only when it
  /// removes nothing beyond [confirmed] (removal keys).
  Future<SyncOutcome> _sync(Set<String> confirmed) async {
    final me = await _identity();
    if (!me.enabled) throw StateError('Library Sync is turned off.');
    final now = _clock().toUtc();
    await _location.checkReachable();

    final others = <(String, Uint8List)>[];
    Uint8List? own;
    for (final (deviceId, bytes) in await _readStates()) {
      if (deviceId == me.deviceId) {
        own = bytes;
      } else {
        others.add((deviceId, bytes));
      }
    }
    _othersSeen = {
      for (final (deviceId, bytes) in others)
        deviceId: DeviceState.summaryOf(bytes)
    };

    var protected = false;
    while (true) {
      final pass = await _passInBackground(
          _database,
          _Inputs(
              others: others,
              own: own,
              me: me,
              now: now,
              confirmed: confirmed,
              protected: protected),
          _beforeCommit);
      switch (pass) {
        case _NeedsProtection():
          // Failing to protect the library stops the sync before any change.
          await _backups.createSnapshot(reason: snapshotReason);
          protected = true;
        case _Finished(:final outcome, :final publish):
          if (publish != null) {
            await _location.write(
                _statePath(me.deviceId), utf8.encode(publish));
          }
          if (outcome is SyncCompleted) await _dao.recordSync(now);
          // While an update is needed, sync is stopped.
          if (outcome is! SyncUpdateNeeded) {
            await _keepLocationBackups(me.deviceId, now);
          }
          return outcome;
      }
    }
  }

  /// Writes this Device's Location Backup for the day of [now], unless it is
  /// there already, then deletes its own beyond the latest
  /// [locationBackupsKept]. Other Devices' Location Backups are never touched.
  ///
  /// A failure leaves the sync as it ended: the Location Backup is written
  /// at the next sync instead.
  Future<void> _keepLocationBackups(String deviceId, DateTime now) async {
    try {
      final todaysName =
          '${now.toIso8601String().substring(0, 10)}_$deviceId.json';
      final ownNames = [
        for (final name in await _location.list(backupDirectory))
          if (_locationBackupName.firstMatch(name)?.group(2) == deviceId) name
      ];
      if (!ownNames.contains(todaysName)) {
        await _location.write(
            '$backupDirectory/$todaysName', await _backups.exportFullBackup());
        ownNames.add(todaysName);
      }
      ownNames.sort();
      for (final name in ownNames.reversed.skip(locationBackupsKept)) {
        await _location.delete('$backupDirectory/$name');
      }
    } on Exception catch (error, stack) {
      log('Location Backup not written', error: error, stackTrace: stack);
    }
  }

  /// A Location Backup's name: the day it was written (UTC) and the
  /// permanent ID of the Device that wrote it.
  static final _locationBackupName =
      RegExp(r'^(\d{4}-\d{2}-\d{2})_([^_/]+)\.json$');

  /// This Device's identity; sync must have been enabled.
  Future<SyncIdentity> _identity() async =>
      await _dao.identity() ??
      (throw StateError('Library Sync is not enabled.'));

  static String _statePath(String deviceId) => '$stateDirectory/$deviceId.json';

  /// Every Device State in the Sync Location, with the ID of the Device
  /// its name gives.
  Future<List<(String, Uint8List)>> _readStates() async => [
        for (final name in await _location.list(stateDirectory))
          if (name.endsWith('.json'))
            if (await _location.read('$stateDirectory/$name') case final bytes?)
              (name.substring(0, name.length - '.json'.length), bytes)
      ];

  // Static, so the worker closure captures only what it is given.
  static Future<_Pass> _passInBackground(Future<Isar> database, _Inputs inputs,
          void Function()? beforeCommit) =>
      SyncDAO.onWorker(
          database, (dao) => _passOnWorker(dao, inputs, beforeCommit));

  /// Decodes, merges, guards and applies off the main isolate.
  static Future<_Pass> _passOnWorker(
      SyncDAO dao, _Inputs inputs, void Function()? beforeCommit) async {
    final states = <DeviceState>[];
    final skipped = <SkippedDeviceState>[];
    // This Device's own, written by a newer build it ran before, is not
    // overwritten in an older format.
    if (inputs.own case final own?) {
      if (_decode(inputs.me.deviceId, own, inputs.now)
          case _TooNew(:final formatVersion)) {
        return _Finished(SyncUpdateNeeded(
            deviceId: inputs.me.deviceId,
            deviceName: inputs.me.deviceName,
            formatVersion: formatVersion));
      }
    }
    for (final (deviceId, bytes) in inputs.others) {
      switch (_decode(deviceId, bytes, inputs.now)) {
        case _Readable(:final state):
          states.add(state);
        case _Skipped(:final skip):
          skipped.add(skip);
        case _TooNew(:final deviceName, :final formatVersion):
          return _Finished(SyncUpdateNeeded(
              deviceId: deviceId,
              deviceName: deviceName,
              formatVersion: formatVersion,
              skipped: skipped));
      }
    }

    final local = await dao.readSyncedLibrary(SyncDAO.newSyncId);
    final expireBefore = inputs.now.subtract(removalMarkerLifetime);
    final lastSync = inputs.me.lastSyncAt;
    final isFirstSync = lastSync == null || lastSync.isBefore(expireBefore);
    final merge = mergeSyncedLibraries(local.library, states,
        unsyncedNames: local.unsyncedNames,
        expireBefore: expireBefore,
        firstSyncAt:
            isFirstSync ? ChangeStamp(inputs.now, inputs.me.deviceId) : null);
    final removals = removalsOf(local.library, merge, {
      for (final state in states) state.deviceId: state.deviceName,
      inputs.me.deviceId: inputs.me.deviceName,
    });
    if (inputs.me.paused) {
      return _Finished(
          SyncHeld(hold: removals, declined: true, skipped: skipped));
    }
    if (removalGuardHolds(removals) &&
        !removals.removals.every((r) => inputs.confirmed.contains(r.key))) {
      return _Finished(
          SyncHeld(hold: removals, declined: false, skipped: skipped));
    }
    final changesLibrary = merge.changes.any(_changesLibrary);
    if (changesLibrary && !inputs.protected) return const _NeedsProtection();

    final applied =
        await dao.apply(local, merge, inputs.now, beforeCommit: beforeCommit);
    final library = applied
        ? (await dao.readSyncedLibrary(SyncDAO.newSyncId)).library
        : local.library;
    final state = DeviceState(
        deviceId: inputs.me.deviceId,
        deviceName: inputs.me.deviceName,
        writtenAt: inputs.now,
        library: library);
    final outcome = SyncCompleted(changed: changesLibrary, skipped: skipped);
    if (inputs.own case final own? when _isCurrent(own, state)) {
      return _Finished(outcome);
    }
    return _Finished(outcome, publish: jsonEncode(state.toJson()));
  }

  /// Whether [change] alters what the owner sees, beyond sync's bookkeeping.
  static bool _changesLibrary(SyncedLibraryChange change) => switch (change) {
        RemovalsLearned() ||
        RemovalsDropped() ||
        AliasesLearned() ||
        PlaylistRekeyed() ||
        PlaylistKept() =>
          false,
        _ => true,
      };

  /// The Device State in [bytes], published by the Device [deviceId].
  static _Decoded _decode(String deviceId, Uint8List bytes, DateTime now) {
    String? name;
    _Skipped damaged(String reason) => _Skipped(DamagedDeviceState(
        deviceId: deviceId, deviceName: name, reason: reason));
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Not a Bloomee Device State.');
      }
      if (json['deviceName'] case final String n when n.isNotEmpty) name = n;
      final state = DeviceState.fromJson(json);
      if (state.deviceId != deviceId) {
        throw const FormatException('Device State names another Device.');
      }
      // Details this Device would store, read now so that one bad Device
      // State cannot fail applying the merge.
      state.library.tracks.values.forEach(trackDBFromJson);
      for (final collection in state.library.saved) {
        playlistDBFromJson(collection.details);
      }
      final latest = state.latestChange;
      if (latest.isAfter(now.add(clockTolerance))) {
        return _Skipped(DeviceStateFromFuture(
            deviceId: deviceId,
            deviceName: state.deviceName,
            changedAt: latest));
      }
      return _Readable(state);
    } on NewerDeviceStateFormat catch (e) {
      return _TooNew(name, e.formatVersion);
    } on FormatException catch (e) {
      return damaged(e.message);
    } on TypeError {
      // A field of the wrong kind.
      return damaged('Device State holds malformed data.');
    } on ArgumentError {
      // A kind of value this build does not know.
      return damaged('Device State holds an unknown value.');
    }
  }

  /// Whether [published] says what [state] does, and was written recently
  /// enough to show when this Device last synced.
  static bool _isCurrent(Uint8List published, DeviceState state) {
    try {
      final old = DeviceState.fromJson(
          jsonDecode(utf8.decode(published)) as Map<String, dynamic>);
      return !old.writtenAt
              .isBefore(state.writtenAt.subtract(stateRefreshInterval)) &&
          jsonEncode(old.contentJson()) == jsonEncode(state.contentJson());
    } on Exception {
      return false;
    } on TypeError {
      return false;
    } on ArgumentError {
      return false;
    }
  }
}

/// What a sync pass is given; sent to the worker isolate.
class _Inputs {
  /// Other Devices' Device States, each with the ID its name gives.
  final List<(String, Uint8List)> others;

  /// This Device's Device State as published, if it is.
  final Uint8List? own;
  final SyncIdentity me;
  final DateTime now;

  /// Removal keys the owner confirmed.
  final Set<String> confirmed;

  /// Whether a protection snapshot was taken for this sync.
  final bool protected;

  const _Inputs({
    required this.others,
    required this.own,
    required this.me,
    required this.now,
    required this.confirmed,
    required this.protected,
  });
}

/// What a Device State read as.
sealed class _Decoded {
  const _Decoded();
}

final class _Readable extends _Decoded {
  final DeviceState state;
  const _Readable(this.state);
}

final class _Skipped extends _Decoded {
  final SkippedDeviceState skip;
  const _Skipped(this.skip);
}

/// Written in a newer format than this build reads.
final class _TooNew extends _Decoded {
  final String? deviceName;
  final int formatVersion;
  const _TooNew(this.deviceName, this.formatVersion);
}

sealed class _Pass {
  const _Pass();
}

/// The merge would change the library, and no protection snapshot was taken.
final class _NeedsProtection extends _Pass {
  const _NeedsProtection();
}

final class _Finished extends _Pass {
  final SyncOutcome outcome;

  /// This Device's new Device State, or null when the published one is
  /// current or the sync stopped.
  final String? publish;

  const _Finished(this.outcome, {this.publish});
}
