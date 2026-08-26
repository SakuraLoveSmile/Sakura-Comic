//! Phase 0 vertical-slice smoke tool.
//!
//! Two modes:
//!
//! 1. Live server (default): auth -> series page (first 10) -> SQLite -> local read-back -> cover cache.
//! 2. Offline fixture (`--fixture`): runs the same chain against the shared fixture with fake fetchers (no network).
//!
//! Usage (live server):
//!
//! ```text
//! cargo run --manifest-path android/komga_core/Cargo.toml --bin phase0_smoke -- \
//!   --db /tmp/comic.sqlite --server-id demo \
//!   --base-url http://192.168.1.10:25600 --api-key YOUR_KEY
//! ```
//!
//! Usage (offline fixture):
//!
//! ```text
//! cargo run --manifest-path android/komga_core/Cargo.toml --bin phase0_smoke -- \
//!   --fixture --db /tmp/comic.sqlite --server-id demo
//! ```

use std::path::{Path, PathBuf};

use komga_core::api::auth::AuthMethod;
use komga_core::api::error::{ApiError, Result};
use komga_core::api::series::KomgaClient;
use komga_core::ffi;
use komga_core::model::series::SeriesPage;
use komga_core::store;
use komga_core::store::thumbnails::VARIANT_SERIES;
use komga_core::sync::{self, SeriesFetcher};

struct Args {
    db: PathBuf,
    server_id: String,
    base_url: String,
    api_key: String,
    fixture: bool,
}

const USAGE: &str = "\
usage: phase0_smoke [--fixture] --db <path> --server-id <id> \
[--base-url <url> --api-key <key>]

  --fixture   run offline against the shared fixture (no network)";

fn parse_args() -> Option<Args> {
    let mut db = None;
    let mut server_id = None;
    let mut base_url = None;
    let mut api_key = None;
    let mut fixture = false;
    let mut iter = std::env::args().skip(1);
    while let Some(flag) = iter.next() {
        match flag.as_str() {
            "--db" => db = Some(PathBuf::from(iter.next()?)),
            "--server-id" => server_id = Some(iter.next()?),
            "--base-url" => base_url = Some(iter.next()?),
            "--api-key" => api_key = Some(iter.next()?),
            "--fixture" => fixture = true,
            _ => return None,
        }
    }
    Some(Args {
        db: db?,
        server_id: server_id?,
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
        run(&args).await
    };
    if let Err(e) = result {
        eprintln!("PHASE 0 SMOKE FAILED: {e}");
        std::process::exit(1);
    }
    println!("PHASE 0 SMOKE OK");
}

/// Live server path.
async fn run(args: &Args) -> Result<()> {
    let conn = store::open(&args.db).map_err(db_err)?;
    let client = KomgaClient::new(
        args.base_url.clone(),
        AuthMethod::ApiKey {
            key: args.api_key.clone(),
        },
    )?;

    println!("== BootstrapSync ==");
    let summary = sync::bootstrap_series(&conn, &client, &args.server_id).await?;
    println!(
        "synced_series={} total_elements={} has_more_pages={}",
        summary.synced_series, summary.total_elements, summary.has_more_pages
    );

    println!("== Local store (SQLite) ==");
    let rows = store::series::list_series(&conn, &args.server_id, summary.synced_series as i64, 0)
        .map_err(db_err)?;
    if rows.is_empty() {
        println!("(no series in local store — is the server empty or authenticated?)");
        return Ok(());
    }
    for row in &rows {
        println!("  {} [{}]", row.name, row.remote_id);
    }

    println!("== Cover cache (facade: cache-first + SQLite bookkeeping) ==");
    let app = crate_facade(&args.db);
    let first = &rows[0];
    let cover_path = app
        .ensure_cover(
            args.server_id.clone(),
            first.remote_id.clone(),
            args.base_url.clone(),
            args.api_key.clone(),
        )
        .await?;
    println!("  cached {} -> {}", first.name, cover_path);

    println!("== SQLite cover bookkeeping (thumbnails) ==");
    print_thumbnail_row(&conn, &args.server_id, &first.remote_id)?;
    Ok(())
}

fn crate_facade(db: &Path) -> ffi::application::App {
    ffi::application::App::new(db.to_string_lossy().into_owned())
}

/// Print the `thumbnails` row for one series (the UI resolves cover files
/// from SQLite — this is the local-first contract).
fn print_thumbnail_row(
    conn: &rusqlite::Connection,
    server_id: &str,
    remote_id: &str,
) -> Result<()> {
    let row =
        komga_core::store::thumbnails::get_thumbnail(conn, server_id, remote_id, VARIANT_SERIES)
            .map_err(db_err)?;
    match row {
        Some(row) => {
            let exists = Path::new(&row.local_path).exists();
            println!(
                "  {} -> {} ({} bytes, file_exists={})",
                row.remote_id,
                row.local_path,
                row.size_bytes,
                if exists { "yes" } else { "NO" }
            );
            if !exists {
                return Err(ApiError::Storage {
                    message: "cover record exists but the file is missing".into(),
                });
            }
            Ok(())
        }
        None => {
            println!("  WARNING: no thumbnails row recorded for {}", remote_id);
            Ok(())
        }
    }
}

/// Offline fixture path: same chain, fake fetchers, no network.
async fn run_fixture(args: &Args) -> Result<()> {
    let conn = store::open(&args.db).map_err(db_err)?;
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../specs/contracts/fixtures/initial-sync/series-page.json");
    let json = std::fs::read_to_string(&fixture).map_err(|e| ApiError::Decode {
        message: format!("read fixture {}: {e}", fixture.display()),
    })?;
    let page: SeriesPage = serde_json::from_str(&json).map_err(|e| ApiError::Decode {
        message: format!("decode fixture: {e}"),
    })?;

    println!("== BootstrapSync (fixture) ==");
    let summary = sync::bootstrap_series(&conn, &FakeSeriesFetcher(page), &args.server_id).await?;
    println!(
        "synced_series={} total_elements={} has_more_pages={}",
        summary.synced_series, summary.total_elements, summary.has_more_pages
    );

    println!("== Local store (SQLite) ==");
    let rows = store::series::list_series(&conn, &args.server_id, summary.synced_series as i64, 0)
        .map_err(db_err)?;
    for row in &rows {
        println!("  {} [{}]", row.name, row.remote_id);
    }
    if rows.is_empty() {
        return Ok(());
    }

    println!("== Cover cache (fixture, facade path) ==");
    let app = crate_facade(&args.db);
    let first = &rows[0];
    let cover_path = app
        .ensure_cover_with(
            &FakeCoverFetcher,
            &args.base_url,
            &args.server_id,
            &first.remote_id,
        )
        .await?;
    println!("  cached {} -> {}", first.name, cover_path);

    println!("== SQLite cover bookkeeping (thumbnails) ==");
    print_thumbnail_row(&conn, &args.server_id, &first.remote_id)?;
    Ok(())
}

/// Fake series endpoint returning the shared fixture.
struct FakeSeriesFetcher(SeriesPage);

impl SeriesFetcher for FakeSeriesFetcher {
    async fn series_page(
        &self,
        _request: &komga_core::api::series::PageRequest,
    ) -> std::result::Result<SeriesPage, ApiError> {
        Ok(self.0.clone())
    }
}

/// Fake cover endpoint returning deterministic bytes.
struct FakeCoverFetcher;

impl komga_core::cache::cover::BytesFetcher for FakeCoverFetcher {
    async fn fetch_bytes(&self, _url: &str) -> Result<Vec<u8>> {
        Ok(b"fake-cover-bytes".to_vec())
    }
}

fn db_err(e: rusqlite::Error) -> ApiError {
    ApiError::Database {
        message: e.to_string(),
    }
}
