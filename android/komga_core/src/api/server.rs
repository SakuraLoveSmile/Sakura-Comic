//! Komga server-info API — the connection probe.
//!
//! Endpoints (from the OpenAPI snapshot):
//! - `GET {base}/actuator/info` — "Get server information" (build + git);
//!   requires authentication on a real server (401 without credentials).
//! - `GET {base}/api/v1/libraries` — plain array of LibraryDto.
//!
//! Fixtures: specs/contracts/fixtures/connection/.

pub use crate::model::server::{Library, ServerInfo};

use super::auth::AuthMethod;
use super::error::Result;
use super::series::KomgaClient;

/// Build the server-info URL (exposed for tests and Swift/Rust parity checks).
pub fn server_info_url(base_url: &str) -> String {
    format!("{}/actuator/info", base_url.trim_end_matches('/'))
}

/// Build the libraries URL (exposed for tests and Swift/Rust parity checks).
pub fn libraries_url(base_url: &str) -> String {
    format!("{}/api/v1/libraries", base_url.trim_end_matches('/'))
}

/// Fetching abstraction so the connection flow can be tested offline.
/// KomgaClient implements both via the impls below.
#[allow(async_fn_in_trait)]
pub trait ServerInfoFetcher {
    async fn server_info(&self) -> Result<ServerInfo>;
}

#[allow(async_fn_in_trait)]
pub trait LibrariesFetcher {
    async fn libraries(&self) -> Result<Vec<Library>>;
}

/// Combination used by the connection flow (fake in offline tests).
pub trait ConnectionFetching: ServerInfoFetcher + LibrariesFetcher {}
impl<T: ServerInfoFetcher + LibrariesFetcher> ConnectionFetching for T {}

impl ServerInfoFetcher for KomgaClient {
    async fn server_info(&self) -> Result<ServerInfo> {
        self.get_json(&server_info_url(&self.base_url)).await
    }
}

impl LibrariesFetcher for KomgaClient {
    async fn libraries(&self) -> Result<Vec<Library>> {
        self.get_json(&libraries_url(&self.base_url)).await
    }
}

impl KomgaClient {
    /// Convenience: `GET /actuator/info`.
    pub async fn fetch_server_info(&self) -> Result<ServerInfo> {
        self.server_info().await
    }

    /// Convenience: `GET /api/v1/libraries`.
    pub async fn fetch_libraries(&self) -> Result<Vec<Library>> {
        self.libraries().await
    }
}

/// Build a client for the probe (auth not applied until request time).
pub fn probe_client(base_url: String, auth: AuthMethod) -> Result<KomgaClient> {
    KomgaClient::new(base_url, auth)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_info_url_is_stable() {
        assert_eq!(
            server_info_url("https://komga.example.com"),
            "https://komga.example.com/actuator/info"
        );
        assert_eq!(
            server_info_url("https://example.com/komga/"),
            "https://example.com/komga/actuator/info"
        );
    }

    #[test]
    fn libraries_url_is_stable() {
        assert_eq!(
            libraries_url("https://komga.example.com"),
            "https://komga.example.com/api/v1/libraries"
        );
        assert_eq!(
            libraries_url("https://example.com/komga/"),
            "https://example.com/komga/api/v1/libraries"
        );
    }
}
