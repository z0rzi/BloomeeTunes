import 'dart:convert';
import 'dart:io';

import 'package:Bloomee/core/constants/setting_keys.dart';
import 'package:Bloomee/core/models/backup/backup_document.dart';
import 'package:Bloomee/core/models/sync/device_state.dart';
import 'package:Bloomee/core/models/sync/sync_outcome.dart';
import 'package:Bloomee/repository/sync/sync_engine.dart';
import 'package:Bloomee/services/db/dao/history_dao.dart';
import 'package:Bloomee/services/db/dao/plugin_storage_dao.dart';
import 'package:Bloomee/services/db/dao/settings_dao.dart';
import 'package:Bloomee/services/db/global_db.dart';
import 'package:Bloomee/src/rust/api/plugin/models.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

import 'support/isar_test_support.dart';
import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncWorld world;

  setUpAll(initializeTestIsar);
  setUp(() async => world = await SyncWorld.create());
  tearDown(() => world.dispose());

  Future<void> nextDay() async => world.clock.advance(const Duration(days: 1));

  /// The Location Backups in the Sync Location.
  List<File> locationBackups() {
    final folder =
        Directory(p.join(world.locationPath, SyncEngine.backupDirectory));
    if (!folder.existsSync()) return [];
    return folder.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  group('Location Backups', () {
    test('a Device writes at most one Location Backup a day', () async {
      final a = await world.device('laptop');
      await a.add('Road trip', [song('yt::1')]);
      await a.sync();
      expect(locationBackups(), hasLength(1));

      world.clock.advance(const Duration(hours: 1));
      await a.add('Road trip', [song('yt::2')]);
      await a.sync();
      await a.sync();
      expect(locationBackups(), hasLength(1), reason: 'still the same day');

      await nextDay();
      await a.sync();
      expect(locationBackups(), hasLength(2));
    });

    test(
        'a Location Backup that cannot be written leaves the sync done, and is written at the next sync',
        () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      // Something in the way of the backups area.
      final blocker =
          File(p.join(world.locationPath, SyncEngine.backupDirectory));
      await blocker.writeAsString('not a folder');
      await a.add('Road trip', [song('yt::1')]);

      expect(await a.sync(), isA<SyncCompleted>());
      await b.sync();
      expect(await b.songsOf('Road trip'), ['yt::1']);

      await blocker.delete();
      await a.sync();
      expect(locationBackups(), hasLength(1), reason: 'the laptop\'s, at last');
    });

    test(
        'a Location Backup is a full backup in the existing format that the existing import restores',
        () async {
      final a = await world.device('laptop');
      await a.add('Road trip', [song('yt::1'), song('yt::2')]);
      await a.playlists.setTrackLiked(song('yt::3'), true);
      await HistoryDAO(Future.value(a.isar), a.tracks)
          .recordPlay(song('yt::4'));
      await SettingsDAO(Future.value(a.isar))
          .putSettingStr(SettingKeys.languageCode, 'de');
      await a.sync();

      // Another install, not syncing, imports it as any backup file.
      final elsewhere = await world.device('elsewhere', enabled: false);
      final document =
          await elsewhere.backups.prepare(locationBackups().single.path);
      expect(document.kind, 'backup');
      await elsewhere.backups.apply(document, const BackupSelection());

      expect(await elsewhere.songsOf('Road trip'), ['yt::1', 'yt::2']);
      expect(await elsewhere.playlists.isTrackLiked('yt::3'), isTrue);
      final played = <String>[];
      for (final h
          in await elsewhere.isar.playbackHistoryDBs.where().findAll()) {
        await h.track.load();
        played.add(h.track.value!.mediaId);
      }
      expect(played, ['yt::4']);
      expect(
          await SettingsDAO(Future.value(elsewhere.isar))
              .getSettingStr(SettingKeys.languageCode),
          'de');
    });

    test(
        'each Device keeps its seven latest Location Backups and never deletes another Device\'s',
        () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      await a.add('Road trip', [song('yt::1')]);
      await b.sync();
      final phoneBackup = locationBackups().single.path;

      final laptopDays = <String>[];
      for (var day = 0; day < 9; day++) {
        await a.sync();
        laptopDays.add(locationBackups().map((f) => f.path).firstWhere(
            (path) => !laptopDays.contains(path) && path != phoneBackup));
        await nextDay();
      }

      expect([for (final f in locationBackups()) f.path]..sort(),
          ([...laptopDays.skip(2), phoneBackup])..sort(),
          reason: 'the laptop kept its seven latest, the phone\'s stays');

      for (var day = 0; day < 8; day++) {
        await b.sync();
        await nextDay();
      }
      expect(locationBackups(), hasLength(14));
      expect(File(phoneBackup).existsSync(), isFalse,
          reason: 'the phone deleted its own oldest');
    });

    test(
        'Location Backups and Device States are plain files that hold no credentials',
        () async {
      final a = await world.device('laptop');
      await a.add('Road trip', [song('yt::1')]);
      final settings = SettingsDAO(Future.value(a.isar));
      await settings.putSettingStr('accountToken', 'secret-token-1');
      await settings.putSettingStr(
          SettingKeys.librarySyncFolder, '/home/me/secret-folder-2');
      await PluginStorageDao(Future.value(a.isar)).putEntry(
          pluginId: 'plugin.example',
          key: 'password',
          value: 'secret-password-3');
      await a.sync();

      final files = await filesIn(world.locationPath);
      expect(files.keys, hasLength(2), reason: 'a Device State and a backup');
      for (final MapEntry(key: path, value: bytes) in files.entries) {
        final text = utf8.decode(bytes);
        expect(jsonDecode(text), isA<Map<String, dynamic>>(), reason: path);
        for (final secret in [
          'secret-token-1',
          'secret-folder-2',
          'secret-password-3'
        ]) {
          expect(text, isNot(contains(secret)), reason: path);
        }
      }
    });
  });

  group('restoring a backup while syncing', () {
    Future<void> later() async =>
        world.clock.advance(const Duration(minutes: 5));
    const album = AlbumSummary(id: 'yt::album', title: 'For Emma', artists: []);
    const artist = ArtistSummary(id: 'yt::artist', name: 'Bon Iver');

    test('a merge-restore\'s additions reach the other Devices', () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      await a.add('Road trip', [song('yt::1'), song('yt::2')]);
      await a.add('Workout', [song('yt::3')]);
      await a.playlists.setTrackLiked(song('yt::4'), true);
      final backup = await a.backup();

      await later();
      await a.remove('Road trip', 'yt::2');
      await a.playlists.deletePlaylistByName('Workout');
      await a.playlists.setTrackLiked(song('yt::4'), false);
      await a.sync();
      await b.sync();
      expect(await b.songsOf('Road trip'), ['yt::1']);

      await later();
      await a.restore(backup);
      await a.sync();
      await b.sync();

      for (final device in [a, b]) {
        expect(await device.songsOf('Road trip'), ['yt::1', 'yt::2'],
            reason: device.name);
        expect(await device.songsOf('Workout'), ['yt::3'], reason: device.name);
        expect(await device.playlists.isTrackLiked('yt::4'), isTrue,
            reason: device.name);
      }
    });

    test(
        'a replace-restore removes from the other Devices what the backup lacks, as the Latest Change',
        () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      await a.add('Road trip', [song('yt::1'), song('yt::2')]);
      await a.playlists.updatePlaylistMeta(await a.rowId('Road trip'),
          description: 'Summer');
      await a.add('Focus', [song('yt::8')]);
      await a.arrangeLibrary(['Focus', 'Road trip']);
      await a.playlists.setTrackLiked(song('yt::5'), true);
      await a.library.saveArtist(artist, sourceName: 'YouTube');
      final backup = await a.backup();

      await later();
      await a.add('Road trip', [song('yt::3')]);
      await a.add('Workout', [song('yt::4')]);
      await a.playlists.setTrackLiked(song('yt::6'), true);
      await a.library.saveAlbum(album, sourceName: 'YouTube');
      await a.sync();
      await b.sync();
      // The phone changes things before the restore, which the laptop
      // has not taken in yet.
      await later();
      await b.remove('Road trip', 'yt::1');
      await b.arrange('Road trip', ['yt::3', 'yt::2']);
      await b.playlists.updatePlaylistMeta(await b.rowId('Road trip'),
          description: 'Winter');
      await b.playlists.setPinned(await b.rowId('Road trip'), true);
      await b.arrangeLibrary(['Road trip', 'Workout', 'Focus']);
      await b.playlists.setTrackLiked(song('yt::5'), false);
      await b.library.removeByMediaId(artist.id, PlaylistTypeDB.artist);
      await b.sync();

      await later();
      await a.restore(backup, replace: true);
      await a.sync();
      await b.sync();
      await a.sync();

      for (final device in [a, b]) {
        expect(
            await device.syncedLibrary(),
            {
              'playlists': [
                [
                  'Focus',
                  null,
                  false,
                  ['yt::8']
                ],
                [
                  'Road trip',
                  'Summer',
                  false,
                  ['yt::1', 'yt::2']
                ],
              ],
              'liked': ['yt::5'],
              'albums': <String>[],
              'artists': [artist.id],
            },
            reason: device.name);
      }

      // What changes after the restore wins over it as usual.
      await later();
      await b.add('Road trip', [song('yt::7')]);
      await b.sync();
      await a.sync();
      expect(await a.songsOf('Road trip'), ['yt::1', 'yt::2', 'yt::7']);
    });

    test(
        'a replace-restore large enough holds the merge for the Removal Guard on the other Devices',
        () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      await a.add('Road trip', [song('yt::1')]);
      final backup = await a.backup();
      await later();
      for (final name in ['Workout', 'Focus', 'Sleep', 'Party']) {
        await a.add(name, [song('yt::$name')]);
      }
      await a.sync();
      await b.sync();

      await later();
      await a.restore(backup, replace: true);
      expect(await a.engine.syncNow(), isA<SyncCompleted>(),
          reason: 'the Device that restored is not asked');

      final outcome = await b.engine.syncNow();
      expect(outcome, isA<SyncHeld>());
      expect({for (final r in (outcome as SyncHeld).hold.removals) r.kind},
          {RemovalKind.playlist});
      expect(outcome.hold.removals, hasLength(4));
      expect(await b.playlistNames(), hasLength(6),
          reason: 'nothing applied while held');

      await b.engine.answerRemovalGuard(outcome.hold, confirm: true);
      expect(await b.libraryOrder(), ['Road trip']);
    });

    test(
        'a playlist a replace-restore deleted comes back whole when another Device changes it later',
        () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      await a.add('Focus', [song('yt::8')]);
      final backup = await a.backup();
      await later();
      await a.add('Road trip', [song('yt::1')]);
      await a.sync();
      await b.sync();

      await later();
      await a.add('Road trip', [song('yt::2')]);
      await a.restore(backup, replace: true);
      await a.sync();
      await later();
      await b.add('Road trip', [song('yt::3')]);
      await b.sync();
      await a.sync();
      await b.sync();

      for (final device in [a, b]) {
        expect(await device.songsOf('Road trip'), ['yt::1', 'yt::2', 'yt::3'],
            reason: device.name);
      }
    });
  });
}
