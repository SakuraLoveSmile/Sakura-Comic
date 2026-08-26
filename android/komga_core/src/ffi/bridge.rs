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
    ReadlistDetailRow, ReadlistPageResult, SeriesDetailRow,
};
use crate::model::server_profile::ServerProfile;
use crate::store::query::{BookPageResult, LibraryCountRow, SeriesPageResult};
use crate::store::read_progress::ContinueReadingRow;
use crate::store::series::SeriesRow;
use crate::store::thumbnails::ThumbnailRow;
use crate::sync::{BootstrapSummary, FullSyncSummary};

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
