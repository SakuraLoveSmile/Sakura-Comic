//! Application Facade — coarse-grained services for Flutter.
//!
//! No flutter_rust_bridge types here. Layering:
//! Core (api/model/store/sync/cache) → Application Facade → FFI Adapter.

use crate::api::auth::AuthMethod;
use crate::api::error::ApiError;
use crate::api::series::KomgaClient;
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
}
