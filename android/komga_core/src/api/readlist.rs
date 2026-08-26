//! Komga readlists API — page-based fetch:
//! `GET {base}/api/v1/readlists?page=N&size=M`

use super::auth::AuthMethod;
use super::error::Result;
use super::series::{KomgaClient, PageRequest};
use crate::model::readlist::ReadListPage;

/// Readlists list URL (stable query order: page, size).
pub fn readlists_page_url(base_url: &str, request: &PageRequest) -> String {
    format!(
        "{}/api/v1/readlists?page={}&size={}",
        base_url.trim_end_matches('/'),
        request.page,
        request.size
    )
}

/// Fetching abstraction so full sync can be tested without network.
#[allow(async_fn_in_trait)]
pub trait ReadListFetcher {
    async fn readlists_page(&self, request: &PageRequest) -> Result<ReadListPage>;
}

impl ReadListFetcher for KomgaClient {
    async fn readlists_page(&self, request: &PageRequest) -> Result<ReadListPage> {
        self.get_json(&readlists_page_url(&self.base_url, request))
            .await
    }
}

/// Convenience constructor for tests behind the trait.
pub struct ReadListClient {
    client: KomgaClient,
}

impl ReadListClient {
    pub fn new(base_url: String, auth: AuthMethod) -> Result<Self> {
        Ok(Self {
            client: KomgaClient::new(base_url, auth)?,
        })
    }

    pub fn client(&self) -> &KomgaClient {
        &self.client
    }
}

impl ReadListFetcher for ReadListClient {
    async fn readlists_page(&self, request: &PageRequest) -> Result<ReadListPage> {
        ReadListFetcher::readlists_page(&self.client, request).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readlists_page_url_is_stable() {
        let req = PageRequest::new(0, 100);
        assert_eq!(
            readlists_page_url("https://komga.example.com", &req),
            "https://komga.example.com/api/v1/readlists?page=0&size=100"
        );
    }

    #[test]
    fn decodes_shared_fixture() {
        let json = include_str!("../../../../specs/contracts/fixtures/library/readlists-page.json");
        let page: ReadListPage = serde_json::from_str(json).expect("shared fixture must decode");
        assert_eq!(page.total_elements, 2);
        assert_eq!(page.content[0].id, "rl-1");
        assert_eq!(page.content[0].name, "Weekend Manga");
        assert_eq!(
            page.content[0].book_ids,
            vec!["book-1-1", "book-1-2", "book-2-1"]
        );
        assert!(page.content[0].ordered);
    }
}
