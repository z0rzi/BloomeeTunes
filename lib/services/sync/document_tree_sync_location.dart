import 'package:Bloomee/services/sync/sync_location.dart';
import 'package:flutter/services.dart';

/// The local folder on Android: a folder the owner chose through the system
/// folder picker, which gives Bloomee lasting access to it (a tree URI,
/// `content://…/tree/…`), read and written through Android's Storage Access
/// Framework by the app's `SyncDocumentTree.kt`. No storage permission is needed.
///
/// The Storage Access Framework cannot replace a file in one step: a new
/// document cannot take a name in use. A write therefore goes to a hidden
/// temporary document (see [SyncTemporaryFiles]), then the file it replaces
/// is deleted and the temporary document renamed into its place. A reader
/// never finds part of a file, but may find none for that moment, or until
/// the next write if Bloomee is stopped within it. That is harmless to
/// sync: the others merge without this Device's Device State for one sync,
/// and nothing is forgotten. A replace in one step would need access to all
/// files, a permission Bloomee does not ask for.
class DocumentTreeSyncLocation implements SyncLocation {
  static const channel = MethodChannel('ls.bloomee/sync_document_tree');

  /// Whether [folder], as chosen, is such a folder rather than a path.
  static bool isDocumentTree(String folder) => folder.startsWith('content://');

  /// How to show the chosen [folder] to the owner: a tree URI as the place
  /// it names (`Sync/Bloomee` on the phone's own storage, `1A2B-3C4D:Music`
  /// on a memory card), a path as it is.
  static String describe(String folder) {
    if (!isDocumentTree(folder)) return folder;
    final segments = Uri.parse(folder).pathSegments;
    final at = segments.indexOf('tree');
    if (at < 0 || at + 1 >= segments.length) return folder;
    final place = segments[at + 1];
    // The whole of the phone's own storage keeps its name, `primary:`.
    return place.startsWith('primary:') && place.length > 'primary:'.length
        ? place.substring('primary:'.length)
        : place;
  }

  /// The tree URI of the chosen folder.
  final String tree;

  const DocumentTreeSyncLocation(this.tree);

  /// Calls [method] on Android's side for [tree], reporting any failure as
  /// an unreachable Sync Location: the folder is gone, its storage removed,
  /// its access revoked, or the storage refused the change.
  Future<T?> _call<T>(String method,
      [Map<String, Object?> arguments = const {}]) async {
    try {
      return await channel
          .invokeMethod<T>(method, {'tree': tree, ...arguments});
    } on PlatformException catch (error) {
      throw SyncLocationUnavailable('Local folder $tree: ${error.message}');
    } on MissingPluginException {
      throw SyncLocationUnavailable(
          'Local folder $tree can only be reached on Android.');
    }
  }

  /// [path]'s directory and name, as Android's side takes them.
  static Map<String, Object?> _at(String path) {
    final segments = syncPathSegments(path);
    return {
      'directory': segments.sublist(0, segments.length - 1),
      'name': segments.last,
    };
  }

  @override
  Future<List<String>> list(String directory) async => [
        for (final name in await _call<List<Object?>>(
                'list', {'directory': syncPathSegments(directory)}) ??
            const [])
          if (name is String && !SyncTemporaryFiles.isTemporary(name)) name
      ];

  @override
  Future<Uint8List?> read(String path) => _call<Uint8List>('read', _at(path));

  @override
  Future<void> write(String path, List<int> bytes) async {
    final target = _at(path);
    final name = target['name']! as String;
    final temporary = SyncTemporaryFiles.nameFor(name);
    String? written;
    try {
      written = await _call<String>('create', {
        ...target,
        'name': temporary,
        'bytes': bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      });
      if (written != temporary) {
        throw SyncLocationUnavailable(
            'Local folder $tree named the new file $written, not $temporary.');
      }
      await _call<void>('delete', target);
      written = await _call<String>(
          'rename', {...target, 'name': temporary, 'to': name});
      if (written != name) {
        throw SyncLocationUnavailable(
            'Local folder $tree named $path $written: another file took its '
            'name meanwhile.');
      }
    } catch (_) {
      if (written != null && written != name) {
        try {
          await _call<void>('delete', {...target, 'name': written});
        } on SyncLocationException {
          // Hidden, or not one the engine reads; a later write may succeed.
        }
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(String path) => _call<void>('delete', _at(path));

  @override
  Future<void> checkReachable() async {
    if (await _call<bool>('reachable') != true) {
      throw SyncLocationUnavailable(
          'Local folder $tree is not available, or Bloomee lost access to it.');
    }
  }
}
