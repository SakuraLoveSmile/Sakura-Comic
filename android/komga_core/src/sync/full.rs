//! Bootstrap Sync — the resumable first mirror of a server's media library.
//!
//! Step order comes from `specs/contracts/initial-sync/README.md`:
//! **Libraries → Series → Books → Collections → Readlists → Read Progress**.
//! Each step pages its endpoint (`PAGE_SIZE` per request), commits one SQLite
//! transaction per page, and records its resume cursor in that same
//! transaction, so an interrupted run continues from the next page instead of
//! re-downloading the library. A failed step keeps its cursor and is flagged
//! `error` in `sync_state`; the next run picks it up automatically.
//!
//! Once a step has completed it is not repeated: keeping the mirror current is
//! Reconcile's job (`sync::reconcile`). `StartAt::Fresh` forces a re-mirror.
//!
//! The UI reads SQLite while this runs (local-first): a partially mirrored
//! library is browsable, just smaller than the final one.
//!
//! The network phase never holds a rusqlite `Connection` across an `await`
//! (`Connection` is not `Sync`, and the FFI bridge requires `Send` futures),
//! so every page is fetched, then opened-written-dropped.

use std::collections::{HashMap, HashSet};

use rusqlite::{params, Connection};

use crate::api::book::BookFetcher;
use crate::api::collection::CollectionFetcher;
use crate::api::error::{ApiError, Result};
use crate::api::readlist::ReadListFetcher;
pub use crate::api::series::PageRequest;
use crate::api::server::LibrariesFetcher;
use crate::model::book::BookPage;
use crate::model::collection::CollectionPage;
use crate::model::readlist::ReadListPage;
use crate::model::series::SeriesPage;
use crate::model::server::Library;
use crate::store;
use crate::store::sync_state;
use crate::sync::bootstrap::SeriesFetcher;

/// Page size used by the local mirror (remote pagination slices).
pub const PAGE_SIZE: u32 = 100;

/// Tally of one mirror run (rows written per step, not local row counts).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FullSyncSummary {
    pub server_id: String,
    pub libraries: usize,
    pub series: usize,
    pub books: usize,
    pub collections: usize,
    pub readlists: usize,
    pub read_progress: usize,
    pub series_pages: u32,
    pub book_pages: u32,
    /// Steps that had already completed, so this run skipped them.
    pub skipped_steps: Vec<String>,
    /// Steps this run continued from a stored cursor (interrupt recovery).
    pub resumed_steps: Vec<String>,
}

/// Everything a mirror run needs; `KomgaClient` implements all of these, and
/// fixture-backed fakes drive offline tests.
#[allow(async_fn_in_trait)]
pub trait LibraryFetcher:
    SeriesFetcher + BookFetcher + CollectionFetcher + ReadListFetcher + LibrariesFetcher
{
}

impl<T> LibraryFetcher for T where
    T: SeriesFetcher + BookFetcher + CollectionFetcher + ReadListFetcher + LibrariesFetcher
{
}

/// Whether to continue from the stored cursors or start the mirror over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StartAt {
    /// Continue from the first step that has unfinished work.
    Resume,
    /// Forget every cursor and re-mirror from the top (manual rebuild).
    Fresh,
}

fn db_err(e: rusqlite::Error) -> ApiError {
    ApiError::Database {
        message: e.to_string(),
    }
}

/// `"page=3"` → `3`; an unparseable cursor restarts that step at page 0.
pub(crate) fn parse_page(cursor: &str) -> u32 {
    cursor
        .strip_prefix("page=")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

pub(crate) fn page_cursor(page: u32) -> String {
    format!("page={page}")
}

/// Books are swept series by series (in `remote_id` order), so their cursor
/// names the series plus the page within it: `"series=s2|page=1"`.
pub(crate) fn book_cursor(series_id: &str, page: u32) -> String {
    format!("series={series_id}|page={page}")
}

pub(crate) fn parse_book_cursor(cursor: &str) -> Option<(String, u32)> {
    let mut series: Option<String> = None;
    let mut page: Option<u32> = None;
    for pair in cursor.split('|') {
        if let Some(v) = pair.strip_prefix("series=") {
            series = Some(v.to_string());
        } else if let Some(v) = pair.strip_prefix("page=") {
            page = v.parse().ok();
        }
    }
    Some((series?, page?))
}

/// The stored resume cursor for one step (`None` = start from the beginning).
pub(crate) fn cursor_for(db_path: &str, server_id: &str, entity: &str) -> Result<Option<String>> {
    let conn = store::open(db_path).map_err(db_err)?;
    sync_state::resume_cursor(&conn, server_id, entity).map_err(db_err)
}

/// Run one step, recording its status transitions (`syncing` → `idle`/`error`).
pub(crate) async fn run_step<S, F>(
    db_path: &str,
    server_id: &str,
    entity: &str,
    work: F,
) -> Result<S>
where
    F: std::future::Future<Output = Result<S>>,
{
    let conn = store::open(db_path).map_err(db_err)?;
    sync_state::begin_entity(&conn, server_id, entity).map_err(db_err)?;
    drop(conn);
    match work.await {
        Ok(value) => {
            let conn = store::open(db_path).map_err(db_err)?;
            sync_state::complete_entity(&conn, server_id, entity).map_err(db_err)?;
            Ok(value)
        }
        Err(error) => {
            // Error recovery: keep the cursor so the next run resumes, and
            // surface the failure on both the step row and the rollup row.
            if let Ok(conn) = store::open(db_path) {
                let _ = sync_state::fail_entity(&conn, server_id, entity, &error.to_string());
                let _ = sync_state::touch_failed_sync(&conn, server_id, &error.to_string());
            }
            Err(error)
        }
    }
}

/// Mirror count of a table for one server (fixture tests / smoke output).
pub fn local_count(conn: &Connection, server_id: &str, table: &str) -> Result<i64> {
    let allowed = [
        "libraries",
        "series",
        "books",
        "collections",
        "readlists",
        "read_progress",
    ];
    if !allowed.contains(&table) {
        return Err(ApiError::Decode {
            message: format!("table {table} is not a mirror table"),
        });
    }
    conn.query_row(
        &format!("SELECT COUNT(*) FROM {table} WHERE server_id = ?1"),
        params![server_id],
        |row| row.get(0),
    )
    .map_err(db_err)
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

/// 1.  Libraries: `GET /api/v1/libraries` returns a plain array, so this
///     step is one request — it still runs first and is still checkpointed,
///     so a later interrupted step never re-triggers it.
async fn sync_libraries(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibrariesFetcher + Sync),
) -> Result<usize> {
    run_step(db_path, server_id, sync_state::ENTITY_LIBRARIES, async {
        let libraries = fetcher.libraries().await?;
        let conn = store::open(db_path).map_err(db_err)?;
        store::libraries::save_libraries_batch(&conn, server_id, &libraries).map_err(db_err)
    })
    .await
}

/// 2. Series: page sweep until `last`.
async fn sync_series(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl SeriesFetcher + Sync),
) -> Result<(usize, u32)> {
    run_step(db_path, server_id, sync_state::ENTITY_SERIES, async {
        let mut page = match cursor_for(db_path, server_id, sync_state::ENTITY_SERIES)? {
            Some(cursor) => parse_page(&cursor),
            None => 0,
        };
        let mut written = 0usize;
        let mut pages = 0u32;
        loop {
            let resp = fetcher
                .series_page(&PageRequest::new(page, PAGE_SIZE))
                .await?;
            let last = resp.last;
            let conn = store::open(db_path).map_err(db_err)?;
            written += store::series::save_series_batch(&conn, server_id, &resp.content)
                .map_err(db_err)?;
            if !last {
                sync_state::checkpoint_entity(
                    &conn,
                    server_id,
                    sync_state::ENTITY_SERIES,
                    &page_cursor(page + 1),
                )
                .map_err(db_err)?;
            }
            drop(conn);
            pages += 1;
            if last {
                return Ok((written, pages));
            }
            page += 1;
        }
    })
    .await
}

/// 3.  Books: sweep every local series — including ones that now look empty,
///     because those are where a remote book deletion shows up.
async fn sync_books(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl BookFetcher + Sync),
) -> Result<(usize, u32, usize)> {
    let series_ids = mirrored_series_ids(db_path, server_id)?;
    let resume = match cursor_for(db_path, server_id, sync_state::ENTITY_BOOKS)? {
        Some(cursor) => parse_book_cursor(&cursor),
        None => None,
    };
    run_step(db_path, server_id, sync_state::ENTITY_BOOKS, async {
        let mut index = 0usize;
        if let Some((resume_series, _)) = &resume {
            // Skip the series a previous run finished. The cursor names the
            // series that was still in progress, so that one is re-entered at
            // `resume_page` below — stepping past it would silently drop the
            // rest of its pages.
            while index < series_ids.len() && &series_ids[index] < resume_series {
                index += 1;
            }
        }
        let mut written = 0usize;
        let mut pages = 0u32;
        let mut progress = 0usize;
        while index < series_ids.len() {
            let series_id = &series_ids[index];
            let mut page = match &resume {
                Some((resume_series, resume_page)) if resume_series == series_id => *resume_page,
                _ => 0,
            };
            loop {
                let resp = fetcher
                    .books_page(series_id, &PageRequest::new(page, PAGE_SIZE))
                    .await?;
                progress += resp
                    .content
                    .iter()
                    .filter(|b| b.read_progress.is_some())
                    .count();
                let last = resp.last;
                let conn = store::open(db_path).map_err(db_err)?;
                written += store::books::save_books_batch(&conn, server_id, &resp.content)
                    .map_err(db_err)?;
                pages += 1;
                if !last {
                    sync_state::checkpoint_entity(
                        &conn,
                        server_id,
                        sync_state::ENTITY_BOOKS,
                        &book_cursor(series_id, page + 1),
                    )
                    .map_err(db_err)?;
                }
                drop(conn);
                if last {
                    break;
                }
                page += 1;
            }
            index += 1;
            // Checkpoint the series boundary too: a run interrupted at the next
            // series' first page would otherwise restart from the top.
            if let Some(next) = series_ids.get(index) {
                let conn = store::open(db_path).map_err(db_err)?;
                sync_state::checkpoint_entity(
                    &conn,
                    server_id,
                    sync_state::ENTITY_BOOKS,
                    &book_cursor(next, 0),
                )
                .map_err(db_err)?;
            }
        }
        Ok((written, pages, progress))
    })
    .await
}

/// 4. Collections (membership rides along in each CollectionDto).
async fn sync_collections(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl CollectionFetcher + Sync),
) -> Result<usize> {
    run_step(db_path, server_id, sync_state::ENTITY_COLLECTIONS, async {
        let mut page = match cursor_for(db_path, server_id, sync_state::ENTITY_COLLECTIONS)? {
            Some(cursor) => parse_page(&cursor),
            None => 0,
        };
        let mut written = 0usize;
        loop {
            let resp = fetcher
                .collections_page(&PageRequest::new(page, PAGE_SIZE))
                .await?;
            let last = resp.last;
            let conn = store::open(db_path).map_err(db_err)?;
            written += store::collections::save_collections_batch(&conn, server_id, &resp.content)
                .map_err(db_err)?;
            if !last {
                sync_state::checkpoint_entity(
                    &conn,
                    server_id,
                    sync_state::ENTITY_COLLECTIONS,
                    &page_cursor(page + 1),
                )
                .map_err(db_err)?;
            }
            drop(conn);
            if last {
                return Ok(written);
            }
            page += 1;
        }
    })
    .await
}

/// 5. Readlists (ordered membership rides along in each ReadListDto).
async fn sync_readlists(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl ReadListFetcher + Sync),
) -> Result<usize> {
    run_step(db_path, server_id, sync_state::ENTITY_READLISTS, async {
        let mut page = match cursor_for(db_path, server_id, sync_state::ENTITY_READLISTS)? {
            Some(cursor) => parse_page(&cursor),
            None => 0,
        };
        let mut written = 0usize;
        loop {
            let resp = fetcher
                .readlists_page(&PageRequest::new(page, PAGE_SIZE))
                .await?;
            let last = resp.last;
            let conn = store::open(db_path).map_err(db_err)?;
            written += store::readlists::save_readlists_batch(&conn, server_id, &resp.content)
                .map_err(db_err)?;
            if !last {
                sync_state::checkpoint_entity(
                    &conn,
                    server_id,
                    sync_state::ENTITY_READLISTS,
                    &page_cursor(page + 1),
                )
                .map_err(db_err)?;
            }
            drop(conn);
            if last {
                return Ok(written);
            }
            page += 1;
        }
    })
    .await
}

/// 6. Read progress: the on-deck shelf is the remote continue-reading hint.
async fn sync_read_progress(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl BookFetcher + Sync),
) -> Result<usize> {
    run_step(
        db_path,
        server_id,
        sync_state::ENTITY_READ_PROGRESS,
        async {
            let mut page = match cursor_for(db_path, server_id, sync_state::ENTITY_READ_PROGRESS)? {
                Some(cursor) => parse_page(&cursor),
                None => 0,
            };
            let mut applied = 0usize;
            loop {
                let resp = fetcher
                    .on_deck_page(&PageRequest::new(page, PAGE_SIZE))
                    .await?;
                let last = resp.last;
                let conn = store::open(db_path).map_err(db_err)?;
                for book in &resp.content {
                    if let Some(progress) = &book.read_progress {
                        store::read_progress::upsert_synced_read_progress(
                            &conn,
                            server_id,
                            &book.id,
                            progress.page,
                            progress.completed,
                            progress.last_modified.clone(),
                        )
                        .map_err(db_err)?;
                        applied += 1;
                    }
                }
                if !last {
                    sync_state::checkpoint_entity(
                        &conn,
                        server_id,
                        sync_state::ENTITY_READ_PROGRESS,
                        &page_cursor(page + 1),
                    )
                    .map_err(db_err)?;
                }
                drop(conn);
                if last {
                    return Ok(applied);
                }
                page += 1;
            }
        },
    )
    .await
}

// ---------------------------------------------------------------------------
// The ordered run
// ---------------------------------------------------------------------------

/// True when a step finished in an earlier run and needs no work now.
fn step_is_complete(db_path: &str, server_id: &str, entity: &str) -> Result<bool> {
    let conn = store::open(db_path).map_err(db_err)?;
    let state = sync_state::get_entity_state(&conn, server_id, entity).map_err(db_err)?;
    Ok(match state {
        Some(state) => state.sync_cursor.is_none() && state.sync_status == sync_state::STATUS_IDLE,
        None => false,
    })
}

/// Decide whether to run a step, and note resume/skip decisions on the summary.
fn step_plan(
    db_path: &str,
    server_id: &str,
    entity: &str,
    summary: &mut FullSyncSummary,
) -> Result<bool> {
    if step_is_complete(db_path, server_id, entity)? {
        summary.skipped_steps.push(entity.to_string());
        return Ok(false);
    }
    if cursor_for(db_path, server_id, entity)?.is_some() {
        summary.resumed_steps.push(entity.to_string());
    }
    Ok(true)
}

/// Bootstrap Sync: mirror the whole media library for one server, continuing
/// from wherever a previous run stopped.
pub async fn bootstrap_sync(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
) -> Result<FullSyncSummary> {
    full_sync_from(db_path, server_id, fetcher, StartAt::Resume).await
}

/// Same run with an explicit restart policy.
pub async fn full_sync_from(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
    start: StartAt,
) -> Result<FullSyncSummary> {
    let mut summary = FullSyncSummary {
        server_id: server_id.to_string(),
        ..Default::default()
    };
    if start == StartAt::Fresh {
        clear_progress(db_path, server_id)?;
    }

    if step_plan(
        db_path,
        server_id,
        sync_state::ENTITY_LIBRARIES,
        &mut summary,
    )? {
        summary.libraries = sync_libraries(db_path, server_id, fetcher).await?;
    }
    if step_plan(db_path, server_id, sync_state::ENTITY_SERIES, &mut summary)? {
        let (series, pages) = sync_series(db_path, server_id, fetcher).await?;
        summary.series += series;
        summary.series_pages += pages;
    }
    if step_plan(db_path, server_id, sync_state::ENTITY_BOOKS, &mut summary)? {
        let (books, pages, progress) = sync_books(db_path, server_id, fetcher).await?;
        summary.books += books;
        summary.book_pages += pages;
        summary.read_progress += progress;
    }
    if step_plan(
        db_path,
        server_id,
        sync_state::ENTITY_COLLECTIONS,
        &mut summary,
    )? {
        summary.collections = sync_collections(db_path, server_id, fetcher).await?;
    }
    if step_plan(
        db_path,
        server_id,
        sync_state::ENTITY_READLISTS,
        &mut summary,
    )? {
        summary.readlists = sync_readlists(db_path, server_id, fetcher).await?;
    }
    if step_plan(
        db_path,
        server_id,
        sync_state::ENTITY_READ_PROGRESS,
        &mut summary,
    )? {
        summary.read_progress += sync_read_progress(db_path, server_id, fetcher).await?;
    }

    let conn = store::open(db_path).map_err(db_err)?;
    sync_state::record_full_sync(&conn, server_id).map_err(db_err)?;
    Ok(summary)
}

/// Kept for the Stage 3/4 call sites: a completed-library run is a no-op.
pub async fn full_sync(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
) -> Result<FullSyncSummary> {
    bootstrap_sync(db_path, server_id, fetcher).await
}

/// Drop every step cursor + completion stamp (what `StartAt::Fresh` does).
pub fn clear_progress(db_path: &str, server_id: &str) -> Result<()> {
    let conn = store::open(db_path).map_err(db_err)?;
    conn.execute(
        "DELETE FROM sync_state WHERE server_id = ?1 AND entity_type != ?2",
        params![server_id, sync_state::ENTITY_FULL],
    )
    .map_err(db_err)?;
    Ok(())
}

/// Ids currently mirrored for one entity type (diff input for Reconcile).
pub fn mirrored_ids(db_path: &str, server_id: &str, entity: &str) -> Result<HashSet<String>> {
    let conn = store::open(db_path).map_err(db_err)?;
    Ok(HashSet::from_iter(
        store::prune::local_ids(&conn, server_id, entity).map_err(db_err)?,
    ))
}

/// Series ids mirrored locally, in sweep order (Books step input).
pub fn mirrored_series_ids(db_path: &str, server_id: &str) -> Result<Vec<String>> {
    let conn = store::open(db_path).map_err(db_err)?;
    let mut stmt = conn
        .prepare("SELECT remote_id FROM series WHERE server_id = ?1 ORDER BY remote_id")
        .map_err(db_err)?;
    let rows = stmt
        .query_map(params![server_id], |row| row.get::<_, String>(0))
        .map_err(db_err)?;
    rows.collect::<rusqlite::Result<_>>().map_err(db_err)
}

/// Fixture-backed fetcher for offline runs and the demo mode: serves the
/// shared library fixtures (single-page everything, no network). The demo
/// server (`bootstrap_demo`) and the stage4/stage5 smoke both use it.
pub struct FixtureLibraryFetcher {}

impl FixtureLibraryFetcher {
    pub(crate) fn series_page() -> SeriesPage {
        let json = include_str!("../../../../specs/contracts/fixtures/library/series-page.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    pub(crate) fn books_by_series() -> HashMap<String, BookPage> {
        let json =
            include_str!("../../../../specs/contracts/fixtures/library/books-by-series.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    pub(crate) fn collections_page() -> CollectionPage {
        let json =
            include_str!("../../../../specs/contracts/fixtures/library/collections-page.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    pub(crate) fn readlists_page() -> ReadListPage {
        let json = include_str!("../../../../specs/contracts/fixtures/library/readlists-page.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    pub(crate) fn on_deck_page() -> BookPage {
        let json = include_str!("../../../../specs/contracts/fixtures/library/ondeck-page.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    pub(crate) fn libraries() -> Vec<Library> {
        let json = include_str!("../../../../specs/contracts/fixtures/library/libraries.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    fn empty_book_page() -> BookPage {
        BookPage {
            content: vec![],
            total_elements: 0,
            total_pages: 0,
            number: 0,
            size: PAGE_SIZE as i64,
            first: true,
            last: true,
        }
    }
}

impl LibrariesFetcher for FixtureLibraryFetcher {
    async fn libraries(&self) -> Result<Vec<Library>> {
        Ok(Self::libraries())
    }
}

impl SeriesFetcher for FixtureLibraryFetcher {
    async fn series_page(&self, request: &PageRequest) -> Result<SeriesPage> {
        let mut page = Self::series_page();
        // Single page: page > 0 yields an empty final page.
        if request.page > 0 {
            page.content = vec![];
            page.total_elements = 0;
            page.first = false;
            page.last = true;
        }
        Ok(page)
    }
}

impl BookFetcher for FixtureLibraryFetcher {
    async fn books_page(&self, series_id: &str, request: &PageRequest) -> Result<BookPage> {
        if request.page > 0 {
            return Ok(Self::empty_book_page());
        }
        match Self::books_by_series().get(series_id) {
            Some(page) => Ok(page.clone()),
            None => Ok(Self::empty_book_page()),
        }
    }

    async fn on_deck_page(&self, _request: &PageRequest) -> Result<BookPage> {
        Ok(Self::on_deck_page())
    }
}

impl CollectionFetcher for FixtureLibraryFetcher {
    async fn collections_page(&self, _request: &PageRequest) -> Result<CollectionPage> {
        Ok(Self::collections_page())
    }
}

impl ReadListFetcher for FixtureLibraryFetcher {
    async fn readlists_page(&self, _request: &PageRequest) -> Result<ReadListPage> {
        Ok(Self::readlists_page())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) fn temp_db() -> String {
        let dir = std::env::temp_dir().join(format!("komga_fullsync_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("comic.sqlite").to_string_lossy().into_owned()
    }

    pub(crate) fn cleanup(db: &str) {
        let _ = std::fs::remove_dir_all(std::path::Path::new(db).parent().unwrap());
    }

    #[tokio::test]
    async fn full_sync_mirrors_everything_from_shared_fixtures() {
        let db = temp_db();
        let summary = bootstrap_sync(&db, "server-1", &FixtureLibraryFetcher {})
            .await
            .unwrap();
        assert_eq!(summary.libraries, 2);
        assert_eq!(summary.series, 3);
        assert_eq!(summary.books, 7);
        assert_eq!(summary.collections, 2);
        assert_eq!(summary.readlists, 2);
        assert_eq!(summary.read_progress, 4); // 3 inline (b1-1, b1-2, b2-1) + 1 on-deck (b1-2)
        assert!(summary.skipped_steps.is_empty());
        assert!(summary.resumed_steps.is_empty());

        // Everything landed locally.
        let conn = store::open(&db).unwrap();
        assert_eq!(store::series::count_series(&conn, "server-1").unwrap(), 3);
        let books: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM books WHERE server_id = ?1",
                params!["server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(books, 7);
        let memberships: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM collection_series WHERE server_id = ?1",
                params!["server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(memberships, 3);
        let progress: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM read_progress WHERE server_id = ?1",
                params!["server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(progress, 3); // book-1-1 (read), book-1-2 (in progress), book-2-1 (read)
                                 // FTS built for series + books.
        let fts_hits: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM series_fts WHERE server_id = ?1",
                params!["server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(fts_hits, 3);
        // Every bootstrap step recorded its own completion, cursor cleared.
        for entity in sync_state::BOOTSTRAP_ORDER {
            let state = sync_state::get_entity_state(&conn, "server-1", entity)
                .unwrap()
                .unwrap_or_else(|| panic!("{entity} step row"));
            assert_eq!(state.sync_status, sync_state::STATUS_IDLE, "{entity}");
            assert!(state.sync_cursor.is_none(), "{entity} left a cursor");
            assert!(state.last_sync_at.is_some(), "{entity}");
        }
        // sync_state carries last_full_sync.
        let state = sync_state::get_sync_state(&conn, "server-1")
            .unwrap()
            .expect("sync_state row");
        assert!(state.last_full_sync.is_some());
        assert!(state.last_successful_sync.is_some());
        drop(conn);
        cleanup(&db);
    }

    #[tokio::test]
    async fn full_sync_from_scratch_is_idempotent() {
        let db = temp_db();
        let first = full_sync_from(&db, "server-1", &FixtureLibraryFetcher {}, StartAt::Fresh)
            .await
            .unwrap();
        let second = full_sync_from(&db, "server-1", &FixtureLibraryFetcher {}, StartAt::Fresh)
            .await
            .unwrap();
        assert_eq!(first.series, second.series);
        assert_eq!(first.books, second.books);
        assert_eq!(first.collections, second.collections);
        let conn = store::open(&db).unwrap();
        assert_eq!(store::series::count_series(&conn, "server-1").unwrap(), 3);
        assert_eq!(local_count(&conn, "server-1", "books").unwrap(), 7);
        drop(conn);
        cleanup(&db);
    }

    #[tokio::test]
    async fn a_completed_bootstrap_is_not_remirrored() {
        let db = temp_db();
        bootstrap_sync(&db, "server-1", &FixtureLibraryFetcher {})
            .await
            .unwrap();
        let second = bootstrap_sync(&db, "server-1", &FixtureLibraryFetcher {})
            .await
            .unwrap();
        // Keeping the mirror current is Reconcile's job; Bootstrap skips
        // steps it already finished.
        assert_eq!(second.skipped_steps, sync_state::BOOTSTRAP_ORDER.to_vec());
        assert_eq!(second.series, 0);
        let conn = store::open(&db).unwrap();
        assert_eq!(local_count(&conn, "server-1", "books").unwrap(), 7);
        drop(conn);
        cleanup(&db);
    }
}
