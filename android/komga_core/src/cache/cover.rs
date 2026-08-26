//! Cover service: thumbnail bytes -> disk cache (local-first).
//!
//! Cache hit returns the file path without touching the network; a miss
//! fetches bytes and stores them. Fetches go through the BytesFetcher
//! trait so this module is testable without a network.

use std::path::PathBuf;

use reqwest::header::HeaderMap;

use crate::api::error::{ApiError, Result};
use crate::api::series::KomgaClient;

use super::{cover_key, DiskCache};

/// Fetches raw bytes for a URL (implemented by KomgaClient, faked in tests).
#[allow(async_fn_in_trait)]
pub trait BytesFetcher {
    async fn fetch_bytes(&self, url: &str) -> Result<Vec<u8>>;
}

impl BytesFetcher for KomgaClient {
    async fn fetch_bytes(&self, url: &str) -> Result<Vec<u8>> {
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
            200 => response
                .bytes()
                .await
                .map(|b| b.to_vec())
                .map_err(|e| ApiError::Decode {
                    message: e.to_string(),
                }),
            401 | 403 => Err(ApiError::Authentication),
            code => Err(ApiError::Server { status_code: code }),
        }
    }
}

/// Cache-first cover store for one server profile.
pub struct CoverStore {
    cache: DiskCache,
    base_url: String,
}

impl CoverStore {
    pub fn new(cache: DiskCache, base_url: impl Into<String>) -> Self {
        Self {
            cache,
            base_url: base_url.into(),
        }
    }

    pub fn cache(&self) -> &DiskCache {
        &self.cache
    }

    /// Returns the cached thumbnail path, fetching and storing it on miss.
    pub async fn ensure_thumbnail<F: BytesFetcher>(
        &self,
        fetcher: &F,
        server_id: &str,
        series_id: &str,
    ) -> Result<PathBuf> {
        let key = cover_key(server_id, series_id);
        let path = self.cache.thumbnail_path(&key);
        if self.cache.exists(&path) {
            return Ok(path);
        }
        let url = crate::api::series::series_thumbnail_url(&self.base_url, series_id);
        let bytes = fetcher.fetch_bytes(&url).await?;
        self.cache
            .store_thumbnail(&key, &bytes)
            .map_err(|e| ApiError::Storage {
                message: e.to_string(),
            })
    }

    /// Book thumbnail variant (the book list reads cover paths from
    /// `thumbnails` rows with `variant = 'book'`).
    pub async fn ensure_book_thumbnail<F: BytesFetcher>(
        &self,
        fetcher: &F,
        server_id: &str,
        book_id: &str,
    ) -> Result<PathBuf> {
        let key = cover_key(server_id, book_id);
        let path = self.cache.thumbnail_path(&key);
        if self.cache.exists(&path) {
            return Ok(path);
        }
        let url = crate::api::book::book_thumbnail_url(&self.base_url, book_id);
        let bytes = fetcher.fetch_bytes(&url).await?;
        self.cache
            .store_thumbnail(&key, &bytes)
            .map_err(|e| ApiError::Storage {
                message: e.to_string(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use uuid::Uuid;

    struct FakeFetcher {
        hits: Arc<AtomicUsize>,
    }

    impl BytesFetcher for FakeFetcher {
        async fn fetch_bytes(&self, _url: &str) -> Result<Vec<u8>> {
            self.hits.fetch_add(1, Ordering::SeqCst);
            Ok(b"cover-bytes".to_vec())
        }
    }

    #[tokio::test]
    async fn ensure_thumbnail_fetches_once_and_caches() {
        let root = std::env::temp_dir().join(format!("komga_cover_test_{}", Uuid::new_v4()));
        let hits = Arc::new(AtomicUsize::new(0));
        let store = CoverStore::new(DiskCache::new(&root).unwrap(), "https://komga.example.com");
        let fetcher = FakeFetcher { hits: hits.clone() };

        let path = store
            .ensure_thumbnail(&fetcher, "srv-1", "series-1")
            .await
            .unwrap();
        assert!(path.exists());
        assert_eq!(std::fs::read(&path).unwrap(), b"cover-bytes");

        let second = store
            .ensure_thumbnail(&fetcher, "srv-1", "series-1")
            .await
            .unwrap();
        assert_eq!(second, path);
        assert_eq!(
            hits.load(Ordering::SeqCst),
            1,
            "second call must hit the cache"
        );

        std::fs::remove_dir_all(&root).unwrap();
    }
}
