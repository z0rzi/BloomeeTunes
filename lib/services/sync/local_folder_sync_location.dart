import 'dart:io';
import 'dart:typed_data';

import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:path/path.dart' as p;

/// A folder on this machine that another tool carries between machines.
///
/// A write goes to a hidden temporary file beside its target (see
/// [SyncTemporaryFiles]) and is then renamed into place, so a reader only
/// ever finds complete files.
class LocalFolderSyncLocation implements SyncLocation {
  /// The chosen folder. It must already exist: a missing folder (an unmounted
  /// drive, say) makes the Sync Location unreachable rather than recreated.
  final String root;

  const LocalFolderSyncLocation(this.root);

  String _resolve(String path) => p.joinAll([root, ...syncPathSegments(path)]);

  /// Runs [operation] once the folder is known to be there, reporting file
  /// system failures as an unreachable Sync Location.
  Future<T> _guard<T>(Future<T> Function() operation) async {
    await checkReachable();
    try {
      return await operation();
    } on FileSystemException catch (error) {
      throw SyncLocationUnavailable('Local folder $root: ${error.message}');
    }
  }

  @override
  Future<List<String>> list(String directory) => _guard(() async {
        final folder = Directory(_resolve(directory));
        if (!await folder.exists()) return [];
        final names = <String>[];
        await for (final entry in folder.list(followLinks: false)) {
          final name = p.basename(entry.path);
          if (entry is File && !SyncTemporaryFiles.isTemporary(name)) {
            names.add(name);
          }
        }
        return names;
      });

  @override
  Future<Uint8List?> read(String path) => _guard(() async {
        try {
          return await File(_resolve(path)).readAsBytes();
        } on PathNotFoundException {
          return null;
        }
      });

  @override
  Future<void> write(String path, List<int> bytes) => _guard(() async {
        final target = File(_resolve(path));
        await target.parent.create(recursive: true);
        final temporary = File(p.join(target.parent.path,
            SyncTemporaryFiles.nameFor(p.basename(target.path))));
        try {
          await temporary.writeAsBytes(bytes, flush: true);
          await temporary.rename(target.path);
        } catch (_) {
          try {
            await temporary.delete();
          } on FileSystemException {
            // Nothing was left behind.
          }
          rethrow;
        }
      });

  @override
  Future<void> delete(String path) => _guard(() async {
        try {
          await File(_resolve(path)).delete();
        } on PathNotFoundException {
          // Already gone.
        }
      });

  @override
  Future<void> checkReachable() async {
    if (!await Directory(root).exists()) {
      throw SyncLocationUnavailable('Local folder $root is not available.');
    }
  }
}
