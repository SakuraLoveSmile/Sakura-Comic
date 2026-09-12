import 'package:flutter/services.dart';

/// Thrown when an Android Keystore or platform credential operation fails.
class KeystoreException implements Exception {
  const KeystoreException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'KeystoreException($code: $message)';
}

/// Secret store contract — credentials live in platform secure storage
/// (Android Keystore via the platform channel; Keychain on Apple), never in
/// the SQLite mirror. `ref` is the keychain/keystore identifier carried by
/// `ServerProfile.credentialRef`.
abstract interface class SecretStore {
  Future<void> save(String ref, String secret);
  Future<String?> read(String ref);
  Future<void> delete(String ref);
}

/// Android Keystore-backed store (AES-GCM master key in AndroidKeyStore,
/// ciphertext in SharedPreferences) implemented in MainActivity.kt.
class KeystoreSecretStore implements SecretStore {
  const KeystoreSecretStore();

  static const MethodChannel _channel =
      MethodChannel('dev.sakurasep.comic/auth_store');

  @override
  Future<void> save(String ref, String secret) async {
    try {
      final success = await _channel
          .invokeMethod<bool>('save', {'ref': ref, 'secret': secret});
      if (success != true) {
        throw const KeystoreException(
            'SAVE_FAILED', 'Keystore save returned false');
      }
    } on PlatformException catch (e) {
      throw KeystoreException(e.code, e.message ?? 'Keystore save failed');
    }
  }

  @override
  Future<String?> read(String ref) async {
    try {
      return await _channel.invokeMethod<String>('read', {'ref': ref});
    } on PlatformException catch (e) {
      throw KeystoreException(e.code, e.message ?? 'Keystore read failed');
    }
  }

  @override
  Future<void> delete(String ref) async {
    try {
      final success = await _channel.invokeMethod<bool>('delete', {'ref': ref});
      if (success != true) {
        throw const KeystoreException(
            'DELETE_FAILED', 'Keystore delete returned false');
      }
    } on PlatformException catch (e) {
      throw KeystoreException(e.code, e.message ?? 'Keystore delete failed');
    }
  }
}

/// In-memory fallback so widget tests and stub mode can run without the
/// platform channel. Never used in production flows when FFI is present.
class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, String>? seed]) : _secrets = {...?seed};

  final Map<String, String> _secrets;

  /// True when no secret is stored (test helper for deletion assertions).
  bool get isEmpty => _secrets.isEmpty;

  @override
  Future<void> save(String ref, String secret) async => _secrets[ref] = secret;

  @override
  Future<String?> read(String ref) async => _secrets[ref];

  @override
  Future<void> delete(String ref) async => _secrets.remove(ref);
}
