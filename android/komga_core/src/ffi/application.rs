//! Application Facade — coarse-grained services for Flutter.
//!
//! No flutter_rust_bridge types here. Layering:
//! Core (api/model/store/sync/cache) → Application Facade → FFI Adapter.

use crate::api::auth::AuthMethod;
use crate::api::contract::{check_server_version, version_capabilities};
use crate::api::error::ApiError;
use crate::api::series::KomgaClient;
use crate::api::server::ConnectionFetching;
use crate::model::server::{Library, ServerInfo};
use crate::model::server_profile::ServerProfile;
use crate::store;
use crate::store::series::SeriesRow;
use crate::sync::{self, BootstrapSummary};

/// Owns the app-level SQLite path; every call opens its own connection
/// (simple for Phase 0; a long-lived pooled connection comes with the
/// streaming API in Phase 1).
pub struct App {
    db_path: String,
}

impl App {
    pub fn new(db_path: impl Into<String>) -> Self {
        Self {
            db_path: db_path.into(),
        }
    }

    pub fn db_path(&self) -> &str {
        &self.db_path
    }

    /// Insert or update a server profile.
    pub fn save_server(&self, profile: &ServerProfile) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::servers::save_server(&conn, profile).map_err(db_err)
    }

    pub fn list_servers(&self) -> Result<Vec<ServerProfile>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::servers::list_servers(&conn).map_err(db_err)
    }

    pub fn get_server(&self, server_id: &str) -> Result<Option<ServerProfile>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::servers::get_server(&conn, server_id).map_err(db_err)
    }

    /// Delete a server profile. If the deleted server was the active one,
    /// the active-server state is cleared with it.
    pub fn delete_server(&self, server_id: &str) -> Result<bool, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        let deleted = store::servers::delete_server(&conn, server_id).map_err(db_err)?;
        if deleted {
            let _ = store::app_state::clear_active_server(&conn);
        }
        Ok(deleted)
    }

    /// Persist the libraries discovered during a successful connection.
    pub fn save_libraries(&self, server_id: &str, libraries: &[Library]) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::libraries::save_libraries_batch(&conn, server_id, libraries).map_err(db_err)?;
        Ok(())
    }

    pub fn list_libraries(
        &self,
        server_id: &str,
    ) -> Result<Vec<crate::store::libraries::LibraryRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::libraries::list_libraries(&conn, server_id).map_err(db_err)
    }

    // MARK: - Active server

    pub fn set_active_server(&self, server_id: &str) -> Result<(), ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::app_state::set_active_server(&conn, server_id).map_err(db_err)
    }

    pub fn get_active_server(&self) -> Result<Option<String>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::app_state::get_active_server(&conn).map_err(db_err)
    }

    // MARK: - Connection probe (acceptance chain: 添加 → 登录 → 验证 → 信息)

    /// Live probe: authenticate + verify Komga + fetch server info +
    /// libraries (checks the version policy; rejects incompatible servers).
    pub async fn test_connection(
        &self,
        base_url: String,
        api_key: String,
    ) -> Result<ConnectionResult, ApiError> {
        let client = KomgaClient::new(base_url, AuthMethod::ApiKey { key: api_key })?;
        self.test_connection_with(&client).await
    }

    /// Same as test_connection with an injectable fetcher (offline tests).
    pub async fn test_connection_with<F: ConnectionFetching + Sync>(
        &self,
        fetcher: &F,
    ) -> Result<ConnectionResult, ApiError> {
        let info = fetcher.server_info().await?;
        let version = info.build.as_ref().and_then(|build| build.version.clone());
        let check = check_server_version(version.as_deref())?;

        let libraries = fetcher.libraries().await?;
        let mut capabilities = version_capabilities(&check);
        capabilities.push(format!("libraries:{}", libraries.len()));
        if libraries.is_empty() {
            capabilities.push("empty-libraries".into());
        }

        Ok(ConnectionResult {
            server_info: info,
            server_version: version,
            libraries,
            capabilities,
        })
    }

    /// BootstrapSync: mirrors the first page (size 10) of a server's series
    /// into SQLite. The transport is async end-to-end; SQLite access is
    /// local and fast.
    pub async fn bootstrap(
        &self,
        server_id: String,
        base_url: String,
        api_key: String,
    ) -> Result<BootstrapSummary, ApiError> {
        let client = KomgaClient::new(base_url, AuthMethod::ApiKey { key: api_key })?;
        self.bootstrap_with(&client, &server_id).await
    }

    /// Same as bootstrap but with an injectable fetcher (offline tests).
    ///
    /// The network phase runs without any DB handle in scope, so the future
    /// stays `Send` for the FFI bridge (rusqlite `Connection` is not `Sync`).
    pub async fn bootstrap_with<F: crate::sync::SeriesFetcher + Sync>(
        &self,
        fetcher: &F,
        server_id: &str,
    ) -> Result<BootstrapSummary, ApiError> {
        let page = sync::fetch_bootstrap_page(fetcher).await?;
        let conn = store::open(&self.db_path).map_err(db_err)?;
        sync::bootstrap_page_to_store(&conn, server_id, &page)
    }

    pub fn fetch_series(
        &self,
        server_id: &str,
        limit: i64,
        offset: i64,
    ) -> Result<Vec<SeriesRow>, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::series::list_series(&conn, server_id, limit, offset).map_err(db_err)
    }

    pub fn count_series(&self, server_id: &str) -> Result<i64, ApiError> {
        let conn = store::open(&self.db_path).map_err(db_err)?;
        store::series::count_series(&conn, server_id).map_err(db_err)
    }
}

fn db_err(e: rusqlite::Error) -> ApiError {
    ApiError::Database {
        message: e.to_string(),
    }
}

/// Outcome of the connection probe: server identity/version, remote
/// entities (libraries) and policy-derived capabilities.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionResult {
    pub server_info: ServerInfo,
    /// `build.version` of the server (policy input).
    pub server_version: Option<String>,
    pub libraries: Vec<Library>,
    /// e.g. `libraries:2`, `unknown-version`, `newer-than-snapshot:1.27.0`.
    pub capabilities: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::series::{Series, SeriesMetadata};
    use crate::model::server_profile::AuthType;
    use uuid::Uuid;

    fn temp_db() -> String {
        std::env::temp_dir()
            .join(format!("komga_app_test_{}.sqlite", Uuid::new_v4()))
            .to_string_lossy()
            .into_owned()
    }

    #[test]
    fn facade_server_and_series_roundtrip() {
        let db = temp_db();
        let app = App::new(&db);

        let mut profile = ServerProfile::new("Home", "https://komga.example.com", AuthType::ApiKey);
        profile.id = "server-1".into();
        app.save_server(&profile).unwrap();
        assert_eq!(app.list_servers().unwrap().len(), 1);

        // Seed series the way BootstrapSync would (store layer is the authority).
        let conn = store::open(&db).unwrap();
        let s = Series {
            id: "s1".into(),
            library_id: "lib-1".into(),
            name: "One Piece".into(),
            created: None,
            last_modified: None,
            books_count: None,
            metadata: Some(SeriesMetadata {
                title: "One Piece".into(),
                status: None,
                summary: None,
                publishers: vec![],
            }),
        };
        store::series::save_series_batch(&conn, "server-1", &[s]).unwrap();
        drop(conn);

        assert_eq!(app.count_series("server-1").unwrap(), 1);
        let rows = app.fetch_series("server-1", 10, 0).unwrap();
        assert_eq!(rows[0].name, "One Piece");
        assert_eq!(app.fetch_series("server-2", 10, 0).unwrap().len(), 0);

        std::fs::remove_file(&db).unwrap();
    }

    struct FakeSeriesFetcher(crate::model::series::SeriesPage);

    impl crate::sync::SeriesFetcher for FakeSeriesFetcher {
        async fn series_page(
            &self,
            _request: &crate::api::series::PageRequest,
        ) -> Result<crate::model::series::SeriesPage, ApiError> {
            Ok(self.0.clone())
        }
    }

    #[tokio::test]
    async fn facade_bootstrap_with_fake_fetcher_writes_store() {
        let db = temp_db();
        let app = App::new(&db);

        let json =
            include_str!("../../../../specs/contracts/fixtures/initial-sync/series-page.json");
        let page: crate::model::series::SeriesPage =
            serde_json::from_str(json).expect("shared fixture must decode");
        let fetcher = FakeSeriesFetcher(page);

        let summary = app.bootstrap_with(&fetcher, "server-1").await.unwrap();
        assert_eq!(summary.synced_series, 3);
        assert_eq!(summary.total_elements, 3);
        assert_eq!(app.count_series("server-1").unwrap(), 3);

        let rows = app.fetch_series("server-1", 10, 0).unwrap();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].name, "Berserk"); // COLLATE NOCASE ordering

        std::fs::remove_file(&db).unwrap();
    }

    /// Fake connection probe backed by the shared connection fixtures.
    struct FakeConnectionFetcher {
        info: crate::model::server::ServerInfo,
        libraries: Vec<crate::model::server::Library>,
        fail_info: bool,
        fail_libraries: bool,
    }

    impl FakeConnectionFetcher {
        fn from_fixtures() -> Self {
            let info = serde_json::from_str(include_str!(
                "../../../../specs/contracts/fixtures/connection/actuator-info.json"
            ))
            .expect("shared fixture must decode");
            let libraries = serde_json::from_str(include_str!(
                "../../../../specs/contracts/fixtures/connection/libraries.json"
            ))
            .expect("shared fixture must decode");
            Self {
                info,
                libraries,
                fail_info: false,
                fail_libraries: false,
            }
        }
    }

    impl crate::api::server::ServerInfoFetcher for FakeConnectionFetcher {
        async fn server_info(
            &self,
        ) -> std::result::Result<crate::model::server::ServerInfo, ApiError> {
            if self.fail_info {
                Err(ApiError::Authentication)
            } else {
                Ok(self.info.clone())
            }
        }
    }

    impl crate::api::server::LibrariesFetcher for FakeConnectionFetcher {
        async fn libraries(
            &self,
        ) -> std::result::Result<Vec<crate::model::server::Library>, ApiError> {
            if self.fail_libraries {
                Err(ApiError::Server { status_code: 500 })
            } else {
                Ok(self.libraries.clone())
            }
        }
    }

    #[tokio::test]
    async fn connection_probe_collects_info_libraries_and_capabilities() {
        let db = temp_db();
        let app = App::new(&db);
        let fetcher = FakeConnectionFetcher::from_fixtures();

        let result = app.test_connection_with(&fetcher).await.unwrap();
        assert_eq!(result.server_version.as_deref(), Some("1.26.3"));
        assert_eq!(result.libraries.len(), 2);
        assert!(result.capabilities.iter().any(|c| c == "libraries:2"));

        // Acceptance chain: save profile + libraries + activate.
        let mut profile = ServerProfile::new("Home", "http://192.168.0.69:25600", AuthType::ApiKey);
        profile.id = "server-1".into();
        profile.capabilities = result.capabilities.clone();
        profile.last_successful_connection = Some("2026-08-26T00:00:00Z".into());
        app.save_server(&profile).unwrap();
        app.save_libraries("server-1", &result.libraries).unwrap();
        app.set_active_server("server-1").unwrap();

        assert_eq!(
            app.get_active_server().unwrap().as_deref(),
            Some("server-1")
        );
        assert_eq!(app.list_servers().unwrap().len(), 1);
        let saved = app.get_server("server-1").unwrap().unwrap();
        assert_eq!(saved.capabilities, result.capabilities);
        assert!(saved.last_successful_connection.is_some());

        // Deleting the active server clears the active state.
        assert!(app.delete_server("server-1").unwrap());
        assert_eq!(app.get_active_server().unwrap(), None);
        assert!(app.list_servers().unwrap().is_empty());

        std::fs::remove_file(&db).unwrap();
    }

    #[tokio::test]
    async fn connection_probe_maps_auth_failure() {
        let db = temp_db();
        let app = App::new(&db);
        let mut fetcher = FakeConnectionFetcher::from_fixtures();
        fetcher.fail_info = true;
        let err = app.test_connection_with(&fetcher).await.unwrap_err();
        assert!(matches!(err, ApiError::Authentication));
        // No DB was ever opened — nothing to clean up.
    }

    #[tokio::test]
    async fn connection_probe_rejects_unsupported_server_version() {
        let db = temp_db();
        let app = App::new(&db);
        let mut fetcher = FakeConnectionFetcher::from_fixtures();
        fetcher.info = serde_json::from_str(r#"{"build":{"version":"2.0.0"}}"#).unwrap();
        let err = app.test_connection_with(&fetcher).await.unwrap_err();
        assert!(matches!(err, ApiError::ApiCompatibility { .. }));
        // No DB was ever opened — nothing to clean up.
    }
}
