import 'dart:io';

import 'package:Bloomee/services/sync/document_tree_sync_location.dart';
import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/document_tree_stand_in.dart';
import 'support/isar_test_support.dart';
import 'support/sync_location_contract.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  syncLocationContract('Android local folder', () async {
    final root = await createTestDirectory('bloomee_sync_tree_');
    final android = DocumentTreeStandIn.install();
    return SyncLocationFixture(
      location: DocumentTreeSyncLocation(android.treeFor(root.path)),
      unreachable: DocumentTreeSyncLocation(
          android.treeFor(p.join(root.path, 'deleted'))),
      // What a writer killed mid-write leaves: a partial temporary document.
      interruptWrite: (path, partial) async {
        final target = p.joinAll([root.path, ...path.split('/')]);
        await Directory(p.dirname(target)).create(recursive: true);
        await File(p.join(p.dirname(target),
                SyncTemporaryFiles.nameFor(p.basename(target))))
            .writeAsBytes(partial);
      },
      dispose: () => root.delete(recursive: true),
    );
  }, mayBrieflyShowNoFile: true);

  group('Android local folder', _adapterTests);
}

void _adapterTests() {
  late Directory root;
  late DocumentTreeStandIn android;

  setUp(() async {
    root = await createTestDirectory('bloomee_sync_tree_');
    android = DocumentTreeStandIn.install();
  });
  tearDown(() => root.delete(recursive: true));

  test(
      'a folder whose access was revoked is unreachable until it is granted again',
      () async {
    final tree = android.treeFor(root.path);
    final location = DocumentTreeSyncLocation(tree);
    await location.write('sync/a.json', [1]);

    android.granted.remove(tree);
    await expectLater(
        location.checkReachable(), throwsA(isA<SyncLocationUnavailable>()));
    await expectLater(
        location.read('sync/a.json'), throwsA(isA<SyncLocationUnavailable>()));

    android.granted.add(tree);
    expect(await location.read('sync/a.json'), [1]);
  });

  test(
      'a write whose name another file took meanwhile fails and leaves that file alone',
      () async {
    final location = DocumentTreeSyncLocation(android.treeFor(root.path));
    android.beforeRename =
        () => File(p.join(root.path, 'sync', 'a.json')).writeAsBytes([9]);

    await expectLater(location.write('sync/a.json', [1]),
        throwsA(isA<SyncLocationUnavailable>()));

    expect(await location.list('sync'), ['a.json']);
    expect(await location.read('sync/a.json'), [9]);
    expect(
        Directory(p.join(root.path, 'sync'))
            .listSync()
            .map((e) => p.basename(e.path)),
        ['a.json'],
        reason: 'no temporary or renamed copy is left behind');
  });

  test('a folder chosen on Android is shown by its place, not its URI', () {
    expect(
        DocumentTreeSyncLocation.describe(
            'content://com.android.externalstorage.documents/tree/primary%3ASync%2FBloomee'),
        'Sync/Bloomee');
    expect(
        DocumentTreeSyncLocation.describe(
            'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3AMusic'),
        '1A2B-3C4D:Music');
    expect(
        DocumentTreeSyncLocation.describe(
            'content://com.android.externalstorage.documents/tree/primary%3A'),
        'primary:');
    expect(DocumentTreeSyncLocation.describe('/home/me/Sync'), '/home/me/Sync');
  });
}
