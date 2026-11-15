import 'dart:io';
import 'dart:math';

import 'package:Bloomee/services/sync/document_tree_sync_location.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Android's side of the local folder, standing in inside a test: answers
/// the calls of [DocumentTreeSyncLocation.channel] the way the app's
/// `SyncDocumentTree.kt` does through the Storage Access Framework, on folders of
/// the test machine.
///
/// It keeps what makes the Storage Access Framework hard: a new document
/// fills as its content arrives; creating or renaming a document onto a name
/// already taken never replaces it, but gives the document another name
/// (`a (1).json`), as Android's own storage provider does; and a folder can
/// only be used while its grant is held and it is there.
class DocumentTreeStandIn {
  /// The folder each tree URI is, whether granted or not.
  final Map<String, String> _trees = {};

  /// The tree URIs whose grant the app holds.
  final Set<String> granted = {};

  /// Runs before each rename, as another app writing into the folder may.
  Future<void> Function()? beforeRename;

  DocumentTreeStandIn._();

  /// Installs a stand-in until the test ends.
  static DocumentTreeStandIn install() {
    final standIn = DocumentTreeStandIn._();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        DocumentTreeSyncLocation.channel, standIn._handle);
    addTearDown(() => messenger.setMockMethodCallHandler(
        DocumentTreeSyncLocation.channel, null));
    return standIn;
  }

  /// A tree URI, as the system folder picker returns, for [folder]; granted
  /// unless [grant] is false. It is the phone's own storage's unless another
  /// provider's [authority] and document [id] are given.
  String treeFor(String folder,
      {bool grant = true,
      String authority = 'com.android.externalstorage.documents',
      String? id}) {
    final documentId = id ?? 'primary:${p.basename(folder)}${_trees.length}';
    final tree = 'content://$authority/tree/${Uri.encodeComponent(documentId)}';
    _trees[tree] = folder;
    if (grant) granted.add(tree);
    return tree;
  }

  Future<Object?> _handle(MethodCall call) async {
    final arguments = (call.arguments as Map).cast<String, Object?>();
    final tree = arguments['tree']! as String;
    final root = _trees[tree];
    final reachable = root != null &&
        granted.contains(tree) &&
        await Directory(root).exists();
    if (call.method == 'reachable') return reachable;
    if (call.method == 'name' && reachable) return p.basename(root);
    if (!reachable) {
      throw PlatformException(
          code: 'unavailable', message: 'No access to the folder $tree');
    }
    final directory =
        p.joinAll([root, ...(arguments['directory']! as List).cast<String>()]);
    final name = arguments['name'] as String?;
    switch (call.method) {
      case 'list':
        if (!await Directory(directory).exists()) return <String>[];
        return [
          await for (final entry in Directory(directory).list())
            if (entry is File) p.basename(entry.path)
        ];
      case 'read':
        try {
          return await File(p.join(directory, name!)).readAsBytes();
        } on PathNotFoundException {
          // Gone, even if only just: `SyncDocumentTree.kt` answers the same.
          return null;
        }
      case 'create':
        await Directory(directory).create(recursive: true);
        final file = File(_unique(directory, name!));
        await _fill(file, arguments['bytes']! as Uint8List);
        return p.basename(file.path);
      case 'delete':
        final file = File(p.join(directory, name!));
        if (await file.exists()) await file.delete();
        return null;
      case 'rename':
        await beforeRename?.call();
        final file = File(p.join(directory, name!));
        if (!await file.exists()) {
          throw PlatformException(
              code: 'unavailable', message: 'No document $name');
        }
        final renamed =
            await file.rename(_unique(directory, arguments['to']! as String));
        return p.basename(renamed.path);
    }
    throw MissingPluginException(call.method);
  }

  /// [name] in [directory], or the name Android's storage provider gives
  /// instead when it is taken.
  static String _unique(String directory, String name) {
    final extension = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    var candidate = p.join(directory, name);
    for (var n = 1; File(candidate).existsSync(); n++) {
      candidate = p.join(directory, '$stem ($n)$extension');
    }
    return candidate;
  }

  /// Writes [bytes] into the new document [file] as a provider does, a piece
  /// at a time, so that a reader meanwhile sees part of them.
  static Future<void> _fill(File file, Uint8List bytes) async {
    final sink = await file.open(mode: FileMode.writeOnly);
    try {
      const piece = 1 << 20;
      var start = 0;
      do {
        final end = min(start + piece, bytes.length);
        await sink.writeFrom(bytes, start, end);
        await sink.flush();
        await Future<void>.delayed(Duration.zero);
        start = end;
      } while (start < bytes.length);
    } finally {
      await sink.close();
    }
  }
}
