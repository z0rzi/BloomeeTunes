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

  group('a folder chosen on Android is shown by its place, not its URI', () {
    const storage = 'content://com.android.externalstorage.documents/tree/';
    const downloads =
        'content://com.android.providers.downloads.documents/tree/';
    String tree(String authority, String id) =>
        '$authority${Uri.encodeComponent(id)}';

    test('a folder of the phone\'s own storage, or its Documents', () {
      expect(
          DocumentTreeSyncLocation.placeOf(
              tree(storage, 'primary:Sync/Bloomee')),
          'Sync/Bloomee');
      expect(DocumentTreeSyncLocation.placeOf(tree(storage, 'primary:')), '/');
      expect(DocumentTreeSyncLocation.placeOf(tree(storage, 'home:Bloomee')),
          'Documents/Bloomee');
      expect(DocumentTreeSyncLocation.placeOf(tree(storage, 'home:')),
          'Documents');
    });

    test('a folder of a memory card', () {
      expect(
          DocumentTreeSyncLocation.placeOf(
              tree(storage, '1A2B-3C4D:Music/Sync')),
          '1A2B-3C4D/Music/Sync');
      expect(DocumentTreeSyncLocation.placeOf(tree(storage, '1A2B-3C4D:')),
          '1A2B-3C4D');
    });

    test('a folder picked under Downloads', () {
      expect(
          DocumentTreeSyncLocation.placeOf(tree(
              downloads, 'raw:/storage/emulated/0/Download/BloomeeSyncTest')),
          'Download/BloomeeSyncTest');
      expect(
          DocumentTreeSyncLocation.placeOf(
              tree(downloads, 'raw:/storage/1A2B-3C4D/Download/Sync')),
          '1A2B-3C4D/Download/Sync');
      expect(DocumentTreeSyncLocation.placeOf(tree(downloads, 'downloads')),
          'Download');
    });

    test('an ID that names no place shows the folder\'s own name', () async {
      final root = await createTestDirectory('bloomee_sync_tree_');
      addTearDown(() => root.delete(recursive: true));
      final android = DocumentTreeStandIn.install();
      final folder =
          await Directory(p.join(root.path, 'BloomeeSyncTest')).create();
      for (final id in ['msf:123', '42']) {
        final opaque = android.treeFor(folder.path,
            authority: 'com.android.providers.downloads.documents', id: id);
        expect(DocumentTreeSyncLocation.placeOf(opaque), isNull);
        expect(await DocumentTreeSyncLocation(opaque).describe(),
            'BloomeeSyncTest');
      }
      final elsewhere = android.treeFor(folder.path,
          authority: 'com.example.cloud.documents', id: 'primary:Sync');
      expect(DocumentTreeSyncLocation.placeOf(elsewhere), isNull,
          reason: 'only Android\'s own storage names IDs after places');
      expect(await DocumentTreeSyncLocation(elsewhere).describe(),
          'BloomeeSyncTest');
    });

    test('a folder that cannot be reached still shows something', () async {
      DocumentTreeStandIn.install();
      final gone = tree(downloads, 'msf:123');
      expect(await DocumentTreeSyncLocation(gone).describe(), 'msf:123');
      expect(
          await DocumentTreeSyncLocation(tree(storage, 'primary:Sync'))
              .describe(),
          'Sync');
    });
  });
}
