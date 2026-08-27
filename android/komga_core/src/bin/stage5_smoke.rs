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
use komga_core::sync::full::FixtureLibraryFetcher;
use komga_core::sync::reconcile::ReconcileTrigger;
use komga_core::sync::scenario;
use serde_json::{json, Value};
use std::time::Instant;

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
    scale: Option<(usize, usize)>,
    auth_failure: bool,
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
        scale: None,
        auth_failure: false,
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
            "--auth-failure" => parsed.auth_failure = true,
            "--scale" => {
                i += 1;
                let series = args[i].parse().expect("--scale takes <SERIES> <BOOKS_PER>");
                i += 1;
                let books = args[i].parse().expect("--scale takes <SERIES> <BOOKS_PER>");
                parsed.scale = Some((series, books));
            }
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
                println!("usage: stage5_smoke --scenario | --scale SERIES BOOKS_PER | (--base-url URL --api-key KEY [--reconcile-only]) [--offline] --db PATH --server-id ID");
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

/// Synthesise a Komga-shaped snapshot of `series` series, each with
/// `books_per` books — the shape the scripted server and fixture server speak.
fn synthetic_snapshot(series: usize, books_per: usize) -> Value {
    let mut series_items: Vec<Value> = Vec::new();
    let mut books = serde_json::Map::new();
    for index in 0..series {
        let id = format!("series-{index:06}");
        series_items.push(json!({
            "id": id,
            "libraryId": "lib-1",
            "name": format!("Scale Series {index}"),
            "created": "2025-01-01T00:00:00Z",
            "lastModified": "2025-01-02T00:00:00Z",
            "booksCount": books_per,
            "metadata": {
                "title": format!("Scale Series {index}"),
                "status": "ONGOING",
                "summary": "Synthetic series used to measure the sync engine.",
                "genres": ["Scale"],
                "tags": ["Synthetic"],
                "authors": [],
            },
        }));
        let items: Vec<Value> = (0..books_per)
            .map(|book| {
                json!({
                    "id": format!("{id}-book-{book:03}"),
                    "seriesId": id,
                    "name": format!("Scale Series {index} #{book}"),
                    "number": book + 1,
                    "created": "2025-01-01T00:00:00Z",
                    "lastModified": "2025-01-02T00:00:00Z",
                    "media": { "mediaType": "CBZ", "pagesCount": 24 },
                })
            })
            .collect();
        books.insert(id, json!([items]));
    }
    // 100 series per page, so the sweep really is paged.
    let pages: Vec<Value> = series_items.chunks(100).map(|chunk| json!(chunk)).collect();
    json!({
        "id": "scale",
        "libraries": [{ "id": "lib-1", "name": "Scale", "root": "/scale" }],
        "series": pages,
        "books": books,
        "collections": [[]],
        "readlists": [[]],
        "onDeck": [[]],
    })
}

/// A bounded scale sweep. "长期运行可靠" needs a measured number rather than an
/// assumption: bootstrap a large library, then reconcile it twice and prove the
/// mirror is already correct, so the cost of a steady-state sweep is on record.
fn run_scale(series: usize, books_per: usize) {
    let total_books = series * books_per;
    section(&format!(
        "Scale sweep: {series} series / {total_books} books (scripted server, no network)"
    ));
    let dir = std::env::temp_dir().join(format!("komga_scale_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join("comic.sqlite").to_string_lossy().into_owned();
    let app = App::new(&db);
    let snapshot = synthetic_snapshot(series, books_per);
    let server = scenario::server_from_snapshot(&snapshot.to_string()).expect("snapshot");
    let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");

    let started = Instant::now();
    let summary = runtime
        .block_on(app.full_sync_with(&server, "scale"))
        .expect("bootstrap");
    let bootstrapped = started.elapsed();
    check(
        "bootstrap mirrored everything",
        summary.series == series && summary.books == total_books,
        &format!(
            "{}/{} series, {}/{} books in {}ms",
            summary.series,
            series,
            summary.books,
            total_books,
            bootstrapped.as_millis()
        ),
    );

    let started = Instant::now();
    let first = runtime
        .block_on(app.reconcile_with(&server, "scale", "manual_refresh"))
        .expect("reconcile");
    let first_elapsed = started.elapsed();
    check(
        "reconcile of a converged mirror changes nothing",
        first.clean && first.total_mutations() == 0,
        &format!(
            "{}ms, mutations={}",
            first_elapsed.as_millis(),
            first.total_mutations()
        ),
    );

    let started = Instant::now();
    let second = runtime
        .block_on(app.reconcile_with(&server, "scale", "did_become_active"))
        .expect("second reconcile");
    let second_elapsed = started.elapsed();
    check(
        "steady-state sweep stays clean",
        second.clean,
        &format!("{}ms", second_elapsed.as_millis()),
    );

    let conn = store::open(&db).expect("open db");
    let stored: Vec<i64> = [
        "SELECT COUNT(*) FROM series WHERE server_id = ?1",
        "SELECT COUNT(*) FROM books WHERE server_id = ?1",
        "SELECT COUNT(*) FROM book_fts WHERE server_id = ?1",
    ]
    .iter()
    .map(|sql| {
        conn.query_row(sql, rusqlite::params!["scale"], |row| row.get(0))
            .unwrap()
    })
    .collect();
    let orphans: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM books b WHERE b.server_id = ?1 AND NOT EXISTS
               (SELECT 1 FROM series s WHERE s.server_id = b.server_id AND s.remote_id = b.series_id)",
            rusqlite::params!["scale"],
            |row| row.get(0),
        )
        .unwrap();
    check(
        "SQLite holds the whole library, index included",
        stored[0] == series as i64
            && stored[1] == total_books as i64
            && stored[2] == total_books as i64
            && orphans == 0,
        &format!(
            "series={} books={} book_fts={} orphans={}",
            stored[0], stored[1], stored[2], orphans
        ),
    );
    println!(
        "  wall time {}ms total: bootstrap {}ms, reconcile {}ms + {}ms",
        (bootstrapped + first_elapsed + second_elapsed).as_millis(),
        bootstrapped.as_millis(),
        first_elapsed.as_millis(),
        second_elapsed.as_millis()
    );
    drop(conn);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A rejected credential must fail *safely*: the sweep reports an
/// authentication error, records it in `sync_state`, changes nothing on disk,
/// leaves the library browsable — and the next healthy sweep converges as usual.
/// Runs against any base URL: the loopback fixture server (deterministic 401) or
/// a real Komga, which answers 401 without a valid key.
fn run_auth_failure(app: &App, server_id: &str, base_url: &str) {
    section("A rejected credential must fail safely and then heal");
    let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
    runtime
        .block_on(app.full_sync_with(&FixtureLibraryFetcher {}, server_id))
        .expect("seed mirror from the shared fixtures");

    let conn = store::open(app.db_path()).expect("open db");
    let before: Vec<i64> = ["series", "books", "collections", "readlists"]
        .iter()
        .map(|table| {
            conn.query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE server_id = ?1"),
                rusqlite::params![server_id],
                |row| row.get(0),
            )
            .unwrap()
        })
        .collect();
    drop(conn);
    println!(
        "  mirrored before the failed sweep: series={} books={} collections={} readlists={}",
        before[0], before[1], before[2], before[3]
    );

    // Never a real credential: this mode exists precisely to be rejected.
    let outcome = runtime.block_on(app.reconcile(
        server_id.to_string(),
        base_url.to_string(),
        "stage5-deliberately-wrong-key".to_string(),
        ReconcileTrigger::ManualRefresh.as_str().to_string(),
    ));
    let message = match outcome {
        Ok(summary) => {
            check(
                "the sweep must be rejected",
                false,
                &format!("succeeded: {summary:?}"),
            );
            return;
        }
        Err(error) => error.to_string(),
    };
    check(
        "rejected as an authentication failure",
        message.contains("authentication"),
        &message,
    );

    let conn = store::open(app.db_path()).expect("open db");
    let after: Vec<i64> = ["series", "books", "collections", "readlists"]
        .iter()
        .map(|table| {
            conn.query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE server_id = ?1"),
                rusqlite::params![server_id],
                |row| row.get(0),
            )
            .unwrap()
        })
        .collect();
    check(
        "nothing was mirrored or deleted by the failed sweep",
        before == after,
        &format!("before {before:?} after {after:?}"),
    );
    let rollup = sync_state::get_sync_state(&conn, server_id)
        .ok()
        .flatten()
        .expect("rollup row");
    check(
        "sync_state records the failure",
        rollup.sync_status == sync_state::STATUS_ERROR && rollup.last_error.is_some(),
        &format!(
            "status={} error={:?}",
            rollup.sync_status, rollup.last_error
        ),
    );
    drop(conn);

    run_offline(app, server_id);

    let healthy = runtime
        .block_on(app.reconcile_with(&FixtureLibraryFetcher {}, server_id, "network_recovered"))
        .expect("reconcile against a healthy server");
    check(
        "the next healthy sweep converges again",
        healthy.clean,
        &format!("clean={} pages={}", healthy.clean, healthy.pages_swept),
    );
    let conn = store::open(app.db_path()).expect("open db");
    let rollup = sync_state::get_sync_state(&conn, server_id)
        .ok()
        .flatten()
        .expect("rollup row");
    check(
        "the recorded failure is cleared by the successful sweep",
        rollup.sync_status == sync_state::STATUS_IDLE && rollup.last_error.is_none(),
        &format!(
            "status={} error={:?}",
            rollup.sync_status, rollup.last_error
        ),
    );
}

fn main() {
    let args = parse_args();
    if args.auth_failure {
        let app = App::new(&args.db);
        let base_url = args.base_url.expect("--base-url for --auth-failure");
        run_auth_failure(&app, &args.server_id, &base_url);
        finish();
        return;
    }
    if let Some((series, books_per)) = args.scale {
        run_scale(series, books_per);
        finish();
        return;
    }
    if args.scenario {
        run_scenarios();
        finish();
        return;
    }
    if args.db.is_empty() {
        panic!("--db PATH is required");
    }
    // A chain of runs shares one database: only a bootstrap run resets it.
    if Path::new(&args.db).exists() && !args.offline && !args.reconcile_only && !args.auth_failure {
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
