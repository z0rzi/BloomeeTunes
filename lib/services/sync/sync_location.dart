import 'dart:typed_data';

/// The single place a Device syncs with (see `GLOSSARY.md`).
///
/// Paths are relative and `/`-separated, such as `sync/<device id>.json`.
/// Every adapter makes [write] all-or-nothing from a reader's point of view:
/// a reader sees either the previous content or the new content, never part
/// of it.
abstract interface class SyncLocation {
  /// Names of the files directly inside [directory]; empty when it is missing.
  Future<List<String>> list(String directory);

  /// The whole content of [path], or null when there is no such file.
  Future<Uint8List?> read(String path);

  /// Replaces [path] with [bytes] in one step, creating its directory.
  Future<void> write(String path, List<int> bytes);

  /// Removes [path]; a missing file is not an error.
  Future<void> delete(String path);

  /// Completes when the Sync Location can be used, otherwise throws
  /// [SyncLocationUnavailable].
  Future<void> checkReachable();
}

/// A Sync Location operation that could not be carried out.
sealed class SyncLocationException implements Exception {
  final String message;
  const SyncLocationException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// The Sync Location cannot be reached now; trying again later may succeed.
final class SyncLocationUnavailable extends SyncLocationException {
  const SyncLocationUnavailable(super.message);
}

/// Rejects paths that could leave the Sync Location.
List<String> syncPathSegments(String path) {
  final segments = path.split('/');
  if (path.isEmpty ||
      segments
          .any((s) => s.isEmpty || s == '.' || s == '..' || s.contains(r'\'))) {
    throw ArgumentError.value(
        path, 'path', 'Not a relative Sync Location path');
  }
  return segments;
}
