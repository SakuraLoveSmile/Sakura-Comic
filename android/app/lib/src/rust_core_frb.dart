import 'package:flutter/foundation.dart' show debugPrint;

import 'rust/ffi/application.dart';
import 'rust/ffi/bridge.dart' as frb;
import 'rust/frb_generated.dart';
import 'rust/model/server.dart';
import 'rust/model/server_profile.dart';
import 'rust/store/query.dart';
import 'rust/store/read_progress.dart';
import 'rust/store/series.dart';
import 'rust/store/thumbnails.dart';
import 'rust/sync/bootstrap.dart';
import 'rust/sync/full.dart';
import 'rust/sync/reconcile.dart';
import 'rust/store/sync_state.dart';
import 'rust_core_api.dart';

/// Tries to load the native library (`libkomga_core.so`).
///
/// Returns `false` when the library is unavailable (widget tests, host runs
/// without a cargo-ndk build) — callers then fall back to the stub
/// repository so the UI still renders.
Future<bool> initRustCore() async {
  try {
    await RustLib.init();
    return true;
  } catch (e, st) {
    // The reason matters: "no .so in the APK" and "the .so is stale" look
    // identical from the caller and need different fixes.
    debugPrint('[RustCore] native library load failed: $e');
    debugPrint('$st');
    return false;
  }
}

/// [RustCoreApi] backed by the generated flutter_rust_bridge bindings
/// (lib/src/rust/). Keep signatures aligned with
/// android/komga_core/src/ffi/bridge.rs.
class FrbRustCoreApi extends RustCoreApi {
  FrbRustCoreApi();

  @override
  Future<BootstrapSummary> bootstrap({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) {
    return frb.bootstrap(
      dbPath: dbPath,
      serverId: serverId,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
  }

  @override
  Future<ConnectionResult> testConnection({
    required String baseUrl,
    required String apiKey,
  }) {
    return frb.testConnection(baseUrl: baseUrl, apiKey: apiKey);
  }

  @override
  Future<List<SeriesRow>> fetchSeries({
    required String dbPath,
    required String serverId,
    int limit = 50,
    int offset = 0,
  }) {
    return frb.fetchSeries(
      dbPath: dbPath,
      serverId: serverId,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<List<ServerProfile>> listServers({required String dbPath}) {
    return frb.listServers(dbPath: dbPath);
  }

  @override
  Future<void> saveServer({
    required String dbPath,
    required ServerProfile profile,
  }) {
    return frb.saveServer(dbPath: dbPath, profile: profile);
  }

  @override
  Future<ServerProfile?> getServer({
    required String dbPath,
    required String serverId,
  }) {
    return frb.getServer(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<bool> deleteServer({
    required String dbPath,
    required String serverId,
  }) {
    return frb.deleteServer(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<void> saveLibraries({
    required String dbPath,
    required String serverId,
    required List<Library> libraries,
  }) {
    return frb.saveLibraries(
      dbPath: dbPath,
      serverId: serverId,
      libraries: libraries,
    );
  }

  @override
  Future<void> setActiveServer({
    required String dbPath,
    required String serverId,
  }) {
    return frb.setActiveServer(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<String?> getActiveServer({required String dbPath}) {
    return frb.getActiveServer(dbPath: dbPath);
  }

  @override
  Future<String?> coverPath({
    required String dbPath,
    required String serverId,
    required String seriesId,
  }) {
    return frb.coverPath(
        dbPath: dbPath, serverId: serverId, seriesId: seriesId);
  }

  @override
  Future<List<ThumbnailRow>> listThumbnails({
    required String dbPath,
    required String serverId,
  }) {
    return frb.listThumbnails(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<Map<String, String>> coverPaths({
    required String dbPath,
    required String serverId,
    required String variant,
    required List<String> remoteIds,
  }) {
    return frb.coverPaths(
      dbPath: dbPath,
      serverId: serverId,
      variant: variant,
      remoteIds: remoteIds,
    );
  }

  @override
  Future<String> ensureCover({
    required String dbPath,
    required String serverId,
    required String seriesId,
    required String baseUrl,
    required String apiKey,
  }) {
    return frb.ensureCover(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
  }

  @override
  Future<int> ensureCovers({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) {
    return frb.ensureCovers(
      dbPath: dbPath,
      serverId: serverId,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
  }

  @override
  Future<BootstrapSummary> bootstrapDemo({
    required String dbPath,
    required String serverId,
  }) {
    return frb.bootstrapDemo(dbPath: dbPath, serverId: serverId);
  }

  // MARK: Stage 4 — media library (FRB)

  @override
  Future<FullSyncSummary> fullSync({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) {
    return frb.fullSync(
      dbPath: dbPath,
      serverId: serverId,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
  }

  @override
  Future<FullSyncSummary> bootstrapSync({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
    required bool resume,
  }) {
    return frb.bootstrapSync(
      dbPath: dbPath,
      serverId: serverId,
      baseUrl: baseUrl,
      apiKey: apiKey,
      resume: resume,
    );
  }

  @override
  Future<ReconcileSummary> reconcile({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
    required String trigger,
  }) {
    return frb.reconcile(
      dbPath: dbPath,
      serverId: serverId,
      baseUrl: baseUrl,
      apiKey: apiKey,
      trigger: trigger,
    );
  }

  @override
  Future<List<EntitySyncState>> syncStates({
    required String dbPath,
    required String serverId,
  }) {
    return frb.syncStates(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<bool> shouldReconcile({
    required String dbPath,
    required String serverId,
    required String trigger,
  }) {
    return frb.shouldReconcile(
      dbPath: dbPath,
      serverId: serverId,
      trigger: trigger,
    );
  }

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
  }) {
    return frb.querySeries(
      dbPath: dbPath,
      serverId: serverId,
      search: search,
      libraryId: libraryId,
      status: status,
      tag: tag,
      genre: genre,
      sort: sort,
      ascending: ascending,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<BookPageResult> queryBooks({
    required String dbPath,
    required String serverId,
    required String seriesId,
    String? search,
    String? readStatus,
    String? tag,
    String sort = 'number',
    bool ascending = true,
    int limit = 100,
    int offset = 0,
  }) {
    return frb.queryBooks(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
      search: search,
      readStatus: readStatus,
      tag: tag,
      sort: sort,
      ascending: ascending,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<String?> seriesReadOverride({
    required String dbPath,
    required String serverId,
    required String seriesId,
  }) {
    return frb.seriesReadOverride(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
    );
  }

  @override
  Future<String?> setSeriesReadOverride({
    required String dbPath,
    required String serverId,
    required String seriesId,
    String? mode,
    String? direction,
  }) {
    return frb.setSeriesReadOverride(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
      mode: mode,
      direction: direction,
    );
  }

  @override
  Future<ReadTargetRow?> seriesReadTarget({
    required String dbPath,
    required String serverId,
    required String seriesId,
  }) {
    return frb.seriesReadTarget(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
    );
  }

  @override
  Future<SeriesDetailRow?> seriesDetail({
    required String dbPath,
    required String serverId,
    required String seriesId,
  }) {
    return frb.seriesDetail(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
    );
  }

  @override
  Future<BookDetailRow?> bookDetail({
    required String dbPath,
    required String serverId,
    required String bookId,
  }) {
    return frb.bookDetail(dbPath: dbPath, serverId: serverId, bookId: bookId);
  }

  @override
  Future<CollectionPageResult> listCollections({
    required String dbPath,
    required String serverId,
    String? search,
    int limit = 100,
    int offset = 0,
  }) {
    return frb.listCollections(
      dbPath: dbPath,
      serverId: serverId,
      search: search,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<CollectionDetailRow?> collectionDetail({
    required String dbPath,
    required String serverId,
    required String collectionId,
    int limit = 200,
    int offset = 0,
  }) {
    return frb.collectionDetail(
      dbPath: dbPath,
      serverId: serverId,
      collectionId: collectionId,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<ReadlistPageResult> listReadlists({
    required String dbPath,
    required String serverId,
    String? search,
    int limit = 100,
    int offset = 0,
  }) {
    return frb.listReadlists(
      dbPath: dbPath,
      serverId: serverId,
      search: search,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<ReadlistDetailRow?> readlistDetail({
    required String dbPath,
    required String serverId,
    required String readlistId,
    int limit = 500,
    int offset = 0,
  }) {
    return frb.readlistDetail(
      dbPath: dbPath,
      serverId: serverId,
      readlistId: readlistId,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<List<ContinueReadingRow>> continueReading({
    required String dbPath,
    required String serverId,
    int limit = 10,
  }) {
    return frb.continueReading(
      dbPath: dbPath,
      serverId: serverId,
      limit: limit,
    );
  }

  @override
  Future<FilterOptions> filterOptions({
    required String dbPath,
    required String serverId,
  }) {
    return frb.filterOptions(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<List<LibraryCountRow>> libraryCounts({
    required String dbPath,
    required String serverId,
  }) {
    return frb.libraryCounts(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<LibraryCountRow?> libraryDetail({
    required String dbPath,
    required String serverId,
    required String libraryId,
  }) {
    return frb.libraryDetail(
        dbPath: dbPath, serverId: serverId, libraryId: libraryId);
  }

  @override
  Future<void> setReadProgress({
    required String dbPath,
    required String serverId,
    required String bookId,
    required int page,
    required bool completed,
  }) {
    return frb.setReadProgress(
      dbPath: dbPath,
      serverId: serverId,
      bookId: bookId,
      page: page,
      completed: completed,
    );
  }

  @override
  Future<void> markRead({
    required String dbPath,
    required String serverId,
    required String bookId,
  }) {
    return frb.markRead(dbPath: dbPath, serverId: serverId, bookId: bookId);
  }

  @override
  Future<void> markUnread({
    required String dbPath,
    required String serverId,
    required String bookId,
  }) {
    return frb.markUnread(dbPath: dbPath, serverId: serverId, bookId: bookId);
  }

  @override
  Future<String?> bookCoverPath({
    required String dbPath,
    required String serverId,
    required String bookId,
  }) {
    return frb.bookCoverPath(
        dbPath: dbPath, serverId: serverId, bookId: bookId);
  }

  @override
  Future<int> ensureBookCovers({
    required String dbPath,
    required String serverId,
    required String seriesId,
    required String baseUrl,
    required String apiKey,
  }) {
    return frb.ensureBookCovers(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
  }

  // MARK: Stage 6 — Mutation Outbox + SSE

  @override
  Future<UploadOutcomeDto> uploadOutbox({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) {
    return frb.uploadOutbox(
      dbPath: dbPath,
      serverId: serverId,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
  }

  @override
  Future<OutboxStatusDto> outboxStatus({
    required String dbPath,
    required String serverId,
  }) {
    return frb.outboxStatus(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<int> retryFailedMutations({
    required String dbPath,
    required String serverId,
  }) async {
    final count = await frb.retryFailedMutations(
      dbPath: dbPath,
      serverId: serverId,
    );
    return count.toInt();
  }

  @override
  Future<SsePollResult?> ssePoll({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
    required String stateJson,
  }) {
    return frb.ssePoll(
      dbPath: dbPath,
      serverId: serverId,
      baseUrl: baseUrl,
      apiKey: apiKey,
      stateJson: stateJson,
    );
  }

  @override
  Future<String> sseReconciled({
    required String dbPath,
    required String serverId,
    required String stateJson,
  }) {
    // serverId rides inside the serialised session, so the transport does not
    // take it again.
    return frb.sseReconciled(
      dbPath: dbPath,
      stateJson: stateJson,
    );
  }

  @override
  Future<String> sseResume({
    required String dbPath,
    required String serverId,
    required String stateJson,
  }) {
    // serverId rides inside the serialised session, so the transport does not
    // take it again.
    return frb.sseResume(
      dbPath: dbPath,
      stateJson: stateJson,
    );
  }

  @override
  Future<void> sseStop({
    required String dbPath,
    required String serverId,
  }) {
    return frb.sseStop(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<AuthStateDto> authState({
    required String dbPath,
    required String serverId,
  }) {
    return frb.authState(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<DiagnosticsDto?> diagnosticsSnapshot({
    required String dbPath,
    required String serverId,
  }) {
    return frb.diagnosticsSnapshot(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<List<LogRecord>> diagnosticsLogs({
    int limit = 100,
    String minLevel = '',
  }) {
    return frb.diagnosticsLogs(limit: limit, minLevel: minLevel);
  }

  @override
  Future<CacheStatsDto?> readerCacheStats({
    required String dbPath,
  }) {
    return frb.readerCacheStats(dbPath: dbPath);
  }

  @override
  Future<CacheCleanupDto?> readerReconcileCache({
    required String dbPath,
  }) {
    return frb.readerReconcileCache(dbPath: dbPath);
  }

  @override
  Future<int> readerClearPrefetch({
    required String dbPath,
  }) async {
    final count = await frb.readerClearPrefetch(dbPath: dbPath);
    return count.toInt();
  }
}
