//! Komga series API — page-based fetch (behavior contract with Swift):
//! GET {base}/api/v1/series?page=N&size=M[&sort=...]

use std::time::Duration;

use reqwest::header::HeaderMap;
use reqwest::Client;

pub use crate::model::series::SeriesPage;

use super::auth::AuthMethod;
use super::error::{ApiError, Result};

/// Page-based query shared by both clients (fixtures in specs/contracts).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageRequest {
    pub page: u32,
    pub size: u32,
    pub sort: Option<String>,
}

impl PageRequest {
    pub fn new(page: u32, size: u32) -> Self {
        Self {
            page,
            size,
            sort: None,
        }
    }

    /// Query pairs in stable order: page, size, sort.
    pub fn to_query_pairs(&self) -> Vec<(String, String)> {
        let mut pairs = vec![
            ("page".to_string(), self.page.to_string()),
            ("size".to_string(), self.size.to_string()),
        ];
        if let Some(sort) = &self.sort {
            pairs.push(("sort".to_string(), sort.clone()));
        }
        pairs
    }
}

/// Build the series list URL (exposed for tests and Swift/Rust parity checks).
pub fn series_page_url(base_url: &str, request: &PageRequest) -> String {
    let mut url = format!("{}/api/v1/series", base_url.trim_end_matches('/'));
    let mut first = true;
    for (key, value) in request.to_query_pairs() {
        url.push_str(if first { "?" } else { "&" });
        first = false;
        url.push_str(&format!("{key}={value}"));
    }
    url
}

/// Komga series thumbnail endpoint (used by the cover cache).
pub fn series_thumbnail_url(base_url: &str, series_id: &str) -> String {
    format!(
        "{}/api/v1/series/{}/thumbnail",
        base_url.trim_end_matches('/'),
        series_id
    )
}

pub struct KomgaClient {
    pub(crate) base_url: String,
    pub(crate) auth: AuthMethod,
    pub(crate) http: Client,
}

impl KomgaClient {
    /// NOTE: reqwest currently ships without a TLS backend (default-features
    /// disabled for Android); https endpoints need a TLS feature decision
    /// during Phase 0 step 02 (native-tls vs rustls). http:// works as-is.
    pub fn new(base_url: String, auth: AuthMethod) -> Result<Self> {
        let http = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|_| ApiError::Network)?;
        Ok(Self {
            base_url,
            auth,
            http,
        })
    }

    pub async fn series_page(&self, request: &PageRequest) -> Result<SeriesPage> {
        self.get_json(&series_page_url(&self.base_url, request))
            .await
    }

    /// Shared authenticated GET: applies auth headers, maps HTTP status
    /// codes to the unified error model, decodes the JSON body.
    pub(crate) async fn get_json<T: serde::de::DeserializeOwned>(&self, url: &str) -> Result<T> {
        let mut headers = HeaderMap::new();
        self.auth.apply_headers(&mut headers);
        let response = self
            .http
            .get(url)
            .headers(headers)
            .send()
            .await
            .map_err(|_| ApiError::Network)?;
        match response.status().as_u16() {
            200 => response.json::<T>().await.map_err(|e| ApiError::Decode {
                message: e.to_string(),
            }),
            401 | 403 => Err(ApiError::Authentication),
            code => Err(ApiError::Server { status_code: code }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::series::Series;

    #[test]
    fn page_request_pairs() {
        let req = PageRequest {
            page: 0,
            size: 10,
            sort: Some("name".into()),
        };
        assert_eq!(
            req.to_query_pairs(),
            vec![
                ("page".into(), "0".into()),
                ("size".into(), "10".into()),
                ("sort".into(), "name".into()),
            ]
        );
    }

    #[test]
    fn series_page_url_is_stable() {
        let req = PageRequest::new(2, 10);
        assert_eq!(
            series_page_url("https://komga.example.com", &req),
            "https://komga.example.com/api/v1/series?page=2&size=10"
        );
        assert_eq!(
            series_page_url("https://example.com/komga/", &req),
            "https://example.com/komga/api/v1/series?page=2&size=10"
        );
    }

    #[test]
    fn series_thumbnail_url_is_stable() {
        assert_eq!(
            series_thumbnail_url("https://komga.example.com", "series-1"),
            "https://komga.example.com/api/v1/series/series-1/thumbnail"
        );
        assert_eq!(
            series_thumbnail_url("https://example.com/komga/", "series-1"),
            "https://example.com/komga/api/v1/series/series-1/thumbnail"
        );
    }

    #[test]
    fn decodes_shared_fixture() {
        let json =
            include_str!("../../../../specs/contracts/fixtures/initial-sync/series-page.json");
        let page: SeriesPage = serde_json::from_str(json).expect("shared fixture must decode");
        assert_eq!(page.total_elements, 3);
        assert_eq!(page.content.len(), 3);
        assert!(page.content.iter().any(|s: &Series| s.name == "One Piece"));
    }
}
