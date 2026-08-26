//! FullSync — mirrors the whole media library into SQLite.
//!
//! Order follows the bootstrap contract (docs/sync-engine.md):
//! Libraries → Series → Books → Collections → Readlists → Read Progress.
//! The UI reads SQLite while sync runs (local-first), and every query
//! below works with the network disconnected afterwards.
//!
//! The network phase never holds a rusqlite `Connection` across an
//! `await` (rusqlite `Connection` is not `Sync`; the FFI bridge requires
//! `Send` futures), so each page is fetched, written, then dropped.

use crate::api::book::BookFetcher;
use crate::api::collection::CollectionFetcher;
use crate::api::error::{ApiError, Result};
use crate::api::readlist::ReadListFetcher;
pub use crate::api::series::PageRequest;
use crate::model::book::BookPage;
use crate::model::collection::CollectionPage;
use crate::model::readlist::ReadListPage;
use crate::model::series::SeriesPage;
use crate::store;
use crate::sync::bootstrap::SeriesFetcher;

/// Page size used by the local mirror (remote pagination slices).
pub const PAGE_SIZE: u32 = 100;

/// Tally of a full mirror run.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FullSyncSummary {
    pub server_id: String,
    pub series: usize,
    pub books: usize,
    pub collections: usize,
    pub readlists: usize,
    pub read_progress: usize,
    pub series_pages: u32,
    pub book_pages: u32,
}

/// Everything a full mirror needs; `KomgaClient` implements all of these,
/// and fixture-backed fakes drive offline tests.
#[allow(async_fn_in_trait)]
pub trait LibraryFetcher:
    SeriesFetcher + BookFetcher + CollectionFetcher + ReadListFetcher
{
}

impl<T> LibraryFetcher for T where
    T: SeriesFetcher + BookFetcher + CollectionFetcher + ReadListFetcher
{
}

fn db_err(e: rusqlite::Error) -> ApiError {
    ApiError::Database {
        message: e.to_string(),
    }
}

/// Fixture-backed fetcher for offline runs and the demo mode: serves the
/// shared library fixtures (single-page everything, no network). The demo
/// server (`bootstrap_demo`) and the stage4 smoke both use it.
pub(crate) struct FixtureLibraryFetcher {}

impl FixtureLibraryFetcher {
    pub(crate) fn series_page() -> SeriesPage {
        let json = include_str!("../../../../specs/contracts/fixtures/library/series-page.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    pub(crate) fn books_by_series() -> std::collections::HashMap<String, BookPage> {
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

    fn empty_book_page() -> BookPage {
        BookPage {
            content: vec![],
            total_elements: 0,
            total_pages: 0,
            number: 0,
            size: 100,
            first: true,
            last: true,
        }
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

/// Mirror the full media library for one server.
pub async fn full_sync(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
) -> Result<FullSyncSummary> {
    let mut summary = FullSyncSummary {
        server_id: server_id.to_string(),
        ..Default::default()
    };

    // Series: every page (books follow series with a non-zero count).
    let mut series_ids: Vec<String> = Vec::new();
    let mut page = 0u32;
    loop {
        let resp = fetcher
            .series_page(&PageRequest::new(page, PAGE_SIZE))
            .await?;
        let conn = store::open(db_path).map_err(db_err)?;
        summary.series +=
            store::series::save_series_batch(&conn, server_id, &resp.content).map_err(db_err)?;
        drop(conn);
        series_ids.extend(
            resp.content
                .iter()
                .filter(|s| s.books_count.unwrap_or(0) > 0)
                .map(|s| s.id.clone()),
        );
        summary.series_pages += 1;
        if resp.last {
            break;
        }
        page += 1;
    }

    // Books per series (each series may span several pages).
    for series_id in &series_ids {
        let mut page = 0u32;
        loop {
            let resp = fetcher
                .books_page(series_id, &PageRequest::new(page, PAGE_SIZE))
                .await?;
            summary.read_progress += resp
                .content
                .iter()
                .filter(|b| b.read_progress.is_some())
                .count();
            let conn = store::open(db_path).map_err(db_err)?;
            summary.books +=
                store::books::save_books_batch(&conn, server_id, &resp.content).map_err(db_err)?;
            drop(conn);
            summary.book_pages += 1;
            if resp.last {
                break;
            }
            page += 1;
        }
    }

    // Collections (membership is embedded in each CollectionDto).
    let mut page = 0u32;
    loop {
        let resp = fetcher
            .collections_page(&PageRequest::new(page, PAGE_SIZE))
            .await?;
        let conn = store::open(db_path).map_err(db_err)?;
        summary.collections +=
            store::collections::save_collections_batch(&conn, server_id, &resp.content)
                .map_err(db_err)?;
        drop(conn);
        if resp.last {
            break;
        }
        page += 1;
    }

    // Readlists (membership is embedded in each ReadListDto).
    let mut page = 0u32;
    loop {
        let resp = fetcher
            .readlists_page(&PageRequest::new(page, PAGE_SIZE))
            .await?;
        let conn = store::open(db_path).map_err(db_err)?;
        summary.readlists +=
            store::readlists::save_readlists_batch(&conn, server_id, &resp.content)
                .map_err(db_err)?;
        drop(conn);
        if resp.last {
            break;
        }
        page += 1;
    }

    // On-deck shelf: remote read-progress hint for continue reading.
    let resp = fetcher
        .on_deck_page(&PageRequest::new(0, PAGE_SIZE))
        .await?;
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
            summary.read_progress += 1;
        }
    }
    drop(conn);

    // Stage 4: `last_full_sync` stamp + successful-sync record.
    let conn = store::open(db_path).map_err(db_err)?;
    store::sync_state::record_full_sync(&conn, server_id).map_err(db_err)?;
    Ok(summary)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_db() -> String {
        let dir = std::env::temp_dir().join(format!("komga_fullsync_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("comic.sqlite").to_string_lossy().into_owned()
    }

    #[tokio::test]
    async fn full_sync_mirrors_everything_from_shared_fixtures() {
        let db = temp_db();
        let summary = full_sync(&db, "server-1", &FixtureLibraryFetcher {})
            .await
            .unwrap();
        assert_eq!(summary.series, 3);
        assert_eq!(summary.books, 7);
        assert_eq!(summary.collections, 2);
        assert_eq!(summary.readlists, 2);
        assert_eq!(summary.read_progress, 4); // 3 inline (b1-1, b1-2, b2-1) + 1 on-deck (b1-2)

        // Everything landed locally.
        let conn = store::open(&db).unwrap();
        assert_eq!(store::series::count_series(&conn, "server-1").unwrap(), 3);
        let books: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM books WHERE server_id = ?1",
                rusqlite::params!["server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(books, 7);
        let memberships: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM collection_series WHERE server_id = ?1",
                rusqlite::params!["server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(memberships, 3);
        let progress: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM read_progress WHERE server_id = ?1",
                rusqlite::params!["server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(progress, 3); // book-1-1 (read), book-1-2 (in progress), book-2-1 (read)
                                 // FTS built for series + books.
        let fts_hits: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM series_fts WHERE server_id = ?1",
                rusqlite::params!["server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(fts_hits, 3);
        // sync_state carries last_full_sync.
        let state = store::sync_state::get_sync_state(&conn, "server-1")
            .unwrap()
            .expect("sync_state row");
        assert!(state.last_full_sync.is_some());
        assert!(state.last_successful_sync.is_some());
        drop(conn);

        std::fs::remove_dir_all(std::path::Path::new(&db).parent().unwrap()).unwrap();
    }

    #[tokio::test]
    async fn full_sync_is_idempotent() {
        let db = temp_db();
        let first = full_sync(&db, "server-1", &FixtureLibraryFetcher {})
            .await
            .unwrap();
        let second = full_sync(&db, "server-1", &FixtureLibraryFetcher {})
            .await
            .unwrap();
        assert_eq!(first.series, second.series);
        assert_eq!(first.books, second.books);
        assert_eq!(first.collections, second.collections);
        let conn = store::open(&db).unwrap();
        assert_eq!(store::series::count_series(&conn, "server-1").unwrap(), 3);
        drop(conn);
        std::fs::remove_dir_all(std::path::Path::new(&db).parent().unwrap()).unwrap();
    }
}
