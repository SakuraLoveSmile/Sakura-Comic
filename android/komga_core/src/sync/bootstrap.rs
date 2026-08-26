//! BootstrapSync — the first page of Series is mirrored into SQLite as it
//! arrives; the UI reads the local store immediately (local-first, no need
//! to wait for a full sync).

use rusqlite::Connection;

use crate::api::error::ApiError;
use crate::api::series::{KomgaClient, PageRequest, SeriesPage};
use crate::store;

/// Result of a bootstrap run (Phase 0 mirrors the first page only).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapSummary {
    pub server_id: String,
    pub synced_series: usize,
    pub total_elements: i64,
    pub has_more_pages: bool,
}

/// Abstraction over the series endpoint so bootstrap can be tested without
/// network (fake fetcher in tests). KomgaClient implements it.
#[allow(async_fn_in_trait)]
pub trait SeriesFetcher {
    async fn series_page(&self, request: &PageRequest) -> Result<SeriesPage, ApiError>;
}

impl SeriesFetcher for KomgaClient {
    async fn series_page(&self, request: &PageRequest) -> Result<SeriesPage, ApiError> {
        KomgaClient::series_page(self, request).await
    }
}

/// Fetch page 0 (size 10) — network only, no DB handle in scope, so the
/// future stays `Send` for the FFI bridge (rusqlite `Connection` is not
/// `Sync` and must never be held across an `await`).
pub async fn fetch_bootstrap_page<F: SeriesFetcher + Sync>(
    fetcher: &F,
) -> Result<SeriesPage, ApiError> {
    fetcher.series_page(&PageRequest::new(0, 10)).await
}

/// Write a fetched page into the local store and produce the summary.
/// Synchronous — never called across an `await`.
pub fn bootstrap_page_to_store(
    conn: &Connection,
    server_id: &str,
    page: &SeriesPage,
) -> Result<BootstrapSummary, ApiError> {
    let written =
        store::series::save_series_batch(conn, server_id, &page.content).map_err(|e| {
            ApiError::Database {
                message: e.to_string(),
            }
        })?;
    Ok(BootstrapSummary {
        server_id: server_id.to_string(),
        synced_series: written,
        total_elements: page.total_elements,
        has_more_pages: !page.last,
    })
}

/// Convenience for tests and host tooling: fetch, then write.
/// Not used on the FFI path (the caller must not hold `conn` across an await).
pub async fn bootstrap_series<F: SeriesFetcher + Sync>(
    conn: &Connection,
    fetcher: &F,
    server_id: &str,
) -> Result<BootstrapSummary, ApiError> {
    let page = fetch_bootstrap_page(fetcher).await?;
    bootstrap_page_to_store(conn, server_id, &page)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    struct FakeFetcher(SeriesPage);

    impl SeriesFetcher for FakeFetcher {
        async fn series_page(&self, _request: &PageRequest) -> Result<SeriesPage, ApiError> {
            Ok(self.0.clone())
        }
    }

    fn fixture_page() -> SeriesPage {
        let json =
            include_str!("../../../../specs/contracts/fixtures/initial-sync/series-page.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    #[tokio::test]
    async fn bootstrap_writes_first_page_to_store() {
        let conn = open_in_memory().unwrap();
        let summary = bootstrap_series(&conn, &FakeFetcher(fixture_page()), "server-1")
            .await
            .unwrap();
        assert_eq!(summary.synced_series, 3);
        assert_eq!(summary.total_elements, 3);
        assert!(!summary.has_more_pages);
        assert_eq!(store::series::count_series(&conn, "server-1").unwrap(), 3);
        assert_eq!(store::series::count_series(&conn, "server-2").unwrap(), 0);
    }
}
