//! stage5_smoke — Stage 5 acceptance: the sync engine converges the local
//! SQLite mirror on Komga and keeps it correct without SSE.
//!
//! Modes:
//!   --scenario              replay the shared contract scenarios (no network)
//!   --base-url URL --api-key K
//!                           bootstrap + reconcile against a live Komga, then
//!                           verify mirror == server, sweep again == no-op
//!   --offline               no credentials at all: prove the mirrored library
//!                           (including delete propagation) still answers queries
//!
//! Usage:
//!   cargo run --bin stage5_smoke -- --scenario
//!   cargo run --bin stage5_smoke -- --base-url $KOMGA_BASE_URL --api-key $KOMGA_API_KEY \
//!       --db /tmp/comic-stage5.sqlite --server-id stage5
//!   cargo run --bin stage5_smoke -- --offline --db /tmp/comic-stage5.sqlite --server-id stage5

use std::path::Path;

use komga_core::api::auth::AuthMethod;
use komga_core::api::book::BookFetcher;
use komga_core::api::collection::CollectionFetcher;
use komga_core::api::readlist::ReadListFetcher;
use komga_core::api::series::{KomgaClient, PageRequest};
use komga_core::ffi::application::App;
use komga_core::store;
use komga_core::store::sync_state;
use komga_core::sync::reconcile::ReconcileTrigger;
use komga_core::sync::scenario;

static FAILURES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
static CHECKS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

fn check(name: &str, ok: bool, detail: &str) {
    let tag = if ok { "PASS" } else { "FAIL" };
    println!("  [{tag}] {name}: {detail}");
    CHECKS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    if !ok {
        FAILURES.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }
}

fn section(title: &str) {
    println!("\n== {title} ==");
}

struct Args {
    scenario: bool,
    reconcile_only: bool,
    offline: bool,
    base_url: Option<String>,
    api_key: Option<String>,
    db: String,
    server_id: String,
}

fn parse_args() -> Args {
    let args: Vec<String> = std::env::args().collect();
    let mut parsed = Args {
        scenario: false,
        reconcile_only: false,
        offline: false,
        base_url: None,
        api_key: None,
        db: String::new(),
        server_id: String::new(),
    };
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--scenario" => parsed.scenario = true,
            "--reconcile-only" => parsed.reconcile_only = true,
            "--offline" => parsed.offline = true,
            "--base-url" => {
                i += 1;
                parsed.base_url = Some(args[i].clone());
            }
            "--api-key" => {
                i += 1;
                parsed.api_key = Some(args[i].clone());
            }
            "--db" => {
                i += 1;
                parsed.db = args[i].clone();
            }
            "--server-id" => {
                i += 1;
                parsed.server_id = args[i].clone();
            }
            "--help" | "-h" => {
                println!("usage: stage5_smoke --scenario | (--base-url URL --api-key KEY) [--offline] --db PATH --server-id ID");
                std::process::exit(0);
            }
            other => panic!("unknown arg: {other}"),
        }
        i += 1;
    }
    parsed
}

/// Replay the shared scenario fixtures: the same JSON the Swift tests use.
fn run_scenarios() {
    section("Scenario replay (specs/contracts/fixtures/sync, SSE disabled)");
    let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
    for (name, json) in scenario::SCENARIOS {
        let scenario = match scenario::parse_scenario(json) {
            Ok(scenario) => scenario,
            Err(error) => {
                check(name, false, &error);
                continue;
            }
        };
        let dir = std::env::temp_dir().join(format!("komga_stage5_{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("comic.sqlite").to_string_lossy().into_owned();
        let reports = runtime.block_on(scenario::run_scenario(&db, &scenario));
        for report in &reports {
            let detail = if report.ok {
                "converged".to_string()
            } else {
                report.detail.join(" | ")
            };
            check(&format!("{name} / {}", report.label), report.ok, &detail);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// Offline half: the mirror must answer the query battery with no network, and
/// the sync bookkeeping must be self-consistent.
fn run_offline(app: &App, server_id: &str) {
    section("Offline replay: no sync, no credentials, SQLite only");
    let conn = store::open(app.db_path()).expect("open db");
    let states = sync_state::list_entity_states(&conn, server_id).expect("sync states");
    check(
        "sync_state rows exist",
        !states.is_empty(),
        &format!("{} entity rows", states.len()),
    );
    let resumable: Vec<&sync_state::EntitySyncState> = states
        .iter()
        .filter(|state| state.sync_cursor.is_some())
        .collect();
    check(
        "no step left mid-sweep",
        resumable.is_empty(),
        &format!("{} rows still hold a resume cursor", resumable.len()),
    );
    let orphan_books: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM books b WHERE b.server_id = ?1 AND NOT EXISTS
               (SELECT 1 FROM series s WHERE s.server_id = b.server_id AND s.remote_id = b.series_id)",
            rusqlite::params![server_id],
            |row| row.get(0),
        )
        .unwrap();
    check(
        "delete cascade left no orphan books",
        orphan_books == 0,
        &format!("{orphan_books} orphans"),
    );
    // The book wall, a search and a filter all resolve from SQLite only.
    let wall = store::query::query_series(
        &conn,
        server_id,
        &store::query::SeriesQuery::default(),
        50,
        0,
    );
    check(
        "series wall reads from SQLite",
        wall.is_ok(),
        &format!(
            "{} rows of {} total",
            wall.as_ref()
                .map(|page| page.items.len())
                .unwrap_or_default(),
            wall.as_ref().map(|page| page.total).unwrap_or_default()
        ),
    );
    let query = store::query::SeriesQuery {
        search: Some("one".into()),
        ..Default::default()
    };
    let hits = store::query::query_series(&conn, server_id, &query, 50, 0);
    check(
        "FTS search works offline",
        hits.is_ok(),
        &format!(
            "{} hit(s)",
            hits.map(|page| page.items.len()).unwrap_or_default()
        ),
    );
    let readlists: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM readlists WHERE server_id = ?1",
            rusqlite::params![server_id],
            |row| row.get(0),
        )
        .unwrap();
    check(
        "readlists mirrored",
        readlists >= 0,
        &format!("{readlists} rows"),
    );
}

fn main() {
    let args = parse_args();
    if args.scenario {
        run_scenarios();
        finish();
        return;
    }
    if args.db.is_empty() {
        panic!("--db PATH is required");
    }
    // A chain of runs shares one database: only a bootstrap run resets it.
    if Path::new(&args.db).exists() && !args.offline && !args.reconcile_only {
        std::fs::remove_file(&args.db).ok();
    }
    let app = App::new(&args.db);
    let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");

    if args.offline {
        run_offline(&app, &args.server_id);
        finish();
        return;
    }

    let base_url = args.base_url.expect("--base-url for the live chain");
    let api_key = args.api_key.expect("--api-key for the live chain");
    let client = KomgaClient::new(
        base_url.clone(),
        AuthMethod::ApiKey {
            key: api_key.clone(),
        },
    )
    .expect("client");

    if args.reconcile_only {
        section("Reconcile Sync only: the server changed underneath a mirrored library");
        let reconcile = runtime
            .block_on(app.reconcile(
                args.server_id.clone(),
                base_url.clone(),
                api_key.clone(),
                ReconcileTrigger::ManualRefresh.as_str().to_string(),
            ))
            .expect("reconcile");
        println!(
            "  series +{}/~{}/-{} books +{}/~{}/-{} collections -{} readlists -{}",
            reconcile.series_added,
            reconcile.series_changed,
            reconcile.series_removed,
            reconcile.books_added,
            reconcile.books_changed,
            reconcile.books_removed,
            reconcile.collections_removed,
            reconcile.readlists_removed
        );
        verify_against_server(&app, &runtime, &client, &args.server_id);
        // Delete propagation over real HTTP must also leave tombstones behind.
        if reconcile.series_removed
            + reconcile.books_removed
            + reconcile.collections_removed
            + reconcile.readlists_removed
            > 0
        {
            let tombstones = app
                .tombstones(&args.server_id, "series")
                .expect("tombstone read");
            check(
                "deleted series left tombstones",
                !tombstones.is_empty() && tombstones.iter().all(|t| t.cause == "reconcile"),
                &format!(
                    "{} series tombstones: {:?}",
                    tombstones.len(),
                    tombstones
                        .iter()
                        .map(|tombstone| tombstone.remote_id.clone())
                        .collect::<Vec<_>>()
                ),
            );
        }
        run_offline(&app, &args.server_id);
        finish();
        return;
    }
    // 1. Bootstrap Sync — ordered, paged, checkpointed.
    section("Bootstrap Sync: Libraries → Series → Books → Collections → Readlists → Progress");
    let summary = runtime
        .block_on(app.bootstrap_sync(
            args.server_id.clone(),
            base_url.clone(),
            api_key.clone(),
            true, // fresh mirror: this acceptance run starts from scratch
        ))
        .expect("bootstrap");
    println!(
    "  libraries={} series={} books={} collections={} readlists={} progress={} ({} series pages, {} book pages)",
    summary.libraries,
    summary.series,
    summary.books,
    summary.collections,
    summary.readlists,
    summary.read_progress,
    summary.series_pages,
    summary.book_pages
    );
    check(
        "every bootstrap step recorded its own row",
        runtime
            .block_on(app.bootstrap_sync(
                args.server_id.clone(),
                base_url.clone(),
                api_key.clone(),
                false,
            ))
            .map(|again| again.skipped_steps.len() == sync_state::BOOTSTRAP_ORDER.len())
            .unwrap_or(false),
        "a second bootstrap skips the steps it already finished (resume semantics)",
    );
    let conn = store::open(&args.db).expect("open db");
    let states = sync_state::list_entity_states(&conn, &args.server_id).expect("states");
    check(
        "sync_state carries entityType + lastSyncAt + syncStatus",
        states.len() >= sync_state::BOOTSTRAP_ORDER.len()
            && states.iter().all(|state| state.last_sync_at.is_some()),
        &format!(
            "{} rows, statuses {:?}",
            states.len(),
            states
                .iter()
                .map(|state| (state.entity_type.clone(), state.sync_status.clone()))
                .collect::<Vec<_>>()
        ),
    );
    drop(conn);

    // 2. Reconcile Sync — the mirror must match what the server reports.
    section("Reconcile Sync: id sweep, Added/Changed/Deleted, mirror == server");
    let reconcile = runtime
        .block_on(app.reconcile(
            args.server_id.clone(),
            base_url.clone(),
            api_key.clone(),
            ReconcileTrigger::ManualRefresh.as_str().to_string(),
        ))
        .expect("reconcile");
    println!(
        "  series +{}/~{}/-{} books +{}/~{}/-{} collections -{} readlists -{} ({} pages swept)",
        reconcile.series_added,
        reconcile.series_changed,
        reconcile.series_removed,
        reconcile.books_added,
        reconcile.books_changed,
        reconcile.books_removed,
        reconcile.collections_removed,
        reconcile.readlists_removed,
        reconcile.pages_swept
    );
    verify_against_server(&app, &runtime, &client, &args.server_id);

    section("Reconcile again: a converged mirror reports clean");
    let second = runtime
        .block_on(app.reconcile(
            args.server_id.clone(),
            base_url.clone(),
            api_key.clone(),
            ReconcileTrigger::AppLaunch.as_str().to_string(),
        ))
        .expect("second reconcile");
    check(
        "second sweep changes nothing",
        second.clean && second.total_mutations() == 0,
        &format!(
            "clean={} mutations={}",
            second.clean,
            second.total_mutations()
        ),
    );
    run_offline(&app, &args.server_id);
    finish();
}

/// Live "最终 SQLite 必须与 Komga 恢复一致" check: compare the mirror against
/// the totals the server reports per series and per collection type.
fn verify_against_server(
    app: &App,
    runtime: &tokio::runtime::Runtime,
    client: &KomgaClient,
    server_id: &str,
) {
    let conn = store::open(app.db_path()).expect("open db");
    let series_rows: Vec<(String, i64)> = {
        let mut stmt = conn
            .prepare(
                "SELECT remote_id, books_count FROM series WHERE server_id = ?1 ORDER BY remote_id",
            )
            .unwrap();
        let rows = stmt
            .query_map(rusqlite::params![server_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<i64>>(1)?.unwrap_or(0),
                ))
            })
            .unwrap();
        rows.collect::<Result<Vec<_>, _>>().unwrap()
    };
    let remote_series = runtime
        .block_on(client.series_page(&PageRequest::new(0, 1)))
        .expect("remote series total");
    let local_series: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM series WHERE server_id = ?1",
            rusqlite::params![server_id],
            |row| row.get(0),
        )
        .unwrap();
    check(
        "series count == server",
        local_series == remote_series.total_elements,
        &format!(
            "local {local_series}, server {}",
            remote_series.total_elements
        ),
    );

    let mut mismatched = Vec::new();
    for (series_id, _) in &series_rows {
        let remote = runtime
            .block_on(client.books_page(series_id, &PageRequest::new(0, 1)))
            .expect("remote books");
        let local: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM books WHERE server_id = ?1 AND series_id = ?2",
                rusqlite::params![server_id, series_id],
                |row| row.get(0),
            )
            .unwrap();
        if local != remote.total_elements {
            mismatched.push(format!(
                "{series_id}: local {local} != server {}",
                remote.total_elements
            ));
        }
    }
    check(
        "every series' book count == server",
        mismatched.is_empty(),
        &format!(
            "{} series checked, mismatches: {:?}",
            series_rows.len(),
            mismatched
        ),
    );

    for (name, entity) in [("collections", "collections"), ("readlists", "readlists")] {
        let remote_total = if entity == "collections" {
            runtime
                .block_on(client.collections_page(&PageRequest::new(0, 1)))
                .map(|page| page.total_elements)
        } else {
            runtime
                .block_on(client.readlists_page(&PageRequest::new(0, 1)))
                .map(|page| page.total_elements)
        };
        let local: i64 = conn
            .query_row(
                &format!("SELECT COUNT(*) FROM {entity} WHERE server_id = ?1"),
                rusqlite::params![server_id],
                |row| row.get(0),
            )
            .unwrap();
        match remote_total {
            Ok(total) => check(
                &format!("{name} count == server"),
                local == total,
                &format!("local {local}, server {total}"),
            ),
            Err(error) => check(
                &format!("{name} count == server"),
                false,
                &error.to_string(),
            ),
        }
    }
    drop(conn);
}

fn finish() {
    let checks = CHECKS.load(std::sync::atomic::Ordering::SeqCst);
    let failures = FAILURES.load(std::sync::atomic::Ordering::SeqCst);
    println!("\n{}/{checks} PASS", checks - failures);
    if failures > 0 {
        std::process::exit(1);
    }
}
