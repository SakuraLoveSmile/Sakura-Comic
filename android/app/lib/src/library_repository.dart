import 'downloads_api.dart';
import 'reader_api.dart';
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

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
  Future<ReaderApi> readerApi({required String bookId}) async => InMemoryReaderApi();

  /// The download surface for the active server. Defaults to the in-memory queue so
  /// a build without the native library (or a widget test) still renders the screen;
  /// `RustLibraryRepository` overrides it with the FFI one.
  Future<DownloadsApi> downloadsApi() async => InMemoryDownloadsApi();

  /// Cover file paths for the active server, resolved from SQLite
  /// (remote_id → local path). Missing covers are rendered as placeholders.
  Future<Map<String, String>> fetchCoverPaths();

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
  Future<ReconcileReport?> reconcileActiveServer({required String trigger}) async => null;

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

  Stream<List<Series>> observeSeries();

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
  }) async =>
      PagedSeries(items: await fetchSeries(), total: (await fetchSeries()).length);

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

  Future<PagedCollections> listCollections({String? search, int limit = 100, int offset = 0}) async =>
      const PagedCollections(items: [], total: 0);

  Future<CollectionDetail?> collectionDetail({required String collectionId}) async => null;

  Future<PagedReadlists> listReadlists({String? search, int limit = 100, int offset = 0}) async =>
      const PagedReadlists(items: [], total: 0);

  Future<ReadlistDetail?> readlistDetail({required String readlistId}) async => null;

  Future<List<ContinueReadingItem>> continueReading({int limit = 10}) async => const [];

  Future<FilterOptions> fetchFilterOptions() async => const FilterOptions();

  Future<List<LibraryCount>> fetchLibraryCounts() async => const [];

  /// One library with counts / root / availability (Library 详情).
  Future<LibraryCount?> libraryDetail({required String libraryId}) async => null;

  Future<Map<String, String>> fetchBookCoverPaths() async => const {};

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
}

/// In-memory stub so the grid UI can be built and tested without FFI.
class StubLibraryRepository extends LibraryRepository {
  const StubLibraryRepository() : super();

  @override
  Future<List<Series>> fetchSeries({int limit = 50, int offset = 0}) async => const [];

  @override
  Future<Map<String, String>> fetchCoverPaths() async => const {};

  @override
  Future<BootstrapSummary?> bootstrapActiveServer({bool resume = true}) async => null;

  @override
  Future<int> syncCovers() async => 0;

  @override
  Future<BootstrapSummary> loadDemo() async => _emptySummary('demo');

  @override
  bool get demoSupported => false;

  @override
  Stream<List<Series>> observeSeries() => const Stream.empty();

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

  @override
  Future<PagedCollections> listCollections(
          {String? search, int limit = 100, int offset = 0}) async =>
      const PagedCollections(items: [], total: 0);

  @override
  Future<CollectionDetail?> collectionDetail({required String collectionId}) async => null;

  @override
  Future<PagedReadlists> listReadlists(
          {String? search, int limit = 100, int offset = 0}) async =>
      const PagedReadlists(items: [], total: 0);

  @override
  Future<ReadlistDetail?> readlistDetail({required String readlistId}) async => null;

  @override
  Future<List<ContinueReadingItem>> continueReading({int limit = 10}) async => const [];

  @override
  Future<FilterOptions> fetchFilterOptions() async => const FilterOptions();

  @override
  Future<List<LibraryCount>> fetchLibraryCounts() async => const [];

  @override
  Future<Map<String, String>> fetchBookCoverPaths() async => const {};

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
        _serverManager = serverManager;

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
    final page = await _api.querySeries(dbPath: dbPath, serverId: serverId, limit: limit, offset: offset);
    debugPrint('[RustCore] fetchSeries($serverId) -> ${page.items.length}/${page.total}');
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
  Future<Map<String, String>> fetchCoverPaths() async {
    final serverId = await _activeServerId();
    if (serverId == null) return const {};
    final rows = await _api.listThumbnails(dbPath: dbPath, serverId: serverId);
    return {
      for (final row in rows)
        if (row.variant == 'series') row.remoteId: row.localPath,
    };
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
  Future<ReconcileReport?> reconcileActiveServer({required String trigger}) async {
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
    final added = (summary.seriesAdded + summary.booksAdded +
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
        .where((state) => state.syncCursor != null && state.entityType != 'full')
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
    final summary = await _api.bootstrapDemo(dbPath: dbPath, serverId: serverId);
    await _api.setActiveServer(dbPath: dbPath, serverId: serverId);
    debugPrint('[RustCore] bootstrapDemo -> ${summary.syncedSeries} series');
    return summary;
  }

  @override
  bool get demoSupported => true;

  @override
  Stream<List<Series>> observeSeries() {
    return Stream.periodic(const Duration(seconds: 15), (_) => null).asyncMap(
      (_) async {
        try {
          return await fetchSeries();
        } catch (_) {
          return const <Series>[];
        }
      },
    );
  }

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
    final row = await _api.seriesDetail(dbPath: dbPath, serverId: serverId, seriesId: seriesId);
    if (row == null) return null;
    return SeriesDetailRowToModel.toSeriesDetail(row);
  }

  @override
  Future<BookDetail?> bookDetail({required String bookId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final row = await _api.bookDetail(dbPath: dbPath, serverId: serverId, bookId: bookId);
    if (row == null) return null;
    return BookDetailRowToModel.toBookDetail(row);
  }

  @override
  Future<PagedCollections> listCollections({String? search, int limit = 100, int offset = 0}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return const PagedCollections(items: [], total: 0);
    final page = await _api.listCollections(
      dbPath: dbPath, serverId: serverId, search: search, limit: limit, offset: offset,
    );
    return PagedCollections(
      items: page.items
          .map((r) => CollectionItem(remoteId: r.remoteId, name: r.name, ordered: r.ordered))
          .toList(),
      total: page.total.toInt(),
    );
  }

  @override
  Future<CollectionDetail?> collectionDetail({required String collectionId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final row = await _api.collectionDetail(
      dbPath: dbPath, serverId: serverId, collectionId: collectionId, limit: 200, offset: 0,
    );
    if (row == null) return null;
    return CollectionDetail(
      item: CollectionItem(remoteId: row.remoteId, name: row.name, ordered: row.ordered),
      members: PagedSeries(
        items: row.members.items.map(SeriesRowToSeries.toSeries).toList(),
        total: row.members.total.toInt(),
      ),
    );
  }

  @override
  Future<PagedReadlists> listReadlists({String? search, int limit = 100, int offset = 0}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return const PagedReadlists(items: [], total: 0);
    final page = await _api.listReadlists(
      dbPath: dbPath, serverId: serverId, search: search, limit: limit, offset: offset,
    );
    return PagedReadlists(
      items: page.items
          .map((r) => ReadlistItem(remoteId: r.remoteId, name: r.name, summary: r.summary, ordered: r.ordered))
          .toList(),
      total: page.total.toInt(),
    );
  }

  @override
  Future<ReadlistDetail?> readlistDetail({required String readlistId}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return null;
    final row = await _api.readlistDetail(
      dbPath: dbPath, serverId: serverId, readlistId: readlistId, limit: 500, offset: 0,
    );
    if (row == null) return null;
    return ReadlistDetail(
      item: ReadlistItem(remoteId: row.remoteId, name: row.name, summary: row.summary, ordered: row.ordered),
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
    final rows = await _api.continueReading(dbPath: dbPath, serverId: serverId, limit: limit);
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
    final options = await _api.filterOptions(dbPath: dbPath, serverId: serverId);
    return FilterOptions(tags: options.tags, genres: options.genres, statuses: options.statuses);
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
  Future<Map<String, String>> fetchBookCoverPaths() async {
    final serverId = await _activeServerId();
    if (serverId == null) return const {};
    final rows = await _api.listThumbnails(dbPath: dbPath, serverId: serverId);
    return {
      for (final row in rows)
        if (row.variant == 'book') row.remoteId: row.localPath,
    };
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
      dbPath: dbPath, serverId: serverId, bookId: bookId, page: page, completed: completed,
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

  @override
  Future<SsePollResult?> ssePoll({required String stateJson}) async {
    final credential = await _activeCredential();
    if (credential == null) return null;
    final (profile, apiKey) = credential;
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
    final serverId = await _activeServerId();
    if (serverId == null) return stateJson;
    return _api.sseReconciled(dbPath: dbPath, serverId: serverId, stateJson: stateJson);
  }

  @override
  Future<String> sseResume({required String stateJson}) async {
    final serverId = await _activeServerId();
    if (serverId == null) return stateJson;
    return _api.sseResume(dbPath: dbPath, serverId: serverId, stateJson: stateJson);
  }

  @override
  Future<void> sseStop() async {
    final serverId = await _activeServerId();
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
  Future<String?> _activeServerId() async {
    final servers = await _api.listServers(dbPath: dbPath);
    if (servers.isEmpty) {
      // A demo seed leaves the media tables populated and `active_server_id`
      // set, but no `servers` row (the demo server has no base URL to store).
      // The demo id is the one id queries must accept even without a row.
      final demo = await _api.getActiveServer(dbPath: dbPath);
      if (demo == 'demo') return 'demo';
      return null;
    }
    final activeId = await _api.getActiveServer(dbPath: dbPath);
    return activeId ?? servers.first.id;
  }

  /// (profile, apiKey) for the active server — or null when unavailable
  /// (no server / no stored secret).
  Future<(ServerProfile, String)?> _activeCredential() async {
    final manager = _serverManager;
    if (manager == null) return null;
    final servers = await _api.listServers(dbPath: dbPath);
    if (servers.isEmpty) return null;
    final activeId = await _api.getActiveServer(dbPath: dbPath);
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
          for (final c in row.collections) CollectionRef(remoteId: c.remoteId, name: c.name),
        ],
      );

  static int? _toInt(dynamic value) => value == null ? null : (value as num).toInt();
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

  static int? _toInt(dynamic value) => value == null ? null : (value as num).toInt();
}

