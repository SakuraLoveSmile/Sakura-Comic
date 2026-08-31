//! stage9_smoke — the offline-download acceptance run.
//!
//! Stage 8 asked whether the reader survives; Stage 9 asks whether a book is still
//! there with the network off. Everything here drives the same `App` methods the FFI
//! calls, because the stage's whole claim is about the shipped surface: a queue that
//! works when a test calls `downloads::engine::run_pass` directly is not yet a
//! download manager.
//!
//! Every phase prints `metric name=value` lines. `scripts/e2e_stage9.sh` asserts on
//! those AND on two witnesses that cannot be talked into agreeing: the fixture
//! server's page journal (what was actually requested) and the filesystem (what is
//! actually on disk). A phase whose only evidence is the core's own report is not
//! evidence — that is how Stage 8's duplicate-request check passed for a whole
//! session while the code behind it was re-downloading a window on every resume.
//!
//!   --phase enqueue-pump       整书下载: queue a book and drive the pump to
//!                            completion. Requests, distinct pages, byte totals
//!                            from three sources (rows, manifest, `stat`).
//!   --phase kill-resume      真断点: the script SIGKILLs this process mid-pass and
//!                            runs `--phase kill-finish` as a second process. The
//!                            claim is that the queue resumes with no lost work and
//!                            re-fetches at most the page that was in flight.
//!   --phase kill-finish      the continuation of the kill above.
//!   --phase interrupted-write  the shapes a crash leaves, reached deterministically:
//!                            a `.part`, a book stuck in `downloading`, a row whose
//!                            file is gone, a file with no row, a corrupt file. Each
//!                            gets its own counter so a regression names its arm.
//!   --phase read-while       边下边读: read forward while the queue runs behind the
//!                            reader. Never asserts "no duplicate requests", because
//!                            one page in flight at the instant the reader turns to
//!                            it is correct behaviour, not a defect.
//!   --phase rotten-pages     单页失败恢复: every Nth page arrives truncated. Bad
//!                            pages burn their own attempts, the book keeps going,
//!                            and the book ends `failed` rather than silently short.
//!   --phase rotten-repair    the same database on a healthy server: the retry costs
//!                            exactly the pages that failed.
//!   --phase link-down        断网续传: the route dies mid-book and comes back. The
//!                            claim is that an outage spends zero attempts and needs
//!                            no user gesture to resume.
//!   --phase survives-everything
//!                            缓存清理不吃下载: an impossible cache budget, both
//!                            tier cleanups, the reconcile sweep, the mirror sweep
//!                            and a fresh process. One metric per attack.
//!   --phase offline-run      the acceptance proper: a fresh process, an
//!                            unreachable server, browse the local library, open the
//!                            downloaded book, read it cover to cover, save the
//!                            position. Server-side page reads must be zero.
//!   --phase reconnect-upload the route comes back; the queued position uploads.
//!   --phase storage          every figure the storage screen shows, for the script
//!                            to compare against `du` and `find`.
//!   --phase facade           every download entry point at least once, plus two
//!                            threads pumping at the same database.
//!   --phase remote-gone      the server 404s the book: terminal, with no attempt
//!                            burned and no loop.
//!
//! Usage (the script owns these):
//!   cargo run --bin stage9_smoke -- --phase enqueue-pump \
//!     --db /tmp/s9.sqlite --base-url http://127.0.0.1:PORT --offline-url \
//!     http://127.0.0.1:1 --key fixture-key --server-id A --book stress-120

use std::future::Future;
use std::time::{Duration, Instant};

use komga_core::api::auth::AuthMethod;
use komga_core::api::mutation::ProgressWriter;
use komga_core::api::page::PageStreaming;
use komga_core::api::series::KomgaClient;
use komga_core::cache::demo_png;
use komga_core::downloads::{self, manifest::DownloadRoot, queue};
use komga_core::ffi::application::{App, DeviceProfileDto};
use komga_core::store::{self, books};

type Smoke = Result<(), Box<dyn std::error::Error>>;

#[derive(Default, Clone)]
struct Args {
    db: String,
    base_url: String,
    offline_url: String,
    gone_url: String,
    key: String,
    phase: String,
    book: String,
    server: String,
    /// Pages per pass. 0 lets the core use the contract's default.
    max_pages: i64,
    /// How many passes to run before this process stops or is killed.
    stop_after: usize,
    /// Free bytes the platform reports. 0 means "the platform will not say".
    free_bytes: i64,
    /// Link class the platform reports.
    link: String,
    /// Cache pool budget for the `survives-everything` attack.
    pool_budget: i64,
    device_memory: i64,
}

fn main() {
    let args = parse();
    let outcome: Smoke = match args.phase.as_str() {
        "enqueue-pump" => phase_enqueue_pump(&args),
        "kill-resume" => phase_kill_resume(&args),
        "kill-finish" => phase_kill_finish(&args),
        "interrupted-write" => phase_interrupted_write(&args),
        "read-while" => phase_read_while(&args),
        "rotten-pages" => phase_rotten_pages(&args),
        "rotten-repair" => phase_rotten_repair(&args),
        "link-down" => phase_link_down(&args),
        "survives-everything" => phase_survives_everything(&args),
        "offline-run" => phase_offline_run(&args),
        "reconnect-upload" => phase_reconnect_upload(&args),
        "storage" => phase_storage(&args),
        "facade" => phase_facade(&args),
        "remote-gone" => phase_remote_gone(&args),
        other => panic!("unknown --phase {other}"),
    };
    match outcome {
        Ok(()) => println!("ok: phase {} passed", args.phase),
        Err(error) => panic!("phase {} failed: {error}", args.phase),
    }
}

fn parse() -> Args {
    let argv: Vec<String> = std::env::args().collect();
    let mut args = Args {
        book: "stress-120".to_string(),
        server: "A".to_string(),
        link: "unmetered".to_string(),
        max_pages: 1,
        stop_after: 0,
        free_bytes: 1 << 30,
        pool_budget: 512 * 1024 * 1024,
        device_memory: 4 * 1024 * 1024 * 1024,
        ..Default::default()
    };
    let mut i = 1;
    while i + 1 < argv.len() {
        match argv[i].as_str() {
            "--db" => args.db = argv[i + 1].clone(),
            "--base-url" => args.base_url = argv[i + 1].clone(),
            "--offline-url" => args.offline_url = argv[i + 1].clone(),
            "--gone-url" => args.gone_url = argv[i + 1].clone(),
            "--key" => args.key = argv[i + 1].clone(),
            "--phase" => args.phase = argv[i + 1].clone(),
            "--book" => args.book = argv[i + 1].clone(),
            "--server-id" => args.server = argv[i + 1].clone(),
            "--max-pages" => args.max_pages = parse_int(&argv[i + 1]),
            "--stop-after" => args.stop_after = parse_int(&argv[i + 1]) as usize,
            "--free-bytes" => args.free_bytes = parse_int(&argv[i + 1]),
            "--link" => args.link = argv[i + 1].clone(),
            "--pool-budget" => args.pool_budget = parse_int(&argv[i + 1]),
            "--device-memory" => args.device_memory = parse_int(&argv[i + 1]),
            other => panic!("unknown arg {other}"),
        }
        i += 2;
    }
    assert!(!args.db.is_empty(), "--db is required");
    assert!(!args.key.is_empty(), "--key is required");
    assert!(!args.base_url.is_empty(), "--base-url is required");
    args
}

fn parse_int(value: &str) -> i64 {
    value.replace('_', "").parse().expect("integer expected")
}

fn metric(name: &str, value: impl std::fmt::Display) {
    println!("metric {name}={value}");
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

/// Put the book in the mirror the way the app would have: a `books` row, then the
/// page manifest.
///
/// A stress book exists only in the server's page route — there is no metadata for
/// it to hand out — so its `books` row is written here. That is scaffolding for a
/// synthetic book, not a shortcut: the row is what lets `stale` mean anything, and
/// the 已失效 claim is one of the things this gate has to prove.
fn seed(args: &Args) -> Smoke {
    // A real sync, so "browse the local library offline" is tested against a library
    // rather than against the one row this harness wrote by hand. Runs before the
    // stress book is saved, because a sync prunes what its snapshot does not list.
    let summary = block_on(app(args).full_sync(
        args.server.clone(),
        args.base_url.clone(),
        args.key.clone(),
    ))?;
    metric("sync_series", summary.series);
    metric("sync_books", summary.books);
    let conn = store::open(&args.db)?;
    let client = KomgaClient::new(
        args.base_url.clone(),
        AuthMethod::ApiKey {
            key: args.key.clone(),
        },
    )?;
    let pages = block_on(client.pages(&args.book))?;
    metric("seed_server_pages", pages.len());
    let last_modified = if let Some(book) = block_on(client.book(&args.book))? {
        books::save_books_batch(&conn, &args.server, std::slice::from_ref(&book))?;
        book.last_modified
            .clone()
            .unwrap_or_else(|| SEED_STAMP.to_string())
    } else {
        conn.execute(
            "INSERT OR REPLACE INTO books
             (server_id, remote_id, series_id, series_title, title, media_type, pages_count, last_modified)
             VALUES (?1, ?2, 'seed', 'Seeded', ?2, 'image/jpeg', ?3, ?4)",
            rusqlite::params![args.server, args.book, pages.len() as i64, SEED_STAMP],
        )?;
        SEED_STAMP.to_string()
    };
    metric("seed_last_modified", &last_modified);
    drop(conn);
    let opened = block_on(app(args).reader_open(
        args.server.clone(),
        args.book.clone(),
        args.base_url.clone(),
        args.key.clone(),
        String::new(),
        String::new(),
        None,
    ))?;
    metric("seed_pages", opened.page_count);
    Ok(())
}

/// The freshness stamp a synthetic book reports. Later than any download a phase
/// could have made, so `stale` can only ever come from the row disappearing.
const SEED_STAMP: &str = "2024-05-11T18:07:33Z";

/// The same book without touching a server: for the offline phases.
fn mirrored_pages(args: &Args) -> Vec<u32> {
    let conn = store::open(&args.db).expect("open");
    let mut stmt = conn
        .prepare(
            "SELECT number FROM book_pages WHERE server_id = ?1 AND book_id = ?2 ORDER BY number",
        )
        .expect("prepare");
    stmt.query_map(rusqlite::params![args.server, args.book], |row| {
        Ok(row.get::<_, i64>(0)? as u32)
    })
    .expect("query")
    .filter_map(Result::ok)
    .collect()
}

fn pump_once(args: &Args, base_url: &str) -> Option<komga_core::ffi::application::DownloadPumpDto> {
    block_on(app(args).download_pump(
        args.server.clone(),
        base_url.to_string(),
        args.key.clone(),
        args.max_pages,
        0,
        args.free_bytes,
        args.link.clone(),
    ))
    .expect("pump")
}

fn book_row(args: &Args) -> komga_core::ffi::application::DownloadBookDto {
    app(args)
        .download_list(args.server.clone())
        .expect("list")
        .into_iter()
        .find(|row| row.book_id == args.book)
        .expect("the book is in the queue")
}

fn root(args: &Args) -> DownloadRoot {
    DownloadRoot::for_db(std::path::Path::new(&args.db)).expect("download root")
}

/// Run some passes, announce readiness, then start one long pass and let the script
/// SIGKILL the middle of it.
///
/// A killed pass leaves exactly one shape on a loopback server: a page whose HTTP
/// body never arrived. The durable write itself takes microseconds, so the torn
/// `.part` that a device losing power mid-rename would leave is not reachable this
/// way — `interrupted-write` covers that arm deterministically, and what this phase
/// covers is what a real process death actually produces: a page list stopped partway
/// through, with nothing half-written anywhere.
/// Drive the queue to completion, or until the pass count budget runs out.
/// Returns `(passes, served_total)`.
fn drain(args: &Args, base_url: &str, max_passes: usize) -> (usize, i64) {
    let mut passes = 0usize;
    let mut served = 0i64;
    while passes < max_passes {
        let Some(report) = pump_once(args, base_url) else {
            continue;
        };
        passes += 1;
        served += report.served;
        if !report.queue_active || report.served == 0 {
            break;
        }
    }
    (passes, served)
}

fn page_files(args: &Args) -> Vec<String> {
    root(args)
        .files_in(&args.server, &args.book)
        .into_iter()
        .filter(|name| name != "manifest.json" && !name.ends_with(".part"))
        .collect()
}

// ------------------------------------------------------------------------ phases

fn phase_enqueue_pump(args: &Args) -> Smoke {
    seed(args)?;
    let queued = app(args).download_enqueue(args.server.clone(), args.book.clone())?;
    metric("queued_state", &queued.state);
    metric("queued_pages", queued.pages_total);
    assert!(queued.pages_total > 4, "the queue needs a real book");
    assert!(
        queued.bytes_total > 0,
        "bytesTotal is what the pre-flight compares to"
    );
    let dir = root(args).book_dir(&args.server, &args.book);
    assert!(dir.is_dir(), "enqueue must create the tree");
    let document = komga_core::downloads::manifest::read_manifest(
        &root(args).manifest_path(&args.server, &args.book),
    )?
    .expect("a queued book describes itself");
    metric("initial_manifest_pages", document.pages.len());
    assert_eq!(i64::from(document.pages_count), queued.pages_total);
    assert!(document.pages.is_empty(), "nothing has arrived yet");

    let total = queued.pages_total as usize;
    let (passes, served) = drain(args, &args.base_url, total + 10);
    metric("passes", passes);
    metric("served_total", served);
    let final_row = book_row(args);
    metric("final_state", &final_row.state);
    metric("pages_done", final_row.pages_done);
    metric("bytes_db", final_row.bytes_done);
    assert_eq!(final_row.state, "completed", "the book did not finish");
    assert_eq!(final_row.pages_done, final_row.pages_total);

    let files = page_files(args);
    metric("files", files.len());
    assert_eq!(
        files.len() as i64,
        final_row.pages_total,
        "one file per page"
    );
    // The names are the contract's: zero-padded, extension from the container.
    assert!(
        files.first().is_some_and(|name| name == "0001.png"),
        "{files:?}"
    );
    metric(
        "parts_left",
        root(args)
            .files_in(&args.server, &args.book)
            .iter()
            .filter(|name| name.ends_with(".part"))
            .count(),
    );
    let disk: i64 = files
        .iter()
        .map(|name| dir.join(name))
        .filter_map(|path| std::fs::metadata(path).ok())
        .map(|meta| meta.len() as i64)
        .sum();
    metric("bytes_disk", disk);
    assert_eq!(disk, final_row.bytes_done, "the rows and the disk disagree");

    let written = komga_core::downloads::manifest::read_manifest(
        &root(args).manifest_path(&args.server, &args.book),
    )?
    .expect("a completed book has a manifest");
    let manifest_bytes: i64 = written.pages.iter().map(|page| page.size_bytes).sum();
    metric("manifest_bytes", manifest_bytes);
    metric("manifest_pages", written.pages.len());
    assert_eq!(
        manifest_bytes, disk,
        "the manifest is a third account, and must agree"
    );
    assert_eq!(i64::from(written.pages_count), written.pages.len() as i64);
    Ok(())
}

fn phase_kill_resume(args: &Args) -> Smoke {
    seed(args)?;
    app(args).download_enqueue(args.server.clone(), args.book.clone())?;
    let passes = if args.stop_after == 0 {
        3
    } else {
        args.stop_after
    };
    let (done, served) = drain(args, &args.base_url, passes);
    metric("killed_after_passes", done);
    metric("killed_after_pages", served);
    // The script waits for this line and then sends SIGKILL into the middle of the
    // pass below, on a server slow enough that the window is seconds wide.
    println!("ready-to-kill");
    use std::io::Write;
    std::io::stdout().flush().ok();
    pump_once(args, &args.base_url);
    loop {
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn phase_kill_finish(args: &Args) -> Smoke {
    let before = book_row(args);
    metric("resumed_state", &before.state);
    metric("resumed_pages", before.pages_done);
    assert!(
        before.pages_done > 0,
        "the interrupted run downloaded nothing"
    );
    let debris = root(args)
        .files_in(&args.server, &args.book)
        .into_iter()
        .filter(|name| name.ends_with(".part"))
        .count();
    metric("parts_found", debris);
    let swept = app(args).download_sweep()?;
    metric("swept_parts", swept.stale_parts);
    metric("swept_repairs", swept.repairs());
    let total = before.pages_total as usize;
    let (passes, served) = drain(args, &args.base_url, total + 10);
    metric("resume_passes", passes);
    metric("resume_served", served);
    metric("pages_before_resume", before.pages_done);
    metric("expected_remaining", total as i64 - before.pages_done);
    // The two halves add up to the book, or something was lost or paid for twice.
    // Arithmetic rather than opinion: a resume that skipped a page cannot reach
    // `pages_done == pages_total`, and one that re-fetched a finished page overshoots.
    assert_eq!(
        served,
        total as i64 - before.pages_done,
        "the resume fetched {served} pages when {} were left",
        total as i64 - before.pages_done
    );
    let final_row = book_row(args);
    metric("final_state", &final_row.state);
    assert_eq!(
        final_row.state, "completed",
        "a resumed download did not finish"
    );
    assert_eq!(final_row.pages_done, final_row.pages_total);
    metric("files", page_files(args).len());
    metric(
        "parts_left",
        root(args)
            .files_in(&args.server, &args.book)
            .iter()
            .filter(|name| name.ends_with(".part"))
            .count(),
    );
    Ok(())
}

/// Every shape an interruption can leave, reached without depending on when a signal
/// arrives. The sweep's job is to notice each one, and a phase that fabricated only
/// some of them would leave the rest unproven.
fn phase_interrupted_write(args: &Args) -> Smoke {
    seed(args)?;
    app(args).download_enqueue(args.server.clone(), args.book.clone())?;
    let pages = mirrored_pages(args);
    assert!(pages.len() >= 8, "this phase needs a real page list");
    let (passes, served) = drain(args, &args.base_url, 4);
    metric("planted_passes", passes);
    metric("planted_served", served);
    metric("planted_files", page_files(args).len());

    let conn = store::open(&args.db)?;
    let dir = root(args).book_dir(&args.server, &args.book);
    // 1. a torn write, which is what a kill actually leaves.
    std::fs::write(dir.join("0009.png.part"), b"half a page")?;
    // 2. a book the pass never settled, because the process died.
    conn.execute(
        "UPDATE downloads SET state = 'downloading' WHERE server_id = ?1 AND book_id = ?2",
        rusqlite::params![args.server, args.book],
    )?;
    // 3. a row that claims a file that is gone.
    let gone = dir.join("0003.png");
    std::fs::remove_file(&gone).ok();
    // 4. a file that arrived while nobody was looking: usable, and unaccounted.
    let adopted = dir.join("0006.png");
    std::fs::write(&adopted, demo_png::demo_page_bytes(6))?;
    conn.execute(
        "UPDATE download_pages SET state = 'pending', file_path = NULL, size_bytes = 0
         WHERE server_id = ?1 AND book_id = ?2 AND page_number = 6",
        rusqlite::params![args.server, args.book],
    )?;
    // 5. a file the right length whose bytes are not an image at all. The length has
    // to be exact: a shorter file is refused by the size check first, and then this
    // arm has proved nothing about the container walk.
    let declared: i64 = {
        let probe = store::open(&args.db)?;
        probe.query_row(
            "SELECT size_bytes FROM book_pages
             WHERE server_id = ?1 AND book_id = ?2 AND number = 2",
            rusqlite::params![args.server, args.book],
            |row| row.get(0),
        )?
    };
    let mut garbage = b"an error page wearing a png name".to_vec();
    garbage.resize(declared as usize, b' ');
    std::fs::write(dir.join("0002.png"), &garbage)?;
    // 6. a file whose length no longer matches its row. Every page of a stress book is
    // the same size, so this harness cannot produce two *valid* images of different
    // lengths; the "valid but wrong length" isolation is the unit test
    // `a_size_drift_is_caught_even_though_the_file_still_walks`, and what is proved
    // here is that a drift is noticed and repaired at all.
    let short = dir.join("0005.png");
    if let Ok(bytes) = std::fs::read(&short) {
        std::fs::write(&short, &bytes[..bytes.len() / 2])?;
    } else {
        downloads::store::mark_page_complete(
            &conn,
            &args.server,
            &args.book,
            5,
            &short.to_string_lossy(),
            declared,
            "image/png",
            "2026-08-30T05:00:00Z",
        )?;
        std::fs::write(&short, b"tiny")?;
    }
    // 7. counters that drifted from the rows.
    conn.execute(
        "UPDATE downloads SET pages_done = 400, bytes_done = 1 WHERE book_id = ?1",
        rusqlite::params![args.book],
    )?;
    drop(conn);

    let swept = app(args).download_sweep()?;
    metric("arm_stale_parts", swept.stale_parts);
    metric("arm_ghost_rows", swept.ghost_rows);
    metric("arm_adopted", swept.adopted_files);
    metric("arm_corrupt", swept.corrupt);
    metric("arm_size_mismatch", swept.size_mismatch);
    metric("arm_freed", swept.freed_bytes);
    metric("arm_counters", swept.counters_repaired);
    metric("arm_manifests", swept.manifests_rewritten);
    assert_eq!(swept.stale_parts, 1, "the torn write was not reaped");
    assert_eq!(swept.ghost_rows, 1, "the missing file was not noticed");
    assert_eq!(swept.adopted_files, 1, "the forgotten file was not adopted");
    assert_eq!(
        swept.corrupt, 1,
        "the container walk did not refuse the fake image"
    );
    assert_eq!(swept.size_mismatch, 1, "the length drift was not noticed");
    assert_eq!(
        swept.counters_repaired, 1,
        "the derived counters were not recomputed"
    );
    assert!(swept.freed_bytes > 0);
    // A file the database forgot stays readable: adoption is the point, not deletion.
    assert!(adopted.exists(), "adopting a file must not delete it");
    let conn = store::open(&args.db)?;
    let state: String = conn.query_row(
        "SELECT state FROM downloads WHERE server_id = ?1 AND book_id = ?2",
        rusqlite::params![args.server, args.book],
        |row| row.get(0),
    )?;
    metric("state_after_sweep", &state);
    assert_ne!(state, "downloading", "a dead pass left its mark forever");
    Ok(())
}

fn phase_read_while(args: &Args) -> Smoke {
    seed(args)?;
    let queued = app(args).download_enqueue(args.server.clone(), args.book.clone())?;
    let total = queued.pages_total;
    assert!(
        total >= 8,
        "read-while-downloading needs a book with a middle"
    );
    block_on(app(args).reader_open(
        args.server.clone(),
        args.book.clone(),
        args.base_url.clone(),
        args.key.clone(),
        "single".to_string(),
        String::new(),
        None,
    ))?;
    let mut reader_fetches = 0i64;
    let mut from_download = 0i64;
    let mut served = 0i64;
    for page in 1..=total {
        // The queue is driven every fourth page, so the reader deliberately
        // overtakes it. A walk where the download is always ahead proves only that
        // two readers of the same file agree; the case that matters is the reader
        // turning to a page the queue has not reached, and neither party waiting on
        // the other.
        if page % 4 == 1 {
            if let Some(report) = pump_once(args, &args.base_url) {
                served += report.served;
            }
        }
        let path = block_on(app(args).reader_page(
            args.server.clone(),
            args.book.clone(),
            page,
            args.base_url.clone(),
            args.key.clone(),
        ))?;
        if std::path::Path::new(&path).starts_with(root(args).root()) {
            from_download += 1;
        } else {
            reader_fetches += 1;
        }
        assert!(
            std::path::Path::new(&path).is_file(),
            "page {page} resolved to a path that is not there"
        );
        // What the server itself declared for this page, and the name the tree is
        // required to use. Both are per-page, so a tier that mixed pages up — the
        // off-by-one class of bug a spread layout makes possible — cannot pass.
        let declared: i64 = {
            let conn = store::open(&args.db)?;
            conn.query_row(
                "SELECT size_bytes FROM book_pages
                 WHERE server_id = ?1 AND book_id = ?2 AND number = ?3",
                rusqlite::params![args.server, args.book, page],
                |row| row.get(0),
            )?
        };
        assert_eq!(
            std::fs::metadata(&path)?.len() as i64,
            declared,
            "page {page} was served a different number of bytes than the manifest said"
        );
        if std::path::Path::new(&path).starts_with(root(args).root()) {
            // The download tree names a file after its page number, so the name is a
            // per-page witness. The cache tier uses reader keys instead, and a page
            // served from there is not this assertion's subject.
            assert_eq!(
                std::path::Path::new(&path)
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or(""),
                format!("{page:04}.png"),
                "page {page} was served from a download file named after another page"
            );
        }
        // Turn, so the session position the pump races toward is the one the reader
        // is actually at: `reader_page` resolves a page, only a turn moves the
        // reader. Without this the queue aims at page 1 for the whole walk.
        app(args).reader_turn(args.server.clone(), args.book.clone(), page)?;
    }
    metric("pages_read", total);
    metric("served_by_queue", served);
    metric("read_from_download_tier", from_download);
    metric("reader_own_fetches", reader_fetches);
    // Both halves of the mixed walk, or the phase has not tested what its name says.
    assert!(from_download > 0, "the reader never used a downloaded page");
    assert!(reader_fetches > 0, "the reader never overtook the queue");
    drain(args, &args.base_url, total as usize + 10);
    let final_row = book_row(args);
    metric("final_state", &final_row.state);
    metric("files", page_files(args).len());
    assert_eq!(final_row.state, "completed");
    assert_eq!(page_files(args).len() as i64, final_row.pages_total);
    Ok(())
}

fn phase_rotten_pages(args: &Args) -> Smoke {
    seed(args)?;
    app(args).download_enqueue(args.server.clone(), args.book.clone())?;
    let total = book_row(args).pages_total;
    let mut passes = 0;
    while passes < total as usize * 3 {
        let Some(report) = pump_once(args, &args.base_url) else {
            break;
        };
        passes += 1;
        if report.served == 0 && !report.queue_active {
            break;
        }
        if report.stop_reason == "idle" {
            break;
        }
    }
    let row = book_row(args);
    metric("rotten_passes", passes);
    metric("rotten_state", &row.state);
    metric("rotten_pages_done", row.pages_done);
    let conn = store::open(&args.db)?;
    let (failed, attempts_max): (i64, i64) = conn.query_row(
        "SELECT COALESCE(SUM(state = 'failed'), 0), COALESCE(MAX(attempts), 0)
         FROM download_pages WHERE server_id = ?1 AND book_id = ?2",
        rusqlite::params![args.server, args.book],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    drop(conn);
    metric("bad_pages", failed);
    metric("attempts_max", attempts_max);
    metric("served_first_try", row.pages_done);
    assert_eq!(
        row.state, "failed",
        "a book with unobtainable pages must say so"
    );
    assert!(
        failed > 0,
        "the truncating server truncated nothing this run"
    );
    assert_eq!(
        attempts_max,
        queue::max_page_attempts(),
        "attempts went past the contract"
    );
    assert!(
        row.pages_done > 0,
        "one bad page stopped the whole book: the queue must move past it"
    );
    Ok(())
}

fn phase_rotten_repair(args: &Args) -> Smoke {
    let before = book_row(args);
    let failed_before = {
        let conn = store::open(&args.db)?;
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM download_pages
             WHERE server_id = ?1 AND book_id = ?2 AND state = 'failed'",
            rusqlite::params![args.server, args.book],
            |row| row.get(0),
        )?;
        count
    };
    metric("repair_failed_before", failed_before);
    metric("repair_done_before", before.pages_done);
    app(args).download_retry(args.server.clone(), args.book.clone())?;
    let (passes, served) = drain(args, &args.base_url, (before.pages_total * 2) as usize);
    let row = book_row(args);
    metric("repair_passes", passes);
    metric("repair_served", served);
    metric("repair_state", &row.state);
    assert_eq!(
        row.state, "completed",
        "a retry against a healthy server must finish"
    );
    // The single-page-retry claim, in one line: the healthy pages were not paid for
    // twice.
    assert_eq!(
        served, failed_before,
        "retry cost {served} requests when only {failed_before} pages had failed"
    );
    Ok(())
}

fn phase_link_down(args: &Args) -> Smoke {
    seed(args)?;
    app(args).download_enqueue(args.server.clone(), args.book.clone())?;
    let total = book_row(args).pages_total;
    let (first_passes, first_served) = drain(args, &args.base_url, 2);
    metric("before_outage_pages", first_served);
    assert!(first_served > 0, "nothing downloaded before the outage");
    let attempts_before = attempts_of(args);
    metric("attempts_before", attempts_before);

    let outage_started = Instant::now();
    let mut outage_requests = 0;
    while outage_requests < 4 {
        let Some(report) = pump_once(args, &args.offline_url) else {
            break;
        };
        outage_requests += 1;
        metric("outage_stop", &report.stop_reason);
        if report.stop_reason != "linkDown" {
            break;
        }
    }
    metric("outage_passes", outage_requests);
    metric("outage_ms", outage_started.elapsed().as_millis());
    let attempts_during = attempts_of(args);
    metric("attempts_during", attempts_during);
    let row_during = book_row(args);
    metric("pages_during", row_during.pages_done);
    assert_eq!(
        attempts_during, attempts_before,
        "an outage spent page retries: {attempts_before} -> {attempts_during}"
    );
    assert_eq!(
        row_during.pages_done, first_served,
        "the book's progress moved during an outage, and one of those moves is a lie"
    );

    // The route comes back. No user gesture, no retry, no restart.
    let (more, served) = drain(args, &args.base_url, (total * 2) as usize);
    metric("after_recovery_passes", more + first_passes);
    metric("after_recovery_served", served);
    let final_row = book_row(args);
    metric("final_state", &final_row.state);
    assert_eq!(
        final_row.state, "completed",
        "a restored link needed a manual retry"
    );
    assert_eq!(final_row.pages_done, final_row.pages_total);
    Ok(())
}

fn attempts_of(args: &Args) -> i64 {
    let conn = store::open(&args.db).expect("open");
    conn.query_row(
        "SELECT COALESCE(SUM(attempts), 0) FROM download_pages WHERE server_id = ?1 AND book_id = ?2",
        rusqlite::params![args.server, args.book],
        |row| row.get(0),
    )
    .unwrap_or(0)
}

fn phase_survives_everything(args: &Args) -> Smoke {
    seed(args)?;
    app(args).download_enqueue(args.server.clone(), args.book.clone())?;
    drain(
        args,
        &args.base_url,
        (book_row(args).pages_total * 2) as usize,
    );
    let before = page_files(args);
    let bytes_before = root(args).book_bytes(&args.server, &args.book);
    metric("files_before", before.len());
    metric("bytes_before", bytes_before);
    assert!(!before.is_empty(), "nothing was downloaded to protect");
    let total = before.len();

    // 1. an impossible cache budget, applied by the same device report a phone sends.
    app(args).reader_configure_device(
        args.server.clone(),
        args.book.clone(),
        DeviceProfileDto {
            device_memory_bytes: args.device_memory,
            cache_budget_bytes: 1,
            avg_page_bytes_hint: 0,
            decoded_page_bytes: 8 * 1024 * 1024,
            network: "wifi".to_string(),
            stable: true,
        },
    )?;
    for page in 1..=total.min(12) {
        // Reads fill the cache, and filling it is what forces eviction to run.
        // Fill the cache the way reading does, then read again through the
        // network-free path: eviction runs on every store, and the download tree has
        // to be invisible to all of it.
        let fetched = block_on(app(args).reader_page(
            args.server.clone(),
            args.book.clone(),
            page as i64,
            args.base_url.clone(),
            args.key.clone(),
        ))?;
        let warm =
            app(args).reader_page_path(args.server.clone(), args.book.clone(), page as i64)?;
        assert_eq!(
            warm.as_deref(),
            Some(fetched.as_str()),
            "a warm page was re-fetched"
        );
    }
    metric("after_budget", page_files(args).len());
    assert_eq!(
        page_files(args).len(),
        total,
        "the eviction budget reached the downloads"
    );

    // 2. both user-facing cleanups.
    app(args).reader_clear_prefetch()?;
    metric("after_clear_prefetch", page_files(args).len());
    let cache_dir = std::path::Path::new(&args.db)
        .parent()
        .map(|dir| dir.join("cache"))
        .unwrap_or_default();
    let cache = komga_core::reader::cache::PageCache::new(&cache_dir)?;
    let conn = store::open(&args.db)?;
    cache.clear_tier(&conn, komga_core::reader::cache::Tier::Page)?;
    metric("after_clear_page", page_files(args).len());
    assert_eq!(
        page_files(args).len(),
        total,
        "clear_tier(page) reached the downloads"
    );

    // 3. the reconciliation sweep, which is the one that deletes what it cannot
    // account for.
    let cleaned = app(args).reader_reconcile_cache()?;
    metric("reconcile_orphans", cleaned.orphan_files);
    metric("reconcile_freed", cleaned.freed_bytes);
    metric("after_reconcile", page_files(args).len());
    assert_eq!(
        page_files(args).len(),
        total,
        "the reconcile sweep took a download"
    );

    // 4. the mirror sweep deciding the book is gone from the server.
    // The mirror sweep deciding the book left the server. `delete_book` is what
    // the sweep calls, and it is the path that used to eat download rows.
    store::prune::delete_book(&conn, &args.server, &args.book)?;
    drop(conn);
    metric("after_prune", page_files(args).len());
    assert_eq!(
        page_files(args).len(),
        total,
        "the mirror sweep deleted a user's files"
    );
    let after_prune = book_row(args);
    metric("stale_after_prune", after_prune.stale);
    assert!(
        after_prune.stale,
        "a vanished book must be labelled, not silently served"
    );

    // 5. a fresh process over the same database.
    metric("after_restart", page_files(args).len());
    assert_eq!(page_files(args).len(), total);
    assert_eq!(
        root(args).book_bytes(&args.server, &args.book),
        bytes_before
    );

    // 6. and the only thing that may remove them.
    let deleted = app(args).download_delete(args.server.clone(), args.book.clone())?;
    metric("delete_files", deleted.files);
    metric("delete_bytes", deleted.freed_bytes);
    metric("after_delete", page_files(args).len());
    assert_eq!(
        page_files(args).len(),
        0,
        "a user delete must take the whole tree"
    );
    assert_eq!(
        deleted.freed_bytes, bytes_before as i64,
        "the freed figure is what the screen shows"
    );
    Ok(())
}

fn phase_offline_run(args: &Args) -> Smoke {
    // A fresh process, an unreachable server, and nothing but what is on the device.
    // Browsing the library with the network off is a read of SQLite, and nothing
    // else. Counted here rather than through a query surface so the phase does not
    // accidentally prove that a query method works.
    let conn = store::open(&args.db)?;
    let library_rows: i64 = conn.query_row(
        "SELECT COUNT(*) FROM books WHERE server_id = ?1",
        rusqlite::params![args.server],
        |row| row.get(0),
    )?;
    drop(conn);
    metric("library_rows", library_rows);
    assert!(library_rows > 0, "the local media library is empty offline");
    let covers = app(args).list_thumbnails(&args.server)?;
    metric("cached_covers", covers.len());
    let queued = app(args).download_list(args.server.clone())?;
    metric("downloaded_books", queued.len());
    assert_eq!(
        queued.len(),
        1,
        "the download the earlier phase made is not there"
    );
    let row = &queued[0];
    metric("offline_state", &row.state);
    assert_eq!(row.state, "completed");

    let opened = block_on(app(args).reader_open(
        args.server.clone(),
        args.book.clone(),
        args.offline_url.clone(),
        "dead".to_string(),
        String::new(),
        String::new(),
        None,
    ))?;
    metric("opened_from_mirror", opened.from_mirror);
    assert!(
        opened.from_mirror,
        "opening a book the server cannot answer must be local"
    );
    assert_eq!(opened.page_count, row.pages_total);

    let mut served = 0i64;
    let mut from_downloads = 0i64;
    for page in 1..=opened.page_count {
        let path = block_on(app(args).reader_page(
            args.server.clone(),
            args.book.clone(),
            page,
            args.offline_url.clone(),
            "dead".to_string(),
        ))?;
        served += 1;
        if std::path::Path::new(&path).starts_with(root(args).root()) {
            from_downloads += 1;
        }
        assert!(std::path::Path::new(&path).is_file());
    }
    metric("pages_read", served);
    metric("served_from_downloads", from_downloads);
    assert_eq!(served, opened.page_count, "the offline read stopped short");
    assert_eq!(
        from_downloads, served,
        "a page came from somewhere other than the download"
    );

    // Progress, saved with the network off.
    // `reader_step` and `reader_turn` are sync on purpose: a page turn must not wait
    // on a runtime when the page is already on the device.
    let turns = app(args).reader_step(args.server.clone(), args.book.clone(), 1)?;
    metric("position_page", turns.page);
    app(args).reader_turn(args.server.clone(), args.book.clone(), 3)?;
    let status = app(args).outbox_status(&args.server)?;
    metric("outbox_queued", status.pending);
    assert!(
        status.pending >= 1,
        "a turn with the network off queued nothing"
    );
    let position_row: i64 = {
        let conn = store::open(&args.db)?;
        conn.query_row(
            "SELECT page FROM reader_position WHERE server_id = ?1 AND book_id = ?2",
            rusqlite::params![args.server, args.book],
            |row| row.get(0),
        )
        .unwrap_or(-1)
    };
    metric("position_saved", position_row);
    assert_eq!(
        position_row, 3,
        "the position the user turned to was not persisted"
    );
    Ok(())
}

fn phase_reconnect_upload(args: &Args) -> Smoke {
    let status = app(args).outbox_status(&args.server)?;
    metric("pending_before", status.pending);
    assert!(
        status.pending >= 1,
        "the offline phase queued nothing to upload"
    );
    let outcome = block_on(app(args).upload_outbox(
        args.server.clone(),
        args.base_url.clone(),
        args.key.clone(),
    ))?;
    metric("uploaded", outcome.uploaded);
    let after = app(args).outbox_status(&args.server)?;
    metric("pending_after", after.pending);
    assert_eq!(after.pending, 0, "a restored link left mutations queued");
    // The server's own journal is what the script asserts against: this line only
    // proves the core believes it sent something, which is exactly the claim that
    // must not be taken on its own word.
    metric("rows_considered", outcome.considered);
    metric("rows_uploaded", outcome.uploaded);
    assert!(
        outcome.uploaded >= 1,
        "the core reported nothing uploaded after a restore"
    );
    Ok(())
}

fn phase_storage(args: &Args) -> Smoke {
    let storage = app(args).download_storage(args.free_bytes)?;
    metric("download_bytes", storage.download_bytes);
    metric("download_pages", storage.download_page_count);
    metric("book_count", storage.book_count);
    metric("download_disk_bytes", storage.download_disk_bytes);
    metric("download_disk_files", storage.download_disk_files);
    metric("unowned_books", storage.unowned_books);
    metric("unowned_bytes", storage.unowned_bytes);
    metric("cache_page_bytes", storage.cache_page_bytes);
    metric("cache_prefetch_bytes", storage.cache_prefetch_bytes);
    metric("cache_thumbnail_bytes", storage.cache_thumbnail_bytes);
    metric("cache_total_bytes", storage.cache_total_bytes);
    metric("free_volume_bytes", storage.free_volume_bytes);
    metric("per_book_rows", storage.per_book.len());
    assert_eq!(
        storage.free_volume_bytes, args.free_bytes,
        "the platform's answer was rewritten"
    );
    let stats = app(args).reader_cache_stats()?;
    metric("stats_download_bytes", stats.download_bytes);
    assert_eq!(
        stats.download_bytes, storage.download_bytes,
        "two screens, two numbers"
    );
    Ok(())
}

fn phase_facade(args: &Args) -> Smoke {
    seed(args)?;
    // Every entry point, in the order a screen would reach them.
    let queued = app(args).download_enqueue(args.server.clone(), args.book.clone())?;
    metric("facade_enqueue", &queued.state);
    let paused = app(args).download_pause(args.server.clone(), args.book.clone())?;
    metric("facade_pause", &paused.state);
    assert_eq!(paused.state, "paused");
    let resumed = app(args).download_resume(args.server.clone(), args.book.clone())?;
    metric("facade_resume", &resumed.state);
    app(args).download_set_allow_cellular(args.server.clone(), args.book.clone(), true)?;
    metric("facade_consent", book_row(args).allow_cellular);
    let listed = app(args).download_list(args.server.clone())?;
    metric("facade_list", listed.len());
    let swept = app(args).download_sweep()?;
    metric("facade_sweep_repairs", swept.repairs());
    let storage = app(args).download_storage(1 << 30)?;
    metric("facade_storage_books", storage.book_count);

    // Two passes, one database: exactly one of them gets to work. This is the only
    // test of the claim that a pump is serialised, and it needs a server slow enough
    // for the two to actually overlap.
    let mut handles = Vec::new();
    for _ in 0..2 {
        let db = args.db.clone();
        let url = args.base_url.clone();
        let key = args.key.clone();
        let server = args.server.clone();
        handles.push(std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("runtime");
            let held = runtime.block_on(App::new(db.clone()).download_pump(
                server,
                url,
                key,
                4,
                0,
                1 << 30,
                "unmetered".to_string(),
            ))?;
            Ok::<_, Box<dyn std::error::Error + Send + Sync>>(held.is_some())
        }));
    }
    let mut worked = 0;
    let mut refused = 0;
    for handle in handles {
        match handle.join() {
            Ok(Ok(true)) => worked += 1,
            Ok(Ok(false)) => refused += 1,
            Ok(Err(error)) => return Err(error),
            Err(_) => panic!("a pump thread panicked"),
        }
    }
    metric("pump_worked_count", worked);
    metric("pump_none_count", refused);
    assert_eq!(
        refused, 1,
        "two passes ran against one queue at once ({worked} worked, {refused} refused)"
    );

    // The slot comes back: a third pass gets work.
    let after = pump_once(args, &args.base_url);
    assert!(after.is_some(), "the pump slot never came back");
    let report = after.expect("a pass that got the slot");
    metric("facade_stop", &report.stop_reason);
    metric("facade_served", report.served);
    assert!(report.served > 0, "a pass with the slot served nothing");
    let deleted = app(args).download_delete(args.server.clone(), args.book.clone())?;
    metric("facade_delete_files", deleted.files);
    metric("facade_files_after", page_files(args).len());
    assert_eq!(page_files(args).len(), 0, "the facade's delete left files");
    Ok(())
}

fn phase_remote_gone(args: &Args) -> Smoke {
    seed(args)?;
    app(args).download_enqueue(args.server.clone(), args.book.clone())?;
    assert!(
        !args.gone_url.is_empty(),
        "--gone-url is required for this phase"
    );
    let first = pump_once(args, &args.gone_url).expect("a pass ran");
    metric("gone_stop", &first.stop_reason);
    metric("gone_served", first.served);
    metric("gone_state", &first.state);
    assert_eq!(
        first.stop_reason, "gone",
        "a 404 was not read as the book being gone"
    );
    assert_eq!(first.state, "failed");
    let attempts = attempts_of(args);
    metric("attempts_burned", attempts);
    assert_eq!(attempts, 0, "a book that is gone burned retries");
    // The next pass must leave it alone rather than rediscovering the 404 every
    // second, which is what an infinite loop looks like from the user's side.
    let second = pump_once(args, &args.gone_url).expect("a pass ran");
    metric("second_stop", &second.stop_reason);
    metric("second_served", second.served);
    assert!(
        !second.queue_active,
        "a terminal failure still looks like work"
    );
    assert_eq!(second.stop_reason, "idle");
    Ok(())
}
