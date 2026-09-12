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
use crate::downloads::{self, manifest::DownloadRoot};
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
        // Every FFI entry point and every smoke binary constructs an `App`, so
        // this is the one place the log backend can be installed and be certain
        // it happened. Losing the slot to a logger that got here first is
        // possible and is reported by `stats().installed` rather than assumed.
        crate::diagnostics::log::install();
        Self {
            db_path: db_path.into(),
        }
    }

    pub fn db_path(&self) -> &str {
        &self.db_path
    }

    /// Record what a finished round trip proved about this server's credential.
    ///
    /// `Ok` says the key works. `ApiError::Authentication` says it does not.
    /// Every other failure — no route, a 500, a page that would not decode —
    /// says nothing about the key and therefore writes nothing: a client that
    /// told the user their password had expired every time they went through a
    /// tunnel would be worse than one that never notices an expiry.
    ///
    /// The write is best-effort in both directions. A store that cannot record
    /// the note must not replace the outcome the caller is about to return, and
    /// `test_connection` runs with no database at all (the add-server form has
    /// not chosen a server id yet), which is skipped rather than failed.
    fn note_credential<T>(&self, server_id: &str, result: &Result<T, ApiError>) {
        let verdict = match result {
            Ok(_) => store::auth_state::CredentialVerdict::Accepted,
            Err(ApiError::Authentication) => store::auth_state::CredentialVerdict::Rejected,
            Err(_) => return,
        };
        self.write_credential(server_id, verdict);
    }

    fn write_credential(&self, server_id: &str, verdict: store::auth_state::CredentialVerdict) {
        if self.db_path.is_empty() {
            return;
        }
        if let Ok(conn) = store::open(&self.db_path) {
            let at = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
            let _ = store::auth_state::note(&conn, server_id, verdict, &at);
        }
    }

    /// Insert or update a server profile.
    pub fn save_server(&self, profile: &ServerProfile) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::servers::save_server(&conn, profile).map_err(db_err)?;
        // Whatever the last verdict said, it was about the credential that used
        // to be here. Only the next round trip can say anything about this one.
        let _ = store::auth_state::clear(&conn, &profile.id);
        Ok(())
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
    ///
    /// Offline downloads survive it, rows and files both. Unlinking a server is a
    /// gesture about the connection; the bookshelf the user filled is a separate
    /// thing, and `download_delete_all` is the gesture that says what to do with it.
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
        // Read before the row goes away, and compare: the active pick belongs to
        // the user, and deleting a server they were *not* browsing must not send
        // them back to the server picker.
        let was_active = store::app_state::is_active_server(&conn, server_id).map_err(db_err)?;
        let deleted = store::servers::delete_server(&conn, server_id).map_err(db_err)?;
        if deleted {
            if let Some(url) = base_url.as_deref() {
                crate::api::series::KomgaClient::forget(url);
            }
            if was_active {
                let _ = store::app_state::clear_active_server(&conn);
            }
            // A verdict about a server that no longer exists must not outlive it:
            // the id could come back as a brand new server with a working key.
            let _ = store::auth_state::clear(&conn, server_id);
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

    /// What the last credentialed contact proved about this server's key.
    ///
    /// `unknown` is a real answer with its own meaning — never contacted, or a
    /// note left by a build this one cannot read — and the UI has to render it
    /// as "ask the server", not as a failure the user has to fix.
    pub fn auth_state(&self, server_id: &str) -> Result<AuthStateDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let (state, at) = store::auth_state::get(&conn, server_id).map_err(db_err)?;
        Ok(AuthStateDto {
            server_id: server_id.to_string(),
            state: state.as_str().to_string(),
            at: at.unwrap_or_default(),
        })
    }

    /// Everything the client can truthfully say about itself, in one read.
    ///
    /// This is the aggregate the release-hardening checklist is written
    /// against: one place a gate can ask "what is the schema, is the file
    /// intact, what does each server's sync think it owes, how many writes are
    /// queued, how many bytes are in each of the three cache tiers, what is the
    /// queue doing, did anything log an error" — and get numbers that also have
    /// to be checkable from outside with `sqlite3` and `find`. A diagnostic that
    /// cannot be corroborated is just a print statement with a struct around it.
    ///
    /// It reports and never repairs: no sweep, no reconcile, no eviction and no
    /// credential write happens here, so asking the question cannot change the
    /// answer. Every field is produced by the same per-area read the UI already
    /// uses, which is what keeps the two from ever disagreeing.
    pub fn diagnostics_snapshot(&self, server_id: &str) -> Result<DiagnosticsDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let db = crate::diagnostics::snapshot::db_health(&conn).map_err(db_err)?;
        let (state, at) = store::auth_state::get(&conn, server_id).map_err(db_err)?;
        let queued = crate::diagnostics::snapshot::count_rows_if_table(&conn, "pending_mutations")
            .map_err(db_err)?
            .unwrap_or_default();
        let rows = downloads::store::list(&conn, Some(server_id)).map_err(download_err)?;
        let log_stats = crate::diagnostics::log::stats();
        drop(conn);

        // Grouped from the listing the queue screen already uses, so the two can
        // never report different totals for the same queue.
        let mut queue: Vec<QueueStateCountDto> = Vec::new();
        for row in rows {
            let slot = match queue.iter_mut().find(|entry| entry.state == row.state) {
                Some(slot) => slot,
                None => {
                    queue.push(QueueStateCountDto {
                        state: row.state.clone(),
                        ..Default::default()
                    });
                    queue.last_mut().expect("just pushed")
                }
            };
            slot.books += 1;
            slot.pages_done += row.pages_done;
            slot.pages_total += row.pages_total;
            slot.bytes_done += row.bytes_done;
            slot.bytes_total += row.bytes_total;
        }
        queue.sort_by(|a, b| a.state.cmp(&b.state));

        Ok(DiagnosticsDto {
            server_id: server_id.to_string(),
            db,
            auth: AuthStateDto {
                server_id: server_id.to_string(),
                state: state.as_str().to_string(),
                at: at.unwrap_or_default(),
            },
            outbox_queued_rows: queued,
            sync: self.sync_states(server_id)?,
            outbox: self.outbox_status(server_id)?,
            cache: self.reader_cache_stats()?,
            storage: self.download_storage(0)?,
            queue,
            policy: ApiPolicyDto {
                contract_version: crate::api::contract::CONTRACT_VERSION.to_string(),
                snapshot_version: crate::api::contract::SNAPSHOT_VERSION.to_string(),
                min_server_version: {
                    let (major, minor, patch) = crate::api::contract::MIN_SERVER_VERSION;
                    format!("{major}.{minor}.{patch}")
                },
            },
            log: log_stats,
        })
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
        let fetched = sync::fetch_bootstrap_page(fetcher).await;
        self.note_credential(server_id, &fetched);
        let page = fetched?;
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

    /// The offline-download tree beside the cache. `docs/offline-storage.md` fixes
    /// the layout, and the two trees being siblings is what keeps every cache sweep
    /// structurally unable to reach a user's download.
    fn download_root(&self) -> Result<DownloadRoot, ApiError> {
        DownloadRoot::for_db(Path::new(&self.db_path)).map_err(root_err)
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

    /// Cover paths for a *page* of entities, so the wall asks for what it is
    /// about to paint rather than for the server's whole thumbnail table.
    ///
    /// The existence check is kept deliberately: `list_series_missing_cover` and
    /// `cover_path` both treat a vanished file as a cache miss so the backfill can
    /// heal it. Dropping the check would leave permanently broken covers rendering
    /// as placeholders forever. It is 50 `stat()` calls now instead of 20,000.
    pub fn cover_paths(
        &self,
        server_id: &str,
        variant: &str,
        remote_ids: &[String],
    ) -> Result<HashMap<String, String>, ApiError> {
        if remote_ids.is_empty() {
            return Ok(HashMap::new());
        }
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let rows = store::thumbnails::cover_paths(&conn, server_id, variant, remote_ids)
            .map_err(db_err)?;
        Ok(rows
            .into_iter()
            .filter(|(_, path)| Path::new(path).exists())
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
        let result = sync::full_sync(&self.db_path, server_id, fetcher).await;
        self.note_credential(server_id, &result);
        result
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
        let result = sync::full_sync_from(&self.db_path, &server_id, &client, start).await;
        self.note_credential(&server_id, &result);
        result
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
        let result = sync::reconcile::reconcile(
            &self.db_path,
            server_id,
            fetcher,
            ReconcileTrigger::parse(trigger),
        )
        .await;
        // The highest-value of the four sites: every trigger — launch, foreground,
        // network return, SSE reconnect, pull to refresh — ends up here, so this
        // is how a key that died between sessions becomes visible on its own.
        self.note_credential(server_id, &result);
        let summary = result?;
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

    /// Which book a "start or continue reading" tap should open for this series
    /// (本地查询). The shelf and the series detail both call this, so they cannot
    /// disagree about what "继续阅读" means.
    pub fn series_read_target(
        &self,
        server_id: &str,
        series_id: &str,
    ) -> Result<ReadTargetRow, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::query::series_read_target_row(&conn, server_id, series_id).map_err(db_err)
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
        // A 401 in mid-queue ends the run as a *status*, not as an error, so the
        // credential verdict has to be read off the summary. A run that
        // considered nothing sent no request and therefore proves nothing —
        // saying "your key is fine" because the queue was empty would be the
        // same lie in the other direction.
        match (summary.status, summary.considered) {
            (sync::upload::RunStatus::BlockedAuthentication, _) => {
                self.write_credential(server_id, store::auth_state::CredentialVerdict::Rejected);
            }
            (sync::upload::RunStatus::Complete, considered) if considered > 0 => {
                self.write_credential(server_id, store::auth_state::CredentialVerdict::Accepted);
            }
            _ => {}
        }
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
pub use crate::store::query::{BookPageResult, ReadTargetRow, SeriesPageResult};

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

/// A download-queue failure crosses the boundary with its own wording intact: the
/// message is what the Downloads screen shows, and rewriting "服务器拒绝了凭据" as a
/// category would throw away the only part the user can act on.
fn download_err(e: downloads::store::QueueError) -> ApiError {
    ApiError::Storage {
        message: e.to_string(),
    }
}

fn root_err(e: downloads::manifest::RootError) -> ApiError {
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

/// What the credential for one server is currently believed to be.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthStateDto {
    pub server_id: String,
    /// `valid` | `expired` | `unknown`.
    pub state: String,
    /// When that was proved, RFC 3339; empty for `unknown`.
    pub at: String,
}

/// The queue grouped by the state the user gave it, summed across their books.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueStateCountDto {
    /// `queued` | `downloading` | `paused` | `completed` | `failed`.
    pub state: String,
    pub books: i64,
    pub pages_done: i64,
    pub pages_total: i64,
    pub bytes_done: i64,
    /// 0 whenever no book in this state ever learned its own size.
    pub bytes_total: i64,
}

/// What this build can talk to. Static: it says nothing about the server that
/// is currently answering, which is what `sync` rows and `probe` are for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiPolicyDto {
    pub contract_version: String,
    pub snapshot_version: String,
    pub min_server_version: String,
}

/// One read of everything the client knows about itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticsDto {
    pub server_id: String,
    /// The store's own account: pragmas, integrity verdict, per-table rows.
    pub db: crate::diagnostics::DbHealth,
    pub auth: AuthStateDto,
    /// Rows in `pending_mutations` for any server, counted straight from SQL.
    /// Reported beside `outbox`, which is per-server: the two disagree by
    /// design when a second server has queued writes.
    pub outbox_queued_rows: i64,
    pub sync: Vec<EntitySyncState>,
    pub outbox: OutboxStatusDto,
    pub cache: CacheStatsDto,
    pub storage: StorageDto,
    pub queue: Vec<QueueStateCountDto>,
    pub policy: ApiPolicyDto,
    pub log: crate::diagnostics::LogStats,
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

        // The two-level rule, and nothing else: series override → global
        // setting. The book's own remembered mode/direction is deliberately not
        // consulted any more (the columns are still written — see
        // `store::position`), because "I set volume 3 to a spread" must not be
        // able to decide how volume 9 opens.
        let global = reader::settings::ReaderSettings::load(&conn).map_err(db_err)?;
        let series_id: Option<String> = conn
            .query_row(
                "SELECT series_id FROM books WHERE server_id = ?1 AND remote_id = ?2",
                rusqlite::params![server_id, book_id],
                |row| row.get(0),
            )
            .ok()
            .flatten();
        let series = match series_id.as_deref() {
            Some(id) => {
                reader::series_override::load_override(&conn, &server_id, id).map_err(db_err)?
            }
            None => None,
        };
        let mut settings = reader::series_override::resolve_for_series(&global, series);
        // An explicit request from the UI is the caller stating the effective
        // choice (it is how a series override the user just made reaches the
        // open path), so it comes after the override rather than before it.
        if !mode.is_empty() {
            settings.mode = reader::paging::ReadMode::parse(&mode);
        }
        if !direction.is_empty() {
            settings.direction = reader::paging::Direction::parse(&direction);
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
        let start_page_offset_ratio = session.page_offset_ratio();
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
            start_page_offset_ratio,
            layout,
        })
    }

    /// Where this page already is on disk, if anywhere. No network: this is what
    /// the UI paints first, and what tells it whether a fetch is needed.
    ///
    /// The order is the stage's contract — Offline Download, then Page Cache, then
    /// whatever the caller does about the network — and it is one function because
    /// `reader_page` starts by calling this one. A downloaded page is never copied
    /// into the cache and never enters the LRU ledger: the row in `download_pages`
    /// is already the truth about it, and a ledger row would make the eviction
    /// budget permanently unsatisfiable.
    pub fn reader_page_path(
        &self,
        server_id: String,
        book_id: String,
        page: i64,
    ) -> Result<Option<String>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        if page >= 1 {
            let downloaded = downloads::recover::usable_page(
                &conn,
                &server_id,
                &book_id,
                page as u32,
                &thumbnails_now(),
            )
            .map_err(download_err)?;
            if downloaded.is_some() {
                return Ok(downloaded.map(|path| path.to_string_lossy().into_owned()));
            }
        }
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

    /// Which pages a prefetch pass must not queue, because they are already on the
    /// device.
    ///
    /// Downloaded pages count as warm. Without this the prefetcher re-queues every
    /// page of a book the user already owns locally, and writes a second copy of each
    /// into the cache tier — bytes the user paid for twice and the LRU then gets to
    /// evict.
    fn prefetch_warm_set(
        &self,
        conn: &Connection,
        server_id: &str,
        book_id: &str,
        manifest: &reader::manifest::PageManifest,
    ) -> Result<HashSet<u32>, ApiError> {
        let mut cached = self.open_reader_cache()?.cached_pages(conn, manifest);
        cached.extend(
            downloads::store::complete_pages(conn, server_id, book_id).map_err(download_err)?,
        );
        Ok(cached)
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
            let cached = self.prefetch_warm_set(&conn, &server_id, &book_id, &manifest)?;
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

    /// The reader mode / direction this series overrides, as JSON, or `None`
    /// when the series follows the global preference (本地偏好).
    pub fn series_read_override(
        &self,
        server_id: &str,
        series_id: &str,
    ) -> Result<Option<String>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let found =
            reader::series_override::load_override(&conn, server_id, series_id).map_err(db_err)?;
        Ok(found.and_then(|value| serde_json::to_string(&value).ok()))
    }

    /// Record what this series should read like, or clear it when neither
    /// dimension is set. Returns the stored JSON — the caller shows it back to
    /// the user, which is how "已把此系列设为双页" can be true.
    pub fn set_series_read_override(
        &self,
        server_id: &str,
        series_id: &str,
        mode: Option<String>,
        direction: Option<String>,
    ) -> Result<Option<String>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let value = reader::series_override::SeriesOverride {
            mode: mode.as_deref().map(reader::paging::ReadMode::parse),
            direction: direction.as_deref().map(reader::paging::Direction::parse),
        };
        if value.is_empty() {
            reader::series_override::clear_override(&conn, server_id, series_id).map_err(db_err)?;
            return Ok(None);
        }
        reader::series_override::save_override(&conn, server_id, series_id, &value)
            .map_err(db_err)?;
        Ok(serde_json::to_string(&value).ok())
    }

    /// Report how far into the current page a webtoon reader has scrolled.
    ///
    /// Deliberately not a database write: a scroll reports continuously, and the
    /// offset rides along with the next persist — which a turn, a mode change or
    /// closing the book always triggers. Persisting here would put the whole
    /// position row through SQLite once per frame.
    pub fn reader_set_page_offset(
        &self,
        server_id: String,
        book_id: String,
        ratio: Option<f64>,
    ) -> Result<(), ApiError> {
        let key = reader_key(&server_id, &book_id);
        let mut guard = readers();
        let live = guard.get_mut(&key).ok_or_else(|| ApiError::InvalidInput {
            message: "reader is not open".to_string(),
        })?;
        live.session.set_page_offset_ratio(ratio);
        Ok(())
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
            // From `download_pages`, not the ledger: a download has no ledger row by
            // design, and reading the `kind = 'download'` sum here reported zero for
            // every download the app had ever made.
            download_bytes: downloads::store::bytes_done_all(&conn).map_err(download_err)?,
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

    // MARK: - Stage 9 offline downloads

    /// Put a book in the download queue. Works with the network dead — the mirrored
    /// manifest already says what the book contains, and a book that was never
    /// mirrored cannot be queued, because nothing local can say how many pages it has.
    pub fn download_enqueue(
        &self,
        server_id: String,
        book_id: String,
    ) -> Result<DownloadBookDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let manifest = self.mirrored_manifest(&conn, &server_id, &book_id)?;
        let numbers: Vec<u32> = (1..=manifest.page_count()).collect();
        let bytes_total: i64 = numbers
            .iter()
            .map(|number| {
                manifest
                    .pages
                    .iter()
                    .find(|page| page.number == *number)
                    .map(|page| page.size_bytes.max(0))
                    .unwrap_or(0)
            })
            .sum();
        let detail = store::books::get_book(&conn, &server_id, &book_id).map_err(db_err)?;
        let root = self.download_root()?;
        let row = downloads::store::enqueue(
            &conn,
            &downloads::store::NewDownload {
                server_id: server_id.clone(),
                book_id: book_id.clone(),
                pages_total: manifest.page_count(),
                bytes_total,
                manifest_path: root
                    .manifest_path(&server_id, &book_id)
                    .to_string_lossy()
                    .into_owned(),
                remote_last_modified: detail.as_ref().and_then(|book| book.last_modified.clone()),
                book_title: detail.as_ref().map(|book| book.title.clone()),
                series_title: detail.as_ref().and_then(|book| book.series_title.clone()),
            },
            &numbers,
            &thumbnails_now(),
        )
        .map_err(download_err)?;
        // The directory and its self-describing manifest exist before a single page
        // byte arrives: a half-finished download has to be legible to a sweep, to a
        // user reading the folder, and to a restore after a crash.
        downloads::recover::rebuild_manifest(&conn, &root, &server_id, &book_id, &thumbnails_now())
            .map_err(download_err)?;
        download_dto(&conn, &Some(row), &server_id, &book_id)
    }

    /// The only gesture that may stop a download in flight, and the only one that
    /// may start one back up again.
    pub fn download_pause(
        &self,
        server_id: String,
        book_id: String,
    ) -> Result<DownloadBookDto, ApiError> {
        self.download_user_set(&server_id, &book_id, downloads::queue::book_state::PAUSED)
    }

    pub fn download_resume(
        &self,
        server_id: String,
        book_id: String,
    ) -> Result<DownloadBookDto, ApiError> {
        self.download_user_set(&server_id, &book_id, downloads::queue::book_state::WAITING)
    }

    /// Re-queue a book's failed pages. Pages already on disk are left alone, which
    /// is the whole value of single-page retry: three bad pages in a four-hundred
    /// page book costs three requests, and the acceptance harness asserts that.
    pub fn download_retry(
        &self,
        server_id: String,
        book_id: String,
    ) -> Result<DownloadBookDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        downloads::store::retry_failed_pages(&conn, &server_id, &book_id, &thumbnails_now())
            .map_err(download_err)?;
        // Only a failed book has a state to move. Re-queueing a book a pass is
        // holding is the `downloading -> waiting by user` pair the contract refuses,
        // and for a waiting or paused book the gesture was about its pages, not its
        // state — so the pages are cleared and the state is left exactly where it is.
        if downloads::store::state_of(&conn, &server_id, &book_id)
            .map_err(download_err)?
            .as_deref()
            == Some(downloads::queue::book_state::FAILED)
        {
            downloads::store::user_set(
                &conn,
                &server_id,
                &book_id,
                downloads::queue::book_state::WAITING,
                &thumbnails_now(),
                None,
            )
            .map_err(download_err)?;
        }
        downloads::store::clear_park(&conn, &server_id, &thumbnails_now()).map_err(download_err)?;
        download_dto(&conn, &None, &server_id, &book_id)
    }

    /// The user's explicit "spend my data" consent for one book.
    pub fn download_set_allow_cellular(
        &self,
        server_id: String,
        book_id: String,
        allow: bool,
    ) -> Result<DownloadBookDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        downloads::store::set_allow_cellular(&conn, &server_id, &book_id, allow, &thumbnails_now())
            .map_err(download_err)?;
        download_dto(&conn, &None, &server_id, &book_id)
    }

    fn download_user_set(
        &self,
        server_id: &str,
        book_id: &str,
        to: &str,
    ) -> Result<DownloadBookDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let row =
            downloads::store::user_set(&conn, server_id, book_id, to, &thumbnails_now(), None)
                .map_err(download_err)?;
        download_dto(&conn, &Some(row), server_id, book_id)
    }

    /// Delete a download. Nothing else in the program may do this — see the
    /// OWNERSHIP note in `downloads::mod`.
    ///
    /// The rows go first, then the files: if the process dies between the two, the
    /// tree is one the database no longer claims, which the sweep reports as unowned
    /// and preserves. The other order would leave files the user asked to delete and
    /// no row to name them by.
    pub fn download_delete(
        &self,
        server_id: String,
        book_id: String,
    ) -> Result<DownloadDeleteDto, ApiError> {
        let root = self.download_root()?;
        let conn = store::open(&self.db_path).map_err(db_err)?;
        downloads::store::delete_rows(&conn, &server_id, &book_id).map_err(download_err)?;
        let (files, freed) = root
            .remove_book_tree(&server_id, &book_id)
            .map_err(storage_err)?;
        Ok(DownloadDeleteDto {
            books: 1,
            files: files as i64,
            freed_bytes: freed as i64,
        })
    }

    /// Clear every download for one server, including a directory the database has
    /// no row for. Deleting a server is itself an explicit user action, which is what
    /// makes the unowned trees reachable here: they are otherwise counted and left
    /// alone by the sweep, forever.
    pub fn download_delete_all(&self, server_id: String) -> Result<DownloadDeleteDto, ApiError> {
        let root = self.download_root()?;
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let books = downloads::store::list(&conn, Some(&server_id)).map_err(download_err)?;
        let mut files = 0usize;
        let mut freed = 0u64;
        for book in &books {
            downloads::store::delete_rows(&conn, &server_id, &book.book_id)
                .map_err(download_err)?;
        }
        let (tree_files, tree_bytes) = root.remove_server_tree(&server_id).map_err(storage_err)?;
        files += tree_files;
        freed += tree_bytes;
        Ok(DownloadDeleteDto {
            books: books.len() as i64,
            files: files as i64,
            freed_bytes: freed as i64,
        })
    }

    /// The queue, as SQLite knows it. No network, no filesystem walk: this is what
    /// the Downloads screen reads on every tick.
    pub fn download_list(&self, server_id: String) -> Result<Vec<DownloadBookDto>, ApiError> {
        // The screen reads this on every tick, so it is also where a session that
        // opened the Downloads page finds its tree reconciled. `sweep_once` runs at
        // most once per database per process, whichever caller gets there first.
        let root = self.download_root()?;
        let _ = downloads::recover::sweep_once(Path::new(&self.db_path), &root, &thumbnails_now());
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let rows = downloads::store::list(&conn, Some(&server_id)).map_err(download_err)?;
        rows.iter()
            .map(|row| download_dto(&conn, &Some(row.clone()), &row.server_id, &row.book_id))
            .collect()
    }

    /// What the device is holding, and what it says it has left.
    ///
    /// `free_volume_bytes` comes from the platform and is never probed here: the core
    /// has no business guessing at a volume it cannot see, and `0` means "the platform
    /// would not say", which every consumer resolves conservatively. Both a derived
    /// (SQL) and a measured (walk) figure are reported for the downloads, because the
    /// gap between them is exactly the debris a sweep has not yet collected.
    pub fn download_storage(&self, free_volume_bytes: i64) -> Result<StorageDto, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let cache = self.open_reader_cache()?;
        let root = self.download_root()?;
        let books = downloads::store::storage_rows(&conn).map_err(download_err)?;
        let mut per_book = Vec::with_capacity(books.len());
        let mut disk_files = 0usize;
        let mut disk_bytes = 0i64;
        for row in &books {
            let files = root.files_in(&row.server_id, &row.book_id);
            // The manifest is a file in the directory but not a downloaded page, and
            // the screen's "N files" line means pages.
            disk_files += files
                .iter()
                .filter(|name| name.as_str() != downloads::manifest::MANIFEST_FILE)
                .count();
            disk_bytes += row.bytes_done;
            per_book.push(StorageBookDto {
                server_id: row.server_id.clone(),
                book_id: row.book_id.clone(),
                title: row
                    .book_title
                    .clone()
                    .unwrap_or_else(|| row.book_id.clone()),
                series_title: row.series_title.clone().unwrap_or_default(),
                state: row.state.clone(),
                pages_total: row.pages_total,
                pages_done: row.pages_done,
                bytes_done: row.bytes_done,
                bytes_total: row.bytes_total,
                on_disk: root.book_bytes(&row.server_id, &row.book_id) as i64,
            });
        }
        let (unowned_books, unowned_bytes) = {
            let mut count = 0i64;
            let mut bytes = 0i64;
            let owned: Vec<PathBuf> = books
                .iter()
                .map(|row| root.book_dir(&row.server_id, &row.book_id))
                .collect();
            for (_server, _book, path) in root.book_dirs() {
                if owned.contains(&path) {
                    continue;
                }
                count += 1;
                bytes += root.book_bytes_of(&path) as i64;
            }
            (count, bytes)
        };
        Ok(StorageDto {
            download_bytes: downloads::store::bytes_done_all(&conn).map_err(download_err)?,
            download_page_count: downloads::store::page_count_all(&conn).map_err(download_err)?,
            book_count: books.len() as i64,
            per_book,
            download_disk_bytes: disk_bytes,
            download_disk_files: disk_files as i64,
            unowned_books,
            unowned_bytes,
            cache_page_bytes: cache
                .bytes_of_tier(&conn, reader::cache::Tier::Page)
                .map_err(storage_err)?,
            cache_prefetch_bytes: cache
                .bytes_of_tier(&conn, reader::cache::Tier::Prefetch)
                .map_err(storage_err)?,
            // Covers keep their own table and are not in the LRU ledger, so their
            // bytes come off the directory the same way the ledger's do.
            cache_thumbnail_bytes: thumbnail_bytes(&self.cache_root())?,
            cache_total_bytes: cache.bytes_used(&conn).map_err(storage_err)?,
            cache_budget_bytes: cache.budget(),
            free_volume_bytes,
        })
    }

    /// Run the reconciliation sweep on demand. It also runs once per process on the
    /// first pump or list; this is the version the harness and a diagnostics screen
    /// call so the repairs are visible rather than inferred.
    pub fn download_sweep(&self) -> Result<DownloadSweepDto, ApiError> {
        let root = self.download_root()?;
        downloads::recover::forget_swept();
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let report =
            downloads::recover::sweep(&conn, &root, &thumbnails_now()).map_err(download_err)?;
        Ok(DownloadSweepDto {
            books: report.books as i64,
            stale_parts: report.stale_parts as i64,
            ghost_rows: report.ghost_rows as i64,
            corrupt: report.corrupt as i64,
            size_mismatch: report.size_mismatch as i64,
            adopted_files: report.adopted_files as i64,
            counters_repaired: report.counters_repaired as i64,
            manifests_rewritten: report.manifests_rewritten as i64,
            pages_removed: report.pages_removed as i64,
            unowned_books: report.unowned_books as i64,
            unowned_bytes: report.unowned_bytes,
            freed_bytes: report.freed_bytes,
        })
    }

    /// Drive the queue. One bounded pass per call, and the only function in the
    /// download surface that may make a request.
    ///
    /// `Ok(None)` means another pass holds this database right now — identical
    /// contract and identical reasoning to `sse_poll`: the tick that got the slot
    /// reports the progress, so this one has nothing to do and must not queue a
    /// second writer against the same rows.
    #[allow(clippy::too_many_arguments)]
    pub async fn download_pump(
        &self,
        server_id: String,
        base_url: String,
        api_key: String,
        max_pages: i64,
        max_bytes: i64,
        free_volume_bytes: i64,
        link: String,
    ) -> Result<Option<DownloadPumpDto>, ApiError> {
        let Some(_slot) = PumpSlot::claim(&self.db_path) else {
            return Ok(None);
        };
        let client = KomgaClient::shared(base_url, AuthMethod::ApiKey { key: api_key })?;
        let root = self.download_root()?;
        // Where the reader sits, so a pass races toward the page the user is looking
        // at instead of toward the end of the book. Read from the registry and
        // dropped: no Connection may be held across the await below.
        // Where a live reader sits on this server, so a pass races toward the page
        // the user is looking at rather than toward the end of the book. Borrowed and
        // released before the await below, like every other rule in this file about
        // what may not be held across one.
        let reader = readers().iter().find_map(|(key, live)| {
            let (server, book) = key.split_once('|')?;
            (server == server_id).then(|| downloads::queue::ReaderPosition {
                book_id: book.to_string(),
                page: live.session.page(),
            })
        });
        let report = downloads::engine::run_pass(
            Path::new(&self.db_path),
            &root,
            &client,
            &downloads::engine::PassRequest {
                server_id: &server_id,
                free_bytes: free_volume_bytes,
                link: downloads::queue::Link::parse(&link),
                max_pages: max_pages.max(0) as usize,
                max_bytes: max_bytes.max(0),
                reader,
            },
            chrono::Utc::now(),
        )
        .await
        .map_err(|error| ApiError::Storage {
            message: error.to_string(),
        })?;
        Ok(Some(DownloadPumpDto {
            book: report.book.map(|(_server, book)| book).unwrap_or_default(),
            state: report.state.unwrap_or_default(),
            served: report.served as i64,
            failed_pages: report.failed_pages as i64,
            bytes_written: report.bytes_written,
            pages_done: report.pages_done,
            pages_total: report.pages_total,
            stop_reason: report.stop.as_str().to_string(),
            next_in_ms: report.next_in_ms,
            pump_ms: report.pump_ms as i64,
            last_error: report.last_error.unwrap_or_default(),
            repairs: report.repairs,
            parts_swept: report.parts_swept,
            adopted: report.adopted,
            ghost_rows: report.ghost_rows,
            queue_active: report.queue_active,
        }))
    }
}

// --------------------------------------------------------------------------
// Stage 9 offline-download plumbing: the pump slot, the DTOs that cross the
// FFI, and the two small queries the screens need and the store cannot answer.
// --------------------------------------------------------------------------

/// One pass per database, at a time.
///
/// Same shape as the parked SSE socket and for the same reason: two passes
/// interleaving on one queue would double-fetch the page the other is mid-way
/// through, and the counters the second one writes would be derived from rows the
/// first has not committed yet. The slot is released by `Drop`, so a panic in a pass
/// cannot strand the queue with nobody able to run it.
struct PumpSlot {
    key: String,
}

static PUMP_SLOTS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

impl PumpSlot {
    fn claim(db_path: &str) -> Option<Self> {
        let Ok(mut guard) = PUMP_SLOTS.get_or_init(|| Mutex::new(HashSet::new())).lock() else {
            return None;
        };
        if guard.contains(db_path) {
            return None;
        }
        guard.insert(db_path.to_string());
        Some(Self {
            key: db_path.to_string(),
        })
    }
}

impl Drop for PumpSlot {
    fn drop(&mut self) {
        if let Ok(mut guard) = PUMP_SLOTS.get_or_init(|| Mutex::new(HashSet::new())).lock() {
            guard.remove(&self.key);
        }
    }
}

/// Bytes held by the cover cache. Covers keep their own table rather than ledger
/// rows, so this is a directory walk and belongs on a user-initiated call only.
fn thumbnail_bytes(cache_root: &Path) -> Result<i64, ApiError> {
    let Ok(entries) = std::fs::read_dir(cache_root.join(crate::cache::THUMBNAILS_DIR)) else {
        return Ok(0);
    };
    let mut total = 0i64;
    for entry in entries.flatten() {
        if let Ok(meta) = entry.metadata() {
            if meta.is_file() {
                total += meta.len() as i64;
            }
        }
    }
    Ok(total)
}

/// One queue row, as the Downloads screen reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadBookDto {
    pub server_id: String,
    pub book_id: String,
    pub title: String,
    pub series_title: String,
    pub state: String,
    pub pages_total: i64,
    pub pages_done: i64,
    pub bytes_total: i64,
    pub bytes_done: i64,
    pub position: i64,
    pub last_error: String,
    pub next_retry_at: String,
    pub remote_last_modified: String,
    pub allow_cellular: bool,
    /// The book is gone from the server, or its `lastModified` moved past what this
    /// download recorded. Either way the copy on the device still reads; the screen
    /// says why it will never update again.
    pub stale: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadDeleteDto {
    pub books: i64,
    pub files: i64,
    pub freed_bytes: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadSweepDto {
    pub books: i64,
    pub stale_parts: i64,
    pub ghost_rows: i64,
    pub corrupt: i64,
    pub size_mismatch: i64,
    pub adopted_files: i64,
    pub counters_repaired: i64,
    pub manifests_rewritten: i64,
    pub pages_removed: i64,
    pub unowned_books: i64,
    pub unowned_bytes: i64,
    pub freed_bytes: i64,
}

impl DownloadSweepDto {
    /// How much the sweep had to repair. Zero is the healthy answer, and the one an
    /// acceptance run asserts on: a sweep that reports nothing after a crash means
    /// the crash was never noticed.
    pub fn repairs(&self) -> i64 {
        self.stale_parts
            + self.ghost_rows
            + self.corrupt
            + self.size_mismatch
            + self.adopted_files
            + self.counters_repaired
            + self.manifests_rewritten
            + self.pages_removed
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadPumpDto {
    pub book: String,
    pub state: String,
    pub served: i64,
    pub failed_pages: i64,
    pub bytes_written: i64,
    pub pages_done: i64,
    pub pages_total: i64,
    pub stop_reason: String,
    pub next_in_ms: i64,
    pub pump_ms: i64,
    pub last_error: String,
    /// What the first pass of this process had to repair in the download tree. A
    /// recovery that reports nothing cannot be told apart from one that never ran,
    /// which is the mistake these four fields exist to prevent.
    pub repairs: i64,
    pub parts_swept: i64,
    pub adopted: i64,
    pub ghost_rows: i64,
    pub queue_active: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageBookDto {
    pub server_id: String,
    pub book_id: String,
    pub title: String,
    pub series_title: String,
    pub state: String,
    pub pages_total: i64,
    pub pages_done: i64,
    pub bytes_total: i64,
    pub bytes_done: i64,
    /// Measured from the directory, so the screen can show the gap between what the
    /// rows claim and what the disk holds.
    pub on_disk: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageDto {
    pub download_bytes: i64,
    pub download_page_count: i64,
    pub book_count: i64,
    pub per_book: Vec<StorageBookDto>,
    pub download_disk_bytes: i64,
    pub download_disk_files: i64,
    pub unowned_books: i64,
    pub unowned_bytes: i64,
    pub cache_page_bytes: i64,
    pub cache_prefetch_bytes: i64,
    pub cache_thumbnail_bytes: i64,
    pub cache_total_bytes: i64,
    pub cache_budget_bytes: i64,
    /// 0 means the platform would not say.
    pub free_volume_bytes: i64,
}

fn download_dto(
    conn: &Connection,
    row: &Option<downloads::store::DownloadRow>,
    server_id: &str,
    book_id: &str,
) -> Result<DownloadBookDto, ApiError> {
    let row = match row {
        Some(row) => row.clone(),
        None => downloads::store::get(conn, server_id, book_id)
            .map_err(download_err)?
            .ok_or_else(|| ApiError::InvalidInput {
                message: format!("no download for {server_id}/{book_id}"),
            })?,
    };
    // `stale` is two different facts with one user-visible meaning: this copy will
    // never be refreshed from where it came. The book row is gone (the server dropped
    // it, and Stage 9 keeps the download), or it moved since the job was created.
    let mirror: Option<(Option<String>, Option<String>)> = conn
        .query_row(
            "SELECT title, last_modified FROM books WHERE server_id = ?1 AND remote_id = ?2",
            rusqlite::params![server_id, book_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_err)?;
    let stale = match (&mirror, &row.remote_last_modified) {
        (None, _) => true,
        (Some((_, Some(remote))), Some(recorded)) => remote.as_str() > recorded.as_str(),
        _ => false,
    };
    Ok(DownloadBookDto {
        server_id: row.server_id,
        book_id: row.book_id,
        title: row.book_title.clone().unwrap_or_default(),
        series_title: row.series_title.clone().unwrap_or_default(),
        state: row.state,
        pages_total: row.pages_total,
        pages_done: row.pages_done,
        bytes_total: row.bytes_total,
        bytes_done: row.bytes_done,
        position: row.position,
        last_error: row.last_error.clone().unwrap_or_default(),
        next_retry_at: row.next_retry_at.clone().unwrap_or_default(),
        remote_last_modified: row.remote_last_modified.clone().unwrap_or_default(),
        allow_cellular: row.allow_cellular,
        stale,
    })
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
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
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
        volume_keys_enabled: value.volume_keys_enabled,
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
        volume_keys_enabled: value.volume_keys_enabled,
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
    /// Where in `start_page` the reader was, 0..1, for a webtoon. `None` means
    /// "top of the page" — and also "this book has no saved offset", which the
    /// UI treats the same way.
    pub start_page_offset_ratio: Option<f64>,
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
    /// Whether the hardware volume keys turn pages (off by default).
    pub volume_keys_enabled: bool,
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
    use std::collections::BTreeSet;
    use uuid::Uuid;

    fn temp_db() -> String {
        let dir = std::env::temp_dir().join(format!("komga_app_test_{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("comic.sqlite").to_string_lossy().into_owned()
    }

    /// The DTO is the FFI contract, and it is easy to add a field to the Rust
    /// struct and forget that the boundary now carries one more value: the Dart
    /// decoder rejects a length mismatch at runtime, on a device, with no test
    /// watching. This pins the round trip for the knob most likely to be
    /// "helpfully" defaulted to true.
    #[test]
    fn reader_settings_dto_round_trips_the_volume_keys_knob() {
        let dto = settings_dto(reader::settings::ReaderSettings::default());
        assert!(
            !dto.volume_keys_enabled,
            "the default must be off: stealing the volume keys is the user's call"
        );

        let on = reader::settings::ReaderSettings {
            volume_keys_enabled: true,
            ..reader::settings::ReaderSettings::default()
        };
        let dto = settings_dto(on.clone());
        assert!(dto.volume_keys_enabled);
        assert_eq!(
            settings_of(dto).volume_keys_enabled,
            on.volume_keys_enabled,
            "the field survives the boundary in both directions"
        );

        // And the whole default document survives N trips unchanged.
        let dto = settings_dto(reader::settings::ReaderSettings::default());
        assert_eq!(
            settings_of(dto),
            reader::settings::ReaderSettings::default().sanitized()
        );
    }

    /// A book mirrored and partially on disk the way the engine leaves it: real PNG
    /// bytes at their contract names, rows that point at them, counters derived.
    fn plant_download(app: &App, server: &str, book: &str, numbers: &[u32]) {
        let db = Path::new(&app.db_path);
        let conn = store::open(db).unwrap();
        let root = DownloadRoot::for_db(db).unwrap();
        for number in numbers {
            let (width, height) = crate::cache::demo_png::page_dimensions(*number);
            conn.execute(
                "INSERT OR REPLACE INTO book_pages
                 (server_id, book_id, number, file_name, media_type, width, height, size_bytes, fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                rusqlite::params![
                    server, book, *number as i64,
                    format!("{number:04}.png"), "image/png",
                    width as i64, height as i64,
                    crate::cache::demo_png::demo_page_bytes(*number).len() as i64,
                    thumbnails_now()
                ],
            ).unwrap();
        }
        let numbers: Vec<u32> = (1..=*numbers.last().unwrap()).collect();
        conn.execute(
            "INSERT OR REPLACE INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done, state, created_at, position)
             VALUES (?1, ?2, ?3, ?4, 0, 'waiting', ?5, 1)",
            rusqlite::params![server, book, root.manifest_path(server, book).to_string_lossy().into_owned(),
                              numbers.len() as i64, thumbnails_now()],
        ).unwrap();
        for number in &numbers {
            conn.execute(
                "INSERT OR REPLACE INTO download_pages (server_id, book_id, page_number, state, updated_at)
                 VALUES (?1, ?2, ?3, 'pending', ?4)",
                rusqlite::params![server, book, *number as i64, thumbnails_now()],
            ).unwrap();
        }
        std::fs::create_dir_all(root.book_dir(server, book)).unwrap();
        for number in numbers {
            let path = root.page_path(server, book, number, "png");
            std::fs::write(&path, crate::cache::demo_png::demo_page_bytes(number)).unwrap();
            downloads::store::mark_page_complete(
                &conn,
                server,
                book,
                number,
                &path.to_string_lossy(),
                std::fs::metadata(&path).unwrap().len() as i64,
                "image/png",
                &thumbnails_now(),
            )
            .unwrap();
        }
        downloads::store::recompute_counters(&conn, server, book, &thumbnails_now()).unwrap();
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

    /// The server answered 401. The only failure that says something about a key.
    struct RejectingSeriesFetcher;

    impl crate::sync::SeriesFetcher for RejectingSeriesFetcher {
        async fn series_page(
            &self,
            _request: &crate::api::series::PageRequest,
        ) -> Result<crate::model::series::SeriesPage, ApiError> {
            Err(ApiError::Authentication)
        }
    }

    /// No route. Says nothing about a key, which is the whole point of the test
    /// that uses it.
    struct UnreachableSeriesFetcher;

    impl crate::sync::SeriesFetcher for UnreachableSeriesFetcher {
        async fn series_page(
            &self,
            _request: &crate::api::series::PageRequest,
        ) -> Result<crate::model::series::SeriesPage, ApiError> {
            Err(ApiError::Network)
        }
    }

    #[tokio::test]
    async fn a_rejected_key_is_reported_expired_until_a_later_success_clears_it() {
        let db = temp_db();
        let app = App::new(&db);

        // Never contacted: `unknown`, and the UI has to be able to tell that
        // apart from a problem.
        assert_eq!(app.auth_state("server-1").unwrap().state, "unknown");

        let rejected = app
            .bootstrap_with(&RejectingSeriesFetcher, "server-1")
            .await;
        assert!(matches!(rejected, Err(ApiError::Authentication)));
        let expired = app.auth_state("server-1").unwrap();
        assert_eq!(expired.state, "expired");
        assert!(
            !expired.at.is_empty(),
            "an expiry with no moment is a banner the user cannot reason about"
        );

        // The user fixes the key. The same call, now accepted, is what clears it.
        let json =
            include_str!("../../../../specs/contracts/fixtures/initial-sync/series-page.json");
        let page: crate::model::series::SeriesPage =
            serde_json::from_str(json).expect("shared fixture must decode");
        let accepted = app
            .bootstrap_with(&FakeSeriesFetcher(page), "server-1")
            .await;
        assert!(accepted.is_ok(), "{accepted:?}");
        let valid = app.auth_state("server-1").unwrap();
        assert_eq!(valid.state, "valid");
        assert_eq!(valid.server_id, "server-1");
        cleanup_temp(&db);
    }

    #[tokio::test]
    async fn an_unreachable_server_says_nothing_about_the_key() {
        let db = temp_db();
        let app = App::new(&db);

        let unreachable = app
            .bootstrap_with(&UnreachableSeriesFetcher, "server-1")
            .await;
        assert!(matches!(unreachable, Err(ApiError::Network)));
        // A client that blamed the password for every lost tunnel would be
        // worse than one that never notices an expiry.
        assert_eq!(app.auth_state("server-1").unwrap().state, "unknown");

        // And once a real verdict exists, a network failure must not spend it.
        app.bootstrap_with(&RejectingSeriesFetcher, "server-1")
            .await
            .unwrap_err();
        assert_eq!(app.auth_state("server-1").unwrap().state, "expired");
        app.bootstrap_with(&UnreachableSeriesFetcher, "server-1")
            .await
            .unwrap_err();
        assert_eq!(
            app.auth_state("server-1").unwrap().state,
            "expired",
            "an unreachable server overwrote a verdict the server itself gave"
        );
        cleanup_temp(&db);
    }

    #[tokio::test]
    async fn the_diagnostics_snapshot_agrees_with_the_sql_underneath_it() {
        let db = temp_db();
        let app = App::new(&db);
        // One run that touches most of the areas at once: series, books, covers
        // on disk, sync_state rows and log lines.
        app.bootstrap_demo("gate".to_string()).await.unwrap();
        app.set_read_progress("gate", "berserk-01", 3, false)
            .unwrap();
        let conn = store::open(&db).unwrap();
        conn.execute(
            "INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done,
                                    bytes_total, bytes_done, state)
             VALUES ('gate','berserk-01',NULL,120,40,1200,400,'queued'),
                    ('gate','berserk-02',NULL,60,0,0,0,'failed')",
            [],
        )
        .unwrap();
        drop(conn);

        let snap = app.diagnostics_snapshot("gate").unwrap();
        let conn = store::open(&db).unwrap();
        let count =
            |sql: &str| -> i64 { conn.query_row(sql, [], |row| row.get::<_, i64>(0)).unwrap() };

        assert_eq!(snap.db.integrity, "ok");
        assert_eq!(
            snap.db.schema_version,
            count("PRAGMA user_version"),
            "the snapshot reported a schema the file does not have"
        );
        for table in [
            "series",
            "books",
            "sync_state",
            "pending_mutations",
            "downloads",
        ] {
            let reported = snap
                .db
                .tables
                .iter()
                .find(|entry| entry.table == table)
                .unwrap_or_else(|| panic!("{table} missing from the table report"))
                .rows;
            assert_eq!(
                reported,
                count(&format!("SELECT count(*) FROM {table}")),
                "{table}: the snapshot and the table disagree"
            );
        }

        // The per-server badge and the all-server total, read off the same rows.
        let pending = count("SELECT count(*) FROM pending_mutations WHERE state = 'pending'");
        assert_eq!(snap.outbox.pending, pending);
        assert_eq!(snap.outbox_queued_rows, pending);
        assert_eq!(snap.outbox.server_id, "gate");

        // The queue grouping, against the two rows written above.
        assert_eq!(snap.queue.len(), 2);
        let queued = snap.queue.iter().find(|e| e.state == "queued").unwrap();
        assert_eq!(
            (queued.books, queued.pages_total, queued.pages_done),
            (1, 120, 40)
        );
        assert_eq!((queued.bytes_total, queued.bytes_done), (1200, 400));
        assert_eq!(
            count("SELECT count(*) FROM downloads WHERE state = 'failed'"),
            snap.queue
                .iter()
                .find(|e| e.state == "failed")
                .unwrap()
                .books
        );

        // The second witness for the byte figure is the filesystem itself, not
        // another number the snapshot produced.
        let paths: Vec<String> = conn
            .prepare("SELECT local_path FROM thumbnails WHERE server_id = 'gate'")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .filter_map(Result::ok)
            .collect();
        let on_disk: i64 = paths
            .iter()
            .filter_map(|path| std::fs::metadata(path).ok())
            .map(|meta| meta.len() as i64)
            .sum();
        assert!(!paths.is_empty(), "the demo wrote no covers to walk");
        assert_eq!(snap.storage.cache_thumbnail_bytes, on_disk);

        // An offline demo run used no credential, so it may not claim one works.
        assert_eq!(snap.auth.state, "unknown");
        assert_eq!(snap.policy.snapshot_version, "1.26.3");
        assert!(snap.log.installed);
        assert!(snap.log.retained > 0);
        assert_eq!(snap.log.errors, 0);
        assert!(snap.sync.iter().any(|row| row.entity_type == "full"));
        drop(conn);
        cleanup_temp(&db);
    }

    /// Walk an encoded value into `parent.child` / `parent[].child` paths — the
    /// spelling `specs/contracts/fixtures/diagnostics/snapshot.json` uses. The
    /// Swift suite flattens its own snapshot the same way, so the two compare
    /// field *names* rather than two hand-maintained lists.
    fn flatten_paths(value: &serde_json::Value, prefix: &str, out: &mut BTreeSet<String>) {
        match value {
            serde_json::Value::Object(map) => {
                for (key, child) in map {
                    let path = if prefix.is_empty() {
                        key.clone()
                    } else {
                        format!("{prefix}.{key}")
                    };
                    flatten_paths(child, &path, out);
                }
            }
            serde_json::Value::Array(items) => {
                for item in items {
                    flatten_paths(item, &format!("{prefix}[]"), out);
                }
            }
            _ => {
                if !prefix.is_empty() {
                    out.insert(prefix.to_string());
                }
            }
        }
    }

    #[tokio::test]
    async fn the_diagnostics_snapshot_exposes_every_field_the_contract_names() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../specs/contracts/fixtures/diagnostics/snapshot.json"
        ))
        .expect("snapshot fixture must decode");
        let required: Vec<&str> = fixture["fields"]
            .as_array()
            .expect("`fields` must be an array")
            .iter()
            .map(|entry| entry.as_str().expect("each field is a string"))
            .collect();
        assert!(!required.is_empty(), "an empty contract proves nothing");

        let db = temp_db();
        let app = App::new(&db);
        app.bootstrap_demo("gate".to_string()).await.unwrap();
        app.set_read_progress("gate", "berserk-01", 3, false)
            .unwrap();

        // A JSON array of nothing contributes no element paths, so a contract
        // that names `queue[].state` can only be checked against a queue that
        // has a row in it. Reading the shape with an empty queue would let the
        // gate pass by omitting the check, which is how a contract file turns
        // decorative.
        let empty = serde_json::to_value(app.diagnostics_snapshot("gate").unwrap()).unwrap();
        let mut empty_paths = BTreeSet::new();
        flatten_paths(&empty, "", &mut empty_paths);
        assert!(
            !empty_paths.iter().any(|path| path.starts_with("queue[].")),
            "an empty queue reported element paths, so the next assertion is vacuous"
        );

        let conn = store::open(&db).unwrap();
        conn.execute(
            "INSERT INTO downloads (server_id, book_id, state, pages_total, pages_done,
                                    bytes_total, bytes_done)
             VALUES ('gate','berserk-01','queued',10,1,100,10)",
            [],
        )
        .unwrap();
        drop(conn);

        let encoded = serde_json::to_value(app.diagnostics_snapshot("gate").unwrap()).unwrap();
        let mut present = BTreeSet::new();
        flatten_paths(&encoded, "", &mut present);
        for path in &required {
            assert!(
                present.iter().any(|owned| owned == path),
                "the contract names `{path}` but this build's snapshot has no such field"
            );
        }

        // The contract is written in camelCase, and the shape it pins is the
        // *wire* shape: a `#[serde(rename_all)]` dropped somewhere would move
        // every field out from under the Swift side without failing a Rust test.
        assert!(present.iter().any(|path| path == "db.busyTimeoutMs"));
        assert!(
            !present.iter().any(|path| path.contains('_')),
            "a snake_case field leaked into the contract shape"
        );
        cleanup_temp(&db);
    }

    #[tokio::test]
    async fn deleting_a_server_you_were_not_browsing_keeps_the_pick_and_only_loses_its_own_note() {
        let db = temp_db();
        let app = App::new(&db);
        for id in ["home", "work"] {
            let mut profile = ServerProfile::new(id, "https://komga.example.com", AuthType::ApiKey);
            profile.id = id.into();
            app.save_server(&profile).unwrap();
        }
        app.set_active_server("home").unwrap();
        for id in ["home", "work"] {
            app.bootstrap_with(&RejectingSeriesFetcher, id)
                .await
                .unwrap_err();
            assert_eq!(app.auth_state(id).unwrap().state, "expired");
        }

        assert!(app.delete_server("work").unwrap());
        // The shelf the user was on is still theirs.
        assert_eq!(app.get_active_server().unwrap().as_deref(), Some("home"));
        // The deleted server's verdict goes with it; the survivor's does not.
        assert_eq!(app.auth_state("work").unwrap().state, "unknown");
        assert_eq!(app.auth_state("home").unwrap().state, "expired");
        cleanup_temp(&db);
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

    /// The wall asks for a page, not for the server's whole thumbnail table.
    ///
    /// Two things have to hold for that to be safe: only the asked-for ids come
    /// back (and only for the asked-for variant), and a file that has vanished
    /// still reads as a miss — `list_series_missing_cover` and `cover_path` both
    /// depend on that so the backfill can heal a wiped cache. Dropping the
    /// existence check would leave broken covers rendering as placeholders for
    /// good.
    #[tokio::test]
    async fn page_scoped_cover_paths_answer_the_page_and_still_drop_dead_files() {
        let db = temp_db();
        let app = App::new(&db);
        app.bootstrap_demo("demo".into()).await.unwrap();

        let series_ids: Vec<String> = app
            .fetch_series("demo", 10, 0)
            .unwrap()
            .iter()
            .map(|row| row.remote_id.clone())
            .collect();
        assert_eq!(series_ids.len(), 3);

        let found = app
            .cover_paths("demo", VARIANT_SERIES, &series_ids)
            .unwrap();
        assert_eq!(found.len(), 3, "one per asked-for series");
        assert!(found.values().all(|p| Path::new(p).exists()));
        assert!(found.keys().all(|k| series_ids.contains(k)));

        // The book variant never leaks into a series answer, even though the
        // same server holds seven book thumbnails.
        let book_ids: Vec<String> = app
            .list_thumbnails("demo")
            .unwrap()
            .into_iter()
            .filter(|t| t.variant == VARIANT_BOOK)
            .map(|t| t.remote_id)
            .collect();
        assert_eq!(book_ids.len(), 7);
        let books = app.cover_paths("demo", VARIANT_BOOK, &book_ids).unwrap();
        assert_eq!(books.len(), 7);
        assert!(
            books.keys().all(|k| !series_ids.contains(k)),
            "a book id must not appear in a series answer, nor the reverse"
        );

        // Simulate a wiped cache: the row stays, the file goes.
        let victim = series_ids[0].clone();
        std::fs::remove_file(&found[&victim]).unwrap();
        let after = app
            .cover_paths("demo", VARIANT_SERIES, &series_ids)
            .unwrap();
        assert_eq!(after.len(), 2);
        assert!(
            !after.contains_key(&victim),
            "a vanished file has to read as a miss so the backfill can restore it"
        );

        // An empty page asks nothing — it must not fall back to the whole table.
        assert!(app
            .cover_paths("demo", VARIANT_SERIES, &[])
            .unwrap()
            .is_empty());

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

    // ---------------------------------------------------- Stage 9 reader tiers

    /// The order is the stage's contract, and this is the case that proves it is
    /// real: both tiers hold page 1, and they hold *different bytes*. If the reader
    /// asked the cache first, the assertion would still pass on file name alone — so
    /// the comparison is the length of what was served.
    #[test]
    fn a_downloaded_page_is_read_before_the_cached_copy() {
        let db = temp_db();
        let app = App::new(&db);
        plant_download(&app, "s1", "b1", &[1, 2, 3]);
        let conn = store::open(&db).unwrap();
        let manifest = app.mirrored_manifest(&conn, "s1", "b1").unwrap();
        // A deliberately different page in the cache tier under the same key.
        let cache = app.open_reader_cache().unwrap();
        let cached = cache
            .store(
                &conn,
                &manifest.cache_key(1),
                &crate::cache::demo_png::demo_page_bytes(9),
                "image/png",
                &thumbnails_now(),
            )
            .unwrap();
        let downloaded = Path::new(&db)
            .parent()
            .unwrap()
            .join("downloads")
            .join("s1")
            .join("b1")
            .join("0001.png");
        let served = app
            .reader_page_path("s1".into(), "b1".into(), 1)
            .unwrap()
            .expect("the download tier must answer for a downloaded page");
        assert_eq!(
            Path::new(&served),
            downloaded.as_path(),
            "the reader served the cached copy instead of the one the user downloaded"
        );
        assert_ne!(
            std::fs::metadata(&served).unwrap().len(),
            std::fs::metadata(&cached.path).unwrap().len(),
            "both copies were the same size, so the order above proves nothing"
        );
        drop(conn);
        cleanup_temp(&db);
    }

    #[test]
    fn a_downloaded_page_never_enters_the_cache_ledger() {
        let db = temp_db();
        let app = App::new(&db);
        plant_download(&app, "s1", "b1", &[1, 2]);
        for number in 1..=2 {
            assert!(app
                .reader_page_path("s1".into(), "b1".into(), number)
                .unwrap()
                .is_some());
        }
        let conn = store::open(&db).unwrap();
        let ledger: i64 = conn
            .query_row("SELECT COUNT(*) FROM cache_entries", [], |row| row.get(0))
            .unwrap();
        let disk = DiskCache::new(app.cache_root())
            .unwrap()
            .bytes_used()
            .unwrap();
        assert_eq!(ledger, 0, "a download was written into the LRU ledger");
        assert_eq!(disk, 0, "a download was copied into a cache tier");
        drop(conn);
        cleanup_temp(&db);
    }

    /// A download whose file has gone bad is a cache miss, not a dead page: the
    /// reader falls through, and the row is healed on the way past.
    #[test]
    fn a_broken_download_falls_through_to_the_cache_and_heals_itself() {
        let db = temp_db();
        let app = App::new(&db);
        plant_download(&app, "s1", "b1", &[1]);
        let conn = store::open(&db).unwrap();
        let manifest = app.mirrored_manifest(&conn, "s1", "b1").unwrap();
        let cache = app.open_reader_cache().unwrap();
        let cached = cache
            .store(
                &conn,
                &manifest.cache_key(1),
                &crate::cache::demo_png::demo_page_bytes(4),
                "image/png",
                &thumbnails_now(),
            )
            .unwrap();
        let path = app
            .reader_page_path("s1".into(), "b1".into(), 1)
            .unwrap()
            .unwrap();
        std::fs::write(&path, b"this is not the page the row promised").unwrap();
        let served = app
            .reader_page_path("s1".into(), "b1".into(), 1)
            .unwrap()
            .expect("the cache still has a usable copy");
        assert_eq!(served, cached.path.to_string_lossy());
        let row = downloads::store::page(&conn, "s1", "b1", 1)
            .unwrap()
            .unwrap();
        assert_eq!(row.state, downloads::queue::page_state::PENDING);
        assert_eq!(row.file_path, None, "the healed row keeps a dead pointer");
        drop(conn);
        cleanup_temp(&db);
    }

    #[test]
    fn the_prefetch_planner_treats_a_downloaded_page_as_warm() {
        let db = temp_db();
        let app = App::new(&db);
        plant_download(&app, "s1", "b1", &[1, 2, 3]);
        let conn = store::open(&db).unwrap();
        let manifest = app.mirrored_manifest(&conn, "s1", "b1").unwrap();
        let warm = app.prefetch_warm_set(&conn, "s1", "b1", &manifest).unwrap();
        assert!(warm.contains(&1) && warm.contains(&2) && warm.contains(&3));
        assert!(!warm.contains(&4), "a page nobody downloaded is not warm");
        drop(conn);
        cleanup_temp(&db);
    }

    /// The acceptance run in one function: a book the user downloaded reads cover to
    /// cover with the server unreachable, through the same calls the UI makes.
    #[tokio::test]
    async fn a_downloaded_book_reads_cover_to_cover_with_the_server_dead() {
        let db = temp_db();
        let app = App::new(&db);
        plant_download(&app, "s1", "b1", &[1, 2, 3]);
        for number in 1..=3 {
            let path = app
                .reader_page(
                    "s1".to_string(),
                    "b1".to_string(),
                    number,
                    "http://127.0.0.1:1".to_string(),
                    "dead".to_string(),
                )
                .await
                .unwrap_or_else(|error| {
                    panic!("page {number} needed the network: {error}");
                });
            assert!(Path::new(&path).is_file(), "{path} is not on disk");
            assert!(
                Path::new(&path).starts_with(Path::new(&db).parent().unwrap().join("downloads"))
            );
        }
        // Page 4 was never downloaded, and asking for it against a dead server is
        // the honest failure — not a silent blank page.
        let missing = app
            .reader_page(
                "s1".to_string(),
                "b1".to_string(),
                4,
                "http://127.0.0.1:1".to_string(),
                "dead".to_string(),
            )
            .await;
        assert!(matches!(missing, Err(ApiError::Network)), "{missing:?}");
        cleanup_temp(&db);
    }

    /// The book row the mirror would hold, so `stale` has something to be about.
    fn plant_book_row(db: &str, server: &str, book: &str, last_modified: &str) {
        let conn = store::open(db).unwrap();
        conn.execute(
            "INSERT OR REPLACE INTO books (server_id, remote_id, series_id, series_title, title, last_modified)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![
                server, book, "se1", "Series One", format!("Book {book}"), last_modified
            ],
        )
        .unwrap();
    }

    /// The stage's central promise, tested the way it can actually be broken: four
    /// automatic cleanups, then the one gesture that is allowed. Each attack is
    /// counted separately so a regression names the attacker.
    #[test]
    fn a_download_survives_every_automatic_cleanup_and_dies_only_by_a_user_gesture() {
        let db = temp_db();
        let app = App::new(&db);
        plant_book_row(&db, "s1", "b1", "2024-05-11T18:07:33Z");
        plant_download(&app, "s1", "b1", &[1, 2, 3]);
        let root = app.download_root().unwrap();
        let count = || root.files_in("s1", "b1").len();
        let bytes = || root.book_bytes("s1", "b1");
        let before = (count(), bytes());
        assert!(before.0 >= 3, "the plant wrote no pages");

        // 1. an absurd cache budget, which is what eviction actually obeys.
        let conn = store::open(&db).unwrap();
        let cache = app.open_reader_cache_with(1).unwrap();
        for number in 1..=3 {
            cache
                .store(
                    &conn,
                    &format!("s1-b1-p{number}"),
                    &crate::cache::demo_png::demo_page_bytes(number * 7),
                    "image/png",
                    &thumbnails_now(),
                )
                .unwrap();
        }
        assert_eq!(
            count(),
            before.0,
            "the eviction budget reached into the download tree"
        );
        assert_eq!(bytes(), before.1);
        drop(cache);

        // 2. the user-facing tier cleanups.
        app.reader_clear_prefetch().unwrap();
        let cache = app.open_reader_cache().unwrap();
        cache.clear_tier(&conn, reader::cache::Tier::Page).unwrap();
        assert_eq!(
            count(),
            before.0,
            "clear_tier(page) reached into the download tree"
        );

        // 3. the bookkeeping sweep, which is the one that deletes orphans.
        app.reader_reconcile_cache().unwrap();
        assert_eq!(
            count(),
            before.0,
            "the reconcile sweep took a download for an orphan"
        );

        // 4. the mirror sweep deciding the book is gone from the server.
        store::prune::delete_book(&conn, "s1", "b1").unwrap();
        drop(conn);
        assert_eq!(count(), before.0, "the mirror sweep deleted a user's files");
        let listed = app.download_list("s1".to_string()).unwrap();
        assert_eq!(listed.len(), 1, "the queue forgot the book the server did");
        assert!(
            listed[0].stale,
            "a vanished book must be labelled, not silently served"
        );

        // 5. and the only thing allowed to remove it.
        let deleted = app
            .download_delete("s1".to_string(), "b1".to_string())
            .unwrap();
        assert!(deleted.files >= 3, "{deleted:?}");
        assert_eq!(count(), 0, "a user delete must take the whole tree");
        assert!(app.download_list("s1".to_string()).unwrap().is_empty());
        cleanup_temp(&db);
    }

    #[test]
    fn unlinking_a_server_leaves_the_queue_and_its_files_in_place() {
        let db = temp_db();
        let app = App::new(&db);
        let mut profile = ServerProfile::new("Home", "http://127.0.0.1:1", AuthType::ApiKey);
        profile.id = "s1".into();
        app.save_server(&profile).unwrap();
        plant_download(&app, "s1", "b1", &[1, 2]);
        let root = app.download_root().unwrap();
        assert_eq!(root.files_in("s1", "b1").len(), 2);

        app.delete_server("s1").unwrap();
        assert_eq!(
            root.files_in("s1", "b1").len(),
            2,
            "deleting the connection threw away the bookshelf"
        );
        // The rows are the only thing that can name these files for deletion, since
        // the directory is spelled with a sanitised id.
        assert_eq!(app.download_list("s1".to_string()).unwrap().len(), 1);
        let storage = app.download_storage(0).unwrap();
        assert!(
            storage.download_bytes > 0,
            "the storage screen forgot downloads"
        );
        app.download_delete_all("s1".to_string()).unwrap();
        assert_eq!(
            root.files_in("s1", "b1").len(),
            0,
            "the gesture does reclaim them"
        );
        cleanup_temp(&db);
    }

    #[test]
    fn a_download_reports_its_bytes_without_entering_the_lru_ledger() {
        let db = temp_db();
        let app = App::new(&db);
        plant_download(&app, "s1", "b1", &[1, 2, 3]);
        let stats = app.reader_cache_stats().unwrap();
        assert!(
            stats.download_bytes > 0,
            "download bytes were reported as zero"
        );
        assert_eq!(
            stats.disk_bytes, 0,
            "a download wrote into the cache tiers: {stats:?}"
        );
        let conn = store::open(&db).unwrap();
        let ledger: i64 = conn
            .query_row("SELECT COUNT(*) FROM cache_entries", [], |row| row.get(0))
            .unwrap();
        assert_eq!(ledger, 0, "a download put a row in the LRU ledger");
        drop(conn);
        cleanup_temp(&db);
    }

    #[test]
    fn the_queue_control_surface_is_all_local_and_moves_state() {
        let db = temp_db();
        let app = App::new(&db);
        plant_book_row(&db, "s1", "b9", "2024-05-11T18:07:33Z");
        let conn = store::open(&db).unwrap();
        for number in 1..=4 {
            let (width, height) = crate::cache::demo_png::page_dimensions(number);
            conn.execute(
                "INSERT OR REPLACE INTO book_pages
                 (server_id, book_id, number, file_name, media_type, width, height, size_bytes, fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                rusqlite::params!["s1", "b9", number as i64, format!("{number:04}.png"),
                    "image/png", width as i64, height as i64,
                    crate::cache::demo_png::demo_page_bytes(number).len() as i64, thumbnails_now()],
            ).unwrap();
        }
        drop(conn);
        let queued = app
            .download_enqueue("s1".to_string(), "b9".to_string())
            .unwrap();
        assert_eq!(queued.state, "waiting");
        assert_eq!(queued.pages_total, 4);
        assert!(
            queued.bytes_total > 0,
            "the queue must know what it is aiming at"
        );
        // The tree and its manifest exist before a single page has been fetched.
        let root = app.download_root().unwrap();
        assert!(root.book_dir("s1", "b9").is_dir());
        let document = downloads::manifest::read_manifest(&root.manifest_path("s1", "b9"))
            .unwrap()
            .expect("a queued book describes itself");
        assert_eq!(document.pages_count, 4);
        assert!(document.pages.is_empty(), "nothing has arrived yet");

        assert_eq!(
            app.download_pause("s1".into(), "b9".into()).unwrap().state,
            "paused"
        );
        assert_eq!(
            app.download_resume("s1".into(), "b9".into()).unwrap().state,
            "waiting"
        );
        assert!(app.download_retry("s1".into(), "b9".into()).unwrap().state == "waiting");
        assert!(
            app.download_set_allow_cellular("s1".into(), "b9".into(), true)
                .unwrap()
                .allow_cellular
        );
        let swept = app.download_sweep().unwrap();
        assert_eq!(swept.books, 1);
        assert_eq!(swept.repairs(), 0, "a healthy queue has nothing to repair");
        // A book that was never mirrored cannot be queued: nothing local can say how
        // many pages it has.
        assert!(app
            .download_enqueue("s1".to_string(), "unseen".to_string())
            .is_err());
        cleanup_temp(&db);
    }

    /// Two pumps on one database must not interleave on the same rows.
    ///
    /// This asserts the slot, not a concurrent `download_pump`: connecting to a dead
    /// loopback port fails inside a single poll, so a test built on that would watch
    /// one pass finish before the second ever started and call it serialisation. The
    /// overlapping case is proven against a server that is genuinely slow — see the
    /// `facade` phase of `scripts/e2e_stage9.sh` and its `pump_none_count`.
    #[test]
    fn one_pump_slot_per_database_until_it_is_held_back() {
        let db = temp_db();
        let first = PumpSlot::claim(&db).expect("the slot is free");
        assert!(
            PumpSlot::claim(&db).is_none(),
            "a second pass got the same slot"
        );
        // A different database is a different queue, and is not held up by this one.
        let other = format!("{db}-second");
        assert!(PumpSlot::claim(&other).is_some());
        drop(first);
        assert!(PumpSlot::claim(&db).is_some(), "the slot never came back");
        drop(PumpSlot::claim(&other));
        // The second key never existed on disk: a slot is a name, not a database.
        cleanup_temp(&db);
    }

    /// The milestone's two-level rule, tested where it is actually applied: the
    /// reader opens a book with what the *series* says, never with what that one
    /// book was last left in.
    ///
    /// This is the FFI-level half of the "I pressed 双页 in volume 3 and now every
    /// book is a spread" bug. `resolve_for_series` has its own unit tests; what
    /// can break here is the wiring — loading the override at all, reading the
    /// series id off the book row, or letting the old per-book tier back in.
    #[tokio::test]
    async fn a_series_override_decides_the_open_mode_and_a_books_own_row_does_not() {
        let db = temp_db();
        let app = App::new(&db);
        plant_book_row(&db, "s1", "b1", "2024-05-11T18:07:33Z");
        plant_download(&app, "s1", "b1", &[1, 2, 3, 4]);

        let conn = store::open(&db).unwrap();
        // The book was last read as a double-page RTL spread, 40% down page 2.
        // Page 2 rather than 3 because a spread layout makes page 2 an entry
        // page: 3 would legitimately land the reader on 2, and this test is
        // about which *settings* win, not about spread arithmetic.
        store::position::save_with_offset(
            &conn,
            "s1",
            "b1",
            2,
            "double",
            "rtl",
            Some(0.4),
            "2024-05-11T18:07:33Z",
        )
        .unwrap();
        drop(conn);

        // The series says LTR, single page — the user's choice for this series.
        let conn = store::open(&db).unwrap();
        reader::series_override::save_override(
            &conn,
            "s1",
            "se1",
            &reader::series_override::SeriesOverride {
                mode: Some(reader::paging::ReadMode::Single),
                direction: Some(reader::paging::Direction::Ltr),
            },
        )
        .unwrap();
        drop(conn);

        let opened = app
            .reader_open(
                "s1".to_string(),
                "b1".to_string(),
                "http://127.0.0.1:1".to_string(),
                "unused".to_string(),
                String::new(),
                String::new(),
                None,
            )
            .await
            .unwrap();

        assert_eq!(
            opened.layout.mode, "single",
            "the book's remembered 双页 must not decide how it opens"
        );
        assert_eq!(
            opened.layout.direction, "ltr",
            "and neither may the RTL it was last read in"
        );
        assert_eq!(
            opened.start_page, 2,
            "the page itself is still personal to the book"
        );
        assert_eq!(
            opened.start_page_offset_ratio,
            Some(0.4),
            "and the scroll position comes back with it"
        );

        // An explicit request still wins: that is how a change the user just made
        // inside the reader reaches the open path.
        let reopened = app
            .reader_open(
                "s1".to_string(),
                "b1".to_string(),
                "http://127.0.0.1:1".to_string(),
                "unused".to_string(),
                "webtoon".to_string(),
                "vertical".to_string(),
                None,
            )
            .await
            .unwrap();
        assert_eq!(reopened.layout.mode, "webtoon");

        cleanup_temp(&db);
    }

    /// A series nobody overrode follows the global preference, and a book that
    /// has no saved offset reports `None` rather than a zero that would claim the
    /// reader is at the top of a page they never scrolled.
    #[tokio::test]
    async fn a_series_without_an_override_follows_the_global_preference() {
        let db = temp_db();
        let app = App::new(&db);
        plant_book_row(&db, "s1", "b1", "2024-05-11T18:07:33Z");
        plant_download(&app, "s1", "b1", &[1, 2, 3]);

        let conn = store::open(&db).unwrap();
        let mut global = reader::settings::ReaderSettings::load(&conn).unwrap();
        global.mode = reader::paging::ReadMode::Double;
        global.direction = reader::paging::Direction::Rtl;
        reader::settings::ReaderSettings::save(&conn, &global).unwrap();
        drop(conn);

        let opened = app
            .reader_open(
                "s1".to_string(),
                "b1".to_string(),
                "http://127.0.0.1:1".to_string(),
                "unused".to_string(),
                String::new(),
                String::new(),
                None,
            )
            .await
            .unwrap();

        assert_eq!(opened.layout.mode, "double");
        assert_eq!(opened.layout.direction, "rtl");
        assert_eq!(opened.start_page_offset_ratio, None);
        assert_eq!(opened.start_page, 1);

        cleanup_temp(&db);
    }

    /// The 条漫 loop, through the two calls the app actually makes.
    ///
    /// `reader_set_page_offset` records where in the page the reader is, and
    /// `reader_open` hands it back. The store's own tests cover the column; what
    /// can break here is the session: whether the offset survives being set after
    /// the open, and whether it is dropped once the reader is no longer on that
    /// page.
    #[tokio::test]
    async fn a_webtoon_scroll_position_survives_a_reopen_on_the_same_page() {
        let db = temp_db();
        let app = App::new(&db);
        plant_book_row(&db, "offset-server", "offset-book", "2024-05-11T18:07:33Z");
        plant_download(&app, "offset-server", "offset-book", &[1, 2, 3, 4]);

        let opened = app
            .reader_open(
                "offset-server".to_string(),
                "offset-book".to_string(),
                "http://127.0.0.1:1".to_string(),
                "unused".to_string(),
                "webtoon".to_string(),
                "vertical".to_string(),
                None,
            )
            .await
            .unwrap();
        assert_eq!(opened.layout.mode, "webtoon");
        assert_eq!(opened.start_page_offset_ratio, None, "全新的书从页首开始");

        app.reader_set_page_offset(
            "offset-server".to_string(),
            "offset-book".to_string(),
            Some(0.62),
        )
        .unwrap();
        // The offset is held in the session, not written per scroll frame: a
        // scroll reports continuously and a write per report would put the whole
        // position row through SQLite on every frame. `close` is what commits it,
        // and the app calls exactly this when the reader screen goes away.
        app.reader_close("offset-server".to_string(), "offset-book".to_string())
            .unwrap();

        let reopened = app
            .reader_open(
                "offset-server".to_string(),
                "offset-book".to_string(),
                "http://127.0.0.1:1".to_string(),
                "unused".to_string(),
                "webtoon".to_string(),
                "vertical".to_string(),
                None,
            )
            .await
            .unwrap();
        assert_eq!(
            reopened.start_page_offset_ratio,
            Some(0.62),
            "读到一半关掉，下次必须回到同一个高度"
        );
        assert_eq!(reopened.start_page, 1);

        // Moving to a different page ends the claim: page 1 at 62% says nothing
        // about page 3, and carrying it over would drop the reader into the
        // middle of a page they have never seen.
        app.reader_turn("offset-server".to_string(), "offset-book".to_string(), 3)
            .unwrap();
        app.reader_close("offset-server".to_string(), "offset-book".to_string())
            .unwrap();
        let after_turn = app
            .reader_open(
                "offset-server".to_string(),
                "offset-book".to_string(),
                "http://127.0.0.1:1".to_string(),
                "unused".to_string(),
                "webtoon".to_string(),
                "vertical".to_string(),
                None,
            )
            .await
            .unwrap();
        assert_eq!(after_turn.start_page, 3);
        assert_eq!(after_turn.start_page_offset_ratio, None);

        cleanup_temp(&db);
    }

    /// An out-of-range ratio is clamped in the session rather than rejected: an
    /// overscroll bounce reports 1.02, and the page is still worth recording.
    #[tokio::test]
    async fn an_out_of_range_scroll_ratio_is_clamped_at_the_session() {
        let db = temp_db();
        let app = App::new(&db);
        plant_book_row(&db, "clamp-server", "clamp-book", "2024-05-11T18:07:33Z");
        plant_download(&app, "clamp-server", "clamp-book", &[1, 2]);

        app.reader_open(
            "clamp-server".to_string(),
            "clamp-book".to_string(),
            "http://127.0.0.1:1".to_string(),
            "unused".to_string(),
            "webtoon".to_string(),
            "vertical".to_string(),
            None,
        )
        .await
        .unwrap();

        app.reader_set_page_offset(
            "clamp-server".to_string(),
            "clamp-book".to_string(),
            Some(1.4),
        )
        .unwrap();
        {
            let guard = readers();
            let live = guard
                .get(&reader_key("clamp-server", "clamp-book"))
                .unwrap();
            assert_eq!(live.session.page_offset_ratio(), Some(1.0));
        }
        app.reader_close("clamp-server".to_string(), "clamp-book".to_string())
            .unwrap();

        // Setting it on a reader that was never opened is an error, not a silent
        // write to a row for a book nobody is reading.
        assert!(app
            .reader_set_page_offset(
                "clamp-server".to_string(),
                "clamp-unopened".to_string(),
                Some(0.5)
            )
            .is_err());

        cleanup_temp(&db);
    }
}
