//! Application Facade — coarse-grained services for Flutter.
//!
//! No flutter_rust_bridge types here. Layering:
//! Core (api/model/store/sync/cache) → Application Facade → FFI Adapter.

use crate::api::auth::AuthMethod;
use crate::api::contract::{check_server_version, version_capabilities};
use crate::api::error::ApiError;
use crate::api::series::KomgaClient;
use crate::api::server::ConnectionFetching;
use crate::cache::cover::{BytesFetcher, CoverStore};
use crate::cache::DiskCache;
use crate::model::server::{Library, ServerInfo};
use crate::model::server_profile::ServerProfile;
use crate::store;
use crate::store::collections::CollectionRow;
use crate::store::query::{BookQuery, BookSort, SeriesQuery, SeriesSort};
use crate::store::read_progress::ContinueReadingRow;
use crate::store::readlists::ReadlistRow;
use crate::store::series::SeriesRow;
use crate::store::thumbnails::{ThumbnailRow, VARIANT_BOOK, VARIANT_SERIES};
use crate::sync;
use crate::sync::full::FixtureLibraryFetcher;
use crate::sync::{BootstrapSummary, FullSyncSummary, LibraryFetcher};

use rusqlite::OptionalExtension;
use std::path::{Path, PathBuf};

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
        let deleted = store::servers::delete_server(&conn, server_id).map_err(db_err)?;
        if deleted {
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
        let client = KomgaClient::new(base_url, AuthMethod::ApiKey { key: api_key })?;
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
        let client = KomgaClient::new(base_url, AuthMethod::ApiKey { key: api_key })?;
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
        let client = KomgaClient::new(base_url.clone(), AuthMethod::ApiKey { key: api_key })?;
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
        let client = KomgaClient::new(base_url.clone(), AuthMethod::ApiKey { key: api_key })?;
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
        let client = KomgaClient::new(base_url, AuthMethod::ApiKey { key: api_key })?;
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
        let client = KomgaClient::new(base_url.clone(), AuthMethod::ApiKey { key: api_key })?;
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
        let client = KomgaClient::new(base_url.clone(), AuthMethod::ApiKey { key: api_key })?;
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
}
