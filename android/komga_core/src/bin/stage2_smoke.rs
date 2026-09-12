//! Stage 2 acceptance smoke tool.
//!
//! Walks the full acceptance chain on one platform side:
//!   添加服务器 → 登录 → 验证 Komga → 获取服务器信息 → 保存 Server Profile
//!
//! Two modes:
//!
//! 1. Live server (default): probes /actuator/info + /api/v1/libraries,
//!    checks the version policy, saves the profile + libraries, activates.
//! 2. Offline fixture (`--fixture`): the same chain against the shared
//!    connection fixtures with a fake fetcher (no network).
//!
//! Usage (live server):
//!
//! ```text
//! cargo run --manifest-path android/komga_core/Cargo.toml --bin stage2_smoke -- \
//!   --db /tmp/comic-stage2.sqlite --base-url http://192.168.0.69:25600 --api-key YOUR_KEY
//! ```
//!
//! Usage (offline fixture):
//!
//! ```text
//! cargo run --manifest-path android/komga_core/Cargo.toml --bin stage2_smoke -- \
//!   --fixture --db /tmp/comic-stage2.sqlite
//! ```

use std::path::PathBuf;

use komga_core::api::server::{LibrariesFetcher, ServerInfoFetcher};
use komga_core::ffi::application::{App, ConnectionResult};
use komga_core::model::server::{Library, ServerInfo};
use komga_core::model::server_profile::{AuthType, ServerProfile};

struct Args {
    db: PathBuf,
    base_url: String,
    api_key: String,
    fixture: bool,
}

const USAGE: &str = "\
usage: stage2_smoke [--fixture] --db <path> [--base-url <url> --api-key <key>]

  --fixture   run offline against the shared connection fixtures (no network)";

fn parse_args() -> Option<Args> {
    let mut db = None;
    let mut base_url = None;
    let mut api_key = None;
    let mut fixture = false;
    let mut iter = std::env::args().skip(1);
    while let Some(flag) = iter.next() {
        match flag.as_str() {
            "--db" => db = Some(PathBuf::from(iter.next()?)),
            "--base-url" => base_url = Some(iter.next()?),
            "--api-key" => api_key = Some(iter.next()?),
            "--fixture" => fixture = true,
            _ => return None,
        }
    }
    Some(Args {
        db: db?,
        base_url: base_url.unwrap_or_default(),
        api_key: api_key.unwrap_or_default(),
        fixture,
    })
}

#[tokio::main]
async fn main() {
    let args = parse_args().unwrap_or_else(|| {
        eprintln!("{USAGE}");
        std::process::exit(2);
    });
    let result = if args.fixture {
        run_fixture(&args).await
    } else {
        run_live(&args).await
    };
    if let Err(e) = result {
        eprintln!("STAGE 2 SMOKE FAILED: {e}");
        std::process::exit(1);
    }
    println!("STAGE 2 SMOKE OK");
}

/// Live server path.
async fn run_live(args: &Args) -> Result<(), String> {
    let app = App::new(args.db.to_string_lossy().to_string());
    run_acceptance(
        &app,
        "live",
        args.base_url.clone(),
        args.api_key.clone(),
        None::<FakeConnectionFetcher>,
    )
    .await
}

/// Offline fixture path: same chain, fake fetcher, no network.
async fn run_fixture(args: &Args) -> Result<(), String> {
    let app = App::new(args.db.to_string_lossy().to_string());
    let info = serde_json::from_str(include_str!(
        "../../../../specs/contracts/fixtures/connection/actuator-info.json"
    ))
    .map_err(|e| format!("decode info fixture: {e}"))?;
    let libraries = serde_json::from_str(include_str!(
        "../../../../specs/contracts/fixtures/connection/libraries.json"
    ))
    .map_err(|e| format!("decode libraries fixture: {e}"))?;
    run_acceptance(
        &app,
        "fixture",
        "http://192.168.0.69:25600".into(),
        "test-key".into(),
        Some(FakeConnectionFetcher { info, libraries }),
    )
    .await
}

/// The acceptance chain, driven through the Application Facade.
async fn run_acceptance<F>(
    app: &App,
    mode: &str,
    base_url: String,
    api_key: String,
    fake: Option<F>,
) -> Result<(), String>
where
    F: ServerInfoFetcher + LibrariesFetcher + Sync,
{
    println!("== Stage 2 acceptance ({mode}) ==");

    // 1. 添加服务器 (display name + normalized URL — normalization checked
    //    by normalize_server_url inside the client layer and unit tests).
    println!("[1/5] add server profile (display name, base url)");

    // 2+3+4. 登录 → 验证 Komga → 获取服务器信息 (version policy applied).
    println!("[2/5] login + verify Komga + fetch server info (GET /actuator/info)");
    let result: ConnectionResult = match fake {
        Some(fetcher) => app.test_connection_with(&fetcher).await,
        None => app.test_connection(base_url.clone(), api_key).await,
    }
    .map_err(|e| format!("connection probe failed: {e}"))?;
    let version = result.server_version.as_deref().unwrap_or("(unknown)");
    println!(
        "      server={} version={} libraries={} capabilities={:?}",
        base_url.trim_end_matches('/'),
        version,
        result.libraries.len(),
        result.capabilities
    );

    // 5. 保存 Server Profile (+ libraries mirror + activate).
    println!("[3/5] fetch libraries (GET /api/v1/libraries)");
    println!("[4/5] save ServerProfile with credential ref + capabilities");
    let profile = ServerProfile {
        id: format!("server-{mode}"),
        display_name: format!("Home ({mode})"),
        base_url: base_url.clone(),
        auth_type: AuthType::ApiKey,
        credential_ref: Some("keystore://server-{}".replace("{}", mode)),
        capabilities: result.capabilities.clone(),
        last_successful_connection: Some(chrono::Utc::now().to_rfc3339()),
    };
    app.save_server(&profile)
        .map_err(|e| format!("save server failed: {e}"))?;
    app.save_libraries(&profile.id, &result.libraries)
        .map_err(|e| format!("save libraries failed: {e}"))?;

    println!("[5/5] switch server (set active)");
    app.set_active_server(&profile.id)
        .map_err(|e| format!("set active failed: {e}"))?;

    // Read-back assertions.
    let active = app
        .get_active_server()
        .map_err(|e| format!("read active failed: {e}"))?;
    let saved = app
        .get_server(&profile.id)
        .map_err(|e| format!("read profile failed: {e}"))?;
    let libs = app
        .list_libraries(&profile.id)
        .map_err(|e| format!("read libraries failed: {e}"))?;
    assert_eq!(
        active.as_deref(),
        Some(profile.id.as_str()),
        "active server mismatch"
    );
    let saved = saved.ok_or_else(|| "saved profile missing".to_string())?;
    assert_eq!(saved.display_name, profile.display_name);
    assert_eq!(saved.credential_ref, profile.credential_ref);
    assert_eq!(
        libs.len(),
        result.libraries.len(),
        "libraries mirror mismatch"
    );
    println!(
        "      saved profile id={} libraries={} capabilities={:?}",
        saved.id,
        libs.len(),
        saved.capabilities
    );
    println!("ACCEPTANCE CHAIN OK: 添加服务器 → 登录 → 验证 → 服务器信息 → 保存 Profile");
    Ok(())
}

/// Fake connection probe backed by the shared fixtures.
struct FakeConnectionFetcher {
    info: ServerInfo,
    libraries: Vec<Library>,
}

impl ServerInfoFetcher for FakeConnectionFetcher {
    async fn server_info(&self) -> Result<ServerInfo, komga_core::api::error::ApiError> {
        Ok(self.info.clone())
    }
}

impl LibrariesFetcher for FakeConnectionFetcher {
    async fn libraries(&self) -> Result<Vec<Library>, komga_core::api::error::ApiError> {
        Ok(self.libraries.clone())
    }
}
