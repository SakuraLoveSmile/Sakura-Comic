import 'package:flutter/services.dart';

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

  static const MethodChannel _channel = MethodChannel('com.example.comic/auth_store');

  @override
  Future<void> save(String ref, String secret) async {
    await _channel.invokeMethod<bool>('save', {'ref': ref, 'secret': secret});
  }

  @override
  Future<String?> read(String ref) async =>
      await _channel.invokeMethod<String>('read', {'ref': ref});

  @override
  Future<void> delete(String ref) async {
    await _channel.invokeMethod<bool>('delete', {'ref': ref});
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