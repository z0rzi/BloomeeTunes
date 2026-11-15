import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where this Device keeps the credentials of its Sync Location, apart from
/// the database, Device States and backups.
abstract interface class CredentialStore {
  /// The value kept under [key], or null.
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  /// Removes [key]; a missing key is not an error.
  Future<void> delete(String key);
}

/// The credential store cannot be used now, as when the system keyring is
/// missing or locked.
class CredentialStoreUnavailable implements Exception {
  final String message;
  const CredentialStoreUnavailable(this.message);

  @override
  String toString() => 'CredentialStoreUnavailable: $message';
}

/// The system keyring: the Android Keystore, or the desktop secret service
/// (such as GNOME Keyring or KWallet) on Linux.
class KeyringCredentialStore implements CredentialStore {
  final FlutterSecureStorage _storage;

  const KeyringCredentialStore() : _storage = const FlutterSecureStorage();

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on PlatformException catch (error) {
      throw CredentialStoreUnavailable(
          'The system keyring cannot be used: ${error.message ?? error.code}');
    } on MissingPluginException catch (error) {
      throw CredentialStoreUnavailable(
          'There is no system keyring here: ${error.message}');
    }
  }

  @override
  Future<String?> read(String key) => _guard(() => _storage.read(key: key));

  @override
  Future<void> write(String key, String value) =>
      _guard(() => _storage.write(key: key, value: value));

  @override
  Future<void> delete(String key) => _guard(() => _storage.delete(key: key));
}
