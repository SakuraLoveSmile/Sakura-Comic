import 'package:flutter_test/flutter_test.dart';

import 'package:comic_app/src/auth_store.dart';
import 'package:comic_app/src/rust/ffi/application.dart';
import 'package:comic_app/src/rust/model/server.dart';
import 'package:comic_app/src/rust/model/server_profile.dart';
import 'package:comic_app/src/rust/store/series.dart';
import 'package:comic_app/src/rust/store/thumbnails.dart';
import 'package:comic_app/src/rust/sync/bootstrap.dart';
import 'package:comic_app/src/rust_core_api.dart';
import 'package:comic_app/src/server_manager.dart';

void main() {
  group('ServerManager acceptance chain', () {
    test('add → login(test) → verify → info → save profile + secret', () async {
      final api = _MemoryRustCoreApi();
      final secrets = InMemorySecretStore();
      final manager = ServerManager(
        dbPath: '/tmp/test.sqlite',
        api: api,
        secrets: secrets,
      );

      final profile = await manager.add(
        displayName: 'Home',
        baseUrl: 'http://192.168.0.69:25600',
        apiKey: 'secret-key',
      );

      // 登录/验证/信息：probe hit with the given credentials.
      expect(api.probedUrl, 'http://192.168.0.69:25600');
      expect(api.probedKey, 'secret-key');
      // 保存 Server Profile：secret in keystore store, ref on the profile.
      expect(profile.credentialRef, 'keystore:${profile.id}');
      expect(await secrets.read(profile.credentialRef!), 'secret-key');
      expect(await secrets.read('keystore:${profile.id}'), 'secret-key');
      // capabilities + libraries persisted with (serverId, remoteId).
      final saved = api.servers[profile.id]!;
      expect(saved.capabilities, contains('libraries:2'));
      expect(saved.lastSuccessfulConnection, isNotNull);
      expect(api.librariesByServer[profile.id]!.length, 2);

      // switch server.
      await manager.switchTo(serverId: profile.id);
      expect(await manager.activeServerId(), profile.id);
    });

    test('update keeps id and refreshes capabilities', () async {
      final api = _MemoryRustCoreApi();
      final manager = ServerManager(
        dbPath: '/tmp/test.sqlite',
        api: api,
        secrets: InMemorySecretStore(),
      );
      final first = await manager.add(
        displayName: 'Home',
        baseUrl: 'http://a.local:25600',
        apiKey: 'k1',
      );
      final updated = await manager.update(
        existing: first,
        displayName: 'Home Renamed',
        baseUrl: 'http://b.local:25600',
        apiKey: 'k2',
      );
      expect(updated.id, first.id);
      expect(updated.displayName, 'Home Renamed');
      expect(updated.baseUrl, 'http://b.local:25600');
      expect(api.servers.length, 1);
    });

    test('delete removes profile and secret', () async {
      final api = _MemoryRustCoreApi();
      final secrets = InMemorySecretStore();
      final manager = ServerManager(
        dbPath: '/tmp/test.sqlite',
        api: api,
        secrets: secrets,
      );
      final profile = await manager.add(
        displayName: 'Home',
        baseUrl: 'http://a.local:25600',
        apiKey: 'k1',
      );
      expect(await secrets.read(profile.credentialRef!), 'k1');

      final deleted = await manager.delete(serverId: profile.id);
      expect(deleted, isTrue);
      expect(secrets.isEmpty, isTrue);
      expect(api.servers, isEmpty);
      expect(api.stoppedSseServerId, profile.id);
    });

    test(
        'F09: verification failure during add rolls back secret and throws KeystoreException',
        () async {
      final api = _MemoryRustCoreApi();
      final secrets = _FailingReadSecretStore();
      final manager = ServerManager(
        dbPath: '/tmp/test.sqlite',
        api: api,
        secrets: secrets,
      );

      await expectLater(
        () => manager.add(
          displayName: 'Faulty',
          baseUrl: 'http://a.local:25600',
          apiKey: 'key-to-fail',
        ),
        throwsA(isA<KeystoreException>()),
      );

      expect(secrets.deletedKeys, contains(startsWith('keystore:')));
      expect(api.servers, isEmpty);
    });

    test('F09: SQLite saveServer failure rolls back secret and rethrows',
        () async {
      final api = _MemoryRustCoreApi()..failSaveServer = true;
      final secrets = InMemorySecretStore();
      final manager = ServerManager(
        dbPath: '/tmp/test.sqlite',
        api: api,
        secrets: secrets,
      );

      await expectLater(
        () => manager.add(
          displayName: 'FaultyDb',
          baseUrl: 'http://a.local:25600',
          apiKey: 'key-to-rollback',
        ),
        throwsA(isA<StateError>()),
      );

      expect(secrets.isEmpty, isTrue);
      expect(api.servers, isEmpty);
    });

    test(
        'F09: update cleans up old credential ref only after SQLite save succeeds',
        () async {
      final api = _MemoryRustCoreApi();
      final secrets = InMemorySecretStore();
      final manager = ServerManager(
        dbPath: '/tmp/test.sqlite',
        api: api,
        secrets: secrets,
      );

      final initial = await manager.add(
        displayName: 'Initial',
        baseUrl: 'http://a.local:25600',
        apiKey: 'initial-key',
      );
      final initialRef = initial.credentialRef!;
      expect(await secrets.read(initialRef), 'initial-key');

      final updated = await manager.update(
        existing: initial,
        displayName: 'Updated',
        baseUrl: 'http://a.local:25600',
        apiKey: 'new-key',
      );

      expect(updated.credentialRef, isNot(initialRef));
      expect(await secrets.read(initialRef), isNull);
      expect(await secrets.read(updated.credentialRef!), 'new-key');
    });

    test(
        'F09: delete stops SSE and leaves secret intact if SQLite delete fails',
        () async {
      final api = _MemoryRustCoreApi()..failDeleteServer = true;
      final secrets = InMemorySecretStore();
      final manager = ServerManager(
        dbPath: '/tmp/test.sqlite',
        api: api,
        secrets: secrets,
      );

      final profile = await manager.add(
        displayName: 'Undeletable',
        baseUrl: 'http://a.local:25600',
        apiKey: 'safe-key',
      );

      final deleted = await manager.delete(serverId: profile.id);
      expect(deleted, isFalse);
      expect(api.stoppedSseServerId, profile.id);
      expect(await secrets.read(profile.credentialRef!), 'safe-key');
    });
  });
}

/// In-memory fake of the FFI surface, recording probe calls like the real
/// core would (fixture-shaped probe result).
class _MemoryRustCoreApi extends RustCoreApi {
  final Map<String, ServerProfile> servers = {};
  final Map<String, List<Library>> librariesByServer = {};
  String? activeId;
  String? probedUrl;
  String? probedKey;
  String? stoppedSseServerId;
  bool failSaveServer = false;
  bool failDeleteServer = false;

  @override
  Future<void> sseStop({
    required String dbPath,
    required String serverId,
  }) async {
    stoppedSseServerId = serverId;
  }

  @override
  Future<ConnectionResult> testConnection({
    required String baseUrl,
    required String apiKey,
  }) async {
    probedUrl = baseUrl;
    probedKey = apiKey;
    return const ConnectionResult(
      serverInfo: ServerInfo(build: BuildInfo(version: '1.26.3')),
      serverVersion: '1.26.3',
      libraries: [
        Library(id: 'l1', name: 'Manga', root: '/mnt/manga'),
        Library(id: 'l2', name: 'Comics', root: '/mnt/comics'),
      ],
      capabilities: ['libraries:2'],
    );
  }

  @override
  Future<BootstrapSummary> bootstrap({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) async =>
      BootstrapSummary(
        serverId: serverId,
        syncedSeries: BigInt.zero,
        totalElements: 0,
        hasMorePages: false,
      );

  @override
  Future<List<SeriesRow>> fetchSeries({
    required String dbPath,
    required String serverId,
    int limit = 50,
    int offset = 0,
  }) async =>
      const [];

  @override
  Future<List<ServerProfile>> listServers({required String dbPath}) async =>
      servers.values.toList();

  @override
  Future<void> saveServer({
    required String dbPath,
    required ServerProfile profile,
  }) async {
    if (failSaveServer) {
      throw StateError('Simulated SQLite disk write failure');
    }
    servers[profile.id] = profile;
  }

  @override
  Future<ServerProfile?> getServer({
    required String dbPath,
    required String serverId,
  }) async =>
      servers[serverId];

  @override
  Future<bool> deleteServer({
    required String dbPath,
    required String serverId,
  }) async {
    if (failDeleteServer) {
      return false;
    }
    if (activeId == serverId) activeId = null;
    librariesByServer.remove(serverId);
    return servers.remove(serverId) != null;
  }

  @override
  Future<void> saveLibraries({
    required String dbPath,
    required String serverId,
    required List<Library> libraries,
  }) async {
    librariesByServer[serverId] = libraries;
  }

  @override
  Future<void> setActiveServer({
    required String dbPath,
    required String serverId,
  }) async {
    activeId = serverId;
  }

  @override
  Future<String?> getActiveServer({required String dbPath}) async => activeId;

  @override
  Future<String?> coverPath({
    required String dbPath,
    required String serverId,
    required String seriesId,
  }) async =>
      null;

  @override
  Future<Map<String, String>> coverPaths({
    required String dbPath,
    required String serverId,
    required String variant,
    required List<String> remoteIds,
  }) async =>
      const {};

  @override
  Future<List<ThumbnailRow>> listThumbnails({
    required String dbPath,
    required String serverId,
  }) async =>
      const [];

  @override
  Future<String> ensureCover({
    required String dbPath,
    required String serverId,
    required String seriesId,
    required String baseUrl,
    required String apiKey,
  }) async =>
      '';

  @override
  Future<int> ensureCovers({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) async =>
      0;

  @override
  Future<BootstrapSummary> bootstrapDemo({
    required String dbPath,
    required String serverId,
  }) async =>
      BootstrapSummary(
        serverId: serverId,
        syncedSeries: BigInt.zero,
        totalElements: 0,
        hasMorePages: false,
      );
}

class _FailingReadSecretStore implements SecretStore {
  final Map<String, String> _secrets = {};
  final List<String> deletedKeys = [];

  @override
  Future<void> save(String ref, String secret) async {
    _secrets[ref] = secret;
  }

  @override
  Future<String?> read(String ref) async {
    // Simulates returning corrupted data / bad verification
    return 'corrupted-secret-value';
  }

  @override
  Future<void> delete(String ref) async {
    deletedKeys.add(ref);
    _secrets.remove(ref);
  }
}
