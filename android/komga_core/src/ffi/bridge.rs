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
use crate::ffi::application::{
    BookDetailRow, CollectionDetailRow, CollectionPageResult, ConnectionResult, FilterOptions,
    OutboxStatusDto, ReadlistDetailRow, ReadlistPageResult, SeriesDetailRow, SsePollResult,
    UploadOutcomeDto,
};
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
) -> Result<BootstrapSummary, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.bootstrap(server_id, base_url, api_key)
        .await
        .map_err(|e| e.to_string())
}

/// Connection probe (acceptance chain): authenticate + verify Komga +
/// fetch server info + libraries + version policy check.
pub async fn test_connection(
    base_url: String,
    api_key: String,
) -> Result<ConnectionResult, String> {
    let app = crate::ffi::application::App::new(String::new());
    app.test_connection(base_url, api_key)
        .await
        .map_err(|e| e.to_string())
}

pub fn save_server(db_path: String, profile: ServerProfile) -> Result<(), String> {
    let app = crate::ffi::application::App::new(db_path);
    app.save_server(&profile).map_err(|e| e.to_string())
}

pub fn list_servers(db_path: String) -> Result<Vec<ServerProfile>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.list_servers().map_err(|e| e.to_string())
}

pub fn get_server(db_path: String, server_id: String) -> Result<Option<ServerProfile>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.get_server(&server_id).map_err(|e| e.to_string())
}

pub fn delete_server(db_path: String, server_id: String) -> Result<bool, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.delete_server(&server_id).map_err(|e| e.to_string())
}

/// Persist libraries discovered during a successful connection.
pub fn save_libraries(
    db_path: String,
    server_id: String,
    libraries: Vec<Library>,
) -> Result<(), String> {
    let app = crate::ffi::application::App::new(db_path);
    app.save_libraries(&server_id, &libraries)
        .map_err(|e| e.to_string())
}

pub fn set_active_server(db_path: String, server_id: String) -> Result<(), String> {
    let app = crate::ffi::application::App::new(db_path);
    app.set_active_server(&server_id).map_err(|e| e.to_string())
}

pub fn get_active_server(db_path: String) -> Result<Option<String>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.get_active_server().map_err(|e| e.to_string())
}

pub fn fetch_series(
    db_path: String,
    server_id: String,
    limit: i64,
    offset: i64,
) -> Result<Vec<SeriesRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.fetch_series(&server_id, limit, offset)
        .map_err(|e| e.to_string())
}

// MARK: - Cover cache (the grid resolves cover files from SQLite)

/// Cover file path for one series, resolved from SQLite only (None = cache
/// miss; the UI shows a placeholder and triggers ensure_covers).
pub fn cover_path(
    db_path: String,
    server_id: String,
    series_id: String,
) -> Result<Option<String>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.cover_path(&server_id, &series_id)
        .map_err(|e| e.to_string())
}

/// All cover records for one server (dead files filtered out), so the grid
/// maps remote_id → local path with a single call.
pub fn list_thumbnails(db_path: String, server_id: String) -> Result<Vec<ThumbnailRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.list_thumbnails(&server_id).map_err(|e| e.to_string())
}

/// Backfill one series cover (cache miss → download → disk → SQLite row),
/// returning the local file path.
pub async fn ensure_cover(
    db_path: String,
    server_id: String,
    series_id: String,
    base_url: String,
    api_key: String,
) -> Result<String, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.ensure_cover(server_id, series_id, base_url, api_key)
        .await
        .map_err(|e| e.to_string())
}

/// Backfill every series cover without a usable record (缓存缺失自动补齐).
/// Returns the number of covers written.
pub async fn ensure_covers(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
) -> Result<i64, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.ensure_covers(server_id, base_url, api_key)
        .await
        .map(|n| n as i64)
        .map_err(|e| e.to_string())
}

/// Offline demo: seeds the store with the shared fixture series and
/// generated covers — a demonstrable cover wall without a server.
pub async fn bootstrap_demo(
    db_path: String,
    server_id: String,
) -> Result<BootstrapSummary, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.bootstrap_demo(server_id)
        .await
        .map_err(|e| e.to_string())
}

// MARK: - Full mirror sync (media library)

/// FullSync against a live server: series → books → collections →
/// readlists → on-deck progress.
pub async fn full_sync(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
) -> Result<FullSyncSummary, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.full_sync(server_id, base_url, api_key)
        .await
        .map_err(|e| e.to_string())
}

/// Stage 5 Bootstrap Sync: ordered, paged, checkpointed. `resume = true`
/// continues an interrupted run from its stored cursors.
pub async fn bootstrap_sync(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
    resume: bool,
) -> Result<FullSyncSummary, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.bootstrap_sync(server_id, base_url, api_key, !resume)
        .await
        .map_err(|e| e.to_string())
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
) -> Result<ReconcileSummary, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.reconcile(server_id, base_url, api_key, trigger)
        .await
        .map_err(|e| e.to_string())
}

/// Whether this trigger should sweep now (background triggers are throttled).
pub fn should_reconcile(
    db_path: String,
    server_id: String,
    trigger: String,
) -> Result<bool, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.should_reconcile(&server_id, &trigger)
        .map_err(|e| e.to_string())
}

/// Per entity type sync state: entityType / lastSyncAt / syncCursor / syncStatus.
pub fn sync_states(db_path: String, server_id: String) -> Result<Vec<EntitySyncState>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.sync_states(&server_id).map_err(|e| e.to_string())
}

/// Tombstones left by delete propagation for one entity type.
pub fn tombstones(
    db_path: String,
    server_id: String,
    entity_type: String,
) -> Result<Vec<Tombstone>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.tombstones(&server_id, &entity_type)
        .map_err(|e| e.to_string())
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
) -> Result<SeriesPageResult, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.query_series(
        &server_id, search, library_id, status, tag, genre, sort, ascending, limit, offset,
    )
    .map_err(|e| e.to_string())
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
) -> Result<BookPageResult, String> {
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
    .map_err(|e| e.to_string())
}

/// Full series detail: row + metadata + genres + tags + authors +
/// collection memberships (all local).
pub fn series_detail(
    db_path: String,
    server_id: String,
    series_id: String,
) -> Result<Option<SeriesDetailRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.series_detail(&server_id, &series_id)
        .map_err(|e| e.to_string())
}

/// Full book detail: row + metadata + tags + authors + progress (local).
pub fn book_detail(
    db_path: String,
    server_id: String,
    book_id: String,
) -> Result<Option<BookDetailRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.book_detail(&server_id, &book_id)
        .map_err(|e| e.to_string())
}

/// Collections searchable list (paged, local).
pub fn list_collections(
    db_path: String,
    server_id: String,
    search: Option<String>,
    limit: i64,
    offset: i64,
) -> Result<CollectionPageResult, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.list_collections(&server_id, search, limit, offset)
        .map_err(|e| e.to_string())
}

/// Collection detail: the row + its member series (paged, local).
pub fn collection_detail(
    db_path: String,
    server_id: String,
    collection_id: String,
    limit: i64,
    offset: i64,
) -> Result<Option<CollectionDetailRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.collection_detail(&server_id, &collection_id, limit, offset)
        .map_err(|e| e.to_string())
}

/// Readlists searchable list (paged, local).
pub fn list_readlists(
    db_path: String,
    server_id: String,
    search: Option<String>,
    limit: i64,
    offset: i64,
) -> Result<ReadlistPageResult, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.list_readlists(&server_id, search, limit, offset)
        .map_err(|e| e.to_string())
}

/// Readlist detail: the row + its ordered books (paged, local).
pub fn readlist_detail(
    db_path: String,
    server_id: String,
    readlist_id: String,
    limit: i64,
    offset: i64,
) -> Result<Option<ReadlistDetailRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.readlist_detail(&server_id, &readlist_id, limit, offset)
        .map_err(|e| e.to_string())
}

/// Continue-reading shelf (books read partially, local only).
pub fn continue_reading(
    db_path: String,
    server_id: String,
    limit: i64,
) -> Result<Vec<ContinueReadingRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.continue_reading(&server_id, limit)
        .map_err(|e| e.to_string())
}

/// Filter-chip options derived from the local mirror (tags / genres /
/// statuses), distinct + sorted.
pub fn filter_options(db_path: String, server_id: String) -> Result<FilterOptions, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.filter_options(&server_id).map_err(|e| e.to_string())
}

/// Library rows with their local series counts (Library 列表/切换).
pub fn library_counts(db_path: String, server_id: String) -> Result<Vec<LibraryCountRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.library_counts(&server_id).map_err(|e| e.to_string())
}

/// One library with counts + root + availability (Library 详情).
pub fn library_detail(
    db_path: String,
    server_id: String,
    library_id: String,
) -> Result<Option<LibraryCountRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.library_detail(&server_id, &library_id)
        .map_err(|e| e.to_string())
}

// MARK: - Reading status (本地优先 + Mutation Outbox)

/// Local page update + outbox row (READ_PROGRESS).
pub fn set_read_progress(
    db_path: String,
    server_id: String,
    book_id: String,
    page: i64,
    completed: bool,
) -> Result<(), String> {
    let app = crate::ffi::application::App::new(db_path);
    app.set_read_progress(&server_id, &book_id, page, completed)
        .map_err(|e| e.to_string())
}

/// Explicit mark-read + outbox row (MARK_READ).
pub fn mark_read(db_path: String, server_id: String, book_id: String) -> Result<(), String> {
    let app = crate::ffi::application::App::new(db_path);
    app.mark_read(&server_id, &book_id)
        .map_err(|e| e.to_string())
}

/// Explicit mark-unread + outbox row (MARK_UNREAD).
pub fn mark_unread(db_path: String, server_id: String, book_id: String) -> Result<(), String> {
    let app = crate::ffi::application::App::new(db_path);
    app.mark_unread(&server_id, &book_id)
        .map_err(|e| e.to_string())
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
) -> Result<UploadOutcomeDto, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.upload_outbox(server_id, base_url, api_key)
        .await
        .map_err(|e| e.to_string())
}

/// The Outbox badge plus the rows that gave up (UI lists those with a retry).
pub fn outbox_status(db_path: String, server_id: String) -> Result<OutboxStatusDto, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.outbox_status(&server_id).map_err(|e| e.to_string())
}

/// Hand every given-up row back to the retry machine. Returns how many came
/// back to `pending`.
pub fn retry_failed_mutations(db_path: String, server_id: String) -> Result<i64, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.retry_failed_mutations(&server_id)
        .map(|n| n as i64)
        .map_err(|e| e.to_string())
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
) -> Result<Option<SsePollResult>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.sse_poll(server_id, base_url, api_key, state_json)
        .await
        .map_err(|e| e.to_string())
}

/// The reconcile `sse_poll` asked for has run: release the events that arrived
/// during it and hand the session back to the stream.
pub fn sse_reconciled(db_path: String, state_json: String) -> Result<String, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.sse_reconciled(state_json).map_err(|e| e.to_string())
}

/// Make one server's event stream due now (network came back / foreground).
pub fn sse_resume(db_path: String, state_json: String) -> Result<String, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.sse_resume(state_json).map_err(|e| e.to_string())
}

/// Drop this server's parked stream (screen disposed / server switched).
pub fn sse_stop(db_path: String, server_id: String) -> Result<(), String> {
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
) -> Result<Option<String>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.book_cover_path(&server_id, &book_id)
        .map_err(|e| e.to_string())
}

/// Backfill one book cover (cache miss → download → disk → SQLite row),
/// returning the local file path.
pub async fn ensure_book_cover(
    db_path: String,
    server_id: String,
    book_id: String,
    base_url: String,
    api_key: String,
) -> Result<String, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.ensure_book_cover(server_id, book_id, base_url, api_key)
        .await
        .map_err(|e| e.to_string())
}

/// Backfill every book cover of one series (缓存缺失自动补齐, book variant).
/// Returns the number of covers written.
pub async fn ensure_book_covers(
    db_path: String,
    server_id: String,
    series_id: String,
    base_url: String,
    api_key: String,
) -> Result<i64, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.ensure_book_covers(server_id, series_id, base_url, api_key)
        .await
        .map(|n| n as i64)
        .map_err(|e| e.to_string())
}
