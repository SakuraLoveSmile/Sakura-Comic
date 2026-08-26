import 'package:comic_app/src/rust/ffi/application.dart';
import 'package:comic_app/src/rust/model/server.dart';
import 'package:comic_app/src/rust/model/server_profile.dart';
import 'package:comic_app/src/rust/store/series.dart';
import 'package:comic_app/src/rust/store/thumbnails.dart';
import 'package:comic_app/src/rust/sync/bootstrap.dart';
import 'package:comic_app/src/rust_core_api.dart';

/// In-memory fake of the FFI surface, recording probe calls like the real
/// core would (fixture-shaped probe result).
class MemoryRustCoreApi extends RustCoreApi {
  final Map<String, ServerProfile> servers = {};
  final Map<String, List<Library>> librariesByServer = {};
  String? activeId;
  String? probedUrl;
  String? probedKey;

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