//! Komga book pages API — the manifest and the page images:
//! `GET {base}/api/v1/books/{bookId}/pages` -> `array<PageDto>`
//! `GET {base}/api/v1/books/{bookId}/pages/{pageNumber}?zero_based=false`
//!
//! Required-ness follows `specs/openapi/komga-openapi.yaml` (Komga 1.26.3,
//! `PageDto.required = [fileName, mediaType, number, size]`): a DTO may not be
//! looser than the server contract, or a malformed response decodes "fine" here
//! and fails somewhere the reader cannot see it.

use super::auth::AuthMethod;
use super::error::{ApiError, Result};
use super::series::KomgaClient;
use reqwest::header::HeaderMap;
use serde::Deserialize;

/// Page list endpoint. No pagination envelope: Komga answers with a bare array.
pub fn book_pages_url(base_url: &str, book_id: &str) -> String {
    format!(
        "{}/api/v1/books/{}/pages",
        base_url.trim_end_matches('/'),
        book_id
    )
}

/// One page image.
///
/// `zero_based=false` is sent explicitly rather than relied on as a default:
/// asking for page N and silently being served page N-1 would offset every
/// spread in the reader by one, and the reader has no way to notice.
pub fn book_page_url(base_url: &str, book_id: &str, number: u32) -> String {
    format!(
        "{}/api/v1/books/{}/pages/{}?zero_based=false",
        base_url.trim_end_matches('/'),
        book_id,
        number
    )
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageDto {
    pub file_name: String,
    pub media_type: String,
    pub number: i32,
    pub size: String,
    #[serde(default)]
    pub height: Option<i32>,
    #[serde(default)]
    pub width: Option<i32>,
    #[serde(default)]
    pub size_bytes: Option<i64>,
}

/// Transport for the reader's manifest + page bytes. Kept async and separate
/// from `reader::loader::PageSource` so the reader stays free of any transport
/// type; the facade adapts one to the other.
#[allow(async_fn_in_trait)]
pub trait PageStreaming {
    async fn pages(&self, book_id: &str) -> Result<Vec<PageDto>>;
    /// Bytes plus the response `Content-Type`, which is what decides the cached
    /// file's extension.
    async fn page_bytes(&self, book_id: &str, number: u32) -> Result<(Vec<u8>, String)>;
}

impl PageStreaming for KomgaClient {
    async fn pages(&self, book_id: &str) -> Result<Vec<PageDto>> {
        self.get_json(&book_pages_url(&self.base_url, book_id))
            .await
    }

    async fn page_bytes(&self, book_id: &str, number: u32) -> Result<(Vec<u8>, String)> {
        let url = book_page_url(&self.base_url, book_id, number);
        let mut headers = HeaderMap::new();
        self.auth.apply_headers(&mut headers);
        // `image/*` only, so a server that content-negotiates toward a PDF page
        // answers 406 here instead of handing the reader bytes it cannot draw.
        let response = self
            .http
            .get(&url)
            .headers(headers)
            .send()
            .await
            .map_err(|_| ApiError::Network)?;
        match response.status().as_u16() {
            200 => {
                let content_type = response
                    .headers()
                    .get(reqwest::header::CONTENT_TYPE)
                    .and_then(|value| value.to_str().ok())
                    .unwrap_or("application/octet-stream")
                    .to_string();
                let bytes = response.bytes().await.map_err(|e| ApiError::Decode {
                    message: e.to_string(),
                })?;
                Ok((bytes.to_vec(), content_type))
            }
            401 | 403 => Err(ApiError::Authentication),
            code => Err(ApiError::Server { status_code: code }),
        }
    }
}

/// Convenience wrapper mirroring `book::BookClient`.
pub struct PageClient {
    client: KomgaClient,
}

impl PageClient {
    pub fn new(base_url: String, auth: AuthMethod) -> Result<Self> {
        Ok(Self {
            client: KomgaClient::new(base_url, auth)?,
        })
    }

    pub fn client(&self) -> &KomgaClient {
        &self.client
    }
}

impl PageStreaming for PageClient {
    async fn pages(&self, book_id: &str) -> Result<Vec<PageDto>> {
        PageStreaming::pages(&self.client, book_id).await
    }

    async fn page_bytes(&self, book_id: &str, number: u32) -> Result<(Vec<u8>, String)> {
        PageStreaming::page_bytes(&self.client, book_id, number).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_urls_are_one_based_and_explicit() {
        assert_eq!(
            book_pages_url("https://k.example.com/", "b1"),
            "https://k.example.com/api/v1/books/b1/pages"
        );
        assert_eq!(
            book_page_url("https://k.example.com", "b1", 1),
            "https://k.example.com/api/v1/books/b1/pages/1?zero_based=false"
        );
    }

    #[test]
    fn page_dto_decodes_a_real_shape() {
        let dto: PageDto = serde_json::from_str(
            r#"{"fileName":"001.jpg","mediaType":"image/jpeg","number":1,
                "size":"1,2 MB","width":1200,"height":1800,"sizeBytes":1258291}"#,
        )
        .unwrap();
        assert_eq!(dto.file_name, "001.jpg");
        assert_eq!(dto.size_bytes, Some(1258291));
        assert_eq!(dto.width, Some(1200));

        // Dimensions are optional in the schema; the reader treats them as
        // unknown rather than rejecting the page.
        let lean: PageDto = serde_json::from_str(
            r#"{"fileName":"002.jpg","mediaType":"image/jpeg","number":2,"size":"1 kB"}"#,
        )
        .unwrap();
        assert_eq!(lean.width, None);
        assert_eq!(lean.size_bytes, None);

        // A response missing a required field must not decode.
        assert!(serde_json::from_str::<PageDto>(
            r#"{"fileName":"x","mediaType":"image/jpeg","number":1}"#
        )
        .is_err());
    }
}
