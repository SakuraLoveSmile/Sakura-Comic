//! Komga collections API — page-based fetch:
//! `GET {base}/api/v1/collections?page=N&size=M[&search=...]`

use super::auth::AuthMethod;
use super::error::Result;
use super::series::{KomgaClient, PageRequest};
use crate::model::collection::CollectionPage;

/// Collections list URL (stable query order: page, size, search).
pub fn collections_page_url(base_url: &str, request: &PageRequest, search: Option<&str>) -> String {
    let mut url = format!(
        "{}/api/v1/collections?page={}&size={}",
        base_url.trim_end_matches('/'),
        request.page,
        request.size
    );
    if let Some(term) = search {
        url.push_str(&format!("&search={term}"));
    }
    url
}

/// Fetching abstraction so full sync can be tested without network.
#[allow(async_fn_in_trait)]
pub trait CollectionFetcher {
    async fn collections_page(&self, request: &PageRequest) -> Result<CollectionPage>;
}

impl CollectionFetcher for KomgaClient {
    async fn collections_page(&self, request: &PageRequest) -> Result<CollectionPage> {
        self.get_json(&collections_page_url(&self.base_url, request, None))
            .await
    }
}

/// Convenience constructor for tests behind the trait.
pub struct CollectionClient {
    client: KomgaClient,
}

impl CollectionClient {
    pub fn new(base_url: String, auth: AuthMethod) -> Result<Self> {
        Ok(Self {
            client: KomgaClient::new(base_url, auth)?,
        })
    }

    pub fn client(&self) -> &KomgaClient {
        &self.client
    }
}

impl CollectionFetcher for CollectionClient {
    async fn collections_page(&self, request: &PageRequest) -> Result<CollectionPage> {
        CollectionFetcher::collections_page(&self.client, request).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collections_page_url_is_stable() {
        let req = PageRequest::new(1, 100);
        assert_eq!(
            collections_page_url("https://komga.example.com", &req, None),
            "https://komga.example.com/api/v1/collections?page=1&size=100"
        );
        assert_eq!(
            collections_page_url("https://example.com/komga/", &req, Some("fav")),
            "https://example.com/komga/api/v1/collections?page=1&size=100&search=fav"
        );
    }

    #[test]
    fn decodes_shared_fixture() {
        let json =
            include_str!("../../../../specs/contracts/fixtures/library/collections-page.json");
        let page: CollectionPage = serde_json::from_str(json).expect("shared fixture must decode");
        assert_eq!(page.total_elements, 2);
        assert_eq!(page.content[0].id, "col-1");
        assert_eq!(page.content[0].name, "Favorites");
        assert_eq!(page.content[0].series_ids, vec!["series-1", "series-3"]);
        assert_eq!(page.content[1].series_ids, vec!["series-2"]);
    }
}
