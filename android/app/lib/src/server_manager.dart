import 'dart:math';

import 'auth_store.dart';
import 'rust/ffi/application.dart';
import 'rust/model/server_profile.dart';
import 'rust_core_api.dart';
import 'rust_core_frb.dart';

/// Server Profile management on top of the Rust Core (acceptance chain:
/// 添加服务器 → 登录 → 验证 Komga → 获取服务器信息 → 保存 Server Profile).
///
/// Secrets go through [SecretStore] (Android Keystore) and only a
/// `credentialRef` lands in the profile stored by the core.
class ServerManager {
  ServerManager({
    required this.dbPath,
    RustCoreApi? api,
    SecretStore? secrets,
  })  : _api = api ?? FrbRustCoreApi(),
        _secrets = secrets ?? const KeystoreSecretStore();

  final String dbPath;
  final RustCoreApi _api;
  final SecretStore _secrets;
  static final Random _random = Random();

  Future<List<ServerProfile>> list() => _api.listServers(dbPath: dbPath);

  Future<ServerProfile?> get({required String serverId}) =>
      _api.getServer(dbPath: dbPath, serverId: serverId);

  Future<String?> activeServerId() => _api.getActiveServer(dbPath: dbPath);

  /// Login + verify + fetch server info (version policy enforced in core).
  Future<ConnectionResult> testConnection({
    required String baseUrl,
    required String apiKey,
  }) =>
      _api.testConnection(baseUrl: baseUrl, apiKey: apiKey);

  /// Runs the acceptance chain for a NEW server, stores the secret, persists
  /// the profile (credentialRef + capabilities + last connection) and the
  /// mirrored libraries. Returns the saved profile.
  Future<ServerProfile> add({
    required String displayName,
    required String baseUrl,
    required String apiKey,
  }) async {
    final result = await _api.testConnection(baseUrl: baseUrl, apiKey: apiKey);
    final profile = await _buildAndSave(
      displayName: displayName,
      baseUrl: baseUrl,
      apiKey: apiKey,
      capabilities: result.capabilities,
      existingId: null,
    );
    await _api.saveLibraries(
      dbPath: dbPath,
      serverId: profile.id,
      libraries: result.libraries,
    );
    return profile;
  }

  /// Updates an existing profile after a successful re-connection.
  Future<ServerProfile> update({
    required ServerProfile existing,
    required String displayName,
    required String baseUrl,
    required String apiKey,
  }) async {
    final result = await _api.testConnection(baseUrl: baseUrl, apiKey: apiKey);
    final profile = await _buildAndSave(
      displayName: displayName,
      baseUrl: baseUrl,
      apiKey: apiKey,
      capabilities: result.capabilities,
      existingId: existing.id,
    );
    await _api.saveLibraries(
      dbPath: dbPath,
      serverId: profile.id,
      libraries: result.libraries,
    );
    return profile;
  }

  Future<void> switchTo({required String serverId}) =>
      _api.setActiveServer(dbPath: dbPath, serverId: serverId);

  /// Deletes the profile and its secret (core clears the active state).
  Future<bool> delete({required String serverId}) async {
    final profile = await _api.getServer(dbPath: dbPath, serverId: serverId);
    if (profile?.credentialRef != null) {
      await _secrets.delete(profile!.credentialRef!);
    }
    return _api.deleteServer(dbPath: dbPath, serverId: serverId);
  }

  Future<String?> readSecret(String ref) => _secrets.read(ref);

  Future<ServerProfile> _buildAndSave({
    required String displayName,
    required String baseUrl,
    required String apiKey,
    required List<String> capabilities,
    required String? existingId,
  }) async {
    final id = existingId ?? _newServerId();
    final ref = 'keystore:$id';
    await _secrets.save(ref, apiKey);
    final profile = ServerProfile(
      id: id,
      displayName: displayName,
      baseUrl: baseUrl,
      authType: AuthType.apiKey,
      credentialRef: ref,
      capabilities: capabilities,
      lastSuccessfulConnection: DateTime.now().toUtc().toIso8601String(),
    );
    await _api.saveServer(dbPath: dbPath, profile: profile);
    return profile;
  }

  static String _newServerId() {
    final time = DateTime.now().microsecondsSinceEpoch;
    final rand = _random.nextInt(0x7fffffff);
    return 'server-$time-$rand';
  }
}