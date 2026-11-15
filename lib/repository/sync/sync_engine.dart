import 'dart:convert';

import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/repository/sync/synced_library_merge.dart';
import 'package:Bloomee/services/backup/serial_executor.dart';
import 'package:Bloomee/services/db/dao/sync_dao.dart';
import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:isar_community/isar.dart';

typedef SyncClock = DateTime Function();

/// Keeps this Device's Synced Library in step with the other Devices that
/// share its Sync Location (see `docs/adr/0001-one-device-state-per-device.md`).
///
/// It only ever writes this Device's own Device State, and knows nothing about
/// which kind of Sync Location it has.
class SyncEngine {
  /// Where Device States live in the Sync Location.
  static const stateDirectory = 'sync';

  final Future<Isar> _database;
  final SyncLocation _location;
  final SyncClock _clock;
  final SyncDAO _dao;
  final SerialExecutor _runs = SerialExecutor();

  SyncEngine({
    required Future<Isar> database,
    required SyncLocation location,
    SyncClock? clock,
  })  : _database = database,
        _location = location,
        _clock = clock ?? DateTime.now,
        _dao = SyncDAO(database);

  /// Turns Library Sync on for this Device under [deviceName]. The Device's
  /// permanent ID is made the first time and kept afterwards.
  Future<SyncIdentity> enable({required String deviceName}) =>
      _dao.enable(deviceName: deviceName, newDeviceId: SyncDAO.newSyncId());

  /// Takes in what the other Devices published, then publishes this Device's
  /// Synced Library. One sync runs at a time.
  Future<void> syncNow() => _runs.run(_sync);

  Future<void> _sync() async {
    final me = await _dao.identity();
    if (me == null) throw StateError('Library Sync is not enabled.');
    final now = _clock().toUtc();
    await _location.checkReachable();

    final ownName = '${me.deviceId}.json';
    final others = <String>[];
    String? own;
    for (final name in await _location.list(stateDirectory)) {
      if (!name.endsWith('.json')) continue;
      final bytes = await _location.read('$stateDirectory/$name');
      if (bytes == null) continue;
      if (name == ownName) {
        own = utf8.decode(bytes);
      } else {
        others.add(utf8.decode(bytes));
      }
    }

    final publish = await _mergeInBackground(_database, others, own, me, now);
    if (publish != null) {
      await _location.write('$stateDirectory/$ownName', utf8.encode(publish));
    }
    await _dao.recordSync(now);
  }

  // Static, so the worker closure captures only what it is given.
  static Future<String?> _mergeInBackground(Future<Isar> database,
          List<String> others, String? own, SyncIdentity me, DateTime now) =>
      SyncDAO.onWorker(
          database, (dao) => _mergeOnWorker(dao, others, own, me, now));

  /// Decodes, merges and applies off the main isolate. Returns this Device's
  /// new Device State, or null when the published one is still current.
  static Future<String?> _mergeOnWorker(SyncDAO dao, List<String> others,
      String? own, SyncIdentity me, DateTime now) async {
    final states = [
      for (final raw in others)
        DeviceState.fromJson(jsonDecode(raw) as Map<String, dynamic>)
    ];
    final local = await dao.readSyncedLibrary(SyncDAO.newSyncId);
    final merge = mergeSyncedLibraries(local.library, states,
        unsyncedNames: local.unsyncedNames);
    final applied = await dao.apply(local, merge, now);
    final library = applied
        ? (await dao.readSyncedLibrary(SyncDAO.newSyncId)).library
        : local.library;
    final state = DeviceState(
        deviceId: me.deviceId,
        deviceName: me.deviceName,
        writtenAt: now,
        library: library);
    if (own != null && _sameContent(own, state)) return null;
    return jsonEncode(state.toJson());
  }

  static bool _sameContent(String published, DeviceState state) {
    try {
      final old =
          DeviceState.fromJson(jsonDecode(published) as Map<String, dynamic>);
      return jsonEncode(old.contentJson()) == jsonEncode(state.contentJson());
    } on FormatException {
      return false;
    }
  }
}
