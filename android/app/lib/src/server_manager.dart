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

  /// Fired after the active server changes, so a reader that caches it can drop
  /// the cache. Set by whoever owns both this manager and that reader.
  void Function()? onActiveServerChanged;

  Future<List<ServerProfile>> list() async {
    retryPendingCleanups();
    return _api.listServers(dbPath: dbPath);
  }

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
    try {
      await _api.saveLibraries(
        dbPath: dbPath,
        serverId: profile.id,
        libraries: result.libraries,
      );
    } catch (e) {
      if (profile.credentialRef != null) {
        try {
          await _secrets.delete(profile.credentialRef!);
        } catch (_) {}
      }
      rethrow;
    }
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

    // Old credential is only cleaned up after both server profile and libraries are safely in SQLite
    if (existing.credentialRef != null &&
        existing.credentialRef != profile.credentialRef) {
      await _scheduleCleanup(existing.credentialRef!);
    }

    return profile;
  }

  Future<void> switchTo({required String serverId}) async {
    final currentId = await activeServerId();
    if (currentId != null && currentId != serverId) {
      try {
        await _api.sseStop(dbPath: dbPath, serverId: currentId);
      } catch (_) {}
    }
    await _api.setActiveServer(dbPath: dbPath, serverId: serverId);
    onActiveServerChanged?.call();
  }

  /// Deletes the profile and its secret (core clears the active state).
  Future<bool> delete({required String serverId}) async {
    // 1. Stop background SSE / sync for this server
    try {
      await _api.sseStop(dbPath: dbPath, serverId: serverId);
    } catch (_) {}

    final profile = await _api.getServer(dbPath: dbPath, serverId: serverId);

    // 2. Delete server from SQLite first
    final deleted = await _api.deleteServer(dbPath: dbPath, serverId: serverId);

    // 3. Only delete secret if SQLite deletion succeeded
    if (deleted && profile?.credentialRef != null) {
      await _scheduleCleanup(profile!.credentialRef!);
    }
    // The core clears the active id when the active profile goes away, so a
    // cached answer is stale either way. Cheaper to drop it unconditionally than
    // to work out whether this was the active one.
    if (deleted) onActiveServerChanged?.call();
    return deleted;
  }

  Future<String?> readSecret(String ref) => _secrets.read(ref);

  static const String _pendingCleanupsKey = 'comic_pending_cleanups';

  Future<void> _scheduleCleanup(String ref) async {
    try {
      await _secrets.delete(ref);
    } catch (_) {
      await _enqueuePendingCleanup(ref);
    }
  }

  Future<void> _enqueuePendingCleanup(String ref) async {
    try {
      final raw = await _secrets.read(_pendingCleanupsKey);
      final list =
          (raw != null && raw.isNotEmpty) ? raw.split(',') : <String>[];
      if (!list.contains(ref)) {
        list.add(ref);
        await _secrets.save(_pendingCleanupsKey, list.join(','));
      }
    } catch (_) {}
  }

  Future<void> retryPendingCleanups() async {
    try {
      final raw = await _secrets.read(_pendingCleanupsKey);
      if (raw == null || raw.isEmpty) return;
      final list = raw.split(',');
      final remaining = <String>[];
      for (final ref in list) {
        if (ref.isEmpty) continue;
        try {
          await _secrets.delete(ref);
        } catch (_) {
          remaining.add(ref);
        }
      }
      if (remaining.isEmpty) {
        await _secrets.delete(_pendingCleanupsKey);
      } else if (remaining.length != list.length) {
        await _secrets.save(_pendingCleanupsKey, remaining.join(','));
      }
    } catch (_) {}
  }

  Future<ServerProfile> _buildAndSave({
    required String displayName,
    required String baseUrl,
    required String apiKey,
    required List<String> capabilities,
    required String? existingId,
  }) async {
    final id = existingId ?? _newServerId();
    // Use collision-resistant reference with microseconds and random hex
    final ref = existingId == null
        ? 'keystore:$id'
        : 'keystore:${id}_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(0x7fffffff).toRadixString(16)}';

    await _secrets.save(ref, apiKey);

    // Readback verification
    final verified = await _secrets.read(ref);
    if (verified != apiKey) {
      try {
        await _secrets.delete(ref);
      } catch (_) {}
      throw const KeystoreException(
        'VERIFICATION_FAILED',
        'Failed to verify written secret in Keystore',
      );
    }

    final profile = ServerProfile(
      id: id,
      displayName: displayName,
      baseUrl: baseUrl,
      authType: AuthType.apiKey,
      credentialRef: ref,
      capabilities: capabilities,
      lastSuccessfulConnection: DateTime.now().toUtc().toIso8601String(),
    );

    try {
      await _api.saveServer(dbPath: dbPath, profile: profile);
    } catch (e) {
      try {
        await _secrets.delete(ref);
      } catch (_) {}
      rethrow;
    }

    return profile;
  }

  static String _newServerId() {
    final time = DateTime.now().microsecondsSinceEpoch;
    final rand = _random.nextInt(0x7fffffff);
    return 'server-$time-$rand';
  }
}
