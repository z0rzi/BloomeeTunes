import 'dart:io';

import 'package:Bloomee/services/sync/local_folder_sync_location.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/sync_location_contract.dart';

void main() {
  syncLocationContract('local folder', () async {
    final root = await Directory.systemTemp.createTemp('bloomee_sync_folder_');
    return SyncLocationFixture(
      location: LocalFolderSyncLocation(root.path),
      unreachable: LocalFolderSyncLocation(p.join(root.path, 'unmounted')),
      // What a writer killed mid-write leaves: a partial temporary file.
      interruptWrite: (path, partial) async {
        final target = p.joinAll([root.path, ...path.split('/')]);
        await Directory(p.dirname(target)).create(recursive: true);
        await File(p.join(p.dirname(target),
                LocalFolderSyncLocation.temporaryNameFor(p.basename(target))))
            .writeAsBytes(partial);
      },
      dispose: () => root.delete(recursive: true),
    );
  });

  test('the local folder writes to a temporary name and renames it into place',
      () async {
    final root = await Directory.systemTemp.createTemp('bloomee_sync_folder_');
    addTearDown(() => root.delete(recursive: true));
    final location = LocalFolderSyncLocation(root.path);
    await location.write('sync/a.json', [1]);
    final folder = p.join(root.path, 'sync');
    final events = <FileSystemEvent>[];
    final watching = Directory(folder).watch().listen(events.add);
    await location.write('sync/a.json', [2]);
    final target = p.join(folder, 'a.json');
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!events.any((e) => e is FileSystemMoveEvent) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await watching.cancel();
    final move = events.whereType<FileSystemMoveEvent>().single;
    expect(move.destination, target);
    expect(
        LocalFolderSyncLocation.isTemporaryName(p.basename(move.path)), isTrue);
    expect(events.where((e) => e.path == target && e is! FileSystemMoveEvent),
        isEmpty,
        reason: 'the target itself must never be written in place');
    expect(
        await Directory(folder).list().map((e) => p.basename(e.path)).toList(),
        ['a.json']);
  }, skip: Platform.isLinux ? false : 'Relies on inotify move events.');
}
