import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:Bloomee/core/models/backup/backup_document.dart';
import 'package:Bloomee/services/backup/backup_files.dart';
import 'package:Bloomee/services/backup/serial_executor.dart';
import 'package:Bloomee/services/db/dao/backup_dao.dart';
import 'package:Bloomee/services/db/db_provider.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:Bloomee/core/models/backup/recovery_copy.dart';
import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';

class BackupRepository {
  final BackupDAO dao;
  final Future<Isar> database;
  final String supportPath;
  final String? documentsPath;
  final SerialExecutor _operations = SerialExecutor();
  final Random _random = Random.secure();

  /// When protection snapshots are taken, as their names record it.
  final DateTime Function() _clock;

  BackupRepository(
      {required this.dao,
      required this.database,
      required this.supportPath,
      this.documentsPath,
      DateTime Function() clock = DateTime.now})
      : _clock = clock;

  String _id() =>
      '${_clock().toUtc().microsecondsSinceEpoch}_${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  String get snapshotDirectory => p.join(supportPath, 'backups');

  Future<void> runMaintenance(Future<void> Function() maintenance) =>
      _operations.run(maintenance);

  Future<List<LibraryRecoverySource>> libraryRecoverySources() =>
      _operations.run(_libraryRecoverySources);

  Future<List<LibraryRecoverySource>> _libraryRecoverySources() async {
    final live = await database;
    final paths = <String>{p.join(live.directory!, '${live.name}.isar')};
    final roots = <String>{
      supportPath,
      if (documentsPath != null) documentsPath!
    };
    // Only retained v3 databases and snapshots are supported.
    for (final root in roots) {
      paths.addAll([
        p.join(root, 'dbv3.isar'),
        p.join(root, 'bloomee_backup_dbv3.isar'),
        p.join(root, 'bloomeeBackup', 'bloomee_backup_dbv3.isar')
      ]);
    }
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        paths.add(p.join(
            downloads.path, 'bloomeeBackup', 'bloomee_backup_dbv3.isar'));
      }
    } catch (_) {/* This platform may not expose a Downloads directory. */}
    final backups = Directory(snapshotDirectory);
    if (await backups.exists()) {
      await for (final entry in backups.list(followLinks: false)) {
        if (entry is File && entry.path.endsWith('.isar')) {
          paths.add(entry.path);
        }
      }
    }
    final sources = <LibraryRecoverySource>[];
    for (final path in paths.map(p.normalize).toSet()) {
      final stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.file && stat.size > 0) {
        sources.add(LibraryRecoverySource(path, stat.modified, stat.size));
      }
    }
    sources.sort((a, b) => b.modified.compareTo(a.modified));
    return sources;
  }

  Future<LibraryRecoveryPlan> prepareLibraryRecovery(String path) =>
      _operations.run(() async {
        if (!(await _libraryRecoverySources())
            .any((s) => p.equals(s.path, path))) {
          throw const FormatException(
              'Recovery source is no longer available.');
        }
        final live = await database;
        final livePath = p.join(live.directory!, '${live.name}.isar');
        if (!p.equals(livePath, path) &&
            !await FileSystemEntity.identical(livePath, path)) {
          return BackupDAO.readRecoveryFile(path, supportPath, documentsPath);
        }
        // Raw copying a live database is unsafe. Take an engine snapshot first.
        final root = await Directory(p.join(supportPath, 'import_staging'))
            .create(recursive: true);
        final stage = await root.createTemp('snapshot_live_');
        try {
          final snapshot = p.join(stage.path, 'current.isar');
          await live.copyToFile(snapshot);
          return await BackupDAO.readRecoveryFile(
              snapshot, supportPath, documentsPath);
        } finally {
          await stage.delete(recursive: true);
        }
      });

  Future<Map<String, int>> recoverLibrary(LibraryRecoveryPlan plan) =>
      _operations.run(() async {
        if (await File(p.join(supportPath, 'reset_requested')).exists()) {
          throw StateError(
              'Cancel the scheduled reset before recovering data.');
        }
        await _snapshot('before_import');
        final result = await dao.apply(plan.document,
            const BackupSelection(history: false, settings: false),
            recoveredDownloads: plan.downloads);
        await _rotate('before_import', keep: 7);
        return result;
      });

  /// Called once during bootstrap, before imports can open staged databases.
  Future<void> cleanInterruptedWork() => _operations.run(() async {
        final staging = Directory(p.join(supportPath, 'import_staging'));
        if (await staging.exists()) {
          await for (final entry in staging.list(followLinks: false)) {
            if (entry is Directory &&
                p.basename(entry.path).startsWith('snapshot_')) {
              await entry.delete(recursive: true);
            }
          }
        }
        final snapshots = Directory(snapshotDirectory);
        if (await snapshots.exists()) {
          await for (final entry in snapshots.list(followLinks: false)) {
            if (entry is File && entry.path.endsWith('.isar.partial')) {
              await entry.delete();
            }
          }
        }
        final staged = Directory(_exportStagingDirectory);
        if (await staged.exists()) await staged.delete(recursive: true);
        final exports = Directory(
            p.join((await getTemporaryDirectory()).path, 'bloomee_exports'));
        if (await exports.exists()) {
          final cutoff = DateTime.now().subtract(const Duration(days: 7));
          await for (final entry in exports.list(followLinks: false)) {
            if (entry is File &&
                (await entry.lastModified()).isBefore(cutoff)) {
              await entry.delete();
            }
          }
        }
      });

  Future<BackupDocument> prepare(String path) => _operations.run(() async {
        final file = File(path);
        final size = await file.length();
        if (size == 0 || size > BackupDocument.maxBytes * 8) {
          throw const FormatException('Empty or oversized backup.');
        }
        final prefix = await file.open();
        late List<int> header;
        try {
          header = await prefix.read(256);
        } finally {
          await prefix.close();
        }
        final text = utf8
            .decode(header, allowMalformed: true)
            .replaceFirst('\uFEFF', '')
            .trimLeft();
        late BackupDocument document;
        if (text.startsWith('{') ||
            p.extension(path).toLowerCase() == '.json') {
          document = await BackupFiles.readJson(path);
        } else if (['.isar', '.db'].contains(p.extension(path).toLowerCase())) {
          // A binary snapshot is only a compatibility source. Never replace live files.
          final dir = await Directory(p.join(supportPath, 'import_staging'))
              .create(recursive: true);
          final stage = await dir.createTemp('snapshot_');
          final name = 'import_${_id()}';
          Isar? source;
          try {
            await file.copy(p.join(stage.path, '$name.isar'));
            source = await Isar.open(DBProvider.schemas,
                directory: stage.path, name: name, inspector: false);
            final sourceDao = BackupDAO(Future.value(source));
            if (!await sourceDao.hasLibraryData()) {
              throw const FormatException(
                  'Snapshot has no supported library data. Export JSON from the original app version.');
            }
            document = await sourceDao.snapshot();
          } catch (error) {
            throw FormatException(
                'Cannot read this database snapshot. It may be incompatible or damaged. Original data was not changed. $error');
          } finally {
            if (source != null) await source.close();
            await stage.delete(recursive: true);
          }
        } else {
          // JSON is identified by structure even when providers rename it.
          document = await BackupFiles.readJson(path);
        }
        await BackupDAO.validateInBackground(document);
        return document;
      });

  Future<String> export({String? playlistName}) => _operations.run(() async {
        final directory = await Directory(
                p.join((await getTemporaryDirectory()).path, 'bloomee_exports'))
            .create(recursive: true);
        return _exportTo(directory, playlistName: playlistName);
      });

  /// The full-library backup [export] writes, as the bytes of its file, for
  /// a copy kept elsewhere (a Location Backup in the Sync Location).
  Future<Uint8List> exportFullBackup() => _operations.run(() async {
        final directory =
            await Directory(_exportStagingDirectory).create(recursive: true);
        final path = await _exportTo(directory);
        try {
          return await File(path).readAsBytes();
        } finally {
          await File(path).delete();
        }
      });

  String get _exportStagingDirectory => p.join(supportPath, 'export_staging');

  /// Writes the backup [export] describes into [directory], returning its
  /// path once it is complete and validated.
  Future<String> _exportTo(Directory directory, {String? playlistName}) async {
    final document = await dao.snapshot(playlistName: playlistName);
    final name = playlistName == null
        ? 'Bloomee_Backup'
        : BackupFiles.safeName(playlistName);
    final target = File(p.join(directory.path, '${name}_${_id()}.json'));
    final temporary = File('${target.path}.partial');
    try {
      await temporary.writeAsString(jsonEncode(document.data), flush: true);
      if (await temporary.length() > BackupDocument.maxBytes) {
        throw const FormatException(
            'Export exceeds the supported 32 MB JSON limit. Export smaller playlists.');
      }
      // Round-trip validation before the file can be saved or shared.
      await BackupFiles.readJson(temporary.path);
      await temporary.rename(target.path);
      return target.path;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<String> _snapshot(String reason) async {
    final dir = await Directory(snapshotDirectory).create(recursive: true);
    final target = File(p.join(dir.path, '${reason}_${_id()}.isar'));
    final pending = File('${target.path}.partial');
    try {
      final isar = await database;
      await isar.copyToFile(pending.path);
      if (!await pending.exists() || await pending.length() == 0) {
        throw const FileSystemException('Recovery snapshot was not completed.');
      }
      final handle = await pending.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      await pending.rename(target.path);
      return target.path;
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

  /// Takes a protection snapshot kept under [reason], then deletes that
  /// reason's older ones beyond the latest seven. With [keepDaily], the
  /// first of today and the first of yesterday (UTC) are kept as well, so
  /// that, however many follow it, a snapshot is there for at least a day
  /// that predates anything done since: storage stays bounded at nine.
  Future<String> createSnapshot(
          {String reason = 'automatic', bool keepDaily = false}) =>
      _operations.run(() async {
        final path = await _snapshot(reason);
        await _rotate(reason, keep: 7, keepDaily: keepDaily);
        return path;
      });

  Future<void> automaticIfDue() => _operations.run(() async {
        final settings = SettingsDAO(database);
        if (await settings.getSettingBool(SettingKeys.autoBackup) != true) {
          return;
        }
        final raw =
            await settings.getSettingStr(SettingKeys.lastBackupTimestamp);
        final last = raw == null ? null : DateTime.tryParse(raw)?.toUtc();
        final now = DateTime.now().toUtc();
        if (last != null &&
            !last.isAfter(now) &&
            now.difference(last) < const Duration(hours: 24)) {
          return;
        }
        await _snapshot('automatic');
        await settings.putSettingStr(SettingKeys.lastBackupTimestamp,
            DateTime.now().toUtc().toIso8601String());
        await _rotate('automatic', keep: 7);
      });

  /// Execute reset on the next bootstrap, before background writers exist.
  Future<void> requestReset() => _operations.run(() async {
        final snapshot = await _snapshot('before_reset');
        final marker = File(p.join(supportPath, 'reset_requested'));
        final temporary = File('${marker.path}.partial');
        await temporary.writeAsString(
            jsonEncode({'version': 1, 'snapshot': p.basename(snapshot)}),
            flush: true);
        if (await marker.exists()) await marker.delete();
        await temporary.rename(marker.path);
      });

  Future<void> cancelReset() => _operations.run(() async {
        final marker = File(p.join(supportPath, 'reset_requested'));
        if (await marker.exists()) await marker.delete();
      });

  Future<Map<String, int>> apply(
          BackupDocument document, BackupSelection selection,
          {String? deliveryId}) =>
      _operations.run(() async {
        if (await File(p.join(supportPath, 'reset_requested')).exists()) {
          throw StateError('Cancel the scheduled reset before importing data.');
        }
        final any = (selection.library && document.has('playlists')) ||
            (selection.history &&
                (document.has('history') || document.has('searchHistory'))) ||
            (selection.settings && document.has('settings'));
        if (!any) {
          throw const FormatException(
              'Select at least one available data section.');
        }
        // Failure to protect current data aborts the import before any mutation.
        await _snapshot('before_import');
        final result = await dao.apply(document, selection,
            receiptKey: deliveryId == null
                ? null
                : '_backupReceipt/${sha256.convert(utf8.encode(deliveryId))}');
        // Failed imports retain their pre-import snapshot. Only successful runs rotate.
        await _rotate('before_import', keep: 7);
        return result;
      });

  Future<List<RecoveryCopy>> recoverySnapshots() => _operations.run(() async {
        final dir = Directory(snapshotDirectory);
        if (!await dir.exists()) return [];
        final files = await dir
            .list()
            .where((e) => e is File && e.path.endsWith('.isar'))
            .toList();
        final copies = <RecoveryCopy>[];
        for (final f in files) {
          final name = p.basename(f.path);
          final createdAt = _takenAt(name);
          if (createdAt == null) continue;
          copies.add(RecoveryCopy(
              path: f.path,
              createdAt: createdAt,
              reason: name.startsWith('before_import_')
                  ? RecoveryReason.beforeImport
                  : name.startsWith('before_reset_')
                      ? RecoveryReason.beforeReset
                      : RecoveryReason.automatic));
        }
        copies.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return copies;
      });

  /// When the snapshot named [name] was taken, as its name records it.
  static DateTime? _takenAt(String name) {
    final match = RegExp(r'_(\d+)_([a-f0-9]+)\.isar$').firstMatch(name);
    final timestamp = int.tryParse(match?.group(1) ?? '');
    return timestamp == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(timestamp, isUtc: true);
  }

  /// Deletes the snapshots kept under [reason] beyond the latest [keep]; with
  /// [keepDaily], also keeps the first one of today and of yesterday (UTC).
  Future<void> _rotate(String reason,
      {required int keep, bool keepDaily = false}) async {
    try {
      final dir = Directory(snapshotDirectory);
      final files = await dir
          .list()
          .where((e) =>
              e is File &&
              p.basename(e.path).startsWith('${reason}_') &&
              e.path.endsWith('.isar'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      final kept = {...files.take(keep).map((f) => f.path)};
      if (keepDaily) {
        final today = _clock().toUtc();
        final days = {
          for (final day in [today, today.subtract(const Duration(days: 1))])
            day.toIso8601String().substring(0, 10)
        };
        // Oldest first, so that each day's first is met first.
        for (final file in files.reversed) {
          final day = _takenAt(p.basename(file.path))
              ?.toIso8601String()
              .substring(0, 10);
          if (days.remove(day)) kept.add(file.path);
        }
      }
      for (final file in files) {
        if (!kept.contains(file.path)) await file.delete();
      }
    } on FileSystemException {
      // Retention failure must never turn a committed import into a reported failure.
    }
  }
}
