//! Komga books API — page-based fetch for a series' books plus the
//! on-deck shelf (continue reading):
//! `GET {base}/api/v1/series/{seriesId}/books?page=N&size=M`
//! `GET {base}/api/v1/books/ondeck?page=N&size=M`

use super::auth::AuthMethod;
use super::error::Result;
use super::series::{KomgaClient, PageRequest};
use crate::model::book::BookPage;

/// Books list URL for one series (stable query order: page, size).
pub fn books_page_url(base_url: &str, series_id: &str, request: &PageRequest) -> String {
    let mut url = format!(
        "{}/api/v1/series/{}/books?page={}&size={}",
        base_url.trim_end_matches('/'),
        series_id,
        request.page,
        request.size
    );
    if let Some(sort) = &request.sort {
        url.push_str(&format!("&sort={sort}"));
    }
    url
}

/// On-deck (continue reading) URL.
pub fn on_deck_url(base_url: &str, request: &PageRequest) -> String {
    let mut url = format!(
        "{}/api/v1/books/ondeck?page={}&size={}",
        base_url.trim_end_matches('/'),
        request.page,
        request.size
    );
    if let Some(sort) = &request.sort {
        url.push_str(&format!("&sort={sort}"));
    }
    url
}

/// Komga book thumbnail endpoint (used by the cover cache).
pub fn book_thumbnail_url(base_url: &str, book_id: &str) -> String {
    format!(
        "{}/api/v1/books/{}/thumbnail",
        base_url.trim_end_matches('/'),
        book_id
    )
}

/// Fetching abstraction so full sync can be tested without network.
#[allow(async_fn_in_trait)]
pub trait BookFetcher {
    async fn books_page(&self, series_id: &str, request: &PageRequest) -> Result<BookPage>;
    async fn on_deck_page(&self, request: &PageRequest) -> Result<BookPage>;
}

impl BookFetcher for KomgaClient {
    async fn books_page(&self, series_id: &str, request: &PageRequest) -> Result<BookPage> {
        self.get_json(&books_page_url(&self.base_url, series_id, request))
            .await
    }

    async fn on_deck_page(&self, request: &PageRequest) -> Result<BookPage> {
        self.get_json(&on_deck_url(&self.base_url, request)).await
    }
}

/// Convenience constructor for tests behind the trait (keeps `Client` out
/// of trait bounds).
pub struct BookClient {
    client: KomgaClient,
}

impl BookClient {
    pub fn new(base_url: String, auth: AuthMethod) -> Result<Self> {
        Ok(Self {
            client: KomgaClient::new(base_url, auth)?,
        })
    }

    pub fn client(&self) -> &KomgaClient {
        &self.client
    }
}

impl BookFetcher for BookClient {
    async fn books_page(&self, series_id: &str, request: &PageRequest) -> Result<BookPage> {
        BookFetcher::books_page(&self.client, series_id, request).await
    }

    async fn on_deck_page(&self, request: &PageRequest) -> Result<BookPage> {
        BookFetcher::on_deck_page(&self.client, request).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn books_page_url_is_stable() {
        let req = PageRequest::new(2, 100);
        assert_eq!(
            books_page_url("https://komga.example.com", "s1", &req),
            "https://komga.example.com/api/v1/series/s1/books?page=2&size=100"
        );
        assert_eq!(
            books_page_url("https://example.com/komga/", "s2", &req),
            "https://example.com/komga/api/v1/series/s2/books?page=2&size=100"
        );
    }

    #[test]
    fn on_deck_url_is_stable() {
        let req = PageRequest::new(0, 50);
        assert_eq!(
            on_deck_url("https://komga.example.com", &req),
            "https://komga.example.com/api/v1/books/ondeck?page=0&size=50"
        );
    }

    #[test]
    fn book_thumbnail_url_is_stable() {
        assert_eq!(
            book_thumbnail_url("https://komga.example.com", "b1"),
            "https://komga.example.com/api/v1/books/b1/thumbnail"
        );
    }

    #[test]
    fn decodes_shared_fixture() {
        let json =
            include_str!("../../../../specs/contracts/fixtures/library/books-by-series.json");
        let map: std::collections::HashMap<String, BookPage> =
            serde_json::from_str(json).expect("shared fixture must decode");
        let page = &map["series-1"];
        assert_eq!(page.total_elements, 3);
        assert_eq!(page.content.len(), 3);
        let first = &page.content[0];
        assert_eq!(first.id, "book-1-1");
        assert_eq!(first.series_title.as_deref(), Some("One Piece"));
        assert_eq!(first.metadata.as_ref().unwrap().number_sort, Some(1.0));
        let progress = first.read_progress.as_ref().expect("book-1-1 is read");
        assert!(progress.completed);
        assert_eq!(progress.page, Some(20));
    }
}
