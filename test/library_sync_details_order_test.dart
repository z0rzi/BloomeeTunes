import 'package:Bloomee/services/db/global_db.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/isar_test_support.dart';
import 'support/sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncWorld world;

  setUpAll(initializeTestIsar);
  setUp(() async => world = await SyncWorld.create());
  tearDown(() => world.dispose());

  Future<void> later() async => world.clock.advance(const Duration(minutes: 5));

  test(
      'a playlist renamed on one Device is renamed on another, without a second playlist',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2')]);
    await a.sync();
    await b.sync();

    await later();
    await a.rename('Road trip', 'Summer 2026');
    await a.sync();
    await b.sync();
    await a.sync();

    for (final device in [a, b]) {
      expect(await device.libraryOrder(), ['Summer 2026'], reason: device.name);
      expect(await device.songsOf('Summer 2026'), ['yt::1', 'yt::2'],
          reason: device.name);
    }
  });

  Future<(String?, bool)> detailsOf(SyncDevice d, String playlist) async {
    final row = (await d.playlists.getPlaylistByName(playlist))!;
    return (row.description, row.isPinned);
  }

  test(
      'a description changed on one Device and pinning changed on another both survive',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.sync();
    await b.sync();

    await later();
    await a.playlists.updatePlaylistMeta(await a.rowId('Road trip'),
        description: 'Songs for the A7');
    await later();
    await b.playlists.setPinned(await b.rowId('Road trip'), true);
    await a.sync();
    await b.sync();
    await a.sync();

    for (final device in [a, b]) {
      expect(await detailsOf(device, 'Road trip'), ('Songs for the A7', true),
          reason: device.name);
    }
  });

  test('the same detail changed on both Devices ends as the later change',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.add('Focus', [song('yt::2')]);
    await a.sync();
    await b.sync();

    // B changes each detail first, A changes it later; then the other way.
    await later();
    await b.rename('Road trip', 'Holidays');
    await b.playlists
        .updatePlaylistMeta(await b.rowId('Focus'), description: 'by B');
    await later();
    await a.rename('Road trip', 'Summer 2026');
    await a.playlists
        .updatePlaylistMeta(await a.rowId('Focus'), description: 'by A');
    await later();
    await b.playlists.setPinned(await b.rowId('Focus'), true);
    await b.sync();
    await a.sync();
    await b.sync();

    for (final device in [a, b]) {
      // Pinned first.
      expect(await device.libraryOrder(), ['Focus', 'Summer 2026'],
          reason: device.name);
      expect(await detailsOf(device, 'Focus'), ('by A', true),
          reason: device.name);
    }
  });

  test('songs reordered on one Device appear in that order on another',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
    await a.sync();
    await b.sync();

    await later();
    await a.arrange('Road trip', ['yt::3', 'yt::1', 'yt::2']);
    await a.sync();
    await b.sync();

    expect(await b.songsOf('Road trip'), ['yt::3', 'yt::1', 'yt::2']);
  });

  test(
      'a song added on one Device while another reordered ends at the end of that order on both',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
    await a.sync();
    await b.sync();

    await later();
    await b.add('Road trip', [song('yt::4')]);
    await later();
    await a.arrange('Road trip', ['yt::3', 'yt::2', 'yt::1']);
    await a.sync();
    await b.sync();
    await a.sync();

    for (final device in [a, b]) {
      expect(await device.songsOf('Road trip'),
          ['yt::3', 'yt::2', 'yt::1', 'yt::4'],
          reason: device.name);
    }
  });

  test('two reorders of the same playlist end as the later one, whole',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip',
        [song('yt::1'), song('yt::2'), song('yt::3'), song('yt::4')]);
    await a.sync();
    await b.sync();

    await later();
    await a.arrange('Road trip', ['yt::4', 'yt::3', 'yt::2', 'yt::1']);
    await later();
    await b.arrange('Road trip', ['yt::2', 'yt::1', 'yt::4', 'yt::3']);
    await a.sync();
    await b.sync();
    await a.sync();

    for (final device in [a, b]) {
      expect(await device.songsOf('Road trip'),
          ['yt::2', 'yt::1', 'yt::4', 'yt::3'],
          reason: device.name);
    }
  });

  test(
      'a song taken out on one Device after another reordered keeps that order',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
    await a.sync();
    await b.sync();

    await later();
    await b.arrange('Road trip', ['yt::3', 'yt::2', 'yt::1']);
    await later();
    // As smart replacement drops a song: the whole list, minus one.
    await a.playlists.setPlaylistTracks(
        await a.rowId('Road trip'), [song('yt::1'), song('yt::3')]);
    await a.sync();
    await b.sync();
    await a.sync();

    for (final device in [a, b]) {
      expect(await device.songsOf('Road trip'), ['yt::3', 'yt::1'],
          reason: device.name);
    }
  });

  test(
      'the arrangement of playlists in the library made on one Device appears on another',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.add('Focus', [song('yt::2')]);
    await a.add('Party', [song('yt::3')]);
    await a.sync();
    await b.sync();
    expect(await b.libraryOrder(), ['Road trip', 'Focus', 'Party']);

    await later();
    await a.arrangeLibrary(['Party', 'Road trip', 'Focus']);
    await a.sync();
    await b.sync();

    expect(await b.libraryOrder(), ['Party', 'Road trip', 'Focus']);
  });

  test(
      'a playlist created on one Device while another arranged the library is placed after that arrangement on both',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.add('Focus', [song('yt::2')]);
    await a.add('Party', [song('yt::3')]);
    await a.sync();
    await b.sync();

    await later();
    await b.add('Running', [song('yt::4')]);
    await later();
    await a.arrangeLibrary(['Party', 'Focus', 'Road trip']);
    await a.sync();
    await b.sync();
    await a.sync();

    for (final device in [a, b]) {
      expect(await device.libraryOrder(),
          ['Party', 'Focus', 'Road trip', 'Running'],
          reason: device.name);
    }
  });

  test('two arrangements of the library end as the later one, whole', () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.add('Focus', [song('yt::2')]);
    await a.add('Party', [song('yt::3')]);
    await a.sync();
    await b.sync();

    await later();
    await a.arrangeLibrary(['Party', 'Focus', 'Road trip']);
    await later();
    await b.arrangeLibrary(['Focus', 'Road trip', 'Party']);
    await a.sync();
    await b.sync();
    await a.sync();

    for (final device in [a, b]) {
      expect(await device.libraryOrder(), ['Focus', 'Road trip', 'Party'],
          reason: device.name);
    }
  });

  test('two playlists that swap names on one Device swap them on another',
      () async {
    final a = await world.device('laptop');
    final b = await world.device('phone');
    await a.add('Road trip', [song('yt::1')]);
    await a.add('Focus', [song('yt::2')]);
    await a.sync();
    await b.sync();

    await later();
    await a.rename('Road trip', 'Swap');
    await a.rename('Focus', 'Road trip');
    await a.rename('Swap', 'Focus');
    await a.sync();
    await b.sync();

    expect(await b.songsOf('Road trip'), ['yt::2']);
    expect(await b.songsOf('Focus'), ['yt::1']);
    expect(await b.libraryOrder(), hasLength(2));
  });

  group('two playlists that come to bear the same name become one', () {
    Future<void> settle(List<SyncDevice> devices) async {
      for (var round = 0; round < 2; round++) {
        for (final device in devices) {
          await device.sync();
        }
      }
    }

    Future<void> expectOne(
        List<SyncDevice> devices, String name, List<String> songs) async {
      for (final device in devices) {
        expect(await device.libraryOrder(), [name], reason: device.name);
        expect((await device.songsOf(name))!..sort(), songs,
            reason: device.name);
      }
    }

    test('when made apart on two Devices; removals then reach both', () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      await a.add('Road trip', [song('yt::1'), song('yt::2')]);
      await later();
      await b.add('road trip', [song('yt::2'), song('yt::3')]);
      await settle([a, b]);
      // Named as the later one was.
      await expectOne([a, b], 'road trip', ['yt::1', 'yt::2', 'yt::3']);

      await later();
      await a.remove('Road trip', 'yt::3');
      await b.remove('road trip', 'yt::1');
      await settle([a, b]);
      for (final device in [a, b]) {
        expect(await device.songsOf('Road trip'), ['yt::2'],
            reason: device.name);
      }

      await later();
      await b.playlists.deletePlaylistByName('Road trip');
      await settle([a, b]);
      for (final device in [a, b]) {
        expect(await device.libraryOrder(), isEmpty, reason: device.name);
      }
    });

    test(
        'when one is renamed to the name of the other, even on a Device that synced before the rename',
        () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      final c = await world.device('desktop');
      await a.add('Road trip', [song('yt::1')]);
      await settle([a, b, c]);

      await later();
      await b.add('Summer', [song('yt::2')]);
      await a.rename('Road trip', 'Summer');
      await c.add('Road trip', [song('yt::3')]);
      // A meets B's playlist before C hears of the rename: when A keeps the
      // other playlist's sync ID, only the alias A publishes tells C.
      await b.sync();
      await a.sync();
      await c.sync();
      await settle([c, b, a]);
      await expectOne([a, b, c], 'Summer', ['yt::1', 'yt::2', 'yt::3']);

      await later();
      await c.remove('Summer', 'yt::1');
      await settle([c, b, a]);
      for (final device in [a, b, c]) {
        expect((await device.songsOf('Summer'))!..sort(), ['yt::2', 'yt::3'],
            reason: device.name);
      }
    });

    test(
        'when one is deleted and one of the same name made while another Device still changes the first',
        () async {
      final a = await world.device('laptop');
      final b = await world.device('phone');
      await a.add('Road trip', [song('yt::1')]);
      await settle([a, b]);

      await later();
      await a.playlists.deletePlaylistByName('Road trip');
      await a.add('Road trip', [song('yt::2')]);
      await later();
      await b.add('Road trip', [song('yt::3')]);
      await settle([a, b]);
      await expectOne([a, b], 'Road trip', ['yt::1', 'yt::2', 'yt::3']);

      await later();
      await a.remove('Road trip', 'yt::3');
      await settle([a, b]);
      for (final device in [a, b]) {
        expect((await device.songsOf('Road trip'))!..sort(), ['yt::1', 'yt::2'],
            reason: device.name);
      }
    });
  });

  test(
      'an arrangement made before sync was enabled is kept and reaches the other Device',
      () async {
    final a = await world.device('laptop', enabled: false);
    await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
    await later();
    await a.add('Focus', [song('yt::4')]);
    await later();
    await a.add('Party', [song('yt::5')]);
    await a.arrange('Road trip', ['yt::2', 'yt::3', 'yt::1']);
    await a.arrangeLibrary(['Party', 'Road trip', 'Focus']);
    await a.enable();
    final b = await world.device('phone');
    await a.sync();
    await b.sync();
    await a.sync();

    for (final device in [a, b]) {
      expect(await device.libraryOrder(), ['Party', 'Road trip', 'Focus'],
          reason: device.name);
      expect(await device.songsOf('Road trip'), ['yt::2', 'yt::3', 'yt::1'],
          reason: device.name);
    }
  });

  group(
      'every data-access path that renames, edits, pins or reorders reaches the other Device:',
      () {
    // BackupDAO's restores are not listed: how a restore reaches the other
    // Devices is settled with restore under sync. Not listed either, as they
    // change nothing sync covers: normalizePositions (keeps the order) and
    // updatePlaylistThumbnail (artwork is not a synced detail).
    Future<PlaylistDB> row(SyncDevice d) async =>
        (await d.playlists.getPlaylistByName('Road trip')) ??
        (await d.playlists.getPlaylistByName('Summer'))!;
    Future<Object> details(SyncDevice d) async {
      final r = await row(d);
      return (r.name, r.description, r.isPinned);
    }

    Future<Object> songs(SyncDevice d) async =>
        (await d.playlists.getPlaylistTracks((await row(d)).id))
            .map((t) => t.mediaId)
            .join(',');
    Future<Object> library(SyncDevice d) async =>
        (await d.libraryOrder()).join(',');

    final paths = <String,
        (
      Future<void> Function(SyncDevice),
      Future<Object> Function(SyncDevice),
    )>{
      'PlaylistDAO.updatePlaylistMeta, renaming': (
        (d) async =>
            d.playlists.updatePlaylistMeta((await row(d)).id, name: 'Summer'),
        details,
      ),
      'PlaylistDAO.updatePlaylistMeta, describing': (
        (d) async => d.playlists
            .updatePlaylistMeta((await row(d)).id, description: 'A7'),
        details,
      ),
      'PlaylistDAO.putPlaylist': (
        (d) async => d.playlists.putPlaylist((await row(d))
          ..name = 'Summer'
          ..description = 'A7'
          ..isPinned = true),
        details,
      ),
      'PlaylistDAO.setPinned': (
        (d) async => d.playlists.setPinned((await row(d)).id, true),
        details,
      ),
      'PlaylistDAO.reorderTrack': (
        (d) async => d.playlists.reorderTrack((await row(d)).id, 0, 2),
        songs,
      ),
      'PlaylistDAO.setTrackOrder': (
        (d) async => d.playlists.setTrackOrder((await row(d)).id, [2, 0, 1]),
        songs,
      ),
      'PlaylistDAO.setPlaylistTracks': (
        (d) async => d.playlists.setPlaylistTracks(
            (await row(d)).id, [song('yt::3'), song('yt::1'), song('yt::2')]),
        songs,
      ),
      'PlaylistDAO.reorderPlaylists': (
        (d) async {
          final all = await d.playlists.getAllPlaylists();
          await d.playlists
              .reorderPlaylists([for (final p in all.reversed) p.id]);
        },
        library,
      ),
    };

    for (final MapEntry(key: path, value: (change, observe)) in paths.entries) {
      test(path, () async {
        final a = await world.device('laptop');
        final b = await world.device('phone');
        await a.add('Road trip', [song('yt::1'), song('yt::2'), song('yt::3')]);
        await a.add('Focus', [song('yt::4')]);
        await a.sync();
        await b.sync();
        final before = await observe(b);

        await later();
        await change(a);
        final after = await observe(a);
        expect(after, isNot(before), reason: 'it changed on the laptop');
        await a.sync();
        await b.sync();

        expect(await observe(b), after);
      });
    }
  });
}
