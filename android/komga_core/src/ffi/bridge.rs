//! FFI Adapter — stateless, coarse-grained entry points for Flutter.
//!
//! These are the functions flutter_rust_bridge_codegen should mirror to
//! Dart (Phase 0 step 02):
//!
//!   1. enable the `frb` feature (Cargo.toml)
//!   2. run flutter_rust_bridge_codegen with the bridge pattern
//!   3. the generated rust_lib_komga_core replaces StubLibraryRepository
//!      in android/app/lib/src/library_repository.dart
//!
//! Adapter types stay plain Rust (String / Result / domain structs); only
//! the generated frb_generated.rs may depend on flutter_rust_bridge.

use crate::api::server::Library;
use crate::ffi::application::ConnectionResult;
use crate::model::server_profile::ServerProfile;
use crate::store::series::SeriesRow;
use crate::sync::BootstrapSummary;

/// BootstrapSync (API Key auth) — mirrors the first page of series.
pub async fn bootstrap(
    db_path: String,
    server_id: String,
    base_url: String,
    api_key: String,
) -> Result<BootstrapSummary, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.bootstrap(server_id, base_url, api_key)
        .await
        .map_err(|e| e.to_string())
}

/// Connection probe (acceptance chain): authenticate + verify Komga +
/// fetch server info + libraries + version policy check.
pub async fn test_connection(
    base_url: String,
    api_key: String,
) -> Result<ConnectionResult, String> {
    let app = crate::ffi::application::App::new(String::new());
    app.test_connection(base_url, api_key)
        .await
        .map_err(|e| e.to_string())
}

pub fn save_server(db_path: String, profile: ServerProfile) -> Result<(), String> {
    let app = crate::ffi::application::App::new(db_path);
    app.save_server(&profile).map_err(|e| e.to_string())
}

pub fn list_servers(db_path: String) -> Result<Vec<ServerProfile>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.list_servers().map_err(|e| e.to_string())
}

pub fn get_server(db_path: String, server_id: String) -> Result<Option<ServerProfile>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.get_server(&server_id).map_err(|e| e.to_string())
}

pub fn delete_server(db_path: String, server_id: String) -> Result<bool, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.delete_server(&server_id).map_err(|e| e.to_string())
}

/// Persist libraries discovered during a successful connection.
pub fn save_libraries(
    db_path: String,
    server_id: String,
    libraries: Vec<Library>,
) -> Result<(), String> {
    let app = crate::ffi::application::App::new(db_path);
    app.save_libraries(&server_id, &libraries)
        .map_err(|e| e.to_string())
}

pub fn set_active_server(db_path: String, server_id: String) -> Result<(), String> {
    let app = crate::ffi::application::App::new(db_path);
    app.set_active_server(&server_id).map_err(|e| e.to_string())
}

pub fn get_active_server(db_path: String) -> Result<Option<String>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.get_active_server().map_err(|e| e.to_string())
}

pub fn fetch_series(
    db_path: String,
    server_id: String,
    limit: i64,
    offset: i64,
) -> Result<Vec<SeriesRow>, String> {
    let app = crate::ffi::application::App::new(db_path);
    app.fetch_series(&server_id, limit, offset)
        .map_err(|e| e.to_string())
}
