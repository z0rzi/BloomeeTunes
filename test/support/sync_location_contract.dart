import 'dart:async';
import 'dart:convert';

import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:flutter_test/flutter_test.dart';

/// What one adapter provides to run the shared Sync Location contract.
class SyncLocationFixture {
  /// A reachable, empty Sync Location.
  final SyncLocation location;

  /// A Sync Location of the same kind that cannot be reached.
  final SyncLocation unreachable;

  /// Leaves [path] as a writer interrupted after sending [partial] would.
  final Future<void> Function(String path, List<int> partial) interruptWrite;

  final Future<void> Function() dispose;

  const SyncLocationFixture({
    required this.location,
    required this.unreachable,
    required this.interruptWrite,
    required this.dispose,
  });
}

/// The contract every Sync Location adapter passes (Seam 2).
void syncLocationContract(
    String adapter, Future<SyncLocationFixture> Function() open) {
  group('$adapter Sync Location contract', () {
    late SyncLocationFixture fixture;
    late SyncLocation location;

    setUp(() async {
      fixture = await open();
      location = fixture.location;
    });
    tearDown(() => fixture.dispose());

    List<int> text(String value) => utf8.encode(value);

    test('a written file reads back whole', () async {
      await location.write('sync/a.json', text('{"hello":1}'));
      expect(utf8.decode((await location.read('sync/a.json'))!), '{"hello":1}');
    });

    test('writing again replaces the whole file', () async {
      await location.write('sync/a.json', text('a much longer first version'));
      await location.write('sync/a.json', text('short'));
      expect(utf8.decode((await location.read('sync/a.json'))!), 'short');
    });

    test('a missing file reads as nothing', () async {
      expect(await location.read('sync/none.json'), isNull);
    });

    test('listing names the files of one directory only', () async {
      expect(await location.list('sync'), isEmpty);
      await location.write('sync/a.json', text('a'));
      await location.write('sync/b.json', text('b'));
      await location.write('backups/c.json', text('c'));
      expect((await location.list('sync'))..sort(), ['a.json', 'b.json']);
      expect(await location.list('backups'), ['c.json']);
    });

    test('a deleted file is gone, and deleting it again is harmless', () async {
      await location.write('sync/a.json', text('a'));
      await location.write('sync/b.json', text('b'));
      await location.delete('sync/a.json');
      expect(await location.read('sync/a.json'), isNull);
      expect(await location.list('sync'), ['b.json']);
      await location.delete('sync/a.json');
    });

    test('a reachable location says so', () async {
      await location.checkReachable();
    });

    test('an unreachable location refuses every operation', () async {
      final away = fixture.unreachable;
      final unavailable = throwsA(isA<SyncLocationUnavailable>());
      await expectLater(away.checkReachable(), unavailable);
      await expectLater(away.list('sync'), unavailable);
      await expectLater(away.read('sync/a.json'), unavailable);
      await expectLater(away.write('sync/a.json', text('a')), unavailable);
      await expectLater(away.delete('sync/a.json'), unavailable);
    });

    test('an interrupted write leaves the previous file for readers', () async {
      await location.write('sync/a.json', text('complete'));
      await fixture.interruptWrite('sync/a.json', text('compl'));
      expect(utf8.decode((await location.read('sync/a.json'))!), 'complete');
      expect(await location.list('sync'), ['a.json']);
      await fixture.interruptWrite('sync/new.json', text('half'));
      expect(await location.read('sync/new.json'), isNull);
      expect(await location.list('sync'), ['a.json']);
    });

    test('a reader during a write sees the old or the new file, never part',
        () async {
      final before = List<int>.filled(4 << 20, 0x61);
      final after = List<int>.filled(4 << 20, 0x62);
      await location.write('sync/big.json', before);
      final writing = location.write('sync/big.json', after);
      final seen = <String>{};
      var done = false;
      unawaited(writing.whenComplete(() => done = true));
      while (!done) {
        final bytes = await location.read('sync/big.json');
        final names = await location.list('sync');
        expect(names, ['big.json']);
        expect(bytes!.length, before.length);
        expect(bytes.every((b) => b == bytes.first), isTrue,
            reason: 'a reader saw a mix of two versions');
        seen.add(String.fromCharCode(bytes.first));
      }
      await writing;
      expect(seen, isNotEmpty);
      expect((await location.read('sync/big.json'))!.first, 0x62);
    });
  });
}
