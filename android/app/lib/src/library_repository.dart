import 'downloads_api.dart';
import 'reader_api.dart';
import 'dart:async';
import 'dart:io'
    show
        File,
        FileMode,
        Directory,
        FileSystemEntity,
        FileSystemEntityType,
        FileSystemException;

import 'package:flutter/foundation.dart' show debugPrint;

import 'app_settings.dart';

import 'models.dart';
import 'rust/model/server_profile.dart';
import 'rust/store/books.dart' show BookRow;
import 'rust/store/query.dart' show LibraryCountRow;
import 'rust/store/series.dart';
import 'rust/sync/bootstrap.dart';
import 'series.dart';
import 'server_manager.dart';
import 'rust_core_api.dart';
import 'rust_core_frb.dart';

/// Gateway between UI and Rust Core.
///
/// Phase 0: [StubLibraryRepository] keeps the UI testable without FFI;
/// [RustLibraryRepository] talks to komga_core through the generated
/// flutter_rust_bridge bindings. The UI only reads the local store — network
/// is confined to the sync/cover methods below (Local First).
///
/// Abstract class (not `interface`): the Stage 4 query surface carries
/// flat/empty defaults so test doubles stay small.
abstract class LibraryRepository {
  const LibraryRepository();
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0});

  /// The reader's whole surface for one book, wired to the active server.
  ///
  /// Defaults to the in-memory reader so a build without the native library
  /// (or a widget test) can still open the screen; the Rust-backed repository
  /// overrides it with the FFI one.
  Future<ReaderApi> readerApi({required String bookId}) async =>
      InMemoryReaderApi();

  /// The download surface for the active server. Defaults to the in-memory queue so
  /// a build without the native library (or a widget test) still renders the screen;
  /// `RustLibraryRepository` overrides it with the FFI one.
  Future<DownloadsApi> downloadsApi() async => InMemoryDownloadsApi();

  /// Cover file paths for the given series, resolved from SQLite
  /// (remote_id → local path). Missing covers are rendered as placeholders.
  ///
  /// Scoped by id on purpose: the whole-server answer cost one decoded row and
  /// one `stat()` per series *and* per book in the library, on every screen load.
  Future<Map<String, String>> fetchCoverPaths(
      {required List<String> seriesIds});

  /// Bootstrap Sync for the active server: mirror the media library into
  /// SQLite and backfill covers. `resume` continues an interrupted run from
  /// the cursors the core stored per entity type. Returns null when there is
  /// no server (or no credential) to talk to.
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume});

  /// Backfills covers for series without a usable record (缓存缺失自动补齐).
  Future<int> syncCovers();

  /// Stage 5 Reconcile Sync: sweep the server for Added / Changed / Deleted
  /// and converge SQLite on it — this is what makes SSE events optional.
  /// Returns null when there is no server or credential to talk to.
  Future<ReconcileReport?> reconcileActiveServer(
          {required String trigger}) async =>
      null;

  /// Sync bookkeeping (`sync_state`) for the shelf header.
  Future<SyncStatus> fetchSyncStatus() async => const SyncStatus();

  /// Stage 10: what the last credentialed contact proved about the active
  /// server's key. `null` when there is no active server to have a key for.
  ///
  /// The shelf shows its re-authenticate entry off this and nothing else, so
  /// `unknown` has to stay distinguishable from `expired`: a client that never
  /// spoke to the server should not be asking for a new password.
  Future<AuthStateDto?> fetchCredentialState() async => null;

  /// Offline demo: seeds fixture series + generated covers (no server).
  Future<BootstrapSummary> loadDemo();

  /// Whether the repository can seed the demo wall (FFI-backed only).
  bool get demoSupported;

  /// Drop any cached notion of which server is active. Call after changing it by
  /// a route this repository cannot see. A no-op for repositories that keep no
  /// such cache.
  void invalidateActiveServer() {}

  // MARK: Stage 4 default stubs (flat/empty; test doubles extend for free).

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
    // Test-double default only. `total` cannot be known from one page, so a real
    // repository MUST override — `RustLibraryRepository` does, further down.
    final items = await fetchSeries(limit: limit, offset: offset);
    return PagedSeries(items: items, total: items.length);
  }

  Future<PagedBooks> queryBooks({
    required String seriesId,
    String? search,
    String? readStatus,
    String? tag,
    String sort = 'number',
    bool ascending = true,
    int limit = 100,
    int offset = 0,
  }) async =>
      const PagedBooks(items: [], total: 0);

  Future<SeriesDetail?> seriesDetail({required String seriesId}) async => null;

  Future<BookDetail?> bookDetail({required String bookId}) async => null;

  /// Which book the read button should open, and why (统一阅读入口).
  ///
  /// Default `null` for the stub/demo repositories: a repository that cannot
  /// answer must not invent a target — the caller then falls back to its own
  /// first-book behaviour rather than opening the wrong volume.
  Future<ReadTarget?> readTarget({required String seriesId}) async => null;

  Future<PagedCollections> listCollections(
          {String? search, int limit = 100, int offset = 0}) async =>
      const PagedCollections(items: [], total: 0);

  Future<CollectionDetail?> collectionDetail(
          {required String collectionId}) async =>
      null;

  Future<PagedReadlists> listReadlists(
          {String? search, int limit = 100, int offset = 0}) async =>
      const PagedReadlists(items: [], total: 0);

  Future<ReadlistDetail?> readlistDetail({required String readlistId}) async =>
      null;

  Future<List<ContinueReadingItem>> continueReading({int limit = 10}) async =>
      const [];

  Future<FilterOptions> fetchFilterOptions() async => const FilterOptions();

  Future<List<LibraryCount>> fetchLibraryCounts() async => const [];

  /// One library with counts / root / availability (Library 详情).
  Future<LibraryCount?> libraryDetail({required String libraryId}) async =>
      null;

  Future<Map<String, String>> fetchBookCoverPaths({
    required List<String> bookIds,
  }) async =>
      const {};

  Future<int> syncBookCovers({required String seriesId}) async => 0;

  Future<void> setReadProgress({
    required String bookId,
    required int page,
    required bool completed,
  }) async {}

  Future<void> markRead({required String bookId}) async {}

  Future<void> markUnread({required String bookId}) async {}

  // MARK: Stage 6 — Mutation Outbox + SSE


  /// One bounded step of the event stream; `stateJson` is the session as the
  /// previous call returned it. Null means the core has nothing to report.
  Future<SsePollResult?> ssePoll({required String stateJson}) async => null;

  /// Tell the core the owed sweep ran, so it may release buffered events.
  Future<String> sseReconciled({required String stateJson}) async => stateJson;

  /// Connectivity came back: make the stream due now.
  Future<String> sseResume({required String stateJson}) async => stateJson;

  /// Park the stream (screen disposed / server switched).
  Future<void> sseStop() async {}

  /// Drain everything due in the Outbox.
  Future<UploadOutcomeDto> uploadOutbox() async => emptyUploadOutcome('');

  /// Queued-mutation badge (SQLite only, so it works with the network down).
  Future<OutboxStatusDto> outboxStatus() async => emptyOutboxStatus('');

  /// Hand every given-up row back to the retry machine.
  Future<int> retryFailedMutations() async => 0;

  /// Read diagnostics snapshot (SQLite health, outbox, cache, queue, policy, log stats).
  Future<DiagnosticsDto?> diagnosticsSnapshot() async => null;

  /// Recent core log lines, newest first.
  Future<List<LogRecord>> diagnosticsLogs({
    int limit = 100,
    String minLevel = '',
  }) async =>
      const [];

  /// Live cache occupancy across memory and disk.
  Future<CacheStatsDto?> cacheStats() async => null;

  /// Run cache cleanup sweep (orphans, corrupt files, ghost rows).
  Future<CacheCleanupDto?> reconcileCache() async => null;

  /// Drop prefetched pages without touching displayed or downloaded books.
  Future<int> clearPrefetchCache() async => 0;

  /// Load persisted app settings.
  Future<AppSettings> loadAppSettings() async => const AppSettings();

  /// Persist app settings changes.
  Future<void> saveAppSettings(AppSettings settings,
      {bool overwriteCorrupt = false}) async {}

  /// What this series overrides about the reader, or `null` when it follows the
  /// global preference (系列覆盖 → 全局设置 的第一级).
  /// global preference (系列覆盖 → 全局设置 的第一级).
  Future<SeriesReadOverride?> seriesOverride(
          {required String seriesId}) async =>
      null;

  /// Record what this series reads like from now on.
  ///
  /// This is where a mode or direction chosen *inside* the reader goes. It is
  /// deliberately not the global preference: one gesture in one volume must not
  /// decide how every other book opens.
  Future<void> setSeriesOverride({
    required String seriesId,
    String? mode,
    String? direction,
  }) async {}
}

/// In-memory stub so the grid UI can be built and tested without FFI.
class StubLibraryRepository extends LibraryRepository {
  const StubLibraryRepository() : super();

  static AppSettings _stubSettings = const AppSettings();

  @override
  Future<AppSettings> loadAppSettings() async => _stubSettings;

  @override
  Future<void> saveAppSettings(AppSettings settings,
      {bool overwriteCorrupt = false}) async {
    _stubSettings = settings;
  }

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<Map<String, String>> fetchCoverPaths({
    required List<String> seriesIds,
  }) async =>
      const {};

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async =>
      null;

  @override
  Future<int> syncCovers() async => 0;

  @override
  Future<BootstrapSummary> loadDemo() async => _emptySummary('demo');

  @override
  bool get demoSupported => false;

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
  }) async =>
      const PagedSeries(items: [], total: 0);

  @override
  Future<PagedBooks> queryBooks({
    required String seriesId,
    String? search,
    String? readStatus,
    String? tag,
    String sort = 'number',
    bool ascending = true,
    int limit = 100,
    int offset = 0,
  }) async =>
      const PagedBooks(items: [], total: 0);

  @override
  Future<SeriesDetail?> seriesDetail({required String seriesId}) async => null;

  @override
  Future<BookDetail?> bookDetail({required String bookId}) async => null;

  /// Which book the read button should open, and why (统一阅读入口).
  ///
  /// Default `null` for the stub/demo repositories: a repository that cannot
  /// answer must not invent a target — the caller then falls back to its own
  /// first-book behaviour rather than opening the wrong volume.
  @override
  Future<ReadTarget?> readTarget({required String seriesId}) async => null;

  /// What this series overrides about the reader, or `null` when it follows the
  /// global preference (系列覆盖 → 全局设置 的第一级).
  @override
  Future<SeriesReadOverride?> seriesOverride(
          {required String seriesId}) async =>
      null;

  /// Record what this series reads like from now on.
  ///
  /// This is where a mode or direction chosen *inside* the reader goes. It is
  /// deliberately not the global preference: one gesture in one volume must not
  /// decide how every other book opens.
  @override
  Future<void> setSeriesOverride({
    required String seriesId,
    String? mode,
    String? direction,
  }) async {}

  @override
  Future<PagedCollections> listCollections(
          {String? search, int limit = 100, int offset = 0}) async =>
      const PagedCollections(items: [], total: 0);

  @override
  Future<CollectionDetail?> collectionDetail(
          {required String collectionId}) async =>
      null;

  @override
  Future<PagedReadlists> listReadlists(
          {String? search, int limit = 100, int offset = 0}) async =>
      const PagedReadlists(items: [], total: 0);

  @override
  Future<ReadlistDetail?> readlistDetail({required String readlistId}) async =>
      null;

  @override
  Future<List<ContinueReadingItem>> continueReading({int limit = 10}) async =>
      const [];

  @override
  Future<FilterOptions> fetchFilterOptions() async => const FilterOptions();

  @override
  Future<List<LibraryCount>> fetchLibraryCounts() async => const [];

  @override
  Future<Map<String, String>> fetchBookCoverPaths({
    required List<String> bookIds,
  }) async =>
      const {};

  @override
  Future<int> syncBookCovers({required String seriesId}) async => 0;

  @override
  Future<void> setReadProgress({
    required String bookId,
    required int page,
    required bool completed,
  }) async {}

  @override
  Future<void> markRead({required String bookId}) async {}

  @override
  Future<void> markUnread({required String bookId}) async {}

  static BootstrapSummary _emptySummary(String serverId) => BootstrapSummary(
        serverId: serverId,
        syncedSeries: BigInt.zero,
        totalElements: 0,
        hasMorePages: false,
      );
}

/// Rust Core-backed repository (multi-server): reads the active server
/// profile from SQLite via the FFI bridge (falling back to the first
/// profile), then mirrors its series rows.
class RustLibraryRepository extends LibraryRepository {
  RustLibraryRepository({
    required this.dbPath,
    RustCoreApi? api,
    ServerManager? serverManager,
  })  : _api = api ?? FrbRustCoreApi(),
        _serverManager = serverManager {
    // Drop the memo whenever the active server actually moves. ServerManager is
    // the single funnel for that (switchTo / delete); loadDemo sets it directly
    // and invalidates itself.
    serverManager?.onActiveServerChanged = invalidateActiveServer;
  }

  final String dbPath;
  final RustCoreApi _api;

  /// Provides credentials (Keystore) for sync/cover backfill; may be null
  /// in test setups where the wall only renders local data.
  final ServerManager? _serverManager;

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async {
    final serverId = await _activeServerId();
    if (serverId == null) {
      debugPrint('[RustCore] fetchSeries: no active server (servers empty)');
      return const [];
    }
    final page = await _api.querySeries(
        dbPath: dbPath, serverId: serverId, limit: limit, offset: offset);
    debugPrint(
        '[RustCore] fetchSeries($serverId) -> ${page.items.length}/${page.total}');
    return page.items.map(SeriesRowToSeries.toSeries).toList();
  }

  @override
  Future<ReaderApi> readerApi({required String bookId}) async {
    final credential = await _activeCredential();
    if (credential == null) {
      // No server to read from: an empty in-memory book keeps the screen
      // honest (it can navigate) instead of throwing on open.
      return InMemoryReaderApi(pageCount: 0);
    }
    final (profile, apiKey) = credential;
    return FrbReaderApi(
      dbPath: dbPath,
      serverId: profile.id,
      bookId: bookId,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
    );
  }

  @override
  Future<DownloadsApi> downloadsApi() async {
    final credential = await _activeCredential();
    if (credential == null) return InMemoryDownloadsApi();
    final (profile, apiKey) = credential;
    return FrbDownloadsApi(
      dbPath: dbPath,
      serverId: profile.id,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
    );
  }

  @override
  Future<Map<String, String>> fetchCoverPaths({
    required List<String> seriesIds,
  }) async {
    final serverId = await _activeServerId();
    if (serverId == null) return const {};
    return _api.coverPaths(
      dbPath: dbPath,
      serverId: serverId,
      variant: 'series',
      remoteIds: seriesIds,
    );
  }

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async {
    final credential = await _activeCredential();
    if (credential == null) return null;
    final (profile, apiKey) = credential;
    final summary = await _api.bootstrapSync(
      dbPath: dbPath,
      serverId: profile.id,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
      resume: resume,
    );
    debugPrint(
      '[RustCore] bootstrapSync("${profile.id}" resume=$resume) -> '
      '${summary.series} series / ${summary.books} books, '
      'resumed ${summary.resumedSteps}, skipped ${summary.skippedSteps}',
    );
    await syncCovers();
    return BootstrapSummary(
      serverId: profile.id,
      syncedSeries: summary.series,
      totalElements: summary.series.toInt(),
      hasMorePages: false,
    );
  }

  @override
  Future<ReconcileReport?> reconcileActiveServer(
      {required String trigger}) async {
    final credential = await _activeCredential();
    if (credential == null) return null;
    final (profile, apiKey) = credential;
    if (!await _api.shouldReconcile(
      dbPath: dbPath,
      serverId: profile.id,
      trigger: trigger,
    )) {
      debugPrint('[RustCore] reconcile($trigger) throttled');
      return null;
    }
    final summary = await _api.reconcile(
      dbPath: dbPath,
      serverId: profile.id,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
      trigger: trigger,
    );
    final added = (summary.seriesAdded +
            summary.booksAdded +
            summary.collectionsAdded +
            summary.readlistsAdded)
        .toInt();
    final changed = (summary.seriesChanged +
            summary.booksChanged +
            summary.collectionsChanged +
            summary.readlistsChanged)
        .toInt();
    final removed = (summary.seriesRemoved +
            summary.booksRemoved +
            summary.collectionsRemoved +
            summary.readlistsRemoved +
            summary.librariesRemoved)
        .toInt();
    debugPrint(
      '[RustCore] reconcile("$profile.id", $trigger) -> +$added ~$changed -$removed '
      'clean=${summary.clean}',
    );
    // New series need covers; pruned ones were already dropped core-side.
    if (added > 0 || summary.orphanedCovers.isNotEmpty) await syncCovers();
    return ReconcileReport(
      added: added,
      changed: changed,
      removed: removed,
      clean: summary.clean,
    );
  }

  @override
  Future<SyncStatus> fetchSyncStatus() async {
    final serverId = await _activeServerId();
    if (serverId == null) return const SyncStatus();
    final states = await _api.syncStates(dbPath: dbPath, serverId: serverId);
    final rollup = states.where((state) => state.entityType == 'full');
    final resumable = states
        .where(
            (state) => state.syncCursor != null && state.entityType != 'full')
        .map((state) => state.entityType)
        .toList();
    final row = rollup.isEmpty ? null : rollup.first;
    return SyncStatus(
      lastSyncAt: row?.lastSyncAt,
      status: row?.syncStatus ?? 'idle',
      error: row?.lastError,
      resumableEntities: resumable,
    );
  }

  @override
  Future<AuthStateDto?> fetchCredentialState() async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    return _api.authState(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<int> syncCovers() async {
    final credential = await _activeCredential();
    if (credential == null) return 0;
    final (profile, apiKey) = credential;
    final n = await _api.ensureCovers(
      dbPath: dbPath,
      serverId: profile.id,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
    );
    debugPrint('[RustCore] ensureCovers("${profile.id}") -> $n backfilled');
    return n;
  }

  @override
  Future<BootstrapSummary> loadDemo() async {
    const serverId = 'demo';
    final summary =
        await _api.bootstrapDemo(dbPath: dbPath, serverId: serverId);
    await _api.setActiveServer(dbPath: dbPath, serverId: serverId);
    // This path sets the active server without going through ServerManager.
    invalidateActiveServer();
    debugPrint('[RustCore] bootstrapDemo -> ${summary.syncedSeries} series');
    return summary;
  }

  @override
  bool get demoSupported => true;

  // MARK: Stage 4 queries

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
    final serverId = await _activeServerId();
    if (serverId == null) return const PagedSeries(items: [], total: 0);
    final page = await _api.querySeries(
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
    return PagedSeries(
      items: page.items.map(SeriesRowToSeries.toSeries).toList(),
      total: page.total.toInt(),
    );
  }

  @override
  Future<PagedBooks> queryBooks({
    required String seriesId,
    String? search,
    String? readStatus,
    String? tag,
    String sort = 'number',
    bool ascending = true,
    int limit = 100,
    int offset = 0,
  }) async {
    final serverId = await _activeServerId();
    if (serverId == null) return const PagedBooks(items: [], total: 0);
    final page = await _api.queryBooks(
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
    return PagedBooks(
      items: page.items.map(BookRowToBook.toBook).toList(),
      total: page.total.toInt(),
    );
  }

  @override
  Future<SeriesDetail?> seriesDetail({required String seriesId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final row = await _api.seriesDetail(
        dbPath: dbPath, serverId: serverId, seriesId: seriesId);
    if (row == null) return null;
    return SeriesDetailRowToModel.toSeriesDetail(row);
  }

  @override
  Future<ReadTarget?> readTarget({required String seriesId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final row = await _api.seriesReadTarget(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
    );
    if (row == null) return null;
    // Even `intent == empty` is an answer worth returning: "this series has
    // nothing to open" and "we cannot prove there is a next volume" are facts
    // the detail screen has to state, not guess.
    return ReadTarget(
      book: BookRowToBook.toBook(row.book),
      intent: ReadIntent.parse(row.intent),
      position: row.position.toInt(),
      bookCount: row.bookCount?.toInt(),
      catalogComplete: row.complete,
    );
  }

  @override
  Future<SeriesReadOverride?> seriesOverride({required String seriesId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final raw = await _api.seriesReadOverride(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
    );
    return SeriesReadOverride.tryParse(raw);
  }

  @override
  Future<void> setSeriesOverride({
    required String seriesId,
    String? mode,
    String? direction,
  }) async {
    final serverId = await _activeServerId();
    if (serverId == null) return;
    await _api.setSeriesReadOverride(
      dbPath: dbPath,
      serverId: serverId,
      seriesId: seriesId,
      mode: mode,
      direction: direction,
    );
  }

  @override
  Future<BookDetail?> bookDetail({required String bookId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final row = await _api.bookDetail(
        dbPath: dbPath, serverId: serverId, bookId: bookId);
    if (row == null) return null;
    return BookDetailRowToModel.toBookDetail(row);
  }

  @override
  Future<PagedCollections> listCollections(
      {String? search, int limit = 100, int offset = 0}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return const PagedCollections(items: [], total: 0);
    final page = await _api.listCollections(
      dbPath: dbPath,
      serverId: serverId,
      search: search,
      limit: limit,
      offset: offset,
    );
    return PagedCollections(
      items: page.items
          .map((r) => CollectionItem(
              remoteId: r.remoteId, name: r.name, ordered: r.ordered))
          .toList(),
      total: page.total.toInt(),
    );
  }

  @override
  Future<CollectionDetail?> collectionDetail(
      {required String collectionId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final row = await _api.collectionDetail(
      dbPath: dbPath,
      serverId: serverId,
      collectionId: collectionId,
      limit: 200,
      offset: 0,
    );
    if (row == null) return null;
    return CollectionDetail(
      item: CollectionItem(
          remoteId: row.remoteId, name: row.name, ordered: row.ordered),
      members: PagedSeries(
        items: row.members.items.map(SeriesRowToSeries.toSeries).toList(),
        total: row.members.total.toInt(),
      ),
    );
  }

  @override
  Future<PagedReadlists> listReadlists(
      {String? search, int limit = 100, int offset = 0}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return const PagedReadlists(items: [], total: 0);
    final page = await _api.listReadlists(
      dbPath: dbPath,
      serverId: serverId,
      search: search,
      limit: limit,
      offset: offset,
    );
    return PagedReadlists(
      items: page.items
          .map((r) => ReadlistItem(
              remoteId: r.remoteId,
              name: r.name,
              summary: r.summary,
              ordered: r.ordered))
          .toList(),
      total: page.total.toInt(),
    );
  }

  @override
  Future<ReadlistDetail?> readlistDetail({required String readlistId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final row = await _api.readlistDetail(
      dbPath: dbPath,
      serverId: serverId,
      readlistId: readlistId,
      limit: 500,
      offset: 0,
    );
    if (row == null) return null;
    return ReadlistDetail(
      item: ReadlistItem(
          remoteId: row.remoteId,
          name: row.name,
          summary: row.summary,
          ordered: row.ordered),
      books: PagedBooks(
        items: row.books.items.map(BookRowToBook.toBook).toList(),
        total: row.books.total.toInt(),
      ),
    );
  }

  @override
  Future<List<ContinueReadingItem>> continueReading({int limit = 10}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return const [];
    final rows = await _api.continueReading(
        dbPath: dbPath, serverId: serverId, limit: limit);
    return rows
        .map((r) => ContinueReadingItem(
              bookId: r.bookId,
              bookTitle: r.bookTitle,
              seriesId: r.seriesId,
              seriesName: r.seriesName,
              number: r.number,
              page: r.page?.toInt(),
              totalPages: r.totalPages?.toInt(),
              progressPercent: r.progressPct?.toInt(),
            ))
        .toList();
  }

  @override
  Future<FilterOptions> fetchFilterOptions() async {
    final serverId = await _activeServerId();
    if (serverId == null) return const FilterOptions();
    final options =
        await _api.filterOptions(dbPath: dbPath, serverId: serverId);
    return FilterOptions(
        tags: options.tags, genres: options.genres, statuses: options.statuses);
  }

  @override
  Future<List<LibraryCount>> fetchLibraryCounts() async {
    final serverId = await _activeServerId();
    if (serverId == null) return const [];
    final rows = await _api.libraryCounts(dbPath: dbPath, serverId: serverId);
    return rows.map(_toLibraryCount).toList();
  }

  @override
  Future<LibraryCount?> libraryDetail({required String libraryId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final row = await _api.libraryDetail(
      dbPath: dbPath,
      serverId: serverId,
      libraryId: libraryId,
    );
    return row == null ? null : _toLibraryCount(row);
  }

  static LibraryCount _toLibraryCount(LibraryCountRow r) => LibraryCount(
        remoteId: r.remoteId,
        name: r.name,
        root: r.root,
        unavailable: r.unavailable,
        seriesCount: r.seriesCount.toInt(),
        bookCount: r.bookCount.toInt(),
        readCount: r.readCount.toInt(),
      );

  @override
  Future<Map<String, String>> fetchBookCoverPaths({
    required List<String> bookIds,
  }) async {
    final serverId = await _activeServerId();
    if (serverId == null) return const {};
    return _api.coverPaths(
      dbPath: dbPath,
      serverId: serverId,
      variant: 'book',
      remoteIds: bookIds,
    );
  }

  @override
  Future<int> syncBookCovers({required String seriesId}) async {
    final credential = await _activeCredential();
    if (credential == null) return 0;
    final (profile, apiKey) = credential;
    final n = await _api.ensureBookCovers(
      dbPath: dbPath,
      serverId: profile.id,
      seriesId: seriesId,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
    );
    debugPrint('[RustCore] ensureBookCovers("$seriesId") -> $n backfilled');
    return n;
  }

  @override
  Future<void> setReadProgress({
    required String bookId,
    required int page,
    required bool completed,
  }) async {
    final serverId = await _activeServerId();
    if (serverId == null) return;
    await _api.setReadProgress(
      dbPath: dbPath,
      serverId: serverId,
      bookId: bookId,
      page: page,
      completed: completed,
    );
    _scheduleUpload();
  }

  @override
  Future<void> markRead({required String bookId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return;
    await _api.markRead(dbPath: dbPath, serverId: serverId, bookId: bookId);
    _scheduleUpload();
  }

  @override
  Future<void> markUnread({required String bookId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return;
    await _api.markUnread(dbPath: dbPath, serverId: serverId, bookId: bookId);
    _scheduleUpload();
  }

  // MARK: Stage 6 — Mutation Outbox + SSE

  String? _sseServerId;
  int _serverLookupGeneration = 0;

  @override
  Future<SsePollResult?> ssePoll({required String stateJson}) async {
    final generation = _serverLookupGeneration;
    final credential = await _activeCredential();
    if (credential == null || generation != _serverLookupGeneration) {
      return null;
    }
    final (profile, apiKey) = credential;
    // A different server must get a fresh controller/state after sseStop.
    if (_sseServerId != null && _sseServerId != profile.id) return null;
    _sseServerId = profile.id;
    return _api.ssePoll(
      dbPath: dbPath,
      serverId: profile.id,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
      stateJson: stateJson,
    );
  }

  @override
  Future<String> sseReconciled({required String stateJson}) async {
    final serverId = _sseServerId;
    if (serverId == null) return stateJson;
    return _api.sseReconciled(
        dbPath: dbPath, serverId: serverId, stateJson: stateJson);
  }

  @override
  Future<String> sseResume({required String stateJson}) async {
    final serverId = _sseServerId;
    if (serverId == null) return stateJson;
    return _api.sseResume(
        dbPath: dbPath, serverId: serverId, stateJson: stateJson);
  }

  @override
  Future<void> sseStop() async {
    final serverId = _sseServerId;
    _sseServerId = null;
    // Also cancel any poll still resolving credentials before it opens a socket.
    _serverLookupGeneration++;
    if (serverId == null) return;
    await _api.sseStop(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<UploadOutcomeDto> uploadOutbox() async {
    final credential = await _activeCredential();
    if (credential == null) return emptyUploadOutcome('');
    final (profile, apiKey) = credential;
    final outcome = await _api.uploadOutbox(
      dbPath: dbPath,
      serverId: profile.id,
      baseUrl: profile.baseUrl,
      apiKey: apiKey,
    );
    debugPrint(
      '[RustCore] uploadOutbox -> uploaded=${outcome.uploaded} retried=${outcome.retried} '
      'failed=${outcome.outbox.failed} status=${outcome.status}',
    );
    return outcome;
  }

  @override
  Future<OutboxStatusDto> outboxStatus() async {
    final serverId = await _activeServerId();
    if (serverId == null) return emptyOutboxStatus('');
    return _api.outboxStatus(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<int> retryFailedMutations() async {
    final serverId = await _activeServerId();
    if (serverId == null) return 0;
    return _api.retryFailedMutations(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<DiagnosticsDto?> diagnosticsSnapshot() async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    return _api.diagnosticsSnapshot(dbPath: dbPath, serverId: serverId);
  }

  @override
  Future<List<LogRecord>> diagnosticsLogs({
    int limit = 100,
    String minLevel = '',
  }) async {
    return _api.diagnosticsLogs(limit: limit, minLevel: minLevel);
  }

  @override
  Future<CacheStatsDto?> cacheStats() async {
    return _api.readerCacheStats(dbPath: dbPath);
  }

  @override
  Future<CacheCleanupDto?> reconcileCache() async {
    return _api.readerReconcileCache(dbPath: dbPath);
  }

  @override
  Future<int> clearPrefetchCache() async {
    return _api.readerClearPrefetch(dbPath: dbPath);
  }

  /// 上传节流: a page turn is not a request. The write is already in SQLite and
  /// the Outbox, so this only coalesces a burst of them into one drain.
  void _scheduleUpload() {
    _uploadDebounce?.cancel();
    _uploadDebounce = Timer(_uploadDebounceWindow, () {
      unawaited(uploadOutbox());
    });
  }

  Timer? _uploadDebounce;
  static const Duration _uploadDebounceWindow = Duration(seconds: 3);

  /// The profile to display: the active server, else the first one.
  ///
  /// Memoized because one shelf refresh asks nine times (five loaders, some of
  /// which resolve it more than once), and each ask was two FFI round trips.
  ///
  /// The *future* is cached rather than its value: those loaders run under
  /// `Future.wait`, so caching only once the value arrives would let every one
  /// of them miss together and each pay the full two round trips.
  ///
  /// An absence is never memoized — `null` means the user has no server *yet*,
  /// and caching it would keep the shelf empty after they add one.
  Future<String?>? _activeServerLookup;

  /// Drop the memoized active server. Called by [ServerManager] whenever the
  /// active profile changes.
  @override
  void invalidateActiveServer() {
    _activeServerLookup = null;
    _serverLookupGeneration++;
  }

  Future<String?> _activeServerId() {
    final pending = _activeServerLookup;
    if (pending != null) return pending;
    final lookup = _resolveActiveServerId();
    _activeServerLookup = lookup;
    return lookup.then(
      (id) {
        if (id == null && identical(_activeServerLookup, lookup)) {
          _activeServerLookup = null;
        }
        return id;
      },
      onError: (Object error) {
        // A transient failure must not be memoized either.
        if (identical(_activeServerLookup, lookup)) _activeServerLookup = null;
        throw error;
      },
    );
  }

  Future<String?> _resolveActiveServerId() async {
    final servers = await _api.listServers(dbPath: dbPath);
    if (servers.isEmpty) {
      // A demo seed leaves the media tables populated and `active_server_id`
      // set, but no `servers` row (the demo server has no base URL to store).
      // The demo id is the one id queries must accept even without a row.
      final demo = await _api.getActiveServer(dbPath: dbPath);
      return demo == 'demo' ? 'demo' : null;
    }
    final activeId = await _api.getActiveServer(dbPath: dbPath);
    return activeId ?? servers.first.id;
  }

  /// (profile, apiKey) for the active server — or null when unavailable
  /// (no server / no stored secret).
  ///
  /// The secret is deliberately *not* cached: holding a decrypted API key in a
  /// Dart field for the life of the app is a worse trade than one Keystore read
  /// on a user-initiated sync. Only the active *id* is reused here.
  Future<(ServerProfile, String)?> _activeCredential() async {
    final manager = _serverManager;
    if (manager == null) return null;
    // Reuse the memoized id: warm it saves the `getActiveServer` round trip, cold
    // it costs nothing extra.
    final activeId = await _activeServerId();
    if (activeId == null) return null;
    final servers = await _api.listServers(dbPath: dbPath);
    // A demo seed has no profile row, so it has no credential either.
    if (servers.isEmpty) return null;
    final active = servers.firstWhere(
      (s) => s.id == activeId,
      orElse: () => servers.first,
    );
    final ref = active.credentialRef;
    if (ref == null) return null;
    final secret = await manager.readSecret(ref);
    if (secret == null) return null;
    return (active, secret);
  }

  @override
  Future<AppSettings> loadAppSettings() async {
    final file = File('$dbPath.settings.json');
    try {
      final type = await FileSystemEntity.type(file.path);
      if (type == FileSystemEntityType.notFound) return const AppSettings();
      if (type != FileSystemEntityType.file) {
        throw FileSystemException('设置路径不是文件', file.path);
      }
      return AppSettings.decode(await file.readAsString());
    } catch (error) {
      throw AppSettingsLoadException(error);
    }
  }

  Future<void> _settingsWrite = Future<void>.value();

  @override
  Future<void> saveAppSettings(AppSettings settings,
      {bool overwriteCorrupt = false}) {
    final write = _settingsWrite.then(
        (_) => _writeSettings(settings, overwriteCorrupt: overwriteCorrupt));
    _settingsWrite =
        write.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return write;
  }

  Future<void> _writeSettings(AppSettings settings,
      {required bool overwriteCorrupt}) async {
    if (settings.schemaVersion > AppSettings.currentSchemaVersion) {
      throw UnsupportedAppSettingsVersion(settings.schemaVersion);
    }
    final file = File('$dbPath.settings.json');
    Directory? temporaryDirectory;
    try {
      final type = await FileSystemEntity.type(file.path);
      if (type != FileSystemEntityType.notFound) {
        // Never overwrite unreadable data or a newer application's format.
        final content = await file.readAsString();
        try {
          AppSettings.decode(content);
        } on UnsupportedAppSettingsVersion {
          rethrow;
        } on FormatException {
          if (!overwriteCorrupt) rethrow;
        } on AppSettingsFormatException {
          if (!overwriteCorrupt) rethrow;
        }
      }
      temporaryDirectory = await file.parent.createTemp('.comic-settings-');
      final temporaryFile = File('${temporaryDirectory.path}/settings.json');
      final raf = await temporaryFile.open(mode: FileMode.write);
      try {
        await raf.writeString(settings.encode());
        await raf.flush();
      } finally {
        await raf.close();
      }
      // Same filesystem: readers see either the previous or complete new file.
      await temporaryFile.rename(file.path);
    } catch (error) {
      throw AppSettingsSaveException(error);
    } finally {
      if (temporaryDirectory != null) {
        try {
          await temporaryDirectory.delete(recursive: true);
        } catch (_) {
          // Cleanup cannot turn a successful atomic replacement into failure.
        }
      }
    }
  }
}

class AppSettingsLoadException implements Exception {
  const AppSettingsLoadException(this.cause);
  final Object cause;
  @override
  String toString() => '设置加载失败: $cause';
}

class AppSettingsSaveException implements Exception {
  const AppSettingsSaveException(this.cause);
  final Object cause;
  @override
  String toString() => '设置保存失败: $cause';
}

/// Maps the FFI mirror of the Rust `SeriesRow` to the UI model.
abstract final class SeriesRowToSeries {
  static Series toSeries(SeriesRow row) => Series(
        remoteId: row.remoteId,
        libraryId: row.libraryId,
        name: row.name,
        status: row.status,
        sortName: row.sortName,
        booksCount: row.booksCount?.toInt(),
        booksReadCount: row.booksReadCount?.toInt(),
        booksUnreadCount: row.booksUnreadCount?.toInt(),
        booksInProgressCount: row.booksInProgressCount?.toInt(),
      );
}

/// Maps the FFI mirror of the Rust `BookRow` to the UI model.
abstract final class BookRowToBook {
  static Book toBook(BookRow row) => Book(
        remoteId: row.remoteId,
        seriesId: row.seriesId,
        title: row.title,
        seriesTitle: row.seriesTitle,
        number: row.number,
        numberSort: row.numberSort,
        pagesCount: row.pagesCount?.toInt(),
        mediaType: row.mediaType,
        fileSize: row.fileSize?.toInt(),
        progressPage: row.progressPage?.toInt(),
        progressCompleted: row.progressCompleted,
      );
}

/// Maps the FFI mirror of `SeriesDetailRow` to the UI model.
abstract final class SeriesDetailRowToModel {
  static SeriesDetail toSeriesDetail(dynamic row) => SeriesDetail(
        remoteId: row.remoteId,
        libraryId: row.libraryId,
        name: row.name,
        sortName: row.sortName,
        status: row.status,
        booksCount: _toInt(row.booksCount),
        booksReadCount: _toInt(row.booksReadCount),
        booksUnreadCount: _toInt(row.booksUnreadCount),
        booksInProgressCount: _toInt(row.booksInProgressCount),
        summary: row.summary,
        publisher: row.publisher,
        readingDirection: row.readingDirection,
        language: row.language,
        ageRating: row.ageRating,
        totalBookCount: _toInt(row.totalBookCount),
        genres: row.genres,
        tags: row.tags,
        authors: [
          for (final a in row.authors) AuthorRow(name: a.name, role: a.role),
        ],
        collections: [
          for (final c in row.collections)
            CollectionRef(remoteId: c.remoteId, name: c.name),
        ],
      );

  static int? _toInt(dynamic value) =>
      value == null ? null : (value as num).toInt();
}

/// Maps the FFI mirror of `BookDetailRow` to the UI model.
abstract final class BookDetailRowToModel {
  static BookDetail toBookDetail(dynamic row) => BookDetail(
        remoteId: row.remoteId,
        seriesId: row.seriesId,
        title: row.title,
        seriesTitle: row.seriesTitle,
        number: row.number,
        numberSort: row.numberSort,
        summary: row.summary,
        isbn: row.isbn,
        releaseDate: row.releaseDate,
        mediaType: row.mediaType,
        pagesCount: _toInt(row.pagesCount),
        fileSize: _toInt(row.fileSize),
        tags: row.tags,
        authors: [
          for (final a in row.authors) AuthorRow(name: a.name, role: a.role),
        ],
        progressPage: _toInt(row.progressPage),
        progressCompleted: row.progressCompleted,
      );

  static int? _toInt(dynamic value) =>
      value == null ? null : (value as num).toInt();
}
