//! stage10_smoke — the release-hardening acceptance run.
//!
//! Stage 5–9 asked whether the client can sync, read and download. This one asks
//! whether it can *explain itself*: are the lines it writes actually captured, is
//! the state it reports the state in the file, does a failure arrive with a code
//! the UI can branch on, and does a dead credential become visible without the
//! user noticing it first.
//!
//! Those are the questions the Release Hardening list answers, and each of them
//! has a cheap way to pass a test and be false in production: a log ring that is
//! never installed, a health report computed from a constant, an error that
//! arrives as an unparseable sentence, an "expired" flag that a lost tunnel sets
//! and a real 401 does not. So every phase here prints `metric name=value` lines
//! and `scripts/e2e_stage10_core.sh` asserts them against witnesses that are not
//! the core's own word — `sqlite3` on the database file, `find` on the cache
//! tree, and the fixture server's journal for what was actually requested.
//!
//!   --phase log-ring         lines the core wrote during a real run are
//!                            readable, the sweep that healed an orphan file
//!                            says so, and a clean sweep says nothing.
//!   --phase snapshot         every scalar of the self-report, for the script to
//!                            compare against the file it describes.
//!   --phase error-codes      four forced failures and the code each must
//!                            arrive with.
//!   --phase auth-expiry      401 → expired, an outage in between changes
//!                            nothing, the fixed key → valid, and the writes
//!                            the 401 parked reach the server afterwards.
//!   --phase facade           the same four surfaces through the FFI entry
//!                            points the app actually calls.
use std::future::Future;
use std::io::Write;

use komga_core::ffi::application::App;
use komga_core::ffi::error::{CoreError, ErrorCode};

type Smoke = Result<(), Box<dyn std::error::Error>>;

#[derive(Default, Clone)]
struct Args {
    db: String,
    server: String,
    base_url: String,
    key: String,
    /// A key the server will refuse.
    bad_key: String,
    /// A URL that refuses connections, for the "no route" case.
    dead_url: String,
    phase: String,
    /// Where the fixture server reads its forced-status file from.
    fault_file: String,
}

const USAGE: &str = "\
usage: stage10_smoke --phase <log-ring|snapshot|error-codes|auth-expiry|facade> \\
       --db <path> --server <id> --base-url <url> --key <key> [options]

  --bad-key <key>     a credential the server refuses (401)
  --dead-url <url>    an address that refuses connections (no route)
  --book <id>         a book already mirrored in the local store";

fn parse() -> Args {
    let mut args = Args {
        server: "s1".to_string(),
        ..Default::default()
    };
    let mut iter = std::env::args().skip(1);
    while let Some(flag) = iter.next() {
        match flag.as_str() {
            "--db" => args.db = iter.next().expect("--db"),
            "--server" => args.server = iter.next().expect("--server"),
            "--base-url" => args.base_url = iter.next().expect("--base-url"),
            "--key" => args.key = iter.next().expect("--key"),
            "--bad-key" => args.bad_key = iter.next().expect("--bad-key"),
            "--dead-url" => args.dead_url = iter.next().expect("--dead-url"),
            "--phase" => args.phase = iter.next().expect("--phase"),
            "--fault-file" => args.fault_file = iter.next().expect("--fault-file"),
            "--help" | "-h" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            other => panic!("unknown argument {other}"),
        }
    }
    assert!(!args.db.is_empty(), "--db is required\n{USAGE}");
    assert!(!args.phase.is_empty(), "--phase is required\n{USAGE}");
    args
}

fn metric(name: &str, value: impl std::fmt::Display) {
    println!("metric {name}={value}");
}

/// Fail the phase, naming the claim that did not hold. Metrics printed before
/// the failure have already been flushed, so a failing phase still reports as
/// much as it managed to measure.
fn require(condition: bool, claim: &str) {
    assert!(condition, "assertion failed: {claim}");
}

fn block_on<F: Future>(future: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime")
        .block_on(future)
}

fn app(args: &Args) -> App {
    App::new(args.db.clone())
}

/// Ask the running server to answer with a status code instead of content.
/// Returns the fault file's previous content so the caller can restore it.
fn set_fault(args: &Args, status: u16) -> Result<String, Box<dyn std::error::Error>> {
    let path = fault_path(args);
    let previous = std::fs::read_to_string(&path).unwrap_or_default();
    std::fs::write(&path, status.to_string())?;
    Ok(previous)
}

fn clear_fault(args: &Args, previous: String) {
    let path = fault_path(args);
    let _ = std::fs::write(&path, previous);
}

/// The fixture server's forced-status file. Named by the caller rather than
/// derived, because the server was told where to look for it and a guess that
/// lands beside the database silently stops forcing anything: the phase then
/// reports a successful bootstrap as "no error" and the 503 case never runs.
fn fault_path(args: &Args) -> std::path::PathBuf {
    assert!(
        !args.fault_file.is_empty(),
        "--fault-file is required by the phases that force a status"
    );
    std::path::PathBuf::from(&args.fault_file)
}

// MARK: - log-ring

/// Lines the core wrote during a real run must be readable without the caller
/// having enabled anything, and the specific line the phase produces must
/// correspond to something the filesystem can confirm.
fn phase_log_ring(args: &Args) -> Smoke {
    let app = app(args);
    let cache_root = std::path::Path::new(&args.db)
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."))
        .join("cache");
    let pages = cache_root.join("pages");
    std::fs::create_dir_all(&pages)?;

    // An orphan: a file in the pages tier with no ledger row. Nothing repairs it
    // except the sweep, and the sweep is one of the few core paths that logs.
    let orphan = pages.join("orphan-stage10.png");
    std::fs::write(&orphan, b"not really a page, and nobody owns it")?;
    metric(
        "orphan_before",
        std::fs::metadata(&orphan).map(|m| m.len()).unwrap_or(0),
    );

    let before = komga_core::diagnostics::log::stats();
    require(before.installed, "the ring did not own the log backend");
    metric("installed", i64::from(before.installed));
    metric("retained_before", before.retained);

    let sweep = app.reader_reconcile_cache()?;
    metric("sweep_orphan_files", sweep.orphan_files);
    metric("sweep_freed_bytes", sweep.freed_bytes);
    require(
        sweep.orphan_files >= 1,
        "the sweep did not find the orphan it was set up to find",
    );

    let after = komga_core::diagnostics::log::stats();
    let lines = komga_core::diagnostics::log::records(64, None);
    let mentioned = lines
        .iter()
        .any(|record| record.message.contains("cache sweep") && record.level == "info");
    metric("sweep_line_in_ring", i64::from(mentioned));
    require(
        after.retained > before.retained,
        "a sweep that removed a file wrote nothing readable",
    );
    metric("retained_after", after.retained);
    metric("dropped", after.dropped);
    metric("warnings", after.warnings);
    metric("errors", after.errors);
    require(mentioned, "the sweep line is not in the ring");

    // A second sweep finds nothing and must say nothing: the line means
    // "something was wrong" only if an all-clear does not also write it.
    let quiet_before = komga_core::diagnostics::log::stats().retained;
    let again = app.reader_reconcile_cache()?;
    let quiet_after = komga_core::diagnostics::log::stats().retained;
    metric("second_sweep_orphans", again.orphan_files);
    metric("quiet_lines", quiet_after - quiet_before);
    require(
        again.orphan_files == 0 && quiet_after == quiet_before,
        "a clean sweep logged, so the sweep line stops meaning anything",
    );
    metric("orphan_after", i64::from(orphan.exists()));
    Ok(())
}

// MARK: - snapshot

fn phase_snapshot(args: &Args) -> Smoke {
    let app = app(args);
    // A snapshot over an empty database agrees with itself about nothing. Seed
    // through the offline demo first: it writes series, books, covers on disk
    // and sync state without ever contacting a server, which is the only way to
    // get content in here without also moving the credential verdict the phase
    // goes on to report as `unknown`.
    if app.count_series(&args.server)? == 0 {
        block_on(app.bootstrap_demo(args.server.clone()))?;
    }
    let snap = app.diagnostics_snapshot(&args.server)?;
    metric("schema_version", snap.db.schema_version);
    metric("integrity", &snap.db.integrity);
    metric("journal_mode", &snap.db.journal_mode);
    metric("page_size", snap.db.page_size);
    metric("page_count", snap.db.page_count);
    metric("file_bytes", snap.db.file_bytes);
    metric("busy_timeout_ms", snap.db.busy_timeout_ms);
    metric("foreign_keys", i64::from(snap.db.foreign_keys_on));
    metric("table_entries", snap.db.tables.len());
    for entry in &snap.db.tables {
        metric(&format!("rows_{}", entry.table), entry.rows);
    }
    metric("auth_state", &snap.auth.state);
    metric("auth_at_is_empty", i64::from(snap.auth.at.is_empty()));
    metric("outbox_queued_rows", snap.outbox_queued_rows);
    metric("outbox_pending", snap.outbox.pending);
    metric("outbox_waiting", snap.outbox.waiting);
    metric("outbox_failed", snap.outbox.failed);
    metric("outbox_total", snap.outbox.total);
    metric("sync_rows", snap.sync.len());
    for row in &snap.sync {
        metric(&format!("sync_{}", row.entity_type), &row.sync_status);
    }
    metric("cache_page_bytes", snap.cache.page_bytes);
    metric("cache_prefetch_bytes", snap.cache.prefetch_bytes);
    metric("cache_ledger_bytes", snap.cache.ledger_bytes);
    metric("cache_budget_bytes", snap.cache.pool_budget_bytes);
    metric("open_readers", snap.cache.open_readers);
    metric("storage_download_bytes", snap.storage.download_bytes);
    metric("storage_cache_total", snap.storage.cache_total_bytes);
    metric("queue_entries", snap.queue.len());
    for entry in &snap.queue {
        metric(&format!("queue_{}_books", entry.state), entry.books);
        metric(
            &format!("queue_{}_bytes_done", entry.state),
            entry.bytes_done,
        );
    }
    metric("contract_version", &snap.policy.contract_version);
    metric("snapshot_version", &snap.policy.snapshot_version);
    metric("min_server_version", &snap.policy.min_server_version);
    metric("log_installed", i64::from(snap.log.installed));
    metric("log_retained", snap.log.retained);
    metric("log_errors", snap.log.errors);
    metric("log_max_level", &snap.log.max_level);

    // Reading the report must not change what it reports: no sweep, no
    // reconcile, no eviction, no credential write. Two reads must agree.
    let again = app.diagnostics_snapshot(&args.server)?;
    let encoded_first = serde_json::to_string(&snap)?;
    let encoded_second = serde_json::to_string(&again)?;
    let mut diff = 0;
    for (a, b) in snap.db.tables.iter().zip(again.db.tables.iter()) {
        if a.rows != b.rows {
            diff += 1;
        }
    }
    metric("table_drift_between_reads", diff);
    require(
        encoded_first == encoded_second,
        "asking for the snapshot changed the snapshot",
    );
    Ok(())
}

// MARK: - error-codes

fn code_of(error: &CoreError) -> String {
    error.code.as_str().to_string()
}

fn phase_error_codes(args: &Args) -> Smoke {
    let app = app(args);

    // 1. A key the server refuses.
    let rejected = block_on(app.bootstrap(
        args.server.clone(),
        args.base_url.clone(),
        args.bad_key.clone(),
    ));
    let error = rejected.err().ok_or("a refused key reported no error")?;
    let mapped = CoreError::from(error.clone());
    metric("code_auth", code_of(&mapped));
    metric("auth_retryable", i64::from(mapped.retryable));
    metric("auth_needs_user", i64::from(mapped.needs_user));
    metric("auth_message_kept", i64::from(!mapped.message.is_empty()));
    require(
        mapped.code == ErrorCode::AuthExpired,
        &format!("a refused key arrived as {:?}", mapped.code),
    );
    require(
        !mapped.retryable,
        "a rejected key must not be retried by itself",
    );
    require(
        mapped.needs_user,
        "a rejected key is the one thing to tell the user",
    );

    // 2. An address that refuses the connection.
    let unreachable =
        block_on(app.bootstrap(args.server.clone(), args.dead_url.clone(), args.key.clone()));
    let error = unreachable
        .err()
        .ok_or("an unreachable server reported no error")?;
    let mapped = CoreError::from(error);
    metric("code_network", code_of(&mapped));
    require(
        mapped.code == ErrorCode::NetworkUnavailable,
        &format!("expected NetworkUnavailable, got {:?}", mapped.code),
    );
    metric("network_retryable", i64::from(mapped.retryable));
    metric("network_needs_user", i64::from(mapped.needs_user));

    // 3. A URL that is not a URL.
    let malformed = block_on(app.bootstrap(
        args.server.clone(),
        "not a url".to_string(),
        args.key.clone(),
    ));
    let error = malformed.err().ok_or("a malformed url reported no error")?;
    let mapped = CoreError::from(error);
    metric("code_invalid", code_of(&mapped));
    require(
        mapped.code == ErrorCode::InvalidInput,
        &format!("expected InvalidInput, got {:?}", mapped.code),
    );
    metric("invalid_retryable", i64::from(mapped.retryable));

    // 4. A server that answers 503 for everything.
    let previous = set_fault(args, 503)?;
    let failing =
        block_on(app.bootstrap(args.server.clone(), args.base_url.clone(), args.key.clone()));
    clear_fault(args, previous);
    let error = failing.err().ok_or("a 503 reported no error")?;
    let mapped = CoreError::from(error);
    metric("code_server", code_of(&mapped));
    require(
        mapped.code == ErrorCode::ServerError,
        &format!("expected ServerError, got {:?}", mapped.code),
    );
    metric("server_retryable", i64::from(mapped.retryable));
    metric("server_needs_user", i64::from(mapped.needs_user));

    // The message survives the mapping: a support export has to be able to show
    // what the server said, not only which bucket it fell into.
    metric("codes_distinct", {
        let set: std::collections::BTreeSet<String> = [
            code_of(&CoreError::from(
                komga_core::api::error::ApiError::Authentication,
            )),
            code_of(&CoreError::from(komga_core::api::error::ApiError::Network)),
            code_of(&CoreError::from(
                komga_core::api::error::ApiError::InvalidInput {
                    message: "x".into(),
                },
            )),
        ]
        .into_iter()
        .collect();
        set.len()
    });
    Ok(())
}

// MARK: - auth-expiry

fn phase_auth_expiry(args: &Args) -> Smoke {
    let app = app(args);
    // A server this client has never spoken to. Checked under its own id, so
    // the mirror below can populate the store without erasing the case.
    require(
        app.auth_state("never-contacted")?.state == "unknown",
        "a server that was never used claimed something about its credential",
    );
    metric("state_initial", &app.auth_state("never-contacted")?.state);

    // Mirror the real library first. The offline demo seeds a PDF-only library,
    // and a page-progress write for a PDF is refused by design — that would
    // park the write in `failed` for a reason that has nothing to do with this
    // phase. Reading a comic and having the key die mid-book is the story here.
    let mirrored =
        block_on(app.full_sync(args.server.clone(), args.base_url.clone(), args.key.clone()))?;
    metric("mirrored_series", mirrored.series);
    let book = image_book(&app, args)?;
    metric("book_used", &book);
    metric("state_after_mirror", &app.auth_state(&args.server)?.state);

    // 1. The key dies.
    let rejected = block_on(app.bootstrap(
        args.server.clone(),
        args.base_url.clone(),
        args.bad_key.clone(),
    ));
    metric("bootstrap_rejected", i64::from(rejected.is_err()));
    let expired = app.auth_state(&args.server)?;
    metric("state_after_401", &expired.state);
    metric("expiry_moment_recorded", i64::from(!expired.at.is_empty()));

    // 2. An outage in between says nothing about a key, in either direction.
    let outage =
        block_on(app.bootstrap(args.server.clone(), args.dead_url.clone(), args.key.clone()));
    metric("outage_also_failed", i64::from(outage.is_err()));
    let still = app.auth_state(&args.server)?;
    metric("state_after_outage", &still.state);

    // 3. A write made while the credential is dead. It must not reach the
    // server and must not be dropped, and it must stay *pending*: a row that
    // lands in `failed` here would be a queue that gave up on the user.
    app.set_read_progress(&args.server, &book, 7, false)?;
    let queued = app.outbox_status(&args.server)?;
    metric("queued_before_upload", queued.pending + queued.waiting);
    let blocked = block_on(app.upload_outbox(
        args.server.clone(),
        args.base_url.clone(),
        args.bad_key.clone(),
    ))?;
    metric("upload_blocked_status", &blocked.status);
    metric("upload_blocked_uploaded", blocked.uploaded);
    metric("upload_blocked_considered", blocked.considered);
    let after_blocked = app.outbox_status(&args.server)?;
    metric(
        "queued_after_blocked_upload",
        after_blocked.pending + after_blocked.waiting,
    );
    metric("failed_after_blocked_upload", after_blocked.failed);
    require(
        blocked.uploaded == 0 && after_blocked.failed == 0,
        "a 401 mid-queue either sent something or gave up on the write",
    );

    // 4. The user fixes the key. Only a round trip that succeeds can say so.
    let accepted =
        block_on(app.bootstrap(args.server.clone(), args.base_url.clone(), args.key.clone()));
    metric("bootstrap_accepted", i64::from(accepted.is_ok()));
    let valid = app.auth_state(&args.server)?;
    metric("state_after_success", &valid.state);

    // 5. And the parked write still goes out, on its own.
    let uploaded =
        block_on(app.upload_outbox(args.server.clone(), args.base_url.clone(), args.key.clone()))?;
    metric("upload_after_fix_status", &uploaded.status);
    metric("upload_after_fix_uploaded", uploaded.uploaded);
    metric("upload_after_fix_considered", uploaded.considered);
    let drained = app.outbox_status(&args.server)?;
    metric(
        "queued_after_success",
        drained.pending + drained.waiting + drained.failed,
    );
    require(
        uploaded.uploaded == 1,
        "the write the 401 parked never reached the server once the key worked",
    );
    Ok(())
}

/// The first mirrored book that takes page progress at all. The client refuses
/// a PDF's page write by design, so a phase that needs a queued write must not
/// pick one by accident.
fn image_book(app: &App, args: &Args) -> Result<String, Box<dyn std::error::Error>> {
    let _ = app;
    let conn = komga_core::store::open(&args.db)?;
    let found: Option<String> = conn
        .query_row(
            "SELECT remote_id FROM books WHERE server_id = ?1
               AND (media_type IS NULL OR media_type NOT LIKE 'application/%')
             ORDER BY remote_id LIMIT 1",
            rusqlite::params![args.server],
            |row| row.get::<_, String>(0),
        )
        .ok();
    found.ok_or_else(|| "the mirrored library holds no book that takes page progress".into())
}

// MARK: - facade

/// The same surfaces through the FFI entry points the app calls. A hardening
/// feature that works when a test calls the inner method and not when the
/// boundary is crossed is not shipped.
fn phase_facade(args: &Args) -> Smoke {
    let db = args.db.clone();
    let server = args.server.clone();

    // Give the ring something to report first. A facade phase that only reads
    // the log could pass on an empty ring, which is precisely the state the
    // Stage 10 log work was created to end.
    let app = app(args);
    let pages = std::path::Path::new(&args.db)
        .parent()
        .unwrap_or_else(|| std::path::Path::new("."))
        .join("cache")
        .join("pages");
    std::fs::create_dir_all(&pages)?;
    let orphan = pages.join("facade-orphan.png");
    std::fs::write(&orphan, b"an orphan for the facade to report")?;
    let sweep = app.reader_reconcile_cache()?;
    metric("facade_sweep_orphans", sweep.orphan_files);
    require(
        sweep.orphan_files >= 1,
        "the facade phase seeded an orphan the sweep did not find",
    );

    let snapshot = komga_core::ffi::bridge::diagnostics_snapshot(db.clone(), server.clone())
        .map_err(|error| -> Box<dyn std::error::Error> {
            format!("diagnostics_snapshot: {error}").into()
        })?;
    metric("ffi_schema_version", snapshot.db.schema_version);
    metric("ffi_log_installed", i64::from(snapshot.log.installed));

    let logs = komga_core::ffi::bridge::diagnostics_logs(20, "info".to_string())
        .map_err(|error| -> Box<dyn std::error::Error> { error.message.as_str().into() })?;
    metric("ffi_log_records", logs.len());
    let stats = komga_core::ffi::bridge::diagnostics_log_stats()?;
    metric("ffi_log_retained", stats.retained);
    metric("ffi_log_capacity", stats.capacity);
    require(
        stats.retained >= i64::try_from(logs.len()).unwrap_or(i64::MAX),
        "the stats and the record list disagree about how much is held",
    );

    // A filter box that receives a nonsense name must show everything rather
    // than an empty list, which reads as "the client logged nothing".
    let nonsense = komga_core::ffi::bridge::diagnostics_logs(50, "everything".to_string())?;
    metric("ffi_log_unfiltered", nonsense.len());
    let errored = komga_core::ffi::bridge::diagnostics_logs(50, "error".to_string())?;
    metric("ffi_log_errors_only", errored.len());
    require(
        i64::try_from(nonsense.len()).unwrap_or(0) >= stats.retained.max(0) || stats.retained == 0,
        "an unrecognised level name hid lines",
    );

    let auth = komga_core::ffi::bridge::auth_state(db, server)?;
    metric("ffi_auth_state", &auth.state);
    Ok(())
}

fn main() {
    let args = parse();
    let outcome: Smoke = match args.phase.as_str() {
        "log-ring" => phase_log_ring(&args),
        "snapshot" => phase_snapshot(&args),
        "error-codes" => phase_error_codes(&args),
        "auth-expiry" => phase_auth_expiry(&args),
        "facade" => phase_facade(&args),
        other => panic!("unknown --phase {other}"),
    };
    let mut stdout = std::io::stdout();
    let _ = stdout.flush();
    match outcome {
        Ok(()) => println!("ok: phase {} passed", args.phase),
        Err(error) => {
            println!("fail: phase {} {}", args.phase, error);
            std::process::exit(1);
        }
    }
}
