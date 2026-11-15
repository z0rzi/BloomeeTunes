import 'dart:async';
import 'dart:isolate';

import 'package:Bloomee/services/db/global_db.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/isar_test_support.dart';

/// Two tests whose databases are open at the same time, as when a test times
/// out and keeps running alongside the next one: the first holds a write open
/// while the second writes. Returns how many settings each database holds.
Future<List<int>> _settingCountsAfterOverlappingTests() async {
  await initializeTestIsar();
  final directories = [
    await createTestDirectory('bloomee_overlap_'),
    await createTestDirectory('bloomee_overlap_'),
  ];
  // The second open starts before the first has finished.
  final opening = [
    for (final directory in directories) openTestDatabase(directory)
  ];
  final timedOut = await opening[0];
  final next = await opening[1];
  final written = Completer<void>();
  final held = Completer<void>();
  final writing = timedOut.writeTxn(() async {
    await timedOut.appSettingsStrDBs
        .put(AppSettingsStrDB(settingName: 'timed out', settingValue: '1'));
    written.complete();
    await held.future;
  });
  await written.future;
  next.writeTxnSync(() => next.appSettingsStrDBs
      .putSync(AppSettingsStrDB(settingName: 'next', settingValue: '1')));
  held.complete();
  await writing;
  final counts = [
    await timedOut.appSettingsStrDBs.count(),
    await next.appSettingsStrDBs.count(),
  ];
  await timedOut.close();
  await next.close();
  for (final directory in directories) {
    await directory.delete(recursive: true);
  }
  return counts;
}

void main() {
  test(
      'a test that times out holding a write open does not block the next '
      "test's database, nor share it", () async {
    // Off the test's own isolate: were a write to wait forever, it would block
    // that isolate, and this test could only hang instead of failing.
    final counts = await Isolate.run(_settingCountsAfterOverlappingTests)
        .timeout(const Duration(seconds: 20));
    expect(counts, [1, 1]);
  });
}
