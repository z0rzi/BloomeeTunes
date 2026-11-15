import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:Bloomee/services/db/db_provider.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;

Future<void> initializeTestIsar() async {
  var library = Platform.environment['ISAR_TEST_LIBRARY'];
  if (library == null) {
    final config = File('.dart_tool/package_config.json').absolute;
    final packages = (jsonDecode(await config.readAsString())
        as Map<String, dynamic>)['packages'] as List<dynamic>;
    final package = packages
        .cast<Map<String, dynamic>>()
        .singleWhere((entry) => entry['name'] == 'isar_community_flutter_libs');
    final rootUri = package['rootUri'] as String;
    final root =
        config.uri.resolve(rootUri.endsWith('/') ? rootUri : '$rootUri/');
    final relativePath = switch (Platform.operatingSystem) {
      'windows' => 'windows/libisar.dll',
      'linux' => 'linux/libisar.so',
      'macos' => 'macos/libisar.dylib',
      _ => throw UnsupportedError('Database tests require a desktop host.'),
    };
    library = root.resolve(relativePath).toFilePath();
  }
  await Isar.initializeIsarCore(libraries: {Abi.current(): library});
}

/// A new, empty directory for a test's database and files, made in memory
/// (`/dev/shm`) on a Linux machine that has one, else in the system's temporary
/// directory.
///
/// Isar flushes every write transaction to disk, and a test run keeps the disk
/// busy writing out each test file's compiled code: on disk, those flushes can
/// take seconds each, and the database tests then time out.
Future<Directory> createTestDirectory(String prefix) async {
  if (Platform.isLinux) {
    try {
      return await Directory('/dev/shm').createTemp(prefix);
    } on FileSystemException {
      // No memory file system: the system's temporary directory will do.
    }
  }
  return Directory.systemTemp.createTemp(prefix);
}

/// Completes once every open queued on this isolate has finished.
Future<void> _opening = Future.value();

/// Opens a test's database in [directory] (from [createTestDirectory]), under
/// [name] or else a name no other test uses, once any other open on this
/// isolate has finished.
///
/// A test that times out keeps running alongside the next one, so the two
/// tests' opens can overlap and give two Dart handles on one Isar database in
/// one isolate. A write on one handle then waits forever on a write held open
/// on the other, and no timeout can end the wait: the whole run hangs. Two
/// things lead there. Opening a name that is already open returns the open
/// database, whatever the directory. And two opens in progress at once on one
/// isolate can both return the second one's database.
Future<Isar> openTestDatabase(Directory directory, {String? name}) {
  final open = _opening.then((_) => Isar.open(DBProvider.schemas,
      directory: directory.path,
      name: name ?? p.basename(directory.path),
      inspector: false));
  _opening = open.then((_) {}, onError: (Object _) {});
  return open;
}
