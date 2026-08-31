import 'rust/diagnostics/log.dart';
import 'rust/ffi/application.dart';
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

// The Stage 6 surface is expressed in these generated types; re-exporting just
// them keeps callers (repository, controllers) from pulling in the whole
// generated model library, where names like `FilterOptions` collide with the
// app's own view models.
export 'rust/diagnostics/log.dart' show LogRecord;
export 'rust/ffi/application.dart'
    show
        AuthStateDto,
        DiagnosticsDto,
        OutboxEntryDto,
        OutboxStatusDto,
        SsePollResult,
        UploadOutcomeDto;

/// In-memory stub so tests and the fallback UI path can run without FFI.
class StubRustCoreApi extends RustCoreApi {
  StubRustCoreApi();

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
  Future<ConnectionResult> testConnection({
    required String baseUrl,
    required String apiKey,
  }) async =>
      const ConnectionResult(
        serverInfo: ServerInfo(),
        serverVersion: null,
        libraries: [],
        capabilities: [],
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
  Future<List<ServerProfile>> listServers({required String dbPath}) async => const [];

  @override
  Future<void> saveServer({required String dbPath, required ServerProfile profile}) async {}

  @override
  Future<ServerProfile?> getServer({
    required String dbPath,
    required String serverId,
  }) async =>
      null;

  @override
  Future<bool> deleteServer({required String dbPath, required String serverId}) async => false;

  @override
  Future<void> saveLibraries({
    required String dbPath,
    required String serverId,
    required List<Library> libraries,
  }) async {}

  @override
  Future<void> setActiveServer({required String dbPath, required String serverId}) async {}

  @override
  Future<String?> getActiveServer({required String dbPath}) async => null;

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

/// A zero Reconcile summary: test doubles and the no-server path use it.
ReconcileSummary emptyReconcileSummary(String serverId, String trigger) => ReconcileSummary(
      serverId: serverId,
      trigger: trigger,
      seriesUpserted: BigInt.zero,
      seriesAdded: BigInt.zero,
      seriesChanged: BigInt.zero,
      seriesRemoved: BigInt.zero,
      booksUpserted: BigInt.zero,
      booksAdded: BigInt.zero,
      booksChanged: BigInt.zero,
      booksRemoved: BigInt.zero,
      collectionsUpserted: BigInt.zero,
      collectionsAdded: BigInt.zero,
      collectionsChanged: BigInt.zero,
      collectionsRemoved: BigInt.zero,
      readlistsUpserted: BigInt.zero,
      readlistsAdded: BigInt.zero,
      readlistsChanged: BigInt.zero,
      readlistsRemoved: BigInt.zero,
      librariesUpserted: BigInt.zero,
      librariesRemoved: BigInt.zero,
      readProgress: BigInt.zero,
      pagesSwept: 0,
      orphanedCovers: const [],
      clean: true,
    );

/// Contract for the FFI layer mirroring
/// android/komga_core/src/ffi/bridge.rs (Phase 0 step 02).
///
/// The generated bindings in lib/src/rust/ implement this contract natively;
/// [StubRustCoreApi] exists so widget tests and host tooling can run without
/// the native library.
///
/// Abstract class (not `interface`): the Stage 4 media-library surface ships
/// with flat/empty default bodies so test doubles stay small, while the
/// transport methods remain abstract.
abstract class RustCoreApi {
  /// Application Facade `bootstrap` — API-key auth, mirrors the first page.
  Future<BootstrapSummary> bootstrap({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  });

  /// Connection probe (acceptance chain): authenticate + verify Komga +
  /// fetch server info + libraries + version policy check.
  Future<ConnectionResult> testConnection({
    required String baseUrl,
    required String apiKey,
  });

  Future<List<SeriesRow>> fetchSeries({
    required String dbPath,
    required String serverId,
    int limit = 50,
    int offset = 0,
  });

  Future<List<ServerProfile>> listServers({required String dbPath});

  Future<void> saveServer({required String dbPath, required ServerProfile profile});

  Future<ServerProfile?> getServer({
    required String dbPath,
    required String serverId,
  });

  /// Deletes a server profile (clears the active-server state when needed).
  Future<bool> deleteServer({required String dbPath, required String serverId});

  /// Persist libraries discovered during a successful connection.
  Future<void> saveLibraries({
    required String dbPath,
    required String serverId,
    required List<Library> libraries,
  });

  Future<void> setActiveServer({required String dbPath, required String serverId});

  Future<String?> getActiveServer({required String dbPath});

  /// Cover file path for one series, resolved from SQLite only (null = cache
  /// miss; the UI shows a placeholder and triggers ensureCovers).
  Future<String?> coverPath({
    required String dbPath,
    required String serverId,
    required String seriesId,
  });

  /// All cover records for one server (dead files filtered out), so the
  /// grid maps remote_id → local path with a single call.
  Future<List<ThumbnailRow>> listThumbnails({
    required String dbPath,
    required String serverId,
  });

  /// Backfill one series cover (cache miss → download → disk → SQLite row),
  /// returning the local file path.
  Future<String> ensureCover({
    required String dbPath,
    required String serverId,
    required String seriesId,
    required String baseUrl,
    required String apiKey,
  });

  /// Backfill every series cover without a usable record (缓存缺失自动补齐).
  /// Returns the number of covers written.
  Future<int> ensureCovers({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  });

  /// Offline demo: seeds the store with the shared fixture series and
  /// generated covers — a demonstrable cover wall without a server.
  Future<BootstrapSummary> bootstrapDemo({
    required String dbPath,
    required String serverId,
  });

  // MARK: Stage 4 — media library (全部本地：SQLite)
  // These carry flat/empty default bodies: subclasses that extend get them
  // for free; the FRB-backed implementation overrides every one.

  /// FullSync against a live server: series → books → collections →
  /// readlists → on-deck progress.
  Future<FullSyncSummary> fullSync({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) async =>
      FullSyncSummary(
        serverId: serverId,
        libraries: BigInt.zero,
        series: BigInt.zero,
        books: BigInt.zero,
        collections: BigInt.zero,
        readlists: BigInt.zero,
        readProgress: BigInt.zero,
        seriesPages: 0,
        bookPages: 0,
        skippedSteps: const [],
        resumedSteps: const [],
      );

  /// Stage 5 Bootstrap Sync with an explicit resume policy.
  Future<FullSyncSummary> bootstrapSync({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
    required bool resume,
  }) =>
      fullSync(dbPath: dbPath, serverId: serverId, baseUrl: baseUrl, apiKey: apiKey);

  /// Stage 5 Reconcile Sync: remote id sweep → Added / Changed / Deleted.
  Future<ReconcileSummary> reconcile({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
    required String trigger,
  }) async =>
      emptyReconcileSummary(serverId, trigger);

  /// Per entity type sync state (entityType / lastSyncAt / syncCursor / syncStatus).
  Future<List<EntitySyncState>> syncStates({
    required String dbPath,
    required String serverId,
  }) async =>
      const [];

  /// Stage 10: what the last credentialed contact proved about this server's
  /// key. `unknown` until the client has actually spoken to the server.
  Future<AuthStateDto> authState({
    required String dbPath,
    required String serverId,
  }) async =>
      AuthStateDto(serverId: serverId, state: 'unknown', at: '');

  /// Stage 10: the whole self-report in one read — schema and integrity, sync
  /// rows, the outbox, the three cache tiers, the queue and the log ring.
  Future<DiagnosticsDto?> diagnosticsSnapshot({
    required String dbPath,
    required String serverId,
  }) async =>
      null;

  /// Recent core log lines, newest first. No `dbPath`: the ring is process
  /// state, and a line written before a database was opened is still worth
  /// reading.
  Future<List<LogRecord>> diagnosticsLogs({
    int limit = 100,
    String minLevel = '',
  }) async =>
      const [];

  /// Whether this trigger should sweep now (background triggers are throttled).
  Future<bool> shouldReconcile({
    required String dbPath,
    required String serverId,
    required String trigger,
  }) async =>
      true;

  /// Paged series wall with search / filters / sort (本地查询).
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
  }) async =>
      const SeriesPageResult(items: [], total: 0);

  /// Paged book list of one series with read-status / tag filters (本地查询).
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
  }) async =>
      const BookPageResult(items: [], total: 0);

  /// Full series detail (all local).
  Future<SeriesDetailRow?> seriesDetail({
    required String dbPath,
    required String serverId,
    required String seriesId,
  }) async =>
      null;

  /// Full book detail (all local).
  Future<BookDetailRow?> bookDetail({
    required String dbPath,
    required String serverId,
    required String bookId,
  }) async =>
      null;

  /// Collections searchable list (paged, local).
  Future<CollectionPageResult> listCollections({
    required String dbPath,
    required String serverId,
    String? search,
    int limit = 100,
    int offset = 0,
  }) async =>
      const CollectionPageResult(items: [], total: 0);

  /// Collection detail: row + member series (paged, local).
  Future<CollectionDetailRow?> collectionDetail({
    required String dbPath,
    required String serverId,
    required String collectionId,
    int limit = 200,
    int offset = 0,
  }) async =>
      null;

  /// Readlists searchable list (paged, local).
  Future<ReadlistPageResult> listReadlists({
    required String dbPath,
    required String serverId,
    String? search,
    int limit = 100,
    int offset = 0,
  }) async =>
      const ReadlistPageResult(items: [], total: 0);

  /// Readlist detail: row + ordered books (paged, local).
  Future<ReadlistDetailRow?> readlistDetail({
    required String dbPath,
    required String serverId,
    required String readlistId,
    int limit = 500,
    int offset = 0,
  }) async =>
      null;

  /// Continue-reading shelf (books read partially, local only).
  Future<List<ContinueReadingRow>> continueReading({
    required String dbPath,
    required String serverId,
    int limit = 10,
  }) async =>
      const [];

  /// Filter-chip options derived from the local mirror.
  Future<FilterOptions> filterOptions({
    required String dbPath,
    required String serverId,
  }) async =>
      const FilterOptions(tags: [], genres: [], statuses: []);

  /// Library rows with their local series counts (Library 列表/切换).
  Future<List<LibraryCountRow>> libraryCounts({
    required String dbPath,
    required String serverId,
  }) async =>
      const [];

  /// One library with counts + root + availability (Library 详情).
  Future<LibraryCountRow?> libraryDetail({
    required String dbPath,
    required String serverId,
    required String libraryId,
  }) async =>
      null;

  /// Local page update + outbox row (READ_PROGRESS).
  Future<void> setReadProgress({
    required String dbPath,
    required String serverId,
    required String bookId,
    required int page,
    required bool completed,
  }) async {}

  /// Explicit mark-read + outbox row (MARK_READ).
  Future<void> markRead({
    required String dbPath,
    required String serverId,
    required String bookId,
  }) async {}

  /// Explicit mark-unread + outbox row (MARK_UNREAD).
  Future<void> markUnread({
    required String dbPath,
    required String serverId,
    required String bookId,
  }) async {}

  /// Book cover file path resolved from SQLite only (null = cache miss).
  Future<String?> bookCoverPath({
    required String dbPath,
    required String serverId,
    required String bookId,
  }) async =>
      null;

  /// Backfill every book cover of one series (缓存缺失自动补齐, book variant).
  Future<int> ensureBookCovers({
    required String dbPath,
    required String serverId,
    required String seriesId,
    required String baseUrl,
    required String apiKey,
  }) async =>
      0;

  // MARK: Stage 6 — Mutation Outbox + SSE

  /// Drain everything due in the Outbox to Komga. A no-op when nothing is due,
  /// and never destructive: a row is dropped only once the server confirms.
  Future<UploadOutcomeDto> uploadOutbox({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
  }) async =>
      emptyUploadOutcome(serverId);

  /// Queued-mutation counts for the badge (SQLite only, so it works offline).
  Future<OutboxStatusDto> outboxStatus({
    required String dbPath,
    required String serverId,
  }) async =>
      emptyOutboxStatus(serverId);

  /// Hand every given-up row back to the retry machine.
  Future<int> retryFailedMutations({
    required String dbPath,
    required String serverId,
  }) async =>
      0;

  /// One bounded step of the event stream. `stateJson` is the session as the
  /// previous call returned it (empty on the first tick); it is opaque here on
  /// purpose — the reconnect schedule lives in the core, not in the UI.
  Future<SsePollResult?> ssePoll({
    required String dbPath,
    required String serverId,
    required String baseUrl,
    required String apiKey,
    required String stateJson,
  }) async =>
      null;

  /// Tell the core the owed sweep has run, so buffered events may be applied.
  Future<String> sseReconciled({
    required String dbPath,
    required String serverId,
    required String stateJson,
  }) async =>
      stateJson;

  /// Connectivity came back or the app is foreground again: make the stream due
  /// now instead of waiting out the last backoff. The owed sweep is not skipped.
  Future<String> sseResume({
    required String dbPath,
    required String serverId,
    required String stateJson,
  }) async =>
      stateJson;

  /// Drop the stream (screen disposed / server switched).
  Future<void> sseStop({
    required String dbPath,
    required String serverId,
  }) async {}
}

/// A zero upload outcome: test doubles and the no-server path use it.
UploadOutcomeDto emptyUploadOutcome(String serverId) => UploadOutcomeDto(
      serverId: serverId,
      considered: 0,
      uploaded: 0,
      alreadyApplied: 0,
      remoteWins: 0,
      gone: 0,
      retried: 0,
      rejected: 0,
      blockedAuthentication: 0,
      status: 'complete',
      outbox: emptyOutboxStatus(serverId),
    );

/// An empty Outbox status.
OutboxStatusDto emptyOutboxStatus(String serverId) => OutboxStatusDto(
      serverId: serverId,
      pending: 0,
      waiting: 0,
      failed: 0,
      total: 0,
      failedEntries: const [],
    );
