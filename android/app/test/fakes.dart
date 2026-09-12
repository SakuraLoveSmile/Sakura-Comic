import 'package:comic_app/src/library_repository.dart';
import 'package:comic_app/src/models.dart';
import 'package:comic_app/src/rust/ffi/application.dart';
import 'package:comic_app/src/rust/model/server.dart';
import 'package:comic_app/src/rust/model/server_profile.dart';
import 'package:comic_app/src/rust/store/query.dart' show SeriesPageResult;
import 'package:comic_app/src/rust/store/series.dart';
import 'package:comic_app/src/rust/store/thumbnails.dart';
import 'package:comic_app/src/rust/sync/bootstrap.dart';
import 'package:comic_app/src/rust_core_api.dart';
import 'package:comic_app/src/series.dart';

/// In-memory fake of the FFI surface, recording probe calls like the real
/// core would (fixture-shaped probe result).
class MemoryRustCoreApi extends RustCoreApi {
  final Map<String, ServerProfile> servers = {};
  final Map<String, List<Library>> librariesByServer = {};
  String? activeId;
  String? probedUrl;
  String? probedKey;

  /// FFI round trips spent working out which server is active. A repository that
  /// resolves this per query pays two per query; one that memoizes pays two for
  /// a whole refresh.
  int listServersCalls = 0;
  int getActiveServerCalls = 0;

  int get activeServerProbes => listServersCalls + getActiveServerCalls;

  /// Which server the last `querySeries` was issued against, and how many were
  /// issued. This is the observable that proves the repository re-resolved the
  /// active server rather than trusting a stale cache.
  String? lastQueryServerId;
  int querySeriesCalls = 0;
  int? lastQueryLimit;
  int? lastQueryOffset;

  @override
  Future<SeriesPageResult> querySeries({
    required String dbPath,
    required String serverId,
    String? search,
    String? libraryId,
    String? status,
    String? tag,
    String? genre,
    String sort = 'name',
    bool ascending = true,
    int limit = 50,
    int offset = 0,
  }) async {
    querySeriesCalls += 1;
    lastQueryServerId = serverId;
    lastQueryLimit = limit;
    lastQueryOffset = offset;
    return const SeriesPageResult(items: [], total: 0);
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
  Future<List<ServerProfile>> listServers({required String dbPath}) async {
    listServersCalls += 1;
    return servers.values.toList();
  }

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
  Future<String?> getActiveServer({required String dbPath}) async {
    getActiveServerCalls += 1;
    return activeId;
  }

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

/// A repository that serves a library in **real pages**.
///
/// The other fakes in this suite ignore `limit`/`offset` and report
/// `total = items.length`, which is why the wall's pagination had never been
/// exercised. This one honours both and records every request, so a test can
/// assert on the exact page sequence.
///
/// Hazard: a fake that reports `total > items.length` while ignoring `offset`
/// makes `_loadMore()` loop forever — the wall re-asks for the same page and
/// never reaches the end, so `pumpAndSettle` times out. Returning an empty page
/// past the end is what terminates the loop; keep that branch.
class PagingFakeRepository extends LibraryRepository {
  PagingFakeRepository(this.series);

  final List<Series> series;

  /// Every `(limit, offset)` pair the wall asked for, in order.
  final List<(int, int)> pageRequests = [];

  /// Every batch of series ids the wall asked covers for. The point of the
  /// page-scoped lookup is that this tracks the loaded pages, not the library.
  final List<List<String>> coverIdRequests = [];

  @override
  Future<Map<String, String>> fetchCoverPaths({
    required List<String> seriesIds,
  }) async {
    coverIdRequests.add(List.of(seriesIds));
    // No files exist in a widget test; the requested ids are what is asserted.
    return const {};
  }

  @override
  Future<PagedSeries> querySeries({
    String? search,
    String? libraryId,
    String? status,
    String? tag,
    String? genre,
    String sort = 'name',
    bool ascending = true,
    int limit = 50,
    int offset = 0,
  }) async {
    pageRequests.add((limit, offset));
    if (offset >= series.length) {
      return PagedSeries(items: const [], total: series.length);
    }
    final end = offset + limit > series.length ? series.length : offset + limit;
    return PagedSeries(
        items: series.sublist(offset, end), total: series.length);
  }

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async =>
      series;

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async =>
      null;

  @override
  Future<int> syncCovers() async => 0;

  @override
  Future<BootstrapSummary> loadDemo() async => BootstrapSummary(
        serverId: 'demo',
        syncedSeries: BigInt.zero,
        totalElements: 0,
        hasMorePages: false,
      );

  @override
  bool get demoSupported => false;
}
