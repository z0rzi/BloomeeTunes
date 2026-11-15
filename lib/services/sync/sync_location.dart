import 'dart:math';
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
  /// [SyncLocationUnavailable] (or [SyncLocationSignInRefused] for one that
  /// needs signing in).
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

/// The Sync Location no longer accepts this Device's sign-in (it expired, was
/// revoked, or there is none): only the owner signing in again helps.
final class SyncLocationSignInRefused extends SyncLocationException {
  const SyncLocationSignInRefused(super.message);
}

/// The Sync Location was reached but refused the operation for another
/// reason, such as being full.
final class SyncLocationFailed extends SyncLocationException {
  const SyncLocationFailed(super.message);
}

/// The Sync Location does not know the app Bloomee signs in as, as when
/// Dropbox answers `invalid_client` for a wrong app key: only the owner
/// correcting the app key helps.
final class SyncLocationAppRefused extends SyncLocationFailed {
  const SyncLocationAppRefused(super.message);
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

/// The hidden temporary files a Sync Location writes into before moving them
/// into place, where it may otherwise show a file while it arrives:
/// `.<name>.<random>.partial`, beside the file they become. They are never
/// listed.
abstract final class SyncTemporaryFiles {
  static final Random _random = Random.secure();

  /// Whether [name] is such a temporary file.
  static bool isTemporary(String name) =>
      name.startsWith('.') && name.endsWith('.partial');

  /// A new temporary file's name for writing the file [name].
  static String nameFor(String name) =>
      '.$name.${_random.nextInt(1 << 32).toRadixString(16)}.partial';
}
