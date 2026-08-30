//! Application Facade — coarse-grained services for Flutter.
//!
//! No flutter_rust_bridge types here. Layering:
//! Core (api/model/store/sync/cache) → Application Facade → FFI Adapter.

use crate::api::auth::AuthMethod;
use crate::api::contract::{check_server_version, version_capabilities};
use crate::api::error::{ApiError, Result as ApiResult};
use crate::api::mutation::ProgressWriter;
use crate::api::page::PageStreaming;
use crate::api::series::KomgaClient;
use crate::api::server::ConnectionFetching;
use crate::api::sse::{SseClient, SseEvent, SseStream};
use crate::cache::cover::{BytesFetcher, CoverStore};
use crate::cache::DiskCache;
use crate::model::server::{Library, ServerInfo};
use crate::model::server_profile::ServerProfile;
use crate::reader;
use crate::store;
use crate::store::collections::CollectionRow;
use crate::store::outbox::OutboxEntry;
use crate::store::prune::Tombstone;
use crate::store::query::{BookQuery, BookSort, SeriesQuery, SeriesSort};
use crate::store::read_progress::ContinueReadingRow;
use crate::store::readlists::ReadlistRow;
use crate::store::series::SeriesRow;
use crate::store::sync_state::EntitySyncState;
use crate::store::thumbnails::{ThumbnailRow, VARIANT_BOOK, VARIANT_SERIES};
use crate::sync;
use crate::sync::full::FixtureLibraryFetcher;
use crate::sync::sse::{DirtySet, EventSource, Phase, PumpAction, SseSession};
use crate::sync::upload::UploadSummary;
use crate::sync::{
    BootstrapSummary, FullSyncSummary, LibraryFetcher, ReconcileSummary, ReconcileTrigger,
};

use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// Owns the app-level SQLite path; every call opens its own connection
/// (simple for Phase 0; a long-lived pooled connection comes with the
/// streaming API in Phase 1).
pub struct App {
    db_path: String,
}

impl App {
    pub fn new(db_path: impl Into<String>) -> Self {
        Self {
            db_path: db_path.into(),
        }
    }

    pub fn db_path(&self) -> &str {
        &self.db_path
    }

    /// Insert or update a server profile.
    pub fn save_server(&self, profile: &ServerProfile) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::servers::save_server(&conn, profile).map_err(db_err)
    }

    pub fn list_servers(&self) -> Result<Vec<ServerProfile>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::servers::list_servers(&conn).map_err(db_err)
    }

    pub fn get_server(&self, server_id: &str) -> Result<Option<ServerProfile>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::servers::get_server(&conn, server_id).map_err(db_err)
    }

    /// Delete a server profile. If the deleted server was the active one,
    /// the active-server state is cleared with it; its mirrored rows
    /// (series/books/metadata/collections/readlists/…), cover records and
    /// cached cover files are removed too (multi-server safe).
    pub fn delete_server(&self, server_id: &str) -> Result<bool, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        // Collect cover files before the rows go away.
        let files: Vec<PathBuf> = store::thumbnails::list_thumbnails(&conn, server_id)
            .map_err(db_err)?
            .into_iter()
            .map(|row| PathBuf::from(row.local_path))
            .collect();
        // Read the URL before the row goes away: the connection pool is keyed by
        // it, and a deleted server must not keep a live client (and therefore a
        // usable credential) behind.
        let base_url: Option<String> = conn
            .query_row(
                "SELECT base_url FROM servers WHERE id = ?1",
                rusqlite::params![server_id],
                |row| row.get(0),
            )
            .unwrap_or(None);
        let deleted = store::servers::delete_server(&conn, server_id).map_err(db_err)?;
        if deleted {
            if let Some(url) = base_url.as_deref() {
                crate::api::series::KomgaClient::forget(url);
            }
            let _ = store::app_state::clear_active_server(&conn);
            store::delete_server_mirror(&conn, server_id).map_err(db_err)?;
            let cache = DiskCache::new(self.cache_root()).map_err(storage_err)?;
            for file in files {
                let _ = cache.remove(&file);
            }
        }
        Ok(deleted)
    }

    /// Persist the libraries discovered during a successful connection.
    pub fn save_libraries(&self, server_id: &str, libraries: &[Library]) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::libraries::save_libraries_batch(&conn, server_id, libraries).map_err(db_err)?;
        Ok(())
    }

    pub fn list_libraries(
        &self,
        server_id: &str,
    ) -> Result<Vec<crate::store::libraries::LibraryRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::libraries::list_libraries(&conn, server_id).map_err(db_err)
    }

    // MARK: - Active server

    pub fn set_active_server(&self, server_id: &str) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::app_state::set_active_server(&conn, server_id).map_err(db_err)
    }

    pub fn get_active_server(&self) -> Result<Option<String>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::app_state::get_active_server(&conn).map_err(db_err)
    }

    // MARK: - Connection probe (acceptance chain: 添加 → 登录 → 验证 → 信息)

    /// Live probe: authenticate + verify Komga + fetch server info +
    /// libraries (checks the version policy; rejects incompatible servers).
    pub async fn test_connection(
        &self,
        base_url: String,
        api_key: String,
    ) -> Result<ConnectionResult, ApiError> {
        let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
        self.test_connection_with(&client).await
    }

    /// Same as test_connection with an injectable fetcher (offline tests).
    pub async fn test_connection_with<F: ConnectionFetching + Sync>(
        &self,
        fetcher: &F,
    ) -> Result<ConnectionResult, ApiError> {
        let info = fetcher.server_info().await?;
        let version = info.build.as_ref().and_then(|build| build.version.clone());
        let check = check_server_version(version.as_deref())?;

        let libraries = fetcher.libraries().await?;
        let mut capabilities = version_capabilities(&check);
        capabilities.push(format!("libraries:{}", libraries.len()));
        if libraries.is_empty() {
            capabilities.push("empty-libraries".into());
        }

        Ok(ConnectionResult {
            server_info: info,
            server_version: version,
            libraries,
            capabilities,
        })
    }

    /// BootstrapSync: mirrors the first page (size 10) of a server's series
    /// into SQLite. The transport is async end-to-end; SQLite access is
    /// local and fast.
    pub async fn bootstrap(
        &self,
        server_id: String,
        base_url: String,
        api_key: String,
    ) -> Result<BootstrapSummary, ApiError> {
        let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
        self.bootstrap_with(&client, &server_id).await
    }

    /// Same as bootstrap but with an injectable fetcher (offline tests).
    ///
    /// The network phase runs without any DB handle in scope, so the future
    /// stays `Send` for the FFI bridge (rusqlite `Connection` is not `Sync`).
    pub async fn bootstrap_with<F: crate::sync::SeriesFetcher + Sync>(
        &self,
        fetcher: &F,
        server_id: &str,
    ) -> Result<BootstrapSummary, ApiError> {
        let page = sync::fetch_bootstrap_page(fetcher).await?;
        let conn = store::open(&self.db_path).map_err(db_err)?;
        sync::bootstrap_page_to_store(&conn, server_id, &page)
    }

    pub fn fetch_series(
        &self,
        server_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<SeriesRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::series::list_series(&conn, server_id, limit, offset).map_err(db_err)
    }

    pub fn count_series(&self, server_id: &str) -> Result<i64, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::series::count_series(&conn, server_id).map_err(db_err)
    }

    // MARK: - Cover cache (local-first: cover file paths live in SQLite)

    /// The app cache root (<db dir>/cache), same layout as the Swift app
    /// and phase0_smoke: cache/thumbnails + cache/pages.
    fn cache_root(&self) -> PathBuf {
        Path::new(&self.db_path)
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("cache")
    }

    fn open_cover_store(&self, base_url: &str) -> Result<CoverStore, ApiError> {
        let cache = DiskCache::new(self.cache_root()).map_err(storage_err)?;
        Ok(CoverStore::new(cache, base_url))
    }

    /// Cover file path for one series, resolved from SQLite only. Returns
    /// None when the record is missing or the file has vanished (cache miss
    /// → callers run ensure_cover / ensure_covers to backfill).
    pub fn cover_path(&self, server_id: &str, series_id: &str) -> Result<Option<String>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let row = store::thumbnails::get_thumbnail(&conn, server_id, series_id, VARIANT_SERIES)
            .map_err(db_err)?;
        match row {
            Some(row) if Path::new(&row.local_path).exists() => Ok(Some(row.local_path)),
            _ => Ok(None),
        }
    }

    /// All cover records for one server (dead files filtered out), so the
    /// grid maps remote_id → local path with a single call.
    pub fn list_thumbnails(&self, server_id: &str) -> Result<Vec<ThumbnailRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let rows = store::thumbnails::list_thumbnails(&conn, server_id).map_err(db_err)?;
        Ok(rows
            .into_iter()
            .filter(|row| Path::new(&row.local_path).exists())
            .collect())
    }

    /// Backfill one series cover: cache-first; on miss (no record or file
    /// gone) download, store to disk and record the path in SQLite.
    pub async fn ensure_cover(
        &self,
        server_id: String,
        series_id: String,
        base_url: String,
        api_key: String,
    ) -> Result<String, ApiError> {
        let client = KomgaClient::shared(base_url.clone(), AuthMethod::ApiKey { key: api_key })?;
        self.ensure_cover_with(&client, &base_url, &server_id, &series_id)
            .await
    }

    /// Same as ensure_cover with an injectable fetcher (offline tests; the
    /// demo mode ignores the URL and generates covers). No DB handle is
    /// held across any await.
    pub async fn ensure_cover_with<F: BytesFetcher + Sync>(
        &self,
        fetcher: &F,
        base_url: &str,
        server_id: &str,
        series_id: &str,
    ) -> Result<String, ApiError> {
        if let Some(path) = self.cover_path(server_id, series_id)? {
            return Ok(path);
        }
        let cover_store = self.open_cover_store(base_url)?;
        let path = cover_store
            .ensure_thumbnail(fetcher, server_id, series_id)
            .await?;
        let size = std::fs::metadata(&path)
            .map(|m| m.len() as i64)
            .unwrap_or(0);
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::thumbnails::record_thumbnail(
            &conn,
            server_id,
            series_id,
            VARIANT_SERIES,
            &path.to_string_lossy(),
            size,
        )
        .map_err(db_err)?;
        Ok(path.to_string_lossy().into_owned())
    }

    /// Backfill every series cover that has no usable record yet
    /// (缓存缺失自动补齐). Returns the number of covers written. Individual
    /// failures are logged and skipped — a partially synced wall is better
    /// than none.
    pub async fn ensure_covers(
        &self,
        server_id: String,
        base_url: String,
        api_key: String,
    ) -> Result<usize, ApiError> {
        let client = KomgaClient::shared(base_url.clone(), AuthMethod::ApiKey { key: api_key })?;
        self.ensure_covers_with(&client, &base_url, &server_id)
            .await
    }

    /// Same as ensure_covers with an injectable fetcher (offline tests).
    pub async fn ensure_covers_with<F: BytesFetcher + Sync>(
        &self,
        fetcher: &F,
        base_url: &str,
        server_id: &str,
    ) -> Result<usize, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let candidates =
            store::thumbnails::list_series_missing_cover(&conn, server_id).map_err(db_err)?;
        drop(conn); // rusqlite Connection is not Sync — never held across an await
        let mut backfilled = 0usize;
        for series_id in candidates {
            match self
                .ensure_cover_with(fetcher, base_url, server_id, &series_id)
                .await
            {
                Ok(_) => backfilled += 1,
                Err(e) => log::warn!("cover backfill {series_id}: {e}"),
            }
        }
        Ok(backfilled)
    }

    /// Offline demo: seeds the store with the shared fixture series and
    /// generated covers (no network). Mirrors the Swift app's Demo mode.
    pub async fn bootstrap_demo(&self, server_id: String) -> Result<BootstrapSummary, ApiError> {
        self.bootstrap_demo_with(&FixtureLibraryFetcher {}, &server_id)
            .await
    }

    /// Demo seed with an injectable fetcher (offline tests). Writes the
    /// full media library: libraries → series → books → collections →
    /// readlists → on-deck progress → generated covers (series + book).
    pub async fn bootstrap_demo_with<F: LibraryFetcher + Sync>(
        &self,
        fetcher: &F,
        server_id: &str,
    ) -> Result<BootstrapSummary, ApiError> {
        let summary = sync::full_sync(&self.db_path, server_id, fetcher).await?;
        // Demo libraries (the LIBRARY list/summary UI needs them).
        let libraries: Vec<Library> = serde_json::from_str(include_str!(
            "../../../../specs/contracts/fixtures/library/libraries.json"
        ))
        .map_err(|e| ApiError::Decode {
            message: format!("demo libraries fixture: {e}"),
        })?;
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::libraries::save_libraries_batch(&conn, server_id, &libraries).map_err(db_err)?;
        drop(conn);
        let backfilled = self
            .ensure_covers_with(&DemoCoverFetcher {}, "https://demo.local", server_id)
            .await?;
        log::info!("demo covers backfilled: {backfilled}");
        // Book covers too — the book list resolves `variant = 'book'` paths
        // from SQLite (demo shows the full media library offline).
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let series_rows =
            store::series::list_series(&conn, server_id, i64::MAX, 0).map_err(db_err)?;
        drop(conn);
        for row in &series_rows {
            let n = self
                .ensure_book_covers_with(
                    &DemoCoverFetcher {},
                    "https://demo.local",
                    server_id,
                    &row.remote_id,
                )
                .await?;
            log::info!("demo book covers for {}: {n}", row.name);
        }
        Ok(BootstrapSummary {
            server_id: server_id.to_string(),
            synced_series: summary.series,
            total_elements: summary.series as i64,
            has_more_pages: false,
        })
    }

    // MARK: - Full mirror sync (media library)

    /// FullSync against a live server: series → books → collections →
    /// readlists → on-deck progress (local-first mirror).
    pub async fn full_sync(
        &self,
        server_id: String,
        base_url: String,
        api_key: String,
    ) -> Result<FullSyncSummary, ApiError> {
        let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
        sync::full_sync(&self.db_path, &server_id, &client).await
    }

    /// Same as full_sync with an injectable fetcher (offline tests).
    pub async fn full_sync_with<F: LibraryFetcher + Sync>(
        &self,
        fetcher: &F,
        server_id: &str,
    ) -> Result<FullSyncSummary, ApiError> {
        sync::full_sync(&self.db_path, server_id, fetcher).await
    }

    // MARK: - Stage 5: sync engine (resumable bootstrap + reconcile)

    /// Bootstrap Sync against a live server. `fresh` re-mirrors from page 0;
    /// by default an interrupted run resumes from its stored cursors.
    pub async fn bootstrap_sync(
        &self,
        server_id: String,
        base_url: String,
        api_key: String,
        fresh: bool,
    ) -> Result<FullSyncSummary, ApiError> {
        let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
        let start = if fresh {
            sync::StartAt::Fresh
        } else {
            sync::StartAt::Resume
        };
        let summary = sync::full_sync_from(&self.db_path, &server_id, &client, start).await?;
        Ok(summary)
    }

    /// Reconcile Sync (live server): id sweep + delete propagation. Safe to
    /// call on every trigger — it is what makes SSE events optional.
    pub async fn reconcile(
        &self,
        server_id: String,
        base_url: String,
        api_key: String,
        trigger: String,
    ) -> Result<ReconcileSummary, ApiError> {
        let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
        self.reconcile_with(&client, &server_id, &trigger).await
    }

    /// Reconcile with an injectable fetcher (offline tests / scenario replay).
    pub async fn reconcile_with<F: LibraryFetcher + Sync>(
        &self,
        fetcher: &F,
        server_id: &str,
        trigger: &str,
    ) -> Result<ReconcileSummary, ApiError> {
        let summary = sync::reconcile::reconcile(
            &self.db_path,
            server_id,
            fetcher,
            ReconcileTrigger::parse(trigger),
        )
        .await?;
        // Delete propagation contract: covers of pruned entities go too.
        self.remove_cover_files(&summary.orphaned_covers);
        Ok(summary)
    }

    /// Should this trigger sweep now? Background triggers are throttled so
    /// returning to the foreground does not hammer the server.
    pub fn should_reconcile(&self, server_id: &str, trigger: &str) -> Result<bool, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        sync::reconcile::should_reconcile(
            &conn,
            server_id,
            ReconcileTrigger::parse(trigger),
            chrono::Utc::now(),
        )
        .map_err(db_err)
    }

    /// Per entity type sync state (`serverId` / `entityType` / `lastSyncAt` /
    /// `syncCursor` / `syncStatus`) — drives the sync status UI.
    pub fn sync_states(&self, server_id: &str) -> Result<Vec<EntitySyncState>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::sync_state::list_entity_states(&conn, server_id).map_err(db_err)
    }

    /// Tombstones for one entity type (what Reconcile removed, and when).
    pub fn tombstones(
        &self,
        server_id: &str,
        entity_type: &str,
    ) -> Result<Vec<Tombstone>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::prune::list_tombstones(&conn, server_id, entity_type).map_err(db_err)
    }

    /// Remove orphaned cover files (rows are already gone; files follow).
    fn remove_cover_files(&self, paths: &[String]) {
        let Ok(cache) = DiskCache::new(self.cache_root()) else {
            return;
        };
        for path in paths {
            let _ = cache.remove(std::path::Path::new(path));
        }
    }

    // MARK: - Media library queries (全部本地：SQLite)

    #[allow(clippy::too_many_arguments)]
    /// Paged series wall with search / filters / sort (本地查询).
    pub fn query_series(
        &self,
        server_id: &str,
        search: Option<String>,
        library_id: Option<String>,
        status: Option<String>,
        tag: Option<String>,
        genre: Option<String>,
        sort: String,
        ascending: bool,
        limit: i64,
        offset: i64,
    ) -> Result<SeriesPageResult, ApiError> {
        let sort: SeriesSort = sort.parse()?;
        let query = SeriesQuery {
            search,
            library_id,
            status,
            tag,
            genre,
            sort,
            ascending,
        };
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::query::query_series(&conn, server_id, &query, limit, offset).map_err(db_err)
    }

    #[allow(clippy::too_many_arguments)]
    /// Paged book list of one series with read-status / tag filters
    /// (本地查询).
    pub fn query_books(
        &self,
        server_id: &str,
        series_id: &str,
        search: Option<String>,
        read_status: Option<String>,
        tag: Option<String>,
        sort: String,
        ascending: bool,
        limit: i64,
        offset: i64,
    ) -> Result<BookPageResult, ApiError> {
        let sort: BookSort = sort.parse()?;
        let read_status = match read_status.as_deref() {
            None => None,
            Some(s) => Some(s.parse()?),
        };
        let query = BookQuery {
            search,
            read_status,
            tag,
            sort,
            ascending,
        };
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::query::query_books(&conn, server_id, series_id, &query, limit, offset)
            .map_err(db_err)
    }

    #[allow(clippy::type_complexity)]
    /// Full series detail: row + metadata + genres + tags + authors +
    /// collection memberships (all local).
    pub fn series_detail(
        &self,
        server_id: &str,
        series_id: &str,
    ) -> Result<Option<SeriesDetailRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let Some(row) = store::series::get_series(&conn, server_id, series_id).map_err(db_err)?
        else {
            return Ok(None);
        };
        let metadata: Option<(Option<String>, Option<String>, Option<String>, Option<String>, Option<String>, Option<i64>)> = conn
            .query_row(
                "SELECT summary, publisher, reading_direction, language, age_rating, total_book_count
                   FROM series_metadata WHERE server_id = ?1 AND series_id = ?2",
                rusqlite::params![server_id, series_id],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                    ))
                },
            )
            .optional()
            .map_err(db_err)?;
        let (summary, publisher, reading_direction, language, age_rating, total_book_count) =
            metadata.unwrap_or((None, None, None, None, None, None));
        let mut mstmt = conn
            .prepare(
                "SELECT c.remote_id, c.name FROM collection_series cs
                     JOIN collections c ON c.server_id = cs.server_id AND c.remote_id = cs.collection_id
                     WHERE cs.server_id = ?1 AND cs.series_id = ?2 ORDER BY c.name COLLATE NOCASE",
            )
            .map_err(db_err)?;
        let mrows = mstmt
            .query_map(rusqlite::params![server_id, series_id], |r| {
                Ok(CollectionRef {
                    remote_id: r.get(0)?,
                    name: r.get(1)?,
                })
            })
            .map_err(db_err)?;
        let collections: Vec<CollectionRef> =
            mrows.collect::<rusqlite::Result<_>>().map_err(db_err)?;
        Ok(Some(SeriesDetailRow {
            server_id: row.server_id,
            remote_id: row.remote_id,
            library_id: row.library_id,
            name: row.name,
            sort_name: row.sort_name,
            status: row.status,
            created_at: row.created_at,
            last_modified: row.last_modified,
            books_count: row.books_count,
            books_read_count: row.books_read_count,
            books_unread_count: row.books_unread_count,
            books_in_progress_count: row.books_in_progress_count,
            summary,
            publisher,
            reading_direction,
            language,
            age_rating,
            total_book_count,
            genres: store::series::series_genres(&conn, server_id, series_id).map_err(db_err)?,
            tags: store::series::series_tags(&conn, server_id, series_id).map_err(db_err)?,
            authors: store::series::series_authors(&conn, server_id, series_id).map_err(db_err)?,
            collections,
        }))
    }

    #[allow(clippy::type_complexity)]
    /// Full book detail: row + metadata + tags + authors + progress (local).
    pub fn book_detail(
        &self,
        server_id: &str,
        book_id: &str,
    ) -> Result<Option<BookDetailRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let Some(row) = store::books::get_book(&conn, server_id, book_id).map_err(db_err)? else {
            return Ok(None);
        };
        let metadata: Option<(
            Option<String>,
            Option<String>,
            Option<String>,
            Option<String>,
        )> = conn
            .query_row(
                "SELECT summary, number, isbn, release_date FROM book_metadata
                  WHERE server_id = ?1 AND book_id = ?2",
                rusqlite::params![server_id, book_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()
            .map_err(db_err)?;
        let (summary, number, isbn, release_date) = metadata.unwrap_or((None, None, None, None));
        Ok(Some(BookDetailRow {
            server_id: row.server_id,
            remote_id: row.remote_id,
            series_id: row.series_id,
            series_title: row.series_title,
            title: row.title,
            number: number.or(row.number),
            number_sort: row.number_sort,
            summary,
            isbn,
            release_date,
            media_type: row.media_type,
            pages_count: row.pages_count,
            file_size: row.file_size,
            created_at: row.created_at,
            last_modified: row.last_modified,
            tags: store::books::book_tags(&conn, server_id, book_id).map_err(db_err)?,
            authors: store::books::book_authors(&conn, server_id, book_id).map_err(db_err)?,
            progress_page: row.progress_page,
            progress_completed: row.progress_completed,
        }))
    }

    /// Collections searchable list (paged, local).
    pub fn list_collections(
        &self,
        server_id: &str,
        search: Option<String>,
        limit: i64,
        offset: i64,
    ) -> Result<CollectionPageResult, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let items = store::collections::list_collections(
            &conn,
            server_id,
            search.as_deref(),
            limit,
            offset,
        )
        .map_err(db_err)?;
        let total = store::collections::count_collections(&conn, server_id, search.as_deref())
            .map_err(db_err)?;
        Ok(CollectionPageResult { items, total })
    }

    /// Collection detail: the row + its member series (paged, local).
    pub fn collection_detail(
        &self,
        server_id: &str,
        collection_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<Option<CollectionDetailRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let Some(row) =
            store::collections::get_collection(&conn, server_id, collection_id).map_err(db_err)?
        else {
            return Ok(None);
        };
        let members =
            store::query::collection_series_page(&conn, server_id, collection_id, limit, offset)
                .map_err(db_err)?;
        Ok(Some(CollectionDetailRow {
            remote_id: row.remote_id,
            name: row.name,
            ordered: row.ordered,
            filtered: row.filtered,
            created_date: row.created_date,
            last_modified_date: row.last_modified_date,
            members,
        }))
    }

    /// Readlists searchable list (paged, local).
    pub fn list_readlists(
        &self,
        server_id: &str,
        search: Option<String>,
        limit: i64,
        offset: i64,
    ) -> Result<ReadlistPageResult, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let items =
            store::readlists::list_readlists(&conn, server_id, search.as_deref(), limit, offset)
                .map_err(db_err)?;
        let total = store::readlists::count_readlists(&conn, server_id, search.as_deref())
            .map_err(db_err)?;
        Ok(ReadlistPageResult { items, total })
    }

    /// Readlist detail: the row + its ordered books (paged, local).
    pub fn readlist_detail(
        &self,
        server_id: &str,
        readlist_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<Option<ReadlistDetailRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let Some(row) =
            store::readlists::get_readlist(&conn, server_id, readlist_id).map_err(db_err)?
        else {
            return Ok(None);
        };
        let books = store::query::readlist_books_page(&conn, server_id, readlist_id, limit, offset)
            .map_err(db_err)?;
        Ok(Some(ReadlistDetailRow {
            remote_id: row.remote_id,
            name: row.name,
            summary: row.summary,
            ordered: row.ordered,
            filtered: row.filtered,
            created_date: row.created_date,
            last_modified_date: row.last_modified_date,
            books,
        }))
    }

    /// Continue-reading shelf (books read partially, local only).
    pub fn continue_reading(
        &self,
        server_id: &str,
        limit: i64,
    ) -> Result<Vec<ContinueReadingRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::read_progress::continue_reading(&conn, server_id, limit).map_err(db_err)
    }

    /// Filter-chip options derived from the local mirror (tags / genres /
    /// statuses), distinct + sorted.
    pub fn filter_options(&self, server_id: &str) -> Result<FilterOptions, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        Ok(FilterOptions {
            tags: store::series::list_series_tags(&conn, server_id).map_err(db_err)?,
            genres: store::series::list_series_genres(&conn, server_id).map_err(db_err)?,
            statuses: store::series::list_series_statuses(&conn, server_id).map_err(db_err)?,
        })
    }

    /// Library rows with their local series counts (Library 列表/切换).
    pub fn library_counts(&self, server_id: &str) -> Result<Vec<LibraryCountRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::query::library_counts(&conn, server_id).map_err(db_err)
    }

    /// One library with its counts, root and availability (Library 详情).
    pub fn library_detail(
        &self,
        server_id: &str,
        library_id: &str,
    ) -> Result<Option<LibraryCountRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::query::library_detail(&conn, server_id, library_id).map_err(db_err)
    }

    // MARK: - Reading status (本地优先 + Mutation Outbox)

    /// Local page update + outbox row (READ_PROGRESS).
    pub fn set_read_progress(
        &self,
        server_id: &str,
        book_id: &str,
        page: i64,
        completed: bool,
    ) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::read_progress::upsert_local_read_progress(&conn, server_id, book_id, page, completed)
            .map_err(db_err)
    }

    /// Explicit mark-read + outbox row (MARK_READ).
    pub fn mark_read(&self, server_id: &str, book_id: &str) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::read_progress::mark_read(&conn, server_id, book_id).map_err(db_err)
    }

    /// Explicit mark-unread + outbox row (MARK_UNREAD).
    pub fn mark_unread(&self, server_id: &str, book_id: &str) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::read_progress::mark_unread(&conn, server_id, book_id).map_err(db_err)
    }

    // MARK: - Stage 6: Mutation Upload Sync (the Outbox drain)

    /// One upload pass over the queued mutations: 断网时排队的动作在恢复网络
    /// （或重启、或回到前台）后自己排空。`now` is the real clock here;
    /// `upload_outbox_with` takes an injected one so backoff is testable.
    pub async fn upload_outbox(
        &self,
        server_id: String,
        base_url: String,
        api_key: String,
    ) -> Result<UploadOutcomeDto, ApiError> {
        let db_path = self.db_path.clone();
        let now = utc_now();
        // The uploader reads the queue, re-fetches, then writes — so it holds a
        // `Connection` across its awaits, and that future is not `Send`. Run the
        // pass where the handle can live: one blocking thread, one runtime.
        tokio::task::spawn_blocking(move || {
            let runtime = owned_runtime()?;
            runtime.block_on(async move {
                let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
                let conn = store::open(&db_path).map_err(db_err)?;
                let summary = sync::upload::upload_outbox(&conn, &server_id, &client, &now)
                    .await
                    .map_err(db_err)?;
                Ok(UploadOutcomeDto::of(
                    &summary,
                    outbox_status_of(&conn, &server_id, &now)?,
                ))
            })
        })
        .await
        .map_err(join_err)?
    }

    /// Same as upload_outbox with an injectable writer (offline tests). The
    /// queue and the badge counts come back in one DTO, because the UI always
    /// needs the residue after a pass, never just what the pass did.
    pub async fn upload_outbox_with<W: ProgressWriter + Sync>(
        &self,
        writer: &W,
        server_id: &str,
        now: &str,
    ) -> Result<UploadOutcomeDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let summary = sync::upload::upload_outbox(&conn, server_id, writer, now)
            .await
            .map_err(db_err)?;
        Ok(UploadOutcomeDto::of(
            &summary,
            outbox_status_of(&conn, server_id, now)?,
        ))
    }

    /// The Outbox as the UI sees it: what is queued, and what has given up.
    pub fn outbox_status(&self, server_id: &str) -> Result<OutboxStatusDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        outbox_status_of(&conn, server_id, &utc_now())
    }

    /// Hand every given-up row back to the retry machine (UI "retry now").
    /// Returns how many rows came back to `pending`.
    pub fn retry_failed_mutations(&self, server_id: &str) -> Result<usize, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let entries = store::outbox::all_entries(&conn, server_id).map_err(db_err)?;
        let entities: HashSet<String> = entries
            .into_iter()
            .filter(|entry| entry.state == store::outbox::STATE_FAILED)
            .map(|entry| entry.entity_id)
            .collect();
        let mut revived = 0usize;
        for entity_id in entities {
            revived += store::outbox::retry_failed(&conn, server_id, &entity_id).map_err(db_err)?;
        }
        Ok(revived)
    }

    // MARK: - Stage 6: Event Driven Sync (pollable SSE)

    /// One bounded SSE tick. The App owns start/stop for lifecycle, so Rust
    /// runs no event loop: the caller keeps the session in `state_json`, and
    /// this only parks the *socket* for the duration of the process
    /// (`SSE_SOCKETS`) because a live stream cannot cross the FFI.
    ///
    /// `Ok(None)` means another tick already holds this server's socket — the
    /// caller should simply try again on its next tick.
    pub async fn sse_poll(
        &self,
        server_id: String,
        base_url: String,
        api_key: String,
        state_json: String,
    ) -> Result<Option<SsePollResult>, ApiError> {
        let key = socket_key(&self.db_path, &server_id);
        let Some((mut source, idle_ticks)) =
            claim_socket(&key, || LiveSource::new(&base_url, &api_key))?
        else {
            return Ok(None);
        };
        // A hint stream belongs to one server: a state that came from another
        // one (switched server, replaced database) starts over instead of
        // resuming a socket handover that never happened.
        let mut session = session_for_server(&state_json, &server_id);
        let now = utc_now();
        // The socket half reads no database, so this await stays Send.
        let (action, dirty) = advance_stream(&mut session, &mut source, &now).await;
        // The hint half writes SQLite between its awaits, and `Connection` is
        // Send but not Sync: run it on a blocking thread with a runtime of its
        // own, the way the smoke binaries drive the core.
        let db_path = self.db_path.clone();
        let hints = dirty.clone();
        let streaming_for = server_id.clone();
        let (report, orphans) = tokio::task::spawn_blocking(move || {
            let runtime = owned_runtime()?;
            runtime.block_on(async move {
                let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
                let conn = store::open(&db_path).map_err(db_err)?;
                Ok::<_, ApiError>(
                    sync::sse::apply_dirty(&conn, &streaming_for, &hints, &client).await,
                )
            })
        })
        .await
        .map_err(join_err)??;
        let (action_name, owes_sweep) =
            settle_sweep(&mut session, action, &dirty, dirty.needs_sweep());
        self.remove_cover_files(&orphans);
        let result = SsePollResult::of(
            SseSessionState::of(&server_id, &session),
            action_name,
            &dirty,
            report,
            owes_sweep,
        );
        // The socket goes back whether the tick worked or not — dropping it on
        // an error would turn one bad read into a reconnect storm.
        park_socket(
            &key,
            source,
            if result.action == "idle" {
                idle_ticks + 1
            } else {
                0
            },
            result.keep_socket,
        );
        Ok(Some(result))
    }

    /// The SSE tick with both seams injectable (offline tests): `source` is the
    /// stream, `writer` the re-fetch behind every hint.
    #[allow(clippy::too_many_arguments)]
    pub async fn sse_poll_with<S: EventSource + Sync, W: ProgressWriter + Sync>(
        &self,
        source: &mut S,
        writer: &W,
        conn: &Connection,
        server_id: &str,
        state_json: &str,
        now: &str,
    ) -> Result<SsePollResult, ApiError> {
        let mut session = session_for_server(state_json, server_id);
        let (action, dirty) = advance_stream(&mut session, source, now).await;
        let (report, orphans, needs_sweep) =
            Self::apply_hints(conn, server_id, &dirty, writer).await;
        let (action_name, owes_sweep) = settle_sweep(&mut session, action, &dirty, needs_sweep);
        self.remove_cover_files(&orphans);
        Ok(SsePollResult::of(
            SseSessionState::of(server_id, &session),
            action_name,
            &dirty,
            report,
            owes_sweep,
        ))
    }

    /// `SSE Event → API 重新拉取 → SQLite 更新`. Bare book touches are
    /// re-fetched one by one; anything broader (a series, a collection, a
    /// readlist, an unnameable event) needs the caller's id sweep, so this
    /// reports `reconcile` and lets `sse_reconnected` do it once for all of it.
    async fn apply_hints<W: ProgressWriter + Sync>(
        conn: &Connection,
        server_id: &str,
        dirty: &DirtySet,
        writer: &W,
    ) -> (sync::sse::ApplyReport, Vec<String>, bool) {
        if dirty.is_empty() {
            return (sync::sse::ApplyReport::default(), Vec::new(), false);
        }
        let (report, orphans) = sync::sse::apply_dirty(conn, server_id, dirty, writer).await;
        (report, orphans, dirty.needs_sweep())
    }

    /// The caller finished the sweep `sse_poll` asked for: release the events
    /// that arrived while it ran, so they are consumed now instead of lost.
    /// Connectivity came back, or the app returned to the foreground: make the
    /// stream due immediately instead of waiting out the last backoff. The
    /// sweep it owes is not cancelled — `reconcile_required` survives.
    pub fn sse_resume(&self, state_json: String) -> Result<String, ApiError> {
        let state = session_from_state(&state_json);
        let mut session = state.to_session();
        session.resume(&utc_now());
        Ok(session_to_state(&SseSessionState::of(
            &state.server_id,
            &session,
        )))
    }

    pub fn sse_reconciled(&self, state_json: String) -> Result<String, ApiError> {
        let state = session_from_state(&state_json);
        let mut session = state.to_session();
        session.reconcile_done();
        Ok(session_to_state(&SseSessionState::of(
            &state.server_id,
            &session,
        )))
    }

    /// Give up on one server's stream (screen disposed / server switched): the
    /// parked socket goes away with it, so a stale connection cannot leak.
    pub fn sse_stop(&self, server_id: &str) {
        forget_socket(&socket_key(&self.db_path, server_id));
    }

    // MARK: - Book covers (SQLite-resolved paths, `variant = 'book'`)

    /// Book cover file path resolved from SQLite only (None = cache miss).
    pub fn book_cover_path(
        &self,
        server_id: &str,
        book_id: &str,
    ) -> Result<Option<String>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let row = store::thumbnails::get_thumbnail(&conn, server_id, book_id, VARIANT_BOOK)
            .map_err(db_err)?;
        match row {
            Some(row) if Path::new(&row.local_path).exists() => Ok(Some(row.local_path)),
            _ => Ok(None),
        }
    }

    /// Backfill one book cover (cache miss → download → disk → SQLite row).
    pub async fn ensure_book_cover(
        &self,
        server_id: String,
        book_id: String,
        base_url: String,
        api_key: String,
    ) -> Result<String, ApiError> {
        let client = KomgaClient::shared(base_url.clone(), AuthMethod::ApiKey { key: api_key })?;
        self.ensure_book_cover_with(&client, &base_url, &server_id, &book_id)
            .await
    }

    /// Same as ensure_book_cover with an injectable fetcher (online tests).
    pub async fn ensure_book_cover_with<F: BytesFetcher + Sync>(
        &self,
        fetcher: &F,
        base_url: &str,
        server_id: &str,
        book_id: &str,
    ) -> Result<String, ApiError> {
        if let Some(path) = self.book_cover_path(server_id, book_id)? {
            return Ok(path);
        }
        let cover_store = self.open_cover_store(base_url)?;
        let path = cover_store
            .ensure_book_thumbnail(fetcher, server_id, book_id)
            .await?;
        let size = std::fs::metadata(&path)
            .map(|m| m.len() as i64)
            .unwrap_or(0);
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::thumbnails::record_thumbnail(
            &conn,
            server_id,
            book_id,
            VARIANT_BOOK,
            &path.to_string_lossy(),
            size,
        )
        .map_err(db_err)?;
        Ok(path.to_string_lossy().into_owned())
    }

    /// Backfill every book cover of one series with no usable record yet
    /// (list persists per series — the series detail screen calls this).
    pub async fn ensure_book_covers(
        &self,
        server_id: String,
        series_id: String,
        base_url: String,
        api_key: String,
    ) -> Result<usize, ApiError> {
        let client = KomgaClient::shared(base_url.clone(), AuthMethod::ApiKey { key: api_key })?;
        self.ensure_book_covers_with(&client, &base_url, &server_id, &series_id)
            .await
    }

    /// Same as ensure_book_covers with an injectable fetcher (offline tests).
    pub async fn ensure_book_covers_with<F: BytesFetcher + Sync>(
        &self,
        fetcher: &F,
        base_url: &str,
        server_id: &str,
        series_id: &str,
    ) -> Result<usize, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let candidates =
            store::books::list_series_books(&conn, server_id, series_id).map_err(db_err)?;
        drop(conn);
        let mut backfilled = 0usize;
        for book_id in candidates {
            match self
                .ensure_book_cover_with(fetcher, base_url, server_id, &book_id)
                .await
            {
                Ok(_) => backfilled += 1,
                Err(e) => log::warn!("book cover backfill {book_id}: {e}"),
            }
        }
        Ok(backfilled)
    }
}

/// Demo cover endpoint: deterministic PNG bytes, no network (mirrors the
/// Swift app's `DemoCoverFetcher`).
struct DemoCoverFetcher {}

impl BytesFetcher for DemoCoverFetcher {
    async fn fetch_bytes(&self, url: &str) -> crate::api::error::Result<Vec<u8>> {
        Ok(crate::cache::demo_png::demo_cover_bytes(url))
    }
}

// MARK: - Stage 6 adapters (pollable SSE plumbing for the FFI)

/// The one clock the facade injects into the core's time-dependent entry
/// points, second precision so it compares cleanly against the backoff
/// deadlines the core stores (`next_retry_at` / `next_attempt_at`).
fn utc_now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// The Outbox in the shape the UI reads: counts for the badge plus whatever
/// has given up, which is the only state the user can act on.
fn outbox_status_of(
    conn: &Connection,
    server_id: &str,
    now: &str,
) -> Result<OutboxStatusDto, ApiError> {
    let counts = store::outbox::counts(conn, server_id, now).map_err(db_err)?;
    let failed_entries = store::outbox::all_entries(conn, server_id)
        .map_err(db_err)?
        .into_iter()
        .filter(|entry| entry.state == store::outbox::STATE_FAILED)
        .map(OutboxEntryDto::of)
        .collect();
    Ok(OutboxStatusDto {
        server_id: server_id.to_string(),
        pending: counts.pending,
        waiting: counts.waiting,
        failed: counts.failed,
        total: counts.total(),
        failed_entries,
    })
}

/// Events one tick may consume before handing control back.
const SSE_MAX_EVENTS_PER_POLL: usize = 64;

/// How long one SSE read may wait for a frame before the tick calls it idle.
/// The stream is not closed on idle: only the pending read is cancelled, and it
/// is cancel-safe — bytes are only consumed once a chunk has actually arrived.
const SSE_READ_WINDOW: Duration = Duration::from_millis(750);

/// How many consecutive silent ticks a parked stream may survive. Komga
/// heartbeats every 20s, so a stream that has produced *nothing* — not even a
/// comment frame — for this long is gone without having said so.
const SSE_MAX_IDLE_TICKS: u32 = 20;

/// The `EventSource` the *live* poll uses: the same shape
/// `bin/stage6_smoke.rs` drives, with an idle read reported as `Idle`.
struct LiveSource {
    client: SseClient,
    stream: Option<SseStream>,
}

impl LiveSource {
    fn new(base_url: &str, api_key: &str) -> ApiResult<Self> {
        Ok(Self {
            client: SseClient::new(
                base_url.to_string(),
                AuthMethod::ApiKey {
                    key: api_key.to_string(),
                },
            )?,
            stream: None,
        })
    }
}

impl EventSource for LiveSource {
    async fn open(&mut self, last_event_id: Option<&str>) -> ApiResult<()> {
        self.stream = Some(self.client.connect(last_event_id).await?);
        Ok(())
    }

    async fn next(&mut self) -> ApiResult<Option<SseEvent>> {
        let Some(stream) = self.stream.as_mut() else {
            return Err(ApiError::Network);
        };
        tokio::time::timeout(SSE_READ_WINDOW, stream.next_event())
            .await
            .unwrap_or(Err(ApiError::Idle))
    }

    fn close(&mut self) {
        self.stream = None;
    }
}

/// True for the one failure that means "nothing arrived yet" — it must never
/// be charged to the reconnect schedule, because it happens on every quiet tick.
fn is_idle(error: &ApiError) -> bool {
    matches!(error, ApiError::Idle)
}

/// The session a tick resumes: an unparseable or foreign state is a fresh one,
/// because a stream that cannot be read is a freshness loss only.
fn session_for_server(state_json: &str, server_id: &str) -> SseSession {
    let state = session_from_state(state_json);
    if state.server_id == server_id {
        state.to_session()
    } else {
        SseSession::new()
    }
}

/// One `owned_runtime`-free half of a tick: the state machine plus the socket.
/// No `Connection` is borrowed here, which is what lets the FFI call await it.
async fn advance_stream<S: EventSource + Sync>(
    session: &mut SseSession,
    source: &mut S,
    now: &str,
) -> (PumpAction, DirtySet) {
    // Nothing is ever closed for owing a sweep: `pump` keeps answering Reconcile
    // while Reconciling, and the handshake path needs its socket.
    let mut action = if session.phase == Phase::ReconcileOnly {
        // Parked: no handshake to re-run, but the reason stays reportable.
        PumpAction::ReconcileOnly
    } else {
        PumpAction::Idle
    };
    if session.phase != Phase::ReconcileOnly {
        if session.phase == Phase::Connected {
            action = read_available(session, source, now).await;
        } else {
            action = pump_once(session, source, now).await;
            if action == PumpAction::ReconcileOnly {
                // The stream is absent, not merely behind: the local mirror is
                // only trustworthy after the sweep that trigger names.
                session.reconcile_required = true;
            }
        }
    }
    let dirty = session.take_dirty();
    (action, dirty)
}

/// Decide what the caller owes, and hold or release the session accordingly.
/// One boolean drives both the reported action and `reconcile`: the reconnect
/// gap, a hint only an id sweep can settle, and the one sweep a missing stream
/// owes all ask for the same caller action.
fn settle_sweep(
    session: &mut SseSession,
    action: PumpAction,
    dirty: &DirtySet,
    needs_sweep: bool,
) -> (&'static str, bool) {
    let owes_sweep = needs_sweep
        || action == PumpAction::Reconcile
        || (action == PumpAction::ReconcileOnly && session.reconcile_required);
    if owes_sweep {
        match action {
            // The session holds its events until the caller says the sweep ran:
            // releasing them here would let a reconnect consume the very gap it
            // just refused to trust.
            PumpAction::Reconcile => {}
            PumpAction::ReconcileOnly => session.reconcile_required = false,
            // A hint that only an id sweep can settle: the stream itself is
            // healthy, so keep consuming while the caller sweeps.
            _ => session.reconcile_done(),
        }
    }
    let name = if owes_sweep {
        "reconcile"
    } else {
        match action {
            PumpAction::ReconcileOnly => "reconcile-only",
            PumpAction::BackingOff => "backing-off",
            PumpAction::Reconcile => "reconcile",
            PumpAction::Applied | PumpAction::Idle => {
                if dirty.is_empty() {
                    "idle"
                } else {
                    "applied"
                }
            }
        }
    };
    (name, owes_sweep)
}

/// A current-thread runtime for the passes that must hold a SQLite handle
/// across an await: `Connection` is `Send` but not `Sync`, so their futures
/// cannot be spawned on the FFI executor — the same trick `bin/stage6_smoke.rs`
/// uses, on a blocking thread instead of the main one.
fn owned_runtime() -> ApiResult<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| ApiError::Network)
}

/// A pass that died on its worker thread is reported, not propagated as a panic
/// into the platform thread.
fn join_err(e: tokio::task::JoinError) -> ApiError {
    ApiError::Database {
        message: format!("sync worker failed: {e}"),
    }
}

/// One `sync::sse::pump` step, from any phase except a live stream (which the
/// caller drains so a burst lands in one tick).
async fn pump_once<S: EventSource + Sync>(
    session: &mut SseSession,
    source: &mut S,
    now: &str,
) -> PumpAction {
    sync::sse::pump(session, source, now).await
}

/// Drain everything the stream has already dispatched. `pump` deliberately
/// reads one event per step, and a tick that stopped at the first one would
/// stretch a burst over many polling intervals.
async fn read_available<S: EventSource + Sync>(
    session: &mut SseSession,
    source: &mut S,
    now: &str,
) -> PumpAction {
    let mut applied = false;
    for _ in 0..SSE_MAX_EVENTS_PER_POLL {
        match source.next().await {
            Ok(Some(event)) => {
                session.note_event(&event);
                applied = true;
            }
            // The server closed it or the read failed: a gap we cannot read,
            // so the reconnect has to sweep before anything is trusted again.
            Ok(None) => break,
            // Idle: the stream is fine, it simply has nothing. Leave it open.
            Err(error) if is_idle(&error) => {
                return if applied {
                    PumpAction::Applied
                } else {
                    PumpAction::Idle
                }
            }
            Err(_) => break,
        }
    }
    source.close();
    session.note_disconnected(now, true);
    PumpAction::BackingOff
}

/// One server's parked stream. The socket is the only SSE state the FFI cannot
/// carry, and re-opening it every tick would make "the gap is unknowable" true
/// every tick — i.e. a reconcile storm.
enum Parked {
    Ready(Box<LiveSource>, u32),
    /// A tick holds it right now.
    Polling,
}

static SSE_SOCKETS: OnceLock<Mutex<HashMap<String, Parked>>> = OnceLock::new();

fn sockets() -> &'static Mutex<HashMap<String, Parked>> {
    SSE_SOCKETS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The database is part of the key: two App handles over different files must
/// not share one stream.
fn socket_key(db_path: &str, server_id: &str) -> String {
    format!("{db_path}\u{1}{server_id}")
}

/// Takes the socket for this tick, opening one when there is nothing parked.
/// `None` means a concurrent tick already holds it — that tick reports the
/// events, so this one has nothing to do.
fn claim_socket(
    key: &str,
    make: impl FnOnce() -> ApiResult<LiveSource>,
) -> ApiResult<Option<(LiveSource, u32)>> {
    let parked = {
        let Ok(mut guard) = sockets().lock() else {
            return Ok(None);
        };
        if matches!(guard.get(key), Some(Parked::Polling)) {
            return Ok(None);
        }
        guard.insert(key.to_string(), Parked::Polling)
    };
    Ok(Some(match parked {
        Some(Parked::Ready(source, idle_ticks)) => (*source, idle_ticks),
        _ => (make()?, 0),
    }))
}

/// Parks the socket again for the next tick. `keep` is false once the session
/// owes a handshake only `pump` may run, and a stream that has stopped proving
/// itself alive is dropped rather than re-read forever — either way the entry
/// has to go, or every later tick would believe one is already running.
fn park_socket(key: &str, source: LiveSource, idle_ticks: u32, keep: bool) {
    let Ok(mut guard) = sockets().lock() else {
        return;
    };
    if keep && idle_ticks < SSE_MAX_IDLE_TICKS {
        guard.insert(key.to_string(), Parked::Ready(Box::new(source), idle_ticks));
    } else {
        guard.remove(key);
    }
}

/// Forgets a server's stream entirely (`sse_stop`).
fn forget_socket(key: &str) {
    if let Ok(mut guard) = sockets().lock() {
        guard.remove(key);
    }
}

// MARK: - FFI result types (plain Rust structs, FRB-friendly)

/// Re-export for the bridge: paged series rows + total (本地查询).
pub use crate::store::query::{BookPageResult, SeriesPageResult};

/// Paged collection rows + total.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectionPageResult {
    pub items: Vec<CollectionRow>,
    pub total: i64,
}

/// Paged readlist rows + total.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadlistPageResult {
    pub items: Vec<ReadlistRow>,
    pub total: i64,
}

/// Full series detail (row + metadata + normalized tags/genres/authors +
/// collection memberships).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeriesDetailRow {
    pub server_id: String,
    pub remote_id: String,
    pub library_id: String,
    pub name: String,
    pub sort_name: Option<String>,
    pub status: Option<String>,
    pub created_at: Option<String>,
    pub last_modified: Option<String>,
    pub books_count: Option<i64>,
    pub books_read_count: Option<i64>,
    pub books_unread_count: Option<i64>,
    pub books_in_progress_count: Option<i64>,
    pub summary: Option<String>,
    pub publisher: Option<String>,
    pub reading_direction: Option<String>,
    pub language: Option<String>,
    pub age_rating: Option<String>,
    pub total_book_count: Option<i64>,
    pub genres: Vec<String>,
    pub tags: Vec<String>,
    pub authors: Vec<crate::store::AuthorRow>,
    pub collections: Vec<CollectionRef>,
}

/// A collection that contains a series (detail screen membership chips).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectionRef {
    pub remote_id: String,
    pub name: String,
}

/// Full book detail (row + metadata + tags + authors + read progress).
#[derive(Debug, Clone, PartialEq)]
pub struct BookDetailRow {
    pub server_id: String,
    pub remote_id: String,
    pub series_id: String,
    pub series_title: Option<String>,
    pub title: String,
    pub number: Option<String>,
    pub number_sort: Option<f64>,
    pub summary: Option<String>,
    pub isbn: Option<String>,
    pub release_date: Option<String>,
    pub media_type: Option<String>,
    pub pages_count: Option<i64>,
    pub file_size: Option<i64>,
    pub created_at: Option<String>,
    pub last_modified: Option<String>,
    pub tags: Vec<String>,
    pub authors: Vec<crate::store::AuthorRow>,
    pub progress_page: Option<i64>,
    pub progress_completed: bool,
}

/// Collection detail: row + its member series (paged).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectionDetailRow {
    pub remote_id: String,
    pub name: String,
    pub ordered: bool,
    pub filtered: bool,
    pub created_date: Option<String>,
    pub last_modified_date: Option<String>,
    pub members: SeriesPageResult,
}

/// Readlist detail: row + its ordered books (paged).
#[derive(Debug, Clone, PartialEq)]
pub struct ReadlistDetailRow {
    pub remote_id: String,
    pub name: String,
    pub summary: Option<String>,
    pub ordered: bool,
    pub filtered: bool,
    pub created_date: Option<String>,
    pub last_modified_date: Option<String>,
    pub books: BookPageResult,
}

/// Distinct filter-chip options derived from the local mirror.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct FilterOptions {
    pub tags: Vec<String>,
    pub genres: Vec<String>,
    pub statuses: Vec<String>,
}

/// Library rows with their local series counts (Library 列表/切换).
pub use crate::store::query::LibraryCountRow;

fn db_err(e: rusqlite::Error) -> ApiError {
    ApiError::Database {
        message: e.to_string(),
    }
}

fn storage_err(e: std::io::Error) -> ApiError {
    ApiError::Storage {
        message: e.to_string(),
    }
}

/// Outcome of the connection probe: server identity/version, remote
/// entities (libraries) and policy-derived capabilities.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionResult {
    pub server_info: ServerInfo,
    /// `build.version` of the server (policy input).
    pub server_version: Option<String>,
    pub libraries: Vec<Library>,
    /// e.g. `libraries:2`, `unknown-version`, `newer-than-snapshot:1.27.0`.
    pub capabilities: Vec<String>,
}

// MARK: - Stage 6 result types (Outbox + pollable SSE)

/// One queued client write, in the shape the UI lists it under the badge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutboxEntryDto {
    pub id: String,
    pub entity_id: String,
    pub mutation_type: String,
    pub retry_count: i64,
    pub last_error: Option<String>,
    /// `pending` | `failed`.
    pub state: String,
    pub next_retry_at: Option<String>,
    pub created_at: String,
}

impl OutboxEntryDto {
    fn of(entry: OutboxEntry) -> Self {
        Self {
            id: entry.id,
            entity_id: entry.entity_id,
            mutation_type: entry.mutation_type,
            retry_count: entry.retry_count,
            last_error: entry.last_error,
            state: entry.state,
            next_retry_at: entry.next_retry_at,
            created_at: entry.created_at,
        }
    }
}

/// The Outbox badge plus whatever has given up — the only part of the queue a
/// user can act on.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutboxStatusDto {
    pub server_id: String,
    /// Due right now; an upload pass would take these.
    pub pending: i64,
    /// Still waiting for a backoff deadline that is on disk, not in memory.
    pub waiting: i64,
    pub failed: i64,
    pub total: i64,
    pub failed_entries: Vec<OutboxEntryDto>,
}

/// What one upload pass did, and the queue it left behind: the caller needs
/// both to refresh the badge without a second round trip.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadOutcomeDto {
    pub server_id: String,
    pub considered: i64,
    pub uploaded: i64,
    /// Converged without a request (rule R3).
    pub already_applied: i64,
    /// Rule R4: a strictly later remote action won.
    pub remote_wins: i64,
    /// Rule R1: the server confirmed the entity is gone.
    pub gone: i64,
    pub retried: i64,
    pub rejected: i64,
    pub blocked_authentication: i64,
    /// `complete` | `blocked_authentication`.
    pub status: String,
    pub outbox: OutboxStatusDto,
}

impl UploadOutcomeDto {
    fn of(summary: &UploadSummary, outbox: OutboxStatusDto) -> Self {
        Self {
            server_id: summary.server_id.clone(),
            considered: summary.considered as i64,
            uploaded: summary.uploaded as i64,
            already_applied: summary.already_applied as i64,
            remote_wins: summary.remote_wins as i64,
            gone: summary.gone as i64,
            retried: summary.retried as i64,
            rejected: summary.rejected as i64,
            blocked_authentication: summary.blocked_authentication as i64,
            status: match summary.status {
                sync::upload::RunStatus::BlockedAuthentication => "blocked_authentication",
                sync::upload::RunStatus::Complete => "complete",
            }
            .to_string(),
            outbox,
        }
    }
}

/// A dispatched frame, mirrored for the round trip: the session buffers events
/// while a reconnect sweep runs, and dropping them there would be trusting the
/// stream to be a queue.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SseEventDto {
    pub kind: String,
    pub data: String,
    pub id: Option<String>,
    pub retry_ms: Option<u64>,
}

impl From<&SseEvent> for SseEventDto {
    fn from(event: &SseEvent) -> Self {
        Self {
            kind: event.kind.clone(),
            data: event.data.clone(),
            id: event.id.clone(),
            retry_ms: event.retry_ms,
        }
    }
}

impl From<SseEventDto> for SseEvent {
    fn from(value: SseEventDto) -> Self {
        Self {
            kind: value.kind,
            data: value.data,
            id: value.id,
            retry_ms: value.retry_ms,
        }
    }
}

/// The coalescing hint list, mirrored (`BTreeSet` has no Dart counterpart).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DirtySetDto {
    pub books: Vec<String>,
    pub deleted_books: Vec<String>,
    pub series: Vec<String>,
    pub deleted_series: Vec<String>,
    pub collections: Vec<String>,
    pub readlists: Vec<String>,
    pub global: bool,
}

impl From<&DirtySet> for DirtySetDto {
    fn from(dirty: &DirtySet) -> Self {
        Self {
            books: dirty.books.iter().cloned().collect(),
            deleted_books: dirty.deleted_books.iter().cloned().collect(),
            series: dirty.series.iter().cloned().collect(),
            deleted_series: dirty.deleted_series.iter().cloned().collect(),
            collections: dirty.collections.iter().cloned().collect(),
            readlists: dirty.readlists.iter().cloned().collect(),
            global: dirty.global,
        }
    }
}

impl From<DirtySetDto> for DirtySet {
    fn from(value: DirtySetDto) -> Self {
        Self {
            books: value.books.into_iter().collect(),
            deleted_books: value.deleted_books.into_iter().collect(),
            series: value.series.into_iter().collect(),
            deleted_series: value.deleted_series.into_iter().collect(),
            collections: value.collections.into_iter().collect(),
            readlists: value.readlists.into_iter().collect(),
            global: value.global,
        }
    }
}

/// The SSE session as it travels through Dart: opaque JSON in, same JSON back.
///
/// It is the core `SseSession` plus the server it belongs to, because a session
/// resumed against a different server would resume someone else's gap.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SseSessionState {
    pub server_id: String,
    /// `disconnected` | `reconciling` | `connected` | `reconcile_only`.
    pub phase: String,
    pub attempts: i64,
    pub next_attempt_at: Option<String>,
    pub last_event_id: Option<String>,
    pub retry_floor_ms: Option<u64>,
    pub reconcile_required: bool,
    pub reason: Option<String>,
    pub buffered: Vec<SseEventDto>,
    pub dirty: DirtySetDto,
}

impl SseSessionState {
    fn of(server_id: &str, session: &SseSession) -> Self {
        Self {
            server_id: server_id.to_string(),
            phase: phase_name(session.phase).to_string(),
            attempts: session.attempts,
            next_attempt_at: session.next_attempt_at.clone(),
            last_event_id: session.last_event_id.clone(),
            retry_floor_ms: session.retry_floor_ms,
            reconcile_required: session.reconcile_required,
            reason: session.reason.clone(),
            buffered: session.buffered.iter().map(SseEventDto::from).collect(),
            dirty: DirtySetDto::from(&session.dirty),
        }
    }

    fn to_session(&self) -> SseSession {
        SseSession {
            phase: phase_of(&self.phase),
            attempts: self.attempts,
            next_attempt_at: self.next_attempt_at.clone(),
            last_event_id: self.last_event_id.clone(),
            retry_floor_ms: self.retry_floor_ms,
            buffered: self.buffered.iter().cloned().map(SseEvent::from).collect(),
            dirty: self.dirty.clone().into(),
            reconcile_required: self.reconcile_required,
            reason: self.reason.clone(),
        }
    }
}

fn phase_name(phase: Phase) -> &'static str {
    match phase {
        Phase::Disconnected => "disconnected",
        Phase::Reconciling => "reconciling",
        Phase::Connected => "connected",
        Phase::ReconcileOnly => "reconcile_only",
    }
}

/// Anything unrecognised is `Disconnected` — the one phase that owes a fresh
/// handshake, so a state from a newer core is never trusted into a read.
fn phase_of(name: &str) -> Phase {
    match name {
        "reconciling" => Phase::Reconciling,
        "connected" => Phase::Connected,
        "reconcile_only" => Phase::ReconcileOnly,
        _ => Phase::Disconnected,
    }
}

/// Untrusted input gets a fresh session: a stream that cannot be read is a
/// freshness loss only, which is exactly what the contract allows.
fn session_from_state(state_json: &str) -> SseSessionState {
    serde_json::from_str(state_json).unwrap_or_else(|_| SseSessionState {
        server_id: String::new(),
        phase: phase_name(Phase::Disconnected).to_string(),
        attempts: 0,
        next_attempt_at: None,
        last_event_id: None,
        retry_floor_ms: None,
        reconcile_required: false,
        reason: None,
        buffered: Vec::new(),
        dirty: DirtySetDto::default(),
    })
}

/// Round-trip helper for callers that only ran the sweep (`sse_reconciled`).
fn session_to_state(state: &SseSessionState) -> String {
    serde_json::to_string(state).unwrap_or_else(|_| String::new())
}

/// What one SSE tick reported. `dirtyBooks` are the ids this tick re-fetched
/// into SQLite — the caller re-reads its list rather than applying a payload,
/// because an event is a hint, never truth.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SsePollResult {
    /// Feed this straight back into the next `sse_poll`.
    pub state_json: String,
    /// `idle` | `applied` | `reconcile` | `backing-off` | `reconcile-only`.
    pub action: String,
    /// True when the caller must run a Reconcile (`sse_reconnected`) and then
    /// hand the state back through `sse_reconciled`.
    pub reconcile: bool,
    pub dirty_books: Vec<String>,
    pub phase: String,
    /// Why the stream is parked (e.g. `/sse/v1/events` is not an event stream).
    pub reason: Option<String>,
    /// Counts of the hints this tick turned into local rows.
    pub books_written: i64,
    pub books_deleted: i64,
    /// False once the parked stream is not worth keeping: a closed, failed or
    /// handed-up stream owes a handshake that only the Rust side may run.
    pub keep_socket: bool,
}

impl SsePollResult {
    fn of(
        state: SseSessionState,
        action: &'static str,
        dirty: &DirtySet,
        report: sync::sse::ApplyReport,
        reconcile: bool,
    ) -> Self {
        let mut dirty_books: Vec<String> = dirty.books.iter().cloned().collect();
        dirty_books.extend(dirty.deleted_books.iter().cloned());
        let phase = phase_of(&state.phase);
        Self {
            state_json: session_to_state(&state),
            action: action.to_string(),
            reconcile,
            dirty_books,
            phase: state.phase.clone(),
            reason: state.reason.clone(),
            books_written: report.books_written as i64,
            books_deleted: report.books_deleted as i64,
            // A stream that is merely waiting for the caller's sweep is still
            // open; dropping it there would make the first tick after the sweep
            // read a handle that nothing reconnects.
            keep_socket: matches!(phase, Phase::Connected | Phase::Reconciling),
        }
    }
}

// ==========================================================================
/// Stage 7: the reader facade. See the rules at the top of the impl below.
impl App {
    // MARK: - Stage 7 reader facade
    //
    // Three rules shape everything below, and they are the reason it looks
    // indirect:
    //
    // 1. A page leaves this boundary as a LOCAL FILE PATH, never a URL. The
    //    Flutter/SwiftUI layer therefore cannot make a request even by accident.
    // 2. No `Connection` and no lock guard is ever held across an `await`; the
    //    transport runs first and the synchronous pipeline lands the bytes.
    // 3. Anything that must survive a crash is in SQLite (position, progress,
    //    outbox). The in-process registry below only holds the throttle clock
    //    and the layout the user is looking at, and is rebuilt on open.

    /// Open a book in the reader: mirror-or-fetch the manifest, restore the
    /// position, and hand back the layout the UI should draw.
    #[allow(clippy::too_many_arguments)]
    pub async fn reader_open(
        &self,
        server_id: String,
        book_id: String,
        base_url: String,
        api_key: String,
        mode: String,
        direction: String,
        first_page_single: Option<bool>,
    ) -> Result<ReaderBookDto, ApiError> {
        let (mirrored, media_type) = {
            let conn = store::open(&self.db_path).map_err(db_err)?;
            let rows = store::pages::list(&conn, &server_id, &book_id).map_err(db_err)?;
            let media: Option<String> = conn
                .query_row(
                    "SELECT media_type FROM books WHERE server_id = ?1 AND remote_id = ?2",
                    rusqlite::params![server_id, book_id],
                    |row| row.get(0),
                )
                .unwrap_or(None);
            (rows, media)
        };
        let from_mirror = !mirrored.is_empty();
        let raw = if from_mirror {
            Vec::new()
        } else {
            let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
            let dtos = client.pages(&book_id).await?;
            dtos.iter()
                .map(|page| reader::manifest::RawPage {
                    file_name: page.file_name.clone(),
                    media_type: page.media_type.clone(),
                    number: i64::from(page.number),
                    width: page.width.map(i64::from),
                    height: page.height.map(i64::from),
                    size_bytes: page.size_bytes,
                })
                .collect()
        };

        let conn = store::open(&self.db_path).map_err(db_err)?;
        let manifest = if from_mirror {
            reader::manifest::PageManifest::from_rows(
                &server_id,
                &book_id,
                media_type.as_deref(),
                &mirrored,
            )
        } else {
            let built = reader::manifest::PageManifest::from_raw(
                &server_id,
                &book_id,
                media_type.as_deref(),
                &raw,
            );
            if built.empty_error() {
                return Err(ApiError::InvalidInput {
                    message: format!("book {book_id} reports no pages"),
                });
            }
            let rows: Vec<_> = built.pages.iter().map(|page| page.to_row()).collect();
            store::pages::replace(&conn, &server_id, &book_id, &rows, &thumbnails_now())
                .map_err(db_err)?;
            built
        };
        if manifest.empty_error() {
            return Err(ApiError::InvalidInput {
                message: format!("book {book_id} has no mirrored pages"),
            });
        }

        let mut settings = reader::settings::ReaderSettings::load(&conn).map_err(db_err)?;
        if !mode.is_empty() {
            settings.mode = reader::paging::ReadMode::parse(&mode);
        }
        if !direction.is_empty() {
            // Per-book last-used direction wins over the global default; an
            // explicit request from the UI beats both.
            settings.direction = reader::settings::resolve_direction(
                store::position::get(&conn, &server_id, &book_id)
                    .map_err(db_err)?
                    .as_ref()
                    .map(|saved| reader::paging::Direction::parse(&saved.direction)),
                None,
                reader::paging::Direction::parse(&direction),
            );
        }
        if let Some(first) = first_page_single {
            settings.first_page_single = first;
        }
        let session = reader::session::ReaderSession::open(
            &conn,
            &server_id,
            &book_id,
            manifest.page_count(),
            manifest.writes_page_progress(),
            &settings,
            &reader::session::Clock::now(),
        )
        .map_err(db_err)?;
        let summary = (
            manifest.page_count() as i64,
            manifest.is_paged(),
            manifest.reflowable,
            manifest.fallback.map(|kind| kind.as_str().to_string()),
        );
        let layout = layout_dto(&session, &settings);
        readers().insert(
            reader_key(&server_id, &book_id),
            LiveReader {
                session,
                settings,
                window: None,
                pool_budget_bytes: reader::cache::DEFAULT_BUDGET_BYTES,
            },
        );
        Ok(ReaderBookDto {
            server_id,
            book_id,
            page_count: summary.0,
            paged: summary.1,
            reflowable: summary.2,
            fallback: summary.3,
            from_mirror,
            start_page: layout.page,
            layout,
        })
    }

    /// Where this page already is on disk, if anywhere. No network: this is what
    /// the UI paints first, and what tells it whether a fetch is needed.
    pub fn reader_page_path(
        &self,
        server_id: String,
        book_id: String,
        page: i64,
    ) -> Result<Option<String>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let manifest = self.mirrored_manifest(&conn, &server_id, &book_id)?;
        let cache = self.reader_cache_for(&server_id, &book_id)?;
        let hit = cache
            .lookup(&conn, &manifest.cache_key(page as u32), &thumbnails_now())
            .map_err(storage_err)?;
        Ok(hit.map(|location| location.path.to_string_lossy().into_owned()))
    }

    /// Resolve one page for display, fetching only on a cache miss.
    pub async fn reader_page(
        &self,
        server_id: String,
        book_id: String,
        page: i64,
        base_url: String,
        api_key: String,
    ) -> Result<String, ApiError> {
        if let Some(path) = self.reader_page_path(server_id.clone(), book_id.clone(), page)? {
            return Ok(path);
        }
        let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
        let (bytes, content_type) = client.page_bytes(&book_id, page as u32).await?;
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let manifest = self.mirrored_manifest(&conn, &server_id, &book_id)?;
        let cache = self.reader_cache_for(&server_id, &book_id)?;
        let location = cache
            .store(
                &conn,
                &manifest.cache_key(page as u32),
                &bytes,
                &content_type,
                &thumbnails_now(),
            )
            .map_err(storage_err)?;
        Ok(location.path.to_string_lossy().into_owned())
    }

    /// Pull the pages around one spread into the cache. The window is computed
    /// locally, so a warm neighbourhood costs nothing.
    pub async fn reader_prefetch(
        &self,
        server_id: String,
        book_id: String,
        spread: i64,
        base_url: String,
        api_key: String,
    ) -> Result<i64, ApiError> {
        let (mut plan, manifest) = {
            let conn = store::open(&self.db_path).map_err(db_err)?;
            let manifest = self.mirrored_manifest(&conn, &server_id, &book_id)?;
            let window = self.reader_window_for(&server_id, &book_id);
            let spreads = match self.reader_spreads(&server_id, &book_id)? {
                Some(spreads) => spreads,
                None => return Ok(0),
            };
            let cached = self.open_reader_cache()?.cached_pages(&conn, &manifest);
            (
                reader::prefetch::plan(&spreads, spread.max(0) as usize, window, &cached).queue,
                manifest,
            )
        };
        let budget = self.reader_prefetch_budget(&server_id, &book_id);
        plan.truncate(budget);
        if plan.is_empty() {
            return Ok(0);
        }
        let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;

        // Transport first, storage second, and never the two interleaved: a
        // `Connection` may not be held across an `await`, because the frb async
        // runtime moves the future between threads and rusqlite's handle is
        // neither `Send` nor `Sync`. Fetching the whole (short) window into memory
        // first is also what makes the write half one transaction.
        // The manifest mirror answers "how big should this page be" for the whole
        // window in one query. Reading it per page would open the database again
        // for every download, which is the opposite of what this pass is for.
        let declared_sizes: std::collections::BTreeMap<i64, i64> = {
            let conn = store::open(&self.db_path).map_err(db_err)?;
            let mut rows = conn
                .prepare(
                    "SELECT number, size_bytes FROM book_pages
                     WHERE server_id = ?1 AND book_id = ?2",
                )
                .map_err(db_err)?;
            let collected = rows
                .query_map(rusqlite::params![server_id, book_id], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
                })
                .map_err(db_err)?;
            collected.filter_map(Result::ok).collect()
        };
        let mut fetched: Vec<(String, Vec<u8>, String, i64)> = Vec::new();
        for number in plan {
            let key = manifest.cache_key(number);
            let declared = declared_sizes.get(&(number as i64)).copied().unwrap_or(0);
            match client.page_bytes(&book_id, number).await {
                Ok((bytes, content_type)) => fetched.push((key, bytes, content_type, declared)),
                // One outage must not become N requests, and prefetch failures
                // are never surfaced to the page on screen.
                Err(error) => {
                    log::warn!("prefetch {book_id} page {number}: {error}");
                    break;
                }
            }
        }

        let cache = self.reader_cache_for(&server_id, &book_id)?;
        let conn = store::open(&self.db_path).map_err(db_err)?;
        // One transaction for the whole pass: every landed page writes a
        // `cache_entries` row, and one commit per page is write amplification the
        // reader pays for on the thread it wants to keep responsive with.
        let tx = conn.unchecked_transaction().map_err(db_err)?;
        let mut landed = 0i64;
        for (key, bytes, content_type, declared) in &fetched {
            if cache.is_cached(&tx, key) {
                continue;
            }
            // The prefetch tier, and with the manifest's own declared size: bytes
            // that arrive short must be refused here rather than cached and
            // discovered later as a broken image.
            match cache.store_tier(
                &tx,
                key,
                bytes,
                content_type,
                &thumbnails_now(),
                reader::cache::Tier::Prefetch,
                if *declared > 0 { Some(*declared) } else { None },
            ) {
                Ok(_) => landed += 1,
                Err(error) => log::warn!("page cache {key}: {error}"),
            }
        }
        // Losing this commit is not cosmetic: the page files are already on disk,
        // so vanished rows turn them into orphans that the next sweep deletes and
        // the resume after that re-downloads. `busy_timeout` on every connection
        // (`store::configure`) is what prevents the contention that causes it;
        // retrying here cannot, because `commit` consumes the transaction.
        if let Err(error) = tx.commit() {
            log::error!("prefetch commit for {book_id}: {error}");
            return Err(db_err(error));
        }
        Ok(landed)
    }

    /// Turn to a page: writes position + progress + outbox row, and says whether
    /// an upload is due now.
    pub fn reader_turn(
        &self,
        server_id: String,
        book_id: String,
        page: i64,
    ) -> Result<ReaderTurnDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let key = reader_key(&server_id, &book_id);
        let mut guard = readers();
        let live = guard.get_mut(&key).ok_or_else(|| ApiError::InvalidInput {
            message: "reader is not open".to_string(),
        })?;
        let upload = live
            .session
            .turn_to(&conn, page.max(1) as u32, &reader::session::Clock::now())
            .map_err(db_err)?;
        Ok(ReaderTurnDto {
            page: live.session.page() as i64,
            spread: live.session.spread() as i64,
            upload_now: upload == reader::session::Upload::Now,
        })
    }

    /// Advance (delta = +1) or retreat (delta = -1) one spread, in whatever
    /// direction the reader is currently set to.
    pub fn reader_step(
        &self,
        server_id: String,
        book_id: String,
        delta: i64,
    ) -> Result<ReaderTurnDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let key = reader_key(&server_id, &book_id);
        let mut guard = readers();
        let live = guard.get_mut(&key).ok_or_else(|| ApiError::InvalidInput {
            message: "reader is not open".to_string(),
        })?;
        let clock = reader::session::Clock::now();
        let upload = if delta >= 0 {
            live.session.next(&conn, &clock)
        } else {
            live.session.previous(&conn, &clock)
        }
        .map_err(db_err)?;
        Ok(ReaderTurnDto {
            page: live.session.page() as i64,
            spread: live.session.spread() as i64,
            upload_now: upload == reader::session::Upload::Now,
        })
    }

    /// Change mode/direction mid-book: the layout is recomputed and the same
    /// spread the reader was on survives the re-pairing.
    pub fn reader_set_layout(
        &self,
        server_id: String,
        book_id: String,
        mode: String,
        direction: String,
    ) -> Result<ReaderLayoutDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let key = reader_key(&server_id, &book_id);
        let mut guard = readers();
        let live = guard.get_mut(&key).ok_or_else(|| ApiError::InvalidInput {
            message: "reader is not open".to_string(),
        })?;
        live.settings.mode = reader::paging::ReadMode::parse(&mode);
        live.settings.direction = reader::paging::Direction::parse(&direction);
        live.settings = live.settings.clone().sanitized();
        live.session
            .relayout(
                &conn,
                live.settings.mode,
                live.settings.direction,
                &reader::session::Clock::now(),
            )
            .map_err(db_err)?;
        Ok(layout_dto(&live.session, &live.settings))
    }

    pub fn reader_mark_read(&self, server_id: String, book_id: String) -> Result<bool, ApiError> {
        self.reader_mark(&server_id, &book_id, true)
    }

    pub fn reader_mark_unread(&self, server_id: String, book_id: String) -> Result<bool, ApiError> {
        self.reader_mark(&server_id, &book_id, false)
    }

    fn reader_mark(&self, server_id: &str, book_id: &str, read: bool) -> Result<bool, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let key = reader_key(server_id, book_id);
        let mut guard = readers();
        let live = guard.get_mut(&key).ok_or_else(|| ApiError::InvalidInput {
            message: "reader is not open".to_string(),
        })?;
        let clock = reader::session::Clock::now();
        let upload = if read {
            live.session.mark_read(&conn, &clock)
        } else {
            live.session.mark_unread(&conn, &clock)
        }
        .map_err(db_err)?;
        Ok(upload == reader::session::Upload::Now)
    }

    /// The UI's periodic beat: may flush a queued page, and always says whether
    /// `upload_outbox` should run now.
    pub fn reader_tick(&self, server_id: String, book_id: String) -> Result<bool, ApiError> {
        let key = reader_key(&server_id, &book_id);
        let mut guard = readers();
        match guard.get_mut(&key) {
            Some(live) => {
                Ok(live.session.tick(&reader::session::Clock::now())
                    == reader::session::Upload::Now)
            }
            None => Ok(false),
        }
    }

    /// Leaving the reader. The position is already durable; this only decides
    /// whether one last upload should be attempted before the screen goes.
    pub fn reader_close(&self, server_id: String, book_id: String) -> Result<bool, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let key = reader_key(&server_id, &book_id);
        let mut guard = readers();
        match guard.remove(&key) {
            Some(mut live) => Ok(live
                .session
                .close(&conn, &reader::session::Clock::now())
                .map_err(db_err)?
                == reader::session::Upload::Now),
            None => Ok(false),
        }
    }

    /// Backgrounding: same urgency as closing, but the reader stays open.
    pub fn reader_background(&self, server_id: String, book_id: String) -> Result<bool, ApiError> {
        let key = reader_key(&server_id, &book_id);
        let mut guard = readers();
        match guard.get_mut(&key) {
            Some(live) => Ok(live.session.background(&reader::session::Clock::now())
                == reader::session::Upload::Now),
            None => Ok(false),
        }
    }

    pub fn reader_settings(&self) -> Result<ReaderSettingsDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        Ok(settings_dto(
            reader::settings::ReaderSettings::load(&conn).map_err(db_err)?,
        ))
    }

    pub fn reader_set_settings(
        &self,
        settings: ReaderSettingsDto,
    ) -> Result<ReaderSettingsDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let parsed = settings_of(settings);
        reader::settings::ReaderSettings::save(&conn, &parsed).map_err(db_err)?;
        Ok(settings_dto(
            reader::settings::ReaderSettings::load(&conn).map_err(db_err)?,
        ))
    }

    /// Manifest straight out of SQLite; an error only when it was never mirrored.
    fn mirrored_manifest(
        &self,
        conn: &rusqlite::Connection,
        server_id: &str,
        book_id: &str,
    ) -> Result<reader::manifest::PageManifest, ApiError> {
        let rows = store::pages::list(conn, server_id, book_id).map_err(db_err)?;
        if rows.is_empty() {
            return Err(ApiError::InvalidInput {
                message: format!(
                    "book {book_id} has no mirrored manifest — open it online once first"
                ),
            });
        }
        let media: Option<String> = conn
            .query_row(
                "SELECT media_type FROM books WHERE server_id = ?1 AND remote_id = ?2",
                rusqlite::params![server_id, book_id],
                |row| row.get(0),
            )
            .unwrap_or(None);
        Ok(reader::manifest::PageManifest::from_rows(
            server_id,
            book_id,
            media.as_deref(),
            &rows,
        ))
    }

    fn open_reader_cache(&self) -> Result<reader::cache::PageCache, ApiError> {
        self.open_reader_cache_with(reader::cache::DEFAULT_BUDGET_BYTES)
    }

    /// One handle per call, all sharing the process-wide memory tier.
    ///
    /// `App` is rebuilt for every FFI call, so a tier owned by the handle would
    /// be created and dropped between two page turns and warm nothing at all.
    fn open_reader_cache_with(
        &self,
        pool_budget_bytes: i64,
    ) -> Result<reader::cache::PageCache, ApiError> {
        let mut cache = reader::cache::PageCache::shared(self.cache_root()).map_err(storage_err)?;
        cache.set_budget(pool_budget_bytes);
        Ok(cache)
    }

    /// The cache as the reader's live profile wants it.
    fn reader_cache_for(
        &self,
        server_id: &str,
        book_id: &str,
    ) -> Result<reader::cache::PageCache, ApiError> {
        let pool = readers()
            .get(&reader_key(server_id, book_id))
            .map(|live| live.pool_budget_bytes)
            .unwrap_or(reader::cache::DEFAULT_BUDGET_BYTES);
        self.open_reader_cache_with(pool)
    }

    /// How many pages one prefetch call may pull, from the live plan.
    ///
    /// `in_flight` exists because a window is a queue, not a promise to drain it
    /// in one go: each of these downloads holds the platform thread, and a fast
    /// reader who turns ten pages while one 13-page window is still being served
    /// gets ten windows of work for five pages of reading. The rest of the queue
    /// is picked up by the next call, from wherever the reader has got to.
    fn reader_prefetch_budget(&self, server_id: &str, book_id: &str) -> usize {
        readers()
            .get(&reader_key(server_id, book_id))
            .and_then(|live| live.window)
            .map(|plan| plan.in_flight.max(1))
            .unwrap_or(super::super::reader::window::MAX_IN_FLIGHT)
    }

    /// The window the live reader should prefetch with: the device-derived plan
    /// when the UI has reported one, otherwise the stored user setting.
    fn reader_window_for(&self, server_id: &str, book_id: &str) -> reader::prefetch::Window {
        let guard = readers();
        match guard.get(&reader_key(server_id, book_id)) {
            Some(live) => live
                .window
                .map(|plan| plan.window())
                .unwrap_or(live.settings.prefetch),
            None => reader::prefetch::Window::default(),
        }
    }

    /// Report what this device and link are like, and get back the numbers the
    /// core derived from them.
    ///
    /// This is the only path by which physical RAM, page size and link quality
    /// reach the prefetch planner — the core cannot probe any of them, and it must
    /// not guess generously. The UI calls it once on open and again whenever the
    /// network changes, which is also how a Wi-Fi to cellular handover stops
    /// pulling 4K pages over a metered link.
    pub fn reader_configure_device(
        &self,
        server_id: String,
        book_id: String,
        device: DeviceProfileDto,
    ) -> Result<ReaderWindowDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let manifest = self.mirrored_manifest(&conn, &server_id, &book_id)?;
        let key = reader_key(&server_id, &book_id);
        let (mode, direction, pages_per_spread) = {
            let guard = readers();
            match guard.get(&key) {
                Some(live) => {
                    let width = live
                        .session
                        .layout()
                        .spreads
                        .iter()
                        .map(|spread| spread.len())
                        .max()
                        .unwrap_or(1)
                        .max(1);
                    (live.session.mode(), live.session.direction(), width)
                }
                None => (
                    reader::paging::ReadMode::Single,
                    reader::paging::Direction::Ltr,
                    1,
                ),
            }
        };
        // The manifest's own reported sizes are the best available answer to
        // "how big is a page of this book"; a hint from the UI wins when given,
        // because it can know what the screen will actually decode.
        let measured = {
            let sizes: Vec<i64> = manifest
                .pages
                .iter()
                .map(|page| page.size_bytes)
                .filter(|size| *size > 0)
                .collect();
            if sizes.is_empty() {
                0
            } else {
                sizes.iter().sum::<i64>() / sizes.len() as i64
            }
        };
        let avg_page_bytes = if device.avg_page_bytes_hint > 0 {
            device.avg_page_bytes_hint
        } else {
            measured
        };
        let pool_budget_bytes = if device.cache_budget_bytes > 0 {
            device.cache_budget_bytes
        } else {
            reader::cache::DEFAULT_BUDGET_BYTES
        };
        let profile = reader::window::Profile {
            device_memory_bytes: device.device_memory_bytes,
            cache_budget_bytes: pool_budget_bytes,
            avg_page_bytes,
            pages_per_spread,
            mode,
            direction,
            network: parse_network(&device.network),
            stable: device.stable,
        };
        let plan = reader::window::plan(&profile);
        {
            let mut guard = readers();
            if let Some(live) = guard.get_mut(&key) {
                live.window = Some(plan);
                live.pool_budget_bytes = pool_budget_bytes;
            }
        }

        let cache = self.open_reader_cache_with(pool_budget_bytes)?;
        cache
            .set_memory_budget(plan.memory_budget_bytes)
            .map_err(storage_err)?;
        // A sweep belongs here and not on the hot path: this is the one moment
        // per open where walking every cached file is affordable, and it is what
        // turns a permanently-broken cache into a page that simply reloads.
        let sweep = cache
            .reconcile(&conn, &thumbnails_now())
            .map_err(storage_err)?;
        if sweep.ghost_rows + sweep.orphan_files + sweep.stale_parts + sweep.corrupt > 0 {
            log::info!(
                "cache sweep: {} ghost rows, {} orphan files, {} stale parts, {} corrupt, {} evicted, {} bytes freed",
                sweep.ghost_rows,
                sweep.orphan_files,
                sweep.stale_parts,
                sweep.corrupt,
                sweep.evicted,
                sweep.freed_bytes
            );
        }
        Ok(ReaderWindowDto {
            forward: plan.forward as i64,
            back: plan.back as i64,
            cap: plan.cap as i64,
            memory_budget_bytes: plan.memory_budget_bytes,
            in_flight: plan.in_flight as i64,
            decode_slots: reader::window::decode_slots(
                plan.memory_budget_bytes,
                device.decoded_page_bytes,
            ) as i64,
            avg_page_bytes,
            pages_per_spread: pages_per_spread as i64,
            pool_budget_bytes,
            swept_freed_bytes: sweep.freed_bytes,
            swept_corrupt: sweep.corrupt as i64,
        })
    }

    /// What the cache tiers and the memory tier hold right now. The acceptance
    /// harness reads this to prove memory does not grow over a long session.
    pub fn reader_cache_stats(&self) -> Result<CacheStatsDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let cache = self.open_reader_cache()?;
        let memory = cache.memory_stats().map_err(storage_err)?;
        let on_disk = cache.disk().bytes_used().map_err(storage_err)? as i64;
        Ok(CacheStatsDto {
            page_bytes: cache
                .bytes_of_tier(&conn, reader::cache::Tier::Page)
                .map_err(storage_err)?,
            prefetch_bytes: cache
                .bytes_of_tier(&conn, reader::cache::Tier::Prefetch)
                .map_err(storage_err)?,
            download_bytes: store::cache::bytes_of_kind(&conn, store::cache::KIND_DOWNLOAD)
                .map_err(db_err)?,
            pool_budget_bytes: cache.budget(),
            memory_bytes: memory.bytes,
            memory_peak_bytes: memory.peak_bytes,
            memory_entries: memory.entries as i64,
            memory_hits: memory.hits as i64,
            memory_misses: memory.misses as i64,
            memory_evictions: memory.evictions as i64,
            memory_refused: memory.refused_oversized as i64,
            disk_bytes: on_disk,
            ledger_bytes: cache.bytes_used(&conn).map_err(storage_err)?,
            open_readers: readers().len() as i64,
        })
    }

    /// Run the cleanup sweep on demand (the UI can offer it as an action) and
    /// report exactly what it removed.
    pub fn reader_reconcile_cache(&self) -> Result<CacheCleanupDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let cache = self.open_reader_cache()?;
        let report = cache
            .reconcile(&conn, &thumbnails_now())
            .map_err(storage_err)?;
        Ok(CacheCleanupDto {
            ghost_rows: report.ghost_rows as i64,
            orphan_files: report.orphan_files as i64,
            stale_parts: report.stale_parts as i64,
            corrupt: report.corrupt as i64,
            kind_repaired: report.kind_repaired as i64,
            evicted: report.evicted as i64,
            freed_bytes: report.freed_bytes,
            bytes_after: cache.bytes_used(&conn).map_err(storage_err)?,
        })
    }

    /// Drop the guessed-at bytes and nothing else. Displayed pages and offline
    /// downloads both survive, which is the point of a separate tier.
    pub fn reader_clear_prefetch(&self) -> Result<i64, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let cache = self.open_reader_cache()?;
        let dropped = cache
            .clear_tier(&conn, reader::cache::Tier::Prefetch)
            .map_err(storage_err)?;
        Ok(dropped as i64)
    }

    /// The memory-pressure response: hand back the RAM the prefetch tier mirrors
    /// and keep the tier on disk, so coming back to the app does not cost a window
    /// of downloads. `reader_clear_prefetch` is the user-facing cleanup; this is the
    /// one the UI calls when the OS squeezes memory.
    pub fn reader_release_prefetch(&self) -> Result<i64, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let cache = self.open_reader_cache()?;
        cache.release_prefetch_memory(&conn).map_err(storage_err)
    }

    /// The spread table for the layout the reader is currently using.
    fn reader_spreads(
        &self,
        server_id: &str,
        book_id: &str,
    ) -> Result<Option<Vec<Vec<u32>>>, ApiError> {
        let guard = readers();
        Ok(guard
            .get(&reader_key(server_id, book_id))
            .map(|live| live.session.layout().spreads.clone()))
    }
}

// --------------------------------------------------------------------------
// Stage 7 reader plumbing: the in-process session registry and the flat DTOs
// that cross the FFI.
// --------------------------------------------------------------------------

/// One open reader. `Send` because a Flutter platform thread may service the
/// next call on a different worker than the one that opened it.
struct LiveReader {
    session: reader::session::ReaderSession,
    settings: reader::settings::ReaderSettings,
    /// Computed from the device profile the UI reported; `None` until the UI has
    /// said anything, in which case the user's stored window is used unchanged.
    window: Option<reader::window::WindowPlan>,
    /// Pool ceiling in force for this reader, from the same profile.
    pool_budget_bytes: i64,
}

fn reader_key(server_id: &str, book_id: &str) -> String {
    format!("{server_id}|{book_id}")
}

fn readers() -> std::sync::MutexGuard<'static, std::collections::HashMap<String, LiveReader>> {
    static REGISTRY: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<String, LiveReader>>,
    > = std::sync::OnceLock::new();
    REGISTRY
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn thumbnails_now() -> String {
    store::thumbnails::now_rfc3339()
}

/// The UI's own words for the link. Anything unrecognised becomes `Unknown`,
/// which the planner treats as constrained rather than free — a reader that
/// cannot describe its network should not assume it is on Wi-Fi.
fn parse_network(value: &str) -> reader::window::Network {
    match value {
        "wifi" => reader::window::Network::Wifi,
        "cellular" => reader::window::Network::Cellular,
        "weak" => reader::window::Network::Weak,
        "offline" => reader::window::Network::Offline,
        _ => reader::window::Network::Unknown,
    }
}

/// What the device is, as far as the UI can tell the core.
#[derive(Debug, Clone, Default)]
pub struct DeviceProfileDto {
    /// Physical RAM in bytes; 0 when the platform will not say.
    pub device_memory_bytes: i64,
    /// Ceiling for the whole disk cache pool; 0 for the built-in default.
    pub cache_budget_bytes: i64,
    /// Override for the average page size; 0 to let the manifest answer.
    pub avg_page_bytes_hint: i64,
    /// What one decoded page costs on this screen, which only the UI knows.
    pub decoded_page_bytes: i64,
    /// wifi | cellular | weak | offline | anything else for unknown.
    pub network: String,
    /// False while a flip is in progress: the planner then shrinks the window to
    /// the visible spread instead of queueing a burst per frame.
    pub stable: bool,
}

/// The numbers the core derived from a profile, all of which the UI must apply.
#[derive(Debug, Clone)]
pub struct ReaderWindowDto {
    pub forward: i64,
    pub back: i64,
    pub cap: i64,
    pub memory_budget_bytes: i64,
    pub in_flight: i64,
    pub decode_slots: i64,
    pub avg_page_bytes: i64,
    pub pages_per_spread: i64,
    pub pool_budget_bytes: i64,
    pub swept_freed_bytes: i64,
    pub swept_corrupt: i64,
}

/// Live cache occupancy, tier by tier.
#[derive(Debug, Clone)]
pub struct CacheStatsDto {
    pub page_bytes: i64,
    pub prefetch_bytes: i64,
    pub download_bytes: i64,
    pub pool_budget_bytes: i64,
    pub memory_bytes: i64,
    pub memory_peak_bytes: i64,
    pub memory_entries: i64,
    pub memory_hits: i64,
    pub memory_misses: i64,
    pub memory_evictions: i64,
    pub memory_refused: i64,
    pub disk_bytes: i64,
    pub ledger_bytes: i64,
    /// How many reading sessions the process is holding right now. The registry
    /// is keyed `server|book` and lives for the process's lifetime, so an open
    /// that is not paired with a close would accumulate one session per book
    /// browsed in a sitting — unbounded growth in the exact sense Stage 8 exists
    /// to rule out.
    pub open_readers: i64,
}

/// What one cleanup sweep removed.
#[derive(Debug, Clone)]
pub struct CacheCleanupDto {
    pub ghost_rows: i64,
    pub orphan_files: i64,
    pub stale_parts: i64,
    pub corrupt: i64,
    pub kind_repaired: i64,
    pub evicted: i64,
    pub freed_bytes: i64,
    pub bytes_after: i64,
}

fn layout_dto(
    session: &reader::session::ReaderSession,
    settings: &reader::settings::ReaderSettings,
) -> ReaderLayoutDto {
    let layout = session.layout();
    let nav = layout.nav();
    ReaderLayoutDto {
        spreads: layout.spreads.clone(),
        spread: session.spread() as i64,
        page: session.page() as i64,
        axis: layout.axis.as_str().to_string(),
        reversed: layout.reversed,
        advance_swipe: nav.advance.as_str().to_string(),
        retreat_swipe: nav.retreat.as_str().to_string(),
        tap_next: nav.tap_next.as_str().to_string(),
        tap_prev: nav.tap_prev.as_str().to_string(),
        mode: settings.mode.as_str().to_string(),
        direction: settings.direction.as_str().to_string(),
        page_gap: settings.page_gap as i64,
        background: settings.background.as_str().to_string(),
    }
}

fn settings_of(value: ReaderSettingsDto) -> reader::settings::ReaderSettings {
    reader::settings::ReaderSettings {
        mode: reader::paging::ReadMode::parse(&value.mode),
        direction: reader::paging::Direction::parse(&value.direction),
        first_page_single: value.first_page_single,
        page_gap: value.page_gap.max(0) as u32,
        background: reader::settings::Background::parse(&value.background).unwrap_or_default(),
        keep_screen_awake: value.keep_screen_awake,
        brightness: value.brightness.map(|value| value as f32),
        restore_position: value.restore_position,
        prefetch: reader::prefetch::Window {
            forward: value.prefetch_forward.max(0) as usize,
            back: value.prefetch_back.max(0) as usize,
            cap: value.prefetch_cap.max(1) as usize,
        },
    }
}

fn settings_dto(value: reader::settings::ReaderSettings) -> ReaderSettingsDto {
    ReaderSettingsDto {
        mode: value.mode.as_str().to_string(),
        direction: value.direction.as_str().to_string(),
        first_page_single: value.first_page_single,
        page_gap: value.page_gap as i64,
        background: value.background.as_str().to_string(),
        keep_screen_awake: value.keep_screen_awake,
        brightness: value.brightness.map(|value| value as f64),
        restore_position: value.restore_position,
        prefetch_forward: value.prefetch.forward as i64,
        prefetch_back: value.prefetch.back as i64,
        prefetch_cap: value.prefetch.cap as i64,
    }
}

#[derive(Debug, Clone)]
pub struct ReaderBookDto {
    pub server_id: String,
    pub book_id: String,
    pub page_count: i64,
    pub paged: bool,
    pub reflowable: bool,
    pub fallback: Option<String>,
    pub from_mirror: bool,
    pub start_page: i64,
    pub layout: ReaderLayoutDto,
}

#[derive(Debug, Clone)]
pub struct ReaderLayoutDto {
    pub spreads: Vec<Vec<u32>>,
    pub spread: i64,
    pub page: i64,
    pub axis: String,
    pub reversed: bool,
    pub advance_swipe: String,
    pub retreat_swipe: String,
    pub tap_next: String,
    pub tap_prev: String,
    pub mode: String,
    pub direction: String,
    pub page_gap: i64,
    pub background: String,
}

#[derive(Debug, Clone)]
pub struct ReaderTurnDto {
    pub page: i64,
    pub spread: i64,
    pub upload_now: bool,
}

#[derive(Debug, Clone, Default)]
pub struct ReaderSettingsDto {
    pub mode: String,
    pub direction: String,
    pub first_page_single: bool,
    pub page_gap: i64,
    pub background: String,
    pub keep_screen_awake: bool,
    pub brightness: Option<f64>,
    pub restore_position: bool,
    pub prefetch_forward: i64,
    pub prefetch_back: i64,
    pub prefetch_cap: i64,
}

impl reader::manifest::Fallback {
    fn as_str(self) -> &'static str {
        match self {
            reader::manifest::Fallback::Epub => "epub",
            reader::manifest::Fallback::Pdf => "pdf",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::series::{Series, SeriesMetadata};
    use crate::model::server_profile::AuthType;
    use uuid::Uuid;

    fn temp_db() -> String {
        let dir = std::env::temp_dir().join(format!("komga_app_test_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("comic.sqlite").to_string_lossy().into_owned()
    }

    /// Remove the temp working dir (db file + its cache sibling).
    fn cleanup_temp(db: &str) {
        std::fs::remove_dir_all(Path::new(db).parent().unwrap()).unwrap();
    }

    #[test]
    fn facade_server_and_series_roundtrip() {
        let db = temp_db();
        let app = App::new(&db);

        let mut profile = ServerProfile::new("Home", "https://komga.example.com", AuthType::ApiKey);
        profile.id = "server-1".into();
        app.save_server(&profile).unwrap();
        assert_eq!(app.list_servers().unwrap().len(), 1);

        // Seed series the way BootstrapSync would (store layer is the authority).
        let conn = store::open(&db).unwrap();
        let s = Series {
            id: "s1".into(),
            library_id: "lib-1".into(),
            name: "One Piece".into(),
            created: None,
            last_modified: None,
            books_count: None,
            books_read_count: None,
            books_unread_count: None,
            books_in_progress_count: None,
            books_metadata: None,
            metadata: Some(SeriesMetadata {
                title: "One Piece".into(),
                status: None,
                summary: None,
                publisher: None,
                genres: vec![],
                tags: vec![],
                authors: vec![],
                reading_direction: None,
                language: None,
                age_rating: None,
                title_sort: None,
                total_book_count: None,
            }),
        };
        store::series::save_series_batch(&conn, "server-1", &[s]).unwrap();
        drop(conn);

        assert_eq!(app.count_series("server-1").unwrap(), 1);
        let rows = app.fetch_series("server-1", 10, 0).unwrap();
        assert_eq!(rows[0].name, "One Piece");
        assert_eq!(app.fetch_series("server-2", 10, 0).unwrap().len(), 0);

        cleanup_temp(&db);
    }

    struct FakeSeriesFetcher(crate::model::series::SeriesPage);

    impl crate::sync::SeriesFetcher for FakeSeriesFetcher {
        async fn series_page(
            &self,
            _request: &crate::api::series::PageRequest,
        ) -> Result<crate::model::series::SeriesPage, ApiError> {
            Ok(self.0.clone())
        }
    }

    #[tokio::test]
    async fn facade_bootstrap_with_fake_fetcher_writes_store() {
        let db = temp_db();
        let app = App::new(&db);

        let json =
            include_str!("../../../../specs/contracts/fixtures/initial-sync/series-page.json");
        let page: crate::model::series::SeriesPage =
            serde_json::from_str(json).expect("shared fixture must decode");
        let fetcher = FakeSeriesFetcher(page);

        let summary = app.bootstrap_with(&fetcher, "server-1").await.unwrap();
        assert_eq!(summary.synced_series, 3);
        assert_eq!(summary.total_elements, 3);
        assert_eq!(app.count_series("server-1").unwrap(), 3);

        let rows = app.fetch_series("server-1", 10, 0).unwrap();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].name, "Berserk"); // COLLATE NOCASE ordering

        cleanup_temp(&db);
    }

    /// Fake connection probe backed by the shared connection fixtures.
    struct FakeConnectionFetcher {
        info: crate::model::server::ServerInfo,
        libraries: Vec<crate::model::server::Library>,
        fail_info: bool,
        fail_libraries: bool,
    }

    impl FakeConnectionFetcher {
        fn from_fixtures() -> Self {
            let info = serde_json::from_str(include_str!(
                "../../../../specs/contracts/fixtures/connection/actuator-info.json"
            ))
            .expect("shared fixture must decode");
            let libraries = serde_json::from_str(include_str!(
                "../../../../specs/contracts/fixtures/connection/libraries.json"
            ))
            .expect("shared fixture must decode");
            Self {
                info,
                libraries,
                fail_info: false,
                fail_libraries: false,
            }
        }
    }

    impl crate::api::server::ServerInfoFetcher for FakeConnectionFetcher {
        async fn server_info(
            &self,
        ) -> std::result::Result<crate::model::server::ServerInfo, ApiError> {
            if self.fail_info {
                Err(ApiError::Authentication)
            } else {
                Ok(self.info.clone())
            }
        }
    }

    impl crate::api::server::LibrariesFetcher for FakeConnectionFetcher {
        async fn libraries(
            &self,
        ) -> std::result::Result<Vec<crate::model::server::Library>, ApiError> {
            if self.fail_libraries {
                Err(ApiError::Server { status_code: 500 })
            } else {
                Ok(self.libraries.clone())
            }
        }
    }

    #[tokio::test]
    async fn connection_probe_collects_info_libraries_and_capabilities() {
        let db = temp_db();
        let app = App::new(&db);
        let fetcher = FakeConnectionFetcher::from_fixtures();

        let result = app.test_connection_with(&fetcher).await.unwrap();
        assert_eq!(result.server_version.as_deref(), Some("1.26.3"));
        assert_eq!(result.libraries.len(), 2);
        assert!(result.capabilities.iter().any(|c| c == "libraries:2"));

        // Acceptance chain: save profile + libraries + activate.
        let mut profile = ServerProfile::new("Home", "http://192.168.0.69:25600", AuthType::ApiKey);
        profile.id = "server-1".into();
        profile.capabilities = result.capabilities.clone();
        profile.last_successful_connection = Some("2026-08-26T00:00:00Z".into());
        app.save_server(&profile).unwrap();
        app.save_libraries("server-1", &result.libraries).unwrap();
        app.set_active_server("server-1").unwrap();

        assert_eq!(
            app.get_active_server().unwrap().as_deref(),
            Some("server-1")
        );
        assert_eq!(app.list_servers().unwrap().len(), 1);
        let saved = app.get_server("server-1").unwrap().unwrap();
        assert_eq!(saved.capabilities, result.capabilities);
        assert!(saved.last_successful_connection.is_some());

        // Deleting the active server clears the active state.
        assert!(app.delete_server("server-1").unwrap());
        assert_eq!(app.get_active_server().unwrap(), None);
        assert!(app.list_servers().unwrap().is_empty());

        cleanup_temp(&db);
    }

    #[tokio::test]
    async fn connection_probe_maps_auth_failure() {
        let db = temp_db();
        let app = App::new(&db);
        let mut fetcher = FakeConnectionFetcher::from_fixtures();
        fetcher.fail_info = true;
        let err = app.test_connection_with(&fetcher).await.unwrap_err();
        assert!(matches!(err, ApiError::Authentication));
        cleanup_temp(&db);
    }

    #[tokio::test]
    async fn connection_probe_rejects_unsupported_server_version() {
        let db = temp_db();
        let app = App::new(&db);
        let mut fetcher = FakeConnectionFetcher::from_fixtures();
        fetcher.info = serde_json::from_str(r#"{"build":{"version":"2.0.0"}}"#).unwrap();
        let err = app.test_connection_with(&fetcher).await.unwrap_err();
        assert!(matches!(err, ApiError::ApiCompatibility { .. }));
        cleanup_temp(&db);
    }

    #[tokio::test]
    async fn demo_bootstrap_writes_series_covers_and_sync_state() {
        let db = temp_db();
        let app = App::new(&db);

        let summary = app.bootstrap_demo("demo".into()).await.unwrap();
        assert_eq!(summary.synced_series, 3);
        assert_eq!(app.count_series("demo").unwrap(), 3);

        // Covers: every series resolves its cover path from SQLite and the
        // file actually exists on disk (本地封面墙 data plane).
        let rows = app.fetch_series("demo", 10, 0).unwrap();
        assert_eq!(rows.len(), 3);
        for row in &rows {
            let path = app
                .cover_path("demo", &row.remote_id)
                .unwrap()
                .unwrap_or_else(|| panic!("cover path for {}", row.name));
            assert!(Path::new(&path).exists(), "cover file must exist");
            assert!(std::fs::metadata(&path).unwrap().len() > 0);
        }
        assert_eq!(app.list_thumbnails("demo").unwrap().len(), 10); // 3 series + 7 books
        assert_eq!(
            app.list_thumbnails("demo")
                .unwrap()
                .iter()
                .filter(|t| t.variant == VARIANT_BOOK)
                .count(),
            7
        );

        // Bootstrap recorded the successful sync in sync_state.
        let conn = store::open(&db).unwrap();
        let state = store::sync_state::get_sync_state(&conn, "demo")
            .unwrap()
            .expect("sync_state row must exist");
        assert!(state.last_successful_sync.is_some());

        cleanup_temp(&db);
    }

    #[tokio::test]
    async fn cover_miss_backfills_and_restores_row() {
        let db = temp_db();
        let app = App::new(&db);
        app.bootstrap_demo("demo".into()).await.unwrap();
        let rows = app.fetch_series("demo", 10, 0).unwrap();
        let target = &rows[0];

        // Simulate a cache wipe: the record stays but the file vanishes.
        let path = app.cover_path("demo", &target.remote_id).unwrap().unwrap();
        std::fs::remove_file(&path).unwrap();
        assert_eq!(app.cover_path("demo", &target.remote_id).unwrap(), None);

        // 缓存缺失自动补齐: ensure_cover re-downloads and refreshes the row.
        let restored = app
            .ensure_cover_with(
                &DemoCoverFetcher {},
                "https://demo.local",
                "demo",
                &target.remote_id,
            )
            .await
            .unwrap();
        assert!(Path::new(&restored).exists());
        assert_eq!(
            app.cover_path("demo", &target.remote_id)
                .unwrap()
                .as_deref(),
            Some(restored.as_str())
        );

        // A second call is a pure cache hit (no network, same path).
        let again = app
            .ensure_cover_with(
                &DemoCoverFetcher {},
                "https://demo.local",
                "demo",
                &target.remote_id,
            )
            .await
            .unwrap();
        assert_eq!(again, restored);

        cleanup_temp(&db);
    }

    #[tokio::test]
    async fn backfill_covers_all_missing_series() {
        let db = temp_db();
        let app = App::new(&db);
        app.bootstrap_demo("demo".into()).await.unwrap();
        assert_eq!(app.list_thumbnails("demo").unwrap().len(), 10); // 3 series + 7 books

        // Drop all cover records → the next backfill restores the series
        // covers (book covers run per series via ensure_book_covers).
        let conn = store::open(&db).unwrap();
        store::thumbnails::delete_for_server(&conn, "demo").unwrap();
        drop(conn);
        assert_eq!(app.list_thumbnails("demo").unwrap().len(), 0);

        let n = app
            .ensure_covers_with(&DemoCoverFetcher {}, "https://demo.local", "demo")
            .await
            .unwrap();
        assert_eq!(n, 3);
        assert_eq!(app.list_thumbnails("demo").unwrap().len(), 3);

        // Nothing missing → idempotent no-op.
        let n = app
            .ensure_covers_with(&DemoCoverFetcher {}, "https://demo.local", "demo")
            .await
            .unwrap();
        assert_eq!(n, 0);

        // Book covers backfill per series afterwards.
        let n = app
            .ensure_book_covers_with(
                &DemoCoverFetcher {},
                "https://demo.local",
                "demo",
                "series-1",
            )
            .await
            .unwrap();
        assert_eq!(n, 3);
        assert_eq!(app.list_thumbnails("demo").unwrap().len(), 6);

        cleanup_temp(&db);
    }

    /// Stage 5 contract: a remote series deletion cascades locally, leaves a
    /// tombstone, and takes its cached cover file off the disk with it.
    #[tokio::test]
    async fn reconcile_propagates_remote_delete_and_orphan_covers() {
        let dir = std::env::temp_dir().join(format!("komga_reconcile_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("comic.sqlite").to_string_lossy().into_owned();
        let app = App::new(&db);

        // Mirror the shared fixtures, then pretend a cover is cached for
        // series-3 (a real file under the cache root).
        app.full_sync_with(&FixtureLibraryFetcher {}, "rec")
            .await
            .unwrap();
        let cover = dir.join("cache").join("thumbnails").join("series-3.png");
        std::fs::create_dir_all(cover.parent().unwrap()).unwrap();
        std::fs::write(&cover, b"png").unwrap();
        {
            let conn = store::open(&db).unwrap();
            store::thumbnails::record_thumbnail(
                &conn,
                "rec",
                "series-3",
                crate::store::thumbnails::VARIANT_SERIES,
                &cover.to_string_lossy(),
                3,
            )
            .unwrap();
        }

        // The server now serves the same library minus series-3 (and books).
        let scenario: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../specs/contracts/fixtures/sync/scenario-reconcile.json"
        ))
        .unwrap();
        let mut snapshot = scenario["snapshots"][0].clone();
        snapshot["series"][0]
            .as_array_mut()
            .unwrap()
            .retain(|item| item["id"] != "series-3");
        let books = snapshot["books"].as_object_mut().unwrap();
        books.remove("series-3");
        for page in books.values_mut() {
            page[0]
                .as_array_mut()
                .unwrap()
                .retain(|item| item["seriesId"] != "series-3");
        }
        for collection in snapshot["collections"][0].as_array_mut().unwrap() {
            collection["seriesIds"]
                .as_array_mut()
                .unwrap()
                .retain(|id| id != "series-3");
        }
        let server = crate::sync::scenario::server_from_snapshot(&snapshot.to_string()).unwrap();

        let summary = app
            .reconcile_with(&server, "rec", "manual_refresh")
            .await
            .unwrap();
        assert_eq!(summary.series_removed, 1);
        // series-3's books go through the series cascade, so the scoped book
        // sweep finds nothing extra to remove.
        assert_eq!(summary.books_removed, 0);

        let conn = store::open(&db).unwrap();
        assert_eq!(store::series::count_series(&conn, "rec").unwrap(), 2);
        assert_eq!(
            conn.query_row::<i64, _, _>(
                "SELECT COUNT(*) FROM books WHERE server_id = ?1",
                rusqlite::params!["rec"],
                |row| row.get(0)
            )
            .unwrap(),
            5
        );
        let tombstones = store::prune::list_tombstones(&conn, "rec", "series").unwrap();
        assert_eq!(tombstones.len(), 1);
        assert_eq!(tombstones[0].remote_id, "series-3");
        assert_eq!(tombstones[0].cause, store::prune::CAUSE_RECONCILE);
        // The cover row is gone (its path surfaced on the summary).
        assert_eq!(summary.orphaned_covers, vec![cover.to_string_lossy()]);
        assert!(app.tombstones("rec", "series").unwrap().len() == 1);
        drop(conn);
        // ...and so is the file.
        assert!(!cover.exists(), "the orphaned cover file must be deleted");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn delete_server_cleans_cover_records_and_files() {
        let db = temp_db();
        let app = App::new(&db);
        app.bootstrap_demo("demo".into()).await.unwrap();

        // A server profile is required for delete_server to remove anything.
        let mut profile = ServerProfile::new(
            "Demo",
            "https://demo.local",
            crate::model::server_profile::AuthType::ApiKey,
        );
        profile.id = "demo".into();
        app.save_server(&profile).unwrap();

        let files: Vec<PathBuf> = app
            .list_thumbnails("demo")
            .unwrap()
            .into_iter()
            .map(|row| PathBuf::from(row.local_path))
            .collect();
        assert_eq!(files.len(), 10); // 3 series + 7 book covers
        assert!(files.iter().all(|f| f.exists()));

        assert!(app.delete_server("demo").unwrap());
        assert!(app.list_thumbnails("demo").unwrap().is_empty());
        assert!(
            files.iter().all(|f| !f.exists()),
            "cover files must be removed"
        );

        cleanup_temp(&db);
    }

    // MARK: Stage 6 — Outbox + pollable SSE

    use crate::model::book::{Book, BookMetadata, ReadProgress};
    use crate::store::outbox::{Attempt as UploadAttempt, Refetch, RemoteProgress, WireRequest};
    use std::collections::VecDeque;

    /// A server that always has the same answer for every book.
    struct FakeServer {
        remote: Refetch,
        outcome: UploadAttempt,
    }

    impl ProgressWriter for FakeServer {
        async fn refetch(&self, _book_id: &str) -> Refetch {
            self.remote.clone()
        }

        async fn apply(&self, _request: &WireRequest) -> UploadAttempt {
            self.outcome.clone()
        }

        async fn book(&self, book_id: &str) -> std::result::Result<Option<Book>, ApiError> {
            Ok(Some(mirrored_book(book_id, "Fetched Title", 42, false)))
        }
    }

    fn mirrored_book(book_id: &str, title: &str, page: i64, completed: bool) -> Book {
        Book {
            id: book_id.to_string(),
            series_id: "s1".to_string(),
            series_title: None,
            name: title.to_string(),
            number: None,
            oneshot: false,
            media: None,
            metadata: Some(BookMetadata {
                title: title.to_string(),
                number: None,
                number_sort: None,
                summary: None,
                isbn: None,
                release_date: None,
                authors: Vec::new(),
                tags: Vec::new(),
            }),
            read_progress: Some(ReadProgress {
                page: Some(page),
                completed,
                last_modified: None,
            }),
            created: None,
            last_modified: None,
            size_bytes: None,
        }
    }

    fn remote_found(page: i64, stamp: &str) -> Refetch {
        Refetch::Found(RemoteProgress {
            page: Some(page),
            completed: false,
            last_modified: Some(stamp.to_string()),
            media_type: Some("application/zip".to_string()),
        })
    }

    #[tokio::test]
    async fn an_upload_pass_reports_the_queue_it_left_behind() {
        let db = temp_db();
        let app = App::new(&db);
        {
            let conn = store::open(&db).unwrap();
            store::read_progress::upsert_local_read_progress(&conn, "A", "b1", 30, false).unwrap();
        }
        // The server has something older: rule R5 says our page goes up.
        let online = FakeServer {
            remote: remote_found(3, "2026-08-28T09:00:00Z"),
            outcome: UploadAttempt::Succeeded,
        };
        let outcome = app
            .upload_outbox_with(&online, "A", "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(outcome.uploaded, 1);
        assert_eq!(outcome.status, "complete");
        assert_eq!(
            outcome.outbox.total, 0,
            "the badge must clear with the queue"
        );

        // Offline: the same pass defers everything and loses nothing.
        {
            let conn = store::open(&db).unwrap();
            store::read_progress::mark_read(&conn, "A", "b2").unwrap();
        }
        let offline = FakeServer {
            remote: Refetch::Unreachable,
            outcome: UploadAttempt::Retryable,
        };
        let outcome = app
            .upload_outbox_with(&offline, "A", "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(outcome.uploaded, 0);
        assert_eq!(outcome.retried, 1);
        assert_eq!(outcome.outbox.total, 1);
        assert_eq!(outcome.outbox.waiting, 1, "its deadline is on disk");
        assert_eq!(outcome.outbox.pending, 0, "so it is not due yet");
        cleanup_temp(&db);
    }

    #[tokio::test]
    async fn a_failed_row_is_listed_until_the_ui_retries_it() {
        let db = temp_db();
        let app = App::new(&db);
        let conn = store::open(&db).unwrap();
        store::read_progress::upsert_local_read_progress(&conn, "A", "b1", 12, false).unwrap();
        conn.execute(
            "UPDATE pending_mutations SET state = 'failed', last_error = '400', retry_count = 0",
            [],
        )
        .unwrap();
        drop(conn);

        let status = app.outbox_status("A").unwrap();
        assert_eq!(status.failed, 1);
        assert_eq!(status.total, 1);
        assert_eq!(status.failed_entries.len(), 1);
        assert_eq!(status.failed_entries[0].entity_id, "b1");
        assert_eq!(status.failed_entries[0].mutation_type, "READ_PROGRESS");
        assert_eq!(status.failed_entries[0].last_error.as_deref(), Some("400"));
        assert_eq!(status.failed_entries[0].state, "failed");

        assert_eq!(app.retry_failed_mutations("A").unwrap(), 1);
        let after = app.outbox_status("A").unwrap();
        assert_eq!(after.failed, 0);
        assert!(after.failed_entries.is_empty());
        assert_eq!(after.pending, 1);
        // Idempotent: nothing is left to hand back.
        assert_eq!(app.retry_failed_mutations("A").unwrap(), 0);
        cleanup_temp(&db);
    }

    /// What the scripted stream does once its frames have been dispatched.
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Tail {
        /// Up and quiet — what every idle tick looks like.
        Idle,
        /// The server closed it: the reconnect path owes a sweep.
        Ends,
    }

    /// A scripted stream: handshakes on demand, then dispatches its frames.
    struct FakeSource {
        frames: VecDeque<SseEvent>,
        tail: Tail,
        refuse_handshake: bool,
        closed: bool,
    }

    fn frame(kind: &str, book_id: &str) -> SseEvent {
        SseEvent {
            kind: kind.to_string(),
            data: format!(r#"{{"bookId":"{book_id}"}}"#),
            id: Some(format!("{kind}-1")),
            retry_ms: None,
        }
    }

    impl EventSource for FakeSource {
        async fn open(&mut self, _last_event_id: Option<&str>) -> ApiResult<()> {
            if self.refuse_handshake {
                return Err(ApiError::ApiCompatibility {
                    message: "/sse/v1/events is not an event stream".into(),
                });
            }
            Ok(())
        }

        async fn next(&mut self) -> ApiResult<Option<SseEvent>> {
            match self.frames.pop_front() {
                Some(event) => Ok(Some(event)),
                None => match self.tail {
                    Tail::Idle => Err(ApiError::Idle),
                    Tail::Ends => Ok(None),
                },
            }
        }

        fn close(&mut self) {
            self.closed = true;
        }
    }

    #[tokio::test]
    async fn an_event_refreshes_the_local_row_and_a_reconnect_sweeps_first() {
        let db = temp_db();
        let app = App::new(&db);
        {
            let conn = store::open(&db).unwrap();
            store::books::save_books_batch(
                &conn,
                "A",
                &[mirrored_book("b1", "Stale Title", 1, false)],
            )
            .unwrap();
        }
        let server = FakeServer {
            remote: remote_found(1, "2026-08-28T09:00:00Z"),
            outcome: UploadAttempt::Succeeded,
        };
        let mut source = FakeSource {
            frames: VecDeque::new(),
            tail: Tail::Idle,
            refuse_handshake: false,
            closed: false,
        };
        let mut conn = store::open(&db).unwrap();
        // The caller's half of the round trip: every tick hands back what the
        // last one returned.
        let mut state = String::new();

        // 1. First handshake: the stream is up and nothing has been missed.
        let first = app
            .sse_poll_with(
                &mut source,
                &server,
                &conn,
                "A",
                &state,
                "2026-08-28T12:00:00Z",
            )
            .await
            .unwrap();
        assert_eq!(first.phase, "connected");
        assert_eq!(first.action, "idle", "a bare connect applies nothing");
        assert!(!first.reconcile, "a cold start owes no sweep");
        assert!(first.keep_socket, "the stream stays parked");
        state = first.state_json.clone();

        // 2. A hint re-reads the entity: the local row changes, and the event
        //    payload never becomes the UI's data.
        source.frames.push_back(frame("BookChanged", "b1"));
        let second = app
            .sse_poll_with(
                &mut source,
                &server,
                &conn,
                "A",
                &state,
                "2026-08-28T12:00:02Z",
            )
            .await
            .unwrap();
        assert_eq!(second.action, "applied");
        assert_eq!(second.dirty_books, vec!["b1".to_string()]);
        assert_eq!(second.books_written, 1);
        drop(conn);
        let detail = app.book_detail("A", "b1").unwrap().unwrap();
        assert_eq!(
            detail.title, "Fetched Title",
            "the hint must be re-fetched through the API"
        );
        conn = store::open(&db).unwrap();
        state = second.state_json.clone();

        // 3. A quiet tick leaves the session exactly where it was.
        let third = app
            .sse_poll_with(
                &mut source,
                &server,
                &conn,
                "A",
                &state,
                "2026-08-28T12:00:04Z",
            )
            .await
            .unwrap();
        assert_eq!(third.action, "idle");
        assert_eq!(third.phase, "connected");
        assert!(third.keep_socket);
        state = third.state_json.clone();

        // 4. The stream ended: freshness loss, and a dead socket is not parked.
        source.tail = Tail::Ends;
        let fourth = app
            .sse_poll_with(
                &mut source,
                &server,
                &conn,
                "A",
                &state,
                "2026-08-28T12:00:06Z",
            )
            .await
            .unwrap();
        assert_eq!(fourth.action, "backing-off");
        assert_eq!(fourth.phase, "disconnected");
        assert!(!fourth.keep_socket);
        assert!(source.closed);
        source.tail = Tail::Idle;
        state = fourth.state_json.clone();

        // 5. Reconnecting demands the sweep before a single hint is trusted.
        let fifth = app
            .sse_poll_with(
                &mut source,
                &server,
                &conn,
                "A",
                &state,
                "2026-08-28T12:00:10Z",
            )
            .await
            .unwrap();
        assert_eq!(fifth.action, "reconcile");
        assert!(fifth.reconcile);
        assert_eq!(fifth.phase, "reconciling");
        assert!(fifth.keep_socket, "the gap is not the socket's fault");
        // Asking twice is harmless while the caller still owes the sweep.
        let sixth = app
            .sse_poll_with(
                &mut source,
                &server,
                &conn,
                "A",
                &fifth.state_json,
                "2026-08-28T12:00:12Z",
            )
            .await
            .unwrap();
        assert_eq!(sixth.action, "reconcile");
        assert!(sixth.dirty_books.is_empty(), "nothing applies mid-sweep");
        state = sixth.state_json.clone();

        // 6. The sweep ran, so the stream consumes again — and an event that
        //    arrived in the meantime is not lost.
        source.frames.push_back(frame("BookChanged", "b1"));
        let seventh = app
            .sse_poll_with(
                &mut source,
                &server,
                &conn,
                "A",
                &app.sse_reconciled(state.clone()).unwrap(),
                "2026-08-28T12:00:14Z",
            )
            .await
            .unwrap();
        assert_eq!(seventh.phase, "connected");
        assert_eq!(seventh.dirty_books, vec!["b1".to_string()]);

        // 7. A server with no usable stream degrades freshness only: it asks for
        //    one sweep, then parks, and keeps saying so without demanding more.
        let mut broken = FakeSource {
            frames: VecDeque::new(),
            tail: Tail::Idle,
            refuse_handshake: true,
            closed: false,
        };
        let parked = app
            .sse_poll_with(&mut broken, &server, &conn, "A", "", "2026-08-28T12:00:16Z")
            .await
            .unwrap();
        assert_eq!(parked.action, "reconcile");
        assert_eq!(parked.phase, "reconcile_only");
        assert_eq!(
            parked.reason.as_deref(),
            Some("/sse/v1/events is not an event stream")
        );
        let settled = app
            .sse_poll_with(
                &mut broken,
                &server,
                &conn,
                "A",
                &parked.state_json,
                "2026-08-28T12:00:18Z",
            )
            .await
            .unwrap();
        assert_eq!(settled.action, "reconcile-only");
        assert!(!settled.reconcile, "one sweep is enough");
        drop(conn);
        cleanup_temp(&db);
    }
}
