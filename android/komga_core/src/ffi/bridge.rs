//! FFI Adapter — stateless, coarse-grained entry points for Flutter.
//!
//! These are the functions flutter_rust_bridge_codegen should mirror to
//! Dart (Phase 0 step 02):
//!
//!   1. enable the `frb` feature (Cargo.toml)
//!   2. run flutter_rust_bridge_codegen with the bridge pattern
//!   3. the generated rust_lib_komga_core replaces StubLibraryRepository
//!      in android/app/lib/src/library_repository.dart
//!
//! Adapter types stay plain Rust (String / Result / domain structs); only
//! the generated frb_generated.rs may depend on flutter_rust_bridge.

use crate::api::server::Library;
use crate::diagnostics::{LogRecord, LogStats};
use crate::ffi::application::{AuthStateDto, DiagnosticsDto};
use crate::ffi::application::{
    BookDetailRow, CacheCleanupDto, CacheStatsDto, CollectionDetailRow, CollectionPageResult,
    ConnectionResult, DeviceProfileDto, DownloadBookDto, DownloadDeleteDto, DownloadPumpDto,
    DownloadSweepDto, FilterOptions, OutboxStatusDto, ReaderBookDto, ReaderLayoutDto,
    ReaderSettingsDto, ReaderTurnDto, ReaderWindowDto, ReadlistDetailRow, ReadlistPageResult,
    SeriesDetailRow, SsePollResult, StorageDto, UploadOutcomeDto,
};
use crate::ffi::error::CoreError;
use crate::model::server_profile::ServerProfile;
use crate::store::prune::Tombstone;
use crate::store::query::{BookPageResult, LibraryCountRow, SeriesPageResult};
use crate::store::read_progress::ContinueReadingRow;
use crate::store::series::SeriesRow;
use crate::store::sync_state::EntitySyncState;
use crate::store::thumbnails::ThumbnailRow;
use crate::sync::{BootstrapSummary, FullSyncSummary, ReconcileSummary};

/// BootstrapSync (API Key auth) — mirrors the first page of series.
pub async fn bootstrap(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
) -> Result<BootstrapSummary, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.bootstrap(server_id, base_url, api_key)
        .await
        .map_err(CoreError::from)
}

/// Connection probe (acceptance chain): authenticate + verify Komga +
/// fetch server info + libraries + version policy check.
pub async fn test_connection(
    base_url: String,
    api_key: String,
) -> Result<ConnectionResult, CoreError> {
    let app = crate::ffi::application::App::new(String::new());
    app.test_connection(base_url, api_key)
        .await
        .map_err(CoreError::from)
}

pub fn save_server(db_path: String, profile: ServerProfile) -> Result<(), CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.save_server(&profile).map_err(CoreError::from)
}

pub fn list_servers(db_path: String) -> Result<Vec<ServerProfile>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.list_servers().map_err(CoreError::from)
}

pub fn get_server(db_path: String, server_id: String) -> Result<Option<ServerProfile>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.get_server(&server_id).map_err(CoreError::from)
}

pub fn delete_server(db_path: String, server_id: String) -> Result<bool, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.delete_server(&server_id).map_err(CoreError::from)
}

/// Persist libraries discovered during a successful connection.
pub fn save_libraries(
    db_path: String,
    server_id: String,
    libraries: Vec<Library>,
) -> Result<(), CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.save_libraries(&server_id, &libraries)
        .map_err(CoreError::from)
}

pub fn set_active_server(db_path: String, server_id: String) -> Result<(), CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.set_active_server(&server_id).map_err(CoreError::from)
}

pub fn get_active_server(db_path: String) -> Result<Option<String>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.get_active_server().map_err(CoreError::from)
}

pub fn fetch_series(
    db_path: String,
    server_id: String,
    limit: i64,
    offset: i64,
) -> Result<Vec<SeriesRow>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.fetch_series(&server_id, limit, offset)
        .map_err(CoreError::from)
}

// MARK: - Cover cache (the grid resolves cover files from SQLite)

/// Cover file path for one series, resolved from SQLite only (None = cache
/// miss; the UI shows a placeholder and triggers ensure_covers).
pub fn cover_path(
    db_path: String,
    server_id: String,
    series_id: String,
) -> Result<Option<String>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.cover_path(&server_id, &series_id)
        .map_err(CoreError::from)
}

/// All cover records for one server (dead files filtered out), so the grid
/// maps remote_id → local path with a single call.
pub fn list_thumbnails(db_path: String, server_id: String) -> Result<Vec<ThumbnailRow>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.list_thumbnails(&server_id).map_err(CoreError::from)
}

/// Backfill one series cover (cache miss → download → disk → SQLite row),
/// returning the local file path.
pub async fn ensure_cover(
    db_path: String,
    server_id: String,
    series_id: String,
    base_url: String,
    api_key: String,
) -> Result<String, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.ensure_cover(server_id, series_id, base_url, api_key)
        .await
        .map_err(CoreError::from)
}

/// Backfill every series cover without a usable record (缓存缺失自动补齐).
/// Returns the number of covers written.
pub async fn ensure_covers(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
) -> Result<i64, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.ensure_covers(server_id, base_url, api_key)
        .await
        .map(|n| n as i64)
        .map_err(CoreError::from)
}

/// Offline demo: seeds the store with the shared fixture series and
/// generated covers — a demonstrable cover wall without a server.
pub async fn bootstrap_demo(
    db_path: String,
    server_id: String,
) -> Result<BootstrapSummary, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.bootstrap_demo(server_id).await.map_err(CoreError::from)
}

// MARK: - Full mirror sync (media library)

/// FullSync against a live server: series → books → collections →
/// readlists → on-deck progress.
pub async fn full_sync(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
) -> Result<FullSyncSummary, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.full_sync(server_id, base_url, api_key)
        .await
        .map_err(CoreError::from)
}

/// Stage 5 Bootstrap Sync: ordered, paged, checkpointed. `resume = true`
/// continues an interrupted run from its stored cursors.
pub async fn bootstrap_sync(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
    resume: bool,
) -> Result<FullSyncSummary, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.bootstrap_sync(server_id, base_url, api_key, !resume)
        .await
        .map_err(CoreError::from)
}

/// Stage 5 Reconcile Sync: remote id sweep → Added / Changed / Deleted →
/// local mirror. `trigger` is one of `app_launch`, `did_become_active`,
/// `network_recovered`, `sse_reconnected`, `manual_refresh`.
pub async fn reconcile(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
    trigger: String,
) -> Result<ReconcileSummary, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reconcile(server_id, base_url, api_key, trigger)
        .await
        .map_err(CoreError::from)
}

/// Whether this trigger should sweep now (background triggers are throttled).
pub fn should_reconcile(
    db_path: String,
    server_id: String,
    trigger: String,
) -> Result<bool, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.should_reconcile(&server_id, &trigger)
        .map_err(CoreError::from)
}

/// Per entity type sync state: entityType / lastSyncAt / syncCursor / syncStatus.
pub fn sync_states(db_path: String, server_id: String) -> Result<Vec<EntitySyncState>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.sync_states(&server_id).map_err(CoreError::from)
}

/// Tombstones left by delete propagation for one entity type.
pub fn tombstones(
    db_path: String,
    server_id: String,
    entity_type: String,
) -> Result<Vec<Tombstone>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.tombstones(&server_id, &entity_type)
        .map_err(CoreError::from)
}

// MARK: - Media library queries (全部本地：SQLite，断开网络依旧可用)

/// Paged series wall with search / filters / sort (本地查询).
#[allow(clippy::too_many_arguments)]
pub fn query_series(
    db_path: String,
    server_id: String,
    search: Option<String>,
    library_id: Option<String>,
    status: Option<String>,
    tag: Option<String>,
    genre: Option<String>,
    sort: String,
    ascending: bool,
    limit: i64,
    offset: i64,
) -> Result<SeriesPageResult, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.query_series(
        &server_id, search, library_id, status, tag, genre, sort, ascending, limit, offset,
    )
    .map_err(CoreError::from)
}

/// Paged book list of one series with read-status / tag filters (本地查询).
#[allow(clippy::too_many_arguments)]
pub fn query_books(
    db_path: String,
    server_id: String,
    series_id: String,
    search: Option<String>,
    read_status: Option<String>,
    tag: Option<String>,
    sort: String,
    ascending: bool,
    limit: i64,
    offset: i64,
) -> Result<BookPageResult, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.query_books(
        &server_id,
        &series_id,
        search,
        read_status,
        tag,
        sort,
        ascending,
        limit,
        offset,
    )
    .map_err(CoreError::from)
}

/// Full series detail: row + metadata + genres + tags + authors +
/// collection memberships (all local).
pub fn series_detail(
    db_path: String,
    server_id: String,
    series_id: String,
) -> Result<Option<SeriesDetailRow>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.series_detail(&server_id, &series_id)
        .map_err(CoreError::from)
}

/// Full book detail: row + metadata + tags + authors + progress (local).
pub fn book_detail(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<Option<BookDetailRow>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.book_detail(&server_id, &book_id)
        .map_err(CoreError::from)
}

/// Collections searchable list (paged, local).
pub fn list_collections(
    db_path: String,
    server_id: String,
    search: Option<String>,
    limit: i64,
    offset: i64,
) -> Result<CollectionPageResult, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.list_collections(&server_id, search, limit, offset)
        .map_err(CoreError::from)
}

/// Collection detail: the row + its member series (paged, local).
pub fn collection_detail(
    db_path: String,
    server_id: String,
    collection_id: String,
    limit: i64,
    offset: i64,
) -> Result<Option<CollectionDetailRow>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.collection_detail(&server_id, &collection_id, limit, offset)
        .map_err(CoreError::from)
}

/// Readlists searchable list (paged, local).
pub fn list_readlists(
    db_path: String,
    server_id: String,
    search: Option<String>,
    limit: i64,
    offset: i64,
) -> Result<ReadlistPageResult, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.list_readlists(&server_id, search, limit, offset)
        .map_err(CoreError::from)
}

/// Readlist detail: the row + its ordered books (paged, local).
pub fn readlist_detail(
    db_path: String,
    server_id: String,
    readlist_id: String,
    limit: i64,
    offset: i64,
) -> Result<Option<ReadlistDetailRow>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.readlist_detail(&server_id, &readlist_id, limit, offset)
        .map_err(CoreError::from)
}

/// Continue-reading shelf (books read partially, local only).
pub fn continue_reading(
    db_path: String,
    server_id: String,
    limit: i64,
) -> Result<Vec<ContinueReadingRow>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.continue_reading(&server_id, limit)
        .map_err(CoreError::from)
}

/// Filter-chip options derived from the local mirror (tags / genres /
/// statuses), distinct + sorted.
pub fn filter_options(db_path: String, server_id: String) -> Result<FilterOptions, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.filter_options(&server_id).map_err(CoreError::from)
}

/// Library rows with their local series counts (Library 列表/切换).
pub fn library_counts(
    db_path: String,
    server_id: String,
) -> Result<Vec<LibraryCountRow>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.library_counts(&server_id).map_err(CoreError::from)
}

/// One library with counts + root + availability (Library 详情).
pub fn library_detail(
    db_path: String,
    server_id: String,
    library_id: String,
) -> Result<Option<LibraryCountRow>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.library_detail(&server_id, &library_id)
        .map_err(CoreError::from)
}

// MARK: - Reading status (本地优先 + Mutation Outbox)

/// Local page update + outbox row (READ_PROGRESS).
pub fn set_read_progress(
    db_path: String,
    server_id: String,
    book_id: String,
    page: i64,
    completed: bool,
) -> Result<(), CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.set_read_progress(&server_id, &book_id, page, completed)
        .map_err(CoreError::from)
}

/// Explicit mark-read + outbox row (MARK_READ).
pub fn mark_read(db_path: String, server_id: String, book_id: String) -> Result<(), CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.mark_read(&server_id, &book_id).map_err(CoreError::from)
}

/// Explicit mark-unread + outbox row (MARK_UNREAD).
pub fn mark_unread(db_path: String, server_id: String, book_id: String) -> Result<(), CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.mark_unread(&server_id, &book_id)
        .map_err(CoreError::from)
}

// MARK: - Stage 6: Mutation Upload Sync (Outbox drain)

/// One upload pass over the queued mutations, plus the queue it left behind.
/// Safe to call after every local write, on foreground, on network recovery and
/// on a timer — an eligible row is only ever dropped once the server confirms.
pub async fn upload_outbox(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
) -> Result<UploadOutcomeDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.upload_outbox(server_id, base_url, api_key)
        .await
        .map_err(CoreError::from)
}

/// The Outbox badge plus the rows that gave up (UI lists those with a retry).
pub fn outbox_status(db_path: String, server_id: String) -> Result<OutboxStatusDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.outbox_status(&server_id).map_err(CoreError::from)
}

/// Hand every given-up row back to the retry machine. Returns how many came
/// back to `pending`.
pub fn retry_failed_mutations(db_path: String, server_id: String) -> Result<i64, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.retry_failed_mutations(&server_id)
        .map(|n| n as i64)
        .map_err(CoreError::from)
}

// MARK: - Stage 6: Event Driven Sync (pollable SSE)

/// One bounded event-stream tick. `state_json` is the previous tick's state —
/// opaque here, owned by the caller, which is what keeps start/stop (and so
/// pause-on-background) on the app side. `None` means a tick is still running
/// for this server: skip this beat.
pub async fn sse_poll(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
    state_json: String,
) -> Result<Option<SsePollResult>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.sse_poll(server_id, base_url, api_key, state_json)
        .await
        .map_err(CoreError::from)
}

/// The reconcile `sse_poll` asked for has run: release the events that arrived
/// during it and hand the session back to the stream.
pub fn sse_reconciled(db_path: String, state_json: String) -> Result<String, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.sse_reconciled(state_json).map_err(CoreError::from)
}

/// Make one server's event stream due now (network came back / foreground).
pub fn sse_resume(db_path: String, state_json: String) -> Result<String, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.sse_resume(state_json).map_err(CoreError::from)
}

/// Drop this server's parked stream (screen disposed / server switched).
pub fn sse_stop(db_path: String, server_id: String) -> Result<(), CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.sse_stop(&server_id);
    Ok(())
}

// MARK: - Book covers (SQLite-resolved paths, `variant = 'book'`)

/// Book cover file path resolved from SQLite only (None = cache miss).
pub fn book_cover_path(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<Option<String>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.book_cover_path(&server_id, &book_id)
        .map_err(CoreError::from)
}

/// Backfill one book cover (cache miss → download → disk → SQLite row),
/// returning the local file path.
pub async fn ensure_book_cover(
    db_path: String,
    server_id: String,
    book_id: String,
    base_url: String,
    api_key: String,
) -> Result<String, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.ensure_book_cover(server_id, book_id, base_url, api_key)
        .await
        .map_err(CoreError::from)
}

/// Backfill every book cover of one series (缓存缺失自动补齐, book variant).
/// Returns the number of covers written.
pub async fn ensure_book_covers(
    db_path: String,
    server_id: String,
    series_id: String,
    base_url: String,
    api_key: String,
) -> Result<i64, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.ensure_book_covers(server_id, series_id, base_url, api_key)
        .await
        .map(|n| n as i64)
        .map_err(CoreError::from)
}

// ---------------------------------------------------------------------------
// Stage 7 — reader. The UI asks for pages and gets local file paths; the
// manifest fetch, the page fetch, the cache and the progress write all live on
// the Rust side, which is what keeps transport out of the widget tree.
// ---------------------------------------------------------------------------

/// Open a book: mirror-or-read the page manifest, restore the position, and
/// return the spread layout to draw. `mode` / `direction` / `firstPageSingle`
/// may be empty / null to mean "use what is stored".
#[allow(clippy::too_many_arguments)]
pub async fn reader_open(
    db_path: String,
    server_id: String,
    book_id: String,
    base_url: String,
    api_key: String,
    mode: String,
    direction: String,
    first_page_single: Option<bool>,
) -> Result<ReaderBookDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_open(
        server_id,
        book_id,
        base_url,
        api_key,
        mode,
        direction,
        first_page_single,
    )
    .await
    .map_err(CoreError::from)
}

/// Where a page already is on disk, if anywhere. Never touches the network.
pub fn reader_page_path(
    db_path: String,
    server_id: String,
    book_id: String,
    page: i64,
) -> Result<Option<String>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_page_path(server_id, book_id, page)
        .map_err(CoreError::from)
}

/// Resolve one page for display (cache first, then fetch).
pub async fn reader_page(
    db_path: String,
    server_id: String,
    book_id: String,
    page: i64,
    base_url: String,
    api_key: String,
) -> Result<String, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_page(server_id, book_id, page, base_url, api_key)
        .await
        .map_err(CoreError::from)
}

/// Pull the pages around one spread into the cache; returns how many landed.
pub async fn reader_prefetch(
    db_path: String,
    server_id: String,
    book_id: String,
    spread: i64,
    base_url: String,
    api_key: String,
) -> Result<i64, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_prefetch(server_id, book_id, spread, base_url, api_key)
        .await
        .map_err(CoreError::from)
}

/// Report the device and link, and get back the window and cache numbers the
/// core derived. Called on open and again when the network changes.
pub fn reader_configure_device(
    db_path: String,
    server_id: String,
    book_id: String,
    device: DeviceProfileDto,
) -> Result<ReaderWindowDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_configure_device(server_id, book_id, device)
        .map_err(CoreError::from)
}

/// What the cache tiers and the memory tier hold right now.
pub fn reader_cache_stats(db_path: String) -> Result<CacheStatsDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_cache_stats().map_err(CoreError::from)
}

/// Run the cleanup sweep now: ghost rows, orphan files, stale `.part` debris and
/// entries whose bytes are no longer a whole image.
pub fn reader_reconcile_cache(db_path: String) -> Result<CacheCleanupDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_reconcile_cache().map_err(CoreError::from)
}

/// Drop the prefetched-but-never-displayed bytes. Displayed pages and offline
/// downloads are untouched by construction.
pub fn reader_clear_prefetch(db_path: String) -> Result<i64, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_clear_prefetch().map_err(CoreError::from)
}

/// Release the RAM the prefetch tier mirrors, keeping the tier. This is the
/// `onTrimMemory` answer: a stored file costs no RAM, and deleting the tier here
/// made every backgrounding cost a fresh window of downloads on resume.
pub fn reader_release_prefetch(db_path: String) -> Result<i64, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_release_prefetch().map_err(CoreError::from)
}

/// Turn to a page. Returns the resolved page/spread and whether an upload is due.
pub fn reader_turn(
    db_path: String,
    server_id: String,
    book_id: String,
    page: i64,
) -> Result<ReaderTurnDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_turn(server_id, book_id, page)
        .map_err(CoreError::from)
}

/// Move one spread forward (delta >= 0) or backward (delta < 0).
pub fn reader_step(
    db_path: String,
    server_id: String,
    book_id: String,
    delta: i64,
) -> Result<ReaderTurnDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_step(server_id, book_id, delta)
        .map_err(CoreError::from)
}

/// Change mode / direction mid-book without losing the place.
pub fn reader_set_layout(
    db_path: String,
    server_id: String,
    book_id: String,
    mode: String,
    direction: String,
) -> Result<ReaderLayoutDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_set_layout(server_id, book_id, mode, direction)
        .map_err(CoreError::from)
}

/// Mark read / mark unread: explicit statements, so they are never throttled.
pub fn reader_mark_read(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<bool, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_mark_read(server_id, book_id)
        .map_err(CoreError::from)
}

pub fn reader_mark_unread(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<bool, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_mark_unread(server_id, book_id)
        .map_err(CoreError::from)
}

/// The UI's periodic beat. True means: run `upload_outbox` now.
pub fn reader_tick(db_path: String, server_id: String, book_id: String) -> Result<bool, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_tick(server_id, book_id).map_err(CoreError::from)
}

/// Backgrounding: flush-worthy now, reader stays open.
pub fn reader_background(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<bool, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_background(server_id, book_id)
        .map_err(CoreError::from)
}

/// Leaving the reader for good. True means one last upload should be attempted.
pub fn reader_close(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<bool, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_close(server_id, book_id)
        .map_err(CoreError::from)
}

pub fn reader_settings(db_path: String) -> Result<ReaderSettingsDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_settings().map_err(CoreError::from)
}

pub fn reader_set_settings(
    db_path: String,
    settings: ReaderSettingsDto,
) -> Result<ReaderSettingsDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.reader_set_settings(settings).map_err(CoreError::from)
}

// ---------------------------------------------------------------------------
// Stage 9 — offline downloads. One entry is async (the pump); the rest are
// stateless reads and writes of SQLite plus the download tree, and not one of them
// can make a request.
// ---------------------------------------------------------------------------

/// Put a book in the download queue. Works offline: the mirrored manifest already
/// says what the book contains, and a book that was never mirrored cannot be queued.
pub fn download_enqueue(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<DownloadBookDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_enqueue(server_id, book_id)
        .map_err(CoreError::from)
}

/// Stop a download. Only the user may do this, and only the user may undo it.
pub fn download_pause(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<DownloadBookDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_pause(server_id, book_id)
        .map_err(CoreError::from)
}

pub fn download_resume(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<DownloadBookDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_resume(server_id, book_id)
        .map_err(CoreError::from)
}

/// Re-queue a book's failed pages. Pages already on disk are not fetched again.
pub fn download_retry(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<DownloadBookDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_retry(server_id, book_id)
        .map_err(CoreError::from)
}

/// The explicit "spend my data" consent, per book.
pub fn download_set_allow_cellular(
    db_path: String,
    server_id: String,
    book_id: String,
    allow: bool,
) -> Result<DownloadBookDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_set_allow_cellular(server_id, book_id, allow)
        .map_err(CoreError::from)
}

/// Delete a download: rows and files. The only way anything under `downloads/`
/// leaves the disk on purpose.
pub fn download_delete(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<DownloadDeleteDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_delete(server_id, book_id)
        .map_err(CoreError::from)
}

/// Clear every download for one server, including directories the database has no
/// row for.
pub fn download_delete_all(
    db_path: String,
    server_id: String,
) -> Result<DownloadDeleteDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_delete_all(server_id).map_err(CoreError::from)
}

/// The queue, as SQLite knows it. No network and no filesystem walk.
pub fn download_list(
    db_path: String,
    server_id: String,
) -> Result<Vec<DownloadBookDto>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_list(server_id).map_err(CoreError::from)
}

/// What the device holds and what it says it has left. `free_volume_bytes` comes
/// from the platform; `0` means it would not say.
pub fn download_storage(db_path: String, free_volume_bytes: i64) -> Result<StorageDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_storage(free_volume_bytes)
        .map_err(CoreError::from)
}

/// Reconcile the download tree with its rows on demand. Also runs once per process
/// on the first pump or list; this is the version whose report a harness reads.
pub fn download_sweep(db_path: String) -> Result<DownloadSweepDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_sweep().map_err(CoreError::from)
}

/// Drive the queue one bounded step. `Ok(None)` means another pass holds this
/// database — the same contract as `sse_poll`, for the same reason.
#[allow(clippy::too_many_arguments)]
pub async fn download_pump(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
    max_pages: i64,
    max_bytes: i64,
    free_volume_bytes: i64,
    link: String,
) -> Result<Option<DownloadPumpDto>, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.download_pump(
        server_id,
        base_url,
        api_key,
        max_pages,
        max_bytes,
        free_volume_bytes,
        link,
    )
    .await
    .map_err(CoreError::from)
}

// MARK: - Stage 10: diagnostics, the credential verdict, and the log ring

/// What the last credentialed contact proved about one server's key:
/// `valid`, `expired` or `unknown`, and when it was proved. The shelf shows a
/// re-authenticate entry off this and nothing else.
pub fn auth_state(db_path: String, server_id: String) -> Result<AuthStateDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.auth_state(&server_id).map_err(CoreError::from)
}

/// Everything the client can say about itself in one read — schema and integrity,
/// sync rows, the outbox, the three cache tiers, the queue, the API policy and
/// the log ring. Reports only; no sweep or reconcile runs because somebody
/// asked what the state was.
pub fn diagnostics_snapshot(
    db_path: String,
    server_id: String,
) -> Result<DiagnosticsDto, CoreError> {
    let app = crate::ffi::application::App::new(db_path);
    app.diagnostics_snapshot(&server_id)
        .map_err(CoreError::from)
}

/// Recent core log lines, newest first. `min_level` is one of `error`, `warn`,
/// `info`, `debug`, `trace`; anything else means no filter, so a typo in a
/// filter box shows everything rather than pretending nothing happened.
pub fn diagnostics_logs(limit: i64, min_level: String) -> Result<Vec<LogRecord>, CoreError> {
    // Deliberately not taking a `db_path`: the ring is process state, and a
    // log line that survived a closed database is still worth reading.
    Ok(crate::diagnostics::log::records(
        limit.max(0) as usize,
        crate::diagnostics::log::parse_level(&min_level),
    ))
}

/// The ring's own counters: whether it owns the log backend, what it holds, how
/// much it has evicted, and the newest error line.
pub fn diagnostics_log_stats() -> Result<LogStats, CoreError> {
    Ok(crate::diagnostics::log::stats())
}
