//! One bounded download pass: plan, fetch, write durably, settle.
//!
//! Three rules shape everything below, and each exists because the alternative was
//! worse in a way worth stating:
//!
//!   * a `rusqlite::Connection` is never held across an `await`. The pass plans on
//!     one connection, drops it, then fetches. This is the constraint
//!     `App::reader_prefetch` works around for the same reason, and
//!     `cargo ndk check --features frb` is what catches a regression — it fails only
//!     on the device target, which is why it is a gate rather than a habit.
//!   * a pause is observed at the top of each page's transaction, not by a signal.
//!     [`crate::downloads::store::set_state`]'s optimistic
//!     `WHERE state = <expected>` is what lets a pause that landed mid-book win: the
//!     pass writes zero rows and stops, costing at most the one page already in
//!     flight, with no cancellation flag to keep in sync.
//!   * bytes are judged, written, fsynced, renamed, and then the *file* is judged.
//!     The first verdict proves the response; only the second proves what the reader
//!     is about to open.

use std::path::Path;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use rusqlite::Connection;

use crate::api::error::ApiError;
use crate::api::page::PageStreaming;
use crate::cache::write_atomic_durable;
use crate::reader::integrity::{self, Corruption, ImageInfo, Verdict};
use crate::store;

use super::manifest::{self, DownloadRoot, ManifestPage};
use super::queue::{
    self, book_state, page_state, Actor, Job, Link, Outcome, Scope, SettleMode, Signal, StopReason,
};
use super::recover;
use super::store::{self as downloads, QueueError};

/// A failure of the pass's own machinery. A page's failure is not one of these:
/// that is data the pass records and carries on past.
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("queue storage: {0}")]
    Store(#[from] QueueError),
    #[error("sqlite: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("download tree: {0}")]
    Root(#[from] manifest::RootError),
    #[error("cannot write {path}: {reason}")]
    Io { path: String, reason: String },
}

#[derive(Debug, Clone)]
pub struct PassRequest<'a> {
    pub server_id: &'a str,
    /// What the platform says the volume has left. `0` means it would not say,
    /// which the planner resolves conservatively — never as permission to start a
    /// new book.
    pub free_bytes: i64,
    pub link: Link,
    pub max_pages: usize,
    pub max_bytes: i64,
    /// Where a live reader sits, if one is open on the book being served.
    pub reader: Option<queue::ReaderPosition>,
}

#[derive(Debug, Clone, Default)]
pub struct PassReport {
    pub book: Option<(String, String)>,
    pub state: Option<String>,
    pub served: usize,
    pub failed_pages: usize,
    pub bytes_written: i64,
    pub pages_done: i64,
    pub pages_total: i64,
    pub stop: StopReason,
    pub next_in_ms: i64,
    pub pump_ms: u64,
    pub last_error: Option<String>,
    /// This pass ended for a reason that makes the book terminal (`gone`, a refused
    /// write). `settle` would otherwise re-derive `waiting` from the pending rows
    /// still left in it, and the next pass would claim it and hit the same wall
    /// forever — an infinite loop that looks like a stuck download.
    pub terminal: bool,
    /// What the process-first reconciliation had to repair. Reported by the pass that
    /// ran it, because a recovery that fires silently cannot be told apart from one
    /// that never fired.
    pub repairs: i64,
    pub parts_swept: i64,
    pub adopted: i64,
    pub ghost_rows: i64,
    /// Some book still wants bytes, so the caller has a reason to pump again.
    /// Without it a UI can only guess by watching `served`, which is zero for a pass
    /// that stopped on a link failure with half the queue still to go.
    pub queue_active: bool,
}

/// The transport's failure, as the signal the contract table knows.
///
/// `Decode` is `Link` rather than "bad page" on purpose: `page_bytes` maps a body
/// that stopped mid-stream to `Decode`, and a severed connection is a fact about the
/// route, not about the page. Everything unrecognised falls to `Server`, which burns
/// one attempt and leaves the page retryable — the reading `errors.json` gives an
/// unlisted signal too.
pub fn signal_of(error: &ApiError) -> Signal {
    match error {
        ApiError::Network | ApiError::Decode { .. } => Signal::Link,
        ApiError::Authentication => Signal::Credential,
        ApiError::Server {
            status_code: 404 | 410,
        } => Signal::NotFound,
        ApiError::Server { status_code: 429 } => Signal::RateLimited,
        ApiError::Storage { .. } | ApiError::Database { .. } => Signal::WriteFailed,
        _ => Signal::Server,
    }
}

/// What the container walk made of bytes that did arrive.
pub fn signal_of_verdict(verdict: &Verdict) -> Signal {
    match verdict {
        Verdict::Corrupt(Corruption::ShortRead { .. }) => Signal::ShortRead,
        Verdict::Corrupt(Corruption::Empty) | Verdict::Corrupt(Corruption::TooSmall { .. }) => {
            Signal::TooSmall
        }
        Verdict::Corrupt(_) => Signal::Corrupt,
        // `Indeterminate` is a container this module cannot walk, not damage, and
        // `is_usable` already says so. Refusing such a page would refuse AVIF books
        // that decode perfectly well on both platforms.
        _ => Signal::Ok,
    }
}

/// Why a page did not reach the device, in the user's language. Stored rather than
/// recomputed, because the Downloads screen shows this text.
pub fn describe(outcome: Outcome) -> &'static str {
    match outcome {
        Outcome::Complete => "",
        Outcome::BadPage => "页面没有完整到达",
        Outcome::LinkDown => "连不上服务器",
        Outcome::Blocked => "服务器拒绝了凭据",
        Outcome::Gone => "服务器上已经没有这一页",
        Outcome::Throttled => "服务器在限流",
        Outcome::IoFailed => "设备拒绝写入",
    }
}

fn stop_of(outcome: Outcome) -> StopReason {
    match outcome {
        Outcome::Complete => StopReason::Drained,
        Outcome::BadPage => StopReason::BadPage,
        Outcome::LinkDown => StopReason::LinkDown,
        Outcome::Blocked => StopReason::Blocked,
        Outcome::Gone => StopReason::Gone,
        Outcome::Throttled => StopReason::Throttled,
        Outcome::IoFailed => StopReason::IoFailed,
    }
}

/// What one page attempt ended up meaning. Collapsing the fetch and the container
/// verdict into one of these four is what keeps the loop below readable: every
/// transport failure and every verdict lands here, and the rest of the pass is
/// written once instead of once per branch.
enum PageAttempt {
    /// Bytes the walk accepted, ready to be committed.
    Land {
        bytes: Vec<u8>,
        content_type: String,
        info: Option<ImageInfo>,
    },
    /// About this page: burn an attempt, keep the row retryable or fail it.
    Retry { reason: String },
    /// Not about this page. Write nothing for it, and end the pass.
    Halt {
        stop: StopReason,
        error: Option<String>,
        /// A rejected credential parks the server's whole queue, because the next
        /// book would fail the same way and the user is paying per request.
        park_server: bool,
        /// Terminal for this book: a 404 or a refused write must not be re-derived
        /// as `waiting` from rows that are still pending, or the next pass claims
        /// the book and hits the same wall forever.
        terminal: bool,
    },
}

/// Run one pass. Everything the queue decides comes back as `Ok` with a stop
/// reason; only the pass's own machinery failing is an `Err`.
pub async fn run_pass<F: PageStreaming + ?Sized>(
    db_path: &Path,
    root: &DownloadRoot,
    fetcher: &F,
    request: &PassRequest<'_>,
    now: DateTime<Utc>,
) -> Result<PassReport, EngineError> {
    let stamp = now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let clock = Instant::now();
    let mut report = PassReport::default();

    // Reconcile the tree with its rows on the first pass this process makes. Without
    // this call the sweep runs only when somebody names it, which is the same class of
    // defect Stage 8 found twice: a recovery path that exists but is never reached is
    // indistinguishable from one that does not exist, right up until the process is
    // killed and restarted.
    if let Ok(Some(sweep)) = recover::sweep_once(db_path, root, &stamp) {
        report.repairs = sweep.repairs() as i64;
        report.parts_swept = sweep.stale_parts as i64;
        report.adopted = sweep.adopted_files as i64;
        report.ghost_rows = sweep.ghost_rows as i64;
    }

    let pass = {
        let conn = store::open(db_path)?;
        let books = downloads::plan_books(&conn, Some(request.server_id))?;
        queue::plan_pass(&queue::PassInput {
            now,
            books: &books,
            link: request.link,
            free_bytes: request.free_bytes,
            max_pages: request.max_pages,
            max_bytes: request.max_bytes,
            reader: request.reader.clone(),
        })
    };
    report.stop = pass.stop;
    report.next_in_ms = pass.next_in_ms;
    report.book = pass.book.clone();

    let Some((server_id, book_id)) = pass.book.clone() else {
        settle(db_path, root, &mut report, request.server_id, None, &stamp);
        report.pump_ms = clock.elapsed().as_millis() as u64;
        return Ok(report);
    };

    if pass.claims {
        let conn = store::open(db_path)?;
        let moved = downloads::set_state(
            &conn,
            &server_id,
            &book_id,
            &[book_state::WAITING],
            book_state::DOWNLOADING,
            Actor::Pump,
            &stamp,
            None,
        )?;
        if !moved {
            // Paused or deleted between planning and claiming. There is nothing for
            // this pass to do and nothing to repair.
            report.stop = StopReason::Idle;
            report.next_in_ms = 0;
            return Ok(report);
        }
    }

    let budget = Duration::from_millis(queue::max_elapsed_ms());
    let mut consecutive_bad = 0usize;
    for job in &pass.jobs {
        // Checked before a page, never during one: the bound keeps a download from
        // starving `reader_page`, which shares this process, and abandoning a page
        // halfway to honour it would only fetch it again later. Zero pages served is
        // the one exemption, or a book of slow pages would never move at all.
        if report.served > 0 && clock.elapsed() > budget {
            report.stop = StopReason::Elapsed;
            report.next_in_ms = queue::next_in_ms(report.stop, 0);
            break;
        }

        let declared = (job.declared_bytes > 0).then_some(job.declared_bytes);
        let attempt = match fetcher.page_bytes(&book_id, job.number).await {
            Ok((bytes, content_type)) => {
                let verdict = integrity::inspect(&bytes, &content_type, declared);
                judge(&verdict, bytes, content_type)
            }
            Err(error) => halt(queue::classify(signal_of(&error))),
        };

        match attempt {
            PageAttempt::Land {
                bytes,
                content_type,
                info,
            } => {
                let conn = store::open(db_path)?;
                match land_page(&conn, root, job, &bytes, &content_type, info, &stamp) {
                    Ok(Landed::Written(size)) => {
                        report.served += 1;
                        report.bytes_written += size;
                        consecutive_bad = 0;
                    }
                    Ok(Landed::Rested) => {
                        // The user's gesture won while this page was in flight. Its
                        // bytes are simply unused, and this is the whole reason a
                        // pause needs no signal: the next write changes zero rows.
                        report.stop = StopReason::Paused;
                        report.next_in_ms = 0;
                        break;
                    }
                    Err(error) => {
                        // A refused write is about the device, not the page: disk
                        // full retried per page is a hundred failed writes.
                        report.stop = StopReason::IoFailed;
                        report.last_error = Some(error.to_string());
                        break;
                    }
                }
            }
            PageAttempt::Retry { reason } => {
                let conn = store::open(db_path)?;
                let exhausted = downloads::record_page_attempt(
                    &conn, &server_id, &book_id, job.number, &reason, &stamp,
                )?;
                if exhausted {
                    report.failed_pages += 1;
                }
                consecutive_bad += 1;
                if consecutive_bad >= queue::consecutive_bad_pages() {
                    // A run of bad pages is a sick server, not a sick book. Stopping
                    // here is what keeps a dying server costing three attempts
                    // overall instead of three per page.
                    report.stop = StopReason::BadRun;
                    report.next_in_ms = queue::next_in_ms(report.stop, 0);
                    report.last_error = Some(reason);
                    break;
                }
            }
            PageAttempt::Halt {
                stop,
                error,
                park_server,
                terminal,
            } => {
                report.stop = stop;
                report.next_in_ms = queue::next_in_ms(stop, 0);
                report.last_error = error.clone();
                report.terminal = terminal;
                if park_server {
                    let conn = store::open(db_path)?;
                    let until = now + chrono::Duration::milliseconds(report.next_in_ms.max(1));
                    downloads::park_server(
                        &conn,
                        &server_id,
                        &until.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                        error.as_deref().unwrap_or(""),
                        &stamp,
                    )?;
                }
                break;
            }
        }
    }

    settle(
        db_path,
        root,
        &mut report,
        &server_id,
        Some(&book_id),
        &stamp,
    );
    report.pump_ms = clock.elapsed().as_millis() as u64;
    Ok(report)
}

/// Turn a container verdict into what to do about it.
fn judge(verdict: &Verdict, bytes: Vec<u8>, content_type: String) -> PageAttempt {
    match queue::classify(signal_of_verdict(verdict)) {
        Outcome::Complete => PageAttempt::Land {
            info: verdict.info(),
            bytes,
            content_type,
        },
        outcome => halt(outcome),
    }
}

/// A non-complete outcome, expressed as the scope the contract table gave it.
fn halt(outcome: Outcome) -> PageAttempt {
    let reason = describe(outcome).to_string();
    match queue::scope_of(outcome) {
        Scope::Page => PageAttempt::Retry { reason },
        Scope::Pass => PageAttempt::Halt {
            stop: stop_of(outcome),
            error: (!reason.is_empty()).then_some(reason),
            park_server: false,
            terminal: false,
        },
        Scope::Book => PageAttempt::Halt {
            stop: stop_of(outcome),
            error: Some(if reason.is_empty() {
                "this page is gone".to_string()
            } else {
                reason
            }),
            park_server: false,
            terminal: true,
        },
        Scope::ServerQueue => PageAttempt::Halt {
            stop: stop_of(outcome),
            error: (!reason.is_empty()).then_some(reason),
            park_server: true,
            terminal: false,
        },
    }
}

#[derive(Debug)]
enum Landed {
    Written(i64),
    /// The book was paused or deleted while this page was in flight.
    Rested,
}

/// Commit one landed page: stage, fsync, rename, then verify the file.
fn land_page(
    conn: &Connection,
    root: &DownloadRoot,
    job: &Job,
    bytes: &[u8],
    content_type: &str,
    info: Option<ImageInfo>,
    stamp: &str,
) -> Result<Landed, EngineError> {
    let tx = conn.unchecked_transaction()?;
    if downloads::state_of(&tx, &job.server_id, &job.book_id)?.as_deref()
        != Some(book_state::DOWNLOADING)
    {
        return Ok(Landed::Rested);
    }
    let previous = downloads::page(&tx, &job.server_id, &job.book_id, job.number)?;

    let extension = info
        .map(|found| {
            found
                .format
                .extension()
                .unwrap_or(manifest::FALLBACK_EXTENSION)
        })
        .unwrap_or_else(|| {
            integrity::Format::from_content_type(content_type)
                .extension()
                .unwrap_or(manifest::FALLBACK_EXTENSION)
        });
    let path = root.page_path(&job.server_id, &job.book_id, job.number, extension);

    // The name follows the bytes, so an earlier attempt that arrived as a different
    // container must not leave a second copy of the same page behind. The row's own
    // pointer is not enough: after a heal it is NULL, and the stale file is still on
    // disk — so every sibling of this page number is cleared, which is also what
    // keeps the next sweep from adopting the wrong one.
    let _ = previous;
    for sibling in root.siblings_of(&job.server_id, &job.book_id, job.number) {
        if sibling != path {
            std::fs::remove_file(&sibling).ok();
        }
    }

    let staging = DownloadRoot::staging_path(&path);
    if let Err(error) = write_atomic_durable(&staging, &path, bytes) {
        std::fs::remove_file(&staging).ok();
        return Err(EngineError::Io {
            path: path.to_string_lossy().into_owned(),
            reason: error.to_string(),
        });
    }

    let size = std::fs::metadata(&path)
        .map(|meta| meta.len() as i64)
        .unwrap_or(0);
    // The second witness, read back from disk. A page whose bytes were fine in
    // memory and are not on disk is exactly the failure an offline book must not
    // carry quietly.
    let check = integrity::quick_check_file(&path, Some(size));
    if !check.is_usable() {
        std::fs::remove_file(&path).ok();
        return Err(EngineError::Io {
            path: path.to_string_lossy().into_owned(),
            reason: check.corruption_description(),
        });
    }

    // The sniffed container wins over the response header: the header is a claim,
    // and this is the value a reader of the manifest will compare against the file.
    let media_type = info
        .map(|found| found.format.content_type().to_string())
        .unwrap_or_else(|| content_type.to_string());
    downloads::mark_page_complete(
        &tx,
        &job.server_id,
        &job.book_id,
        job.number,
        &path.to_string_lossy(),
        size,
        &media_type,
        stamp,
    )?;
    downloads::recompute_counters(&tx, &job.server_id, &job.book_id, stamp)?;
    tx.commit()?;
    Ok(Landed::Written(size))
}

/// Settle what the pass touched, refresh the manifest when the book came to rest,
/// and report whether the queue still has work.
fn settle(
    db_path: &Path,
    root: &DownloadRoot,
    report: &mut PassReport,
    server_id: &str,
    book_id: Option<&str>,
    stamp: &str,
) {
    let Some(book_id) = book_id else {
        report.queue_active = queue_active(db_path, server_id);
        return;
    };
    let Ok(conn) = store::open(db_path) else {
        report.queue_active = false;
        return;
    };
    if report.terminal {
        let _ = downloads::set_state(
            &conn,
            server_id,
            book_id,
            &[book_state::DOWNLOADING, book_state::WAITING],
            book_state::FAILED,
            Actor::Settle,
            stamp,
            report.last_error.as_deref(),
        );
    } else {
        let _ = downloads::settle_book(&conn, server_id, book_id, stamp, SettleMode::Pass);
    }
    if let Ok(Some(row)) = downloads::get(&conn, server_id, book_id) {
        report.pages_done = row.pages_done;
        report.pages_total = row.pages_total;
        report.state = Some(row.state.clone());
        if report.last_error.is_none() {
            report.last_error = row.last_error.clone();
        }
        if matches!(
            row.state.as_str(),
            book_state::COMPLETED | book_state::FAILED | book_state::PAUSED
        ) {
            // The moment a third party gets to see the job. The manifest is derived,
            // and rewriting it per page would be O(n) writes for no extra
            // durability — which is why it looks like an omission. See
            // `downloads/manifest.json`'s `notWrittenPerPage`.
            let _ = recover::rebuild_manifest(&conn, root, server_id, book_id, stamp);
        }
    }
    report.queue_active = queue_active(db_path, server_id);
}

fn queue_active(db_path: &Path, server_id: &str) -> bool {
    store::open(db_path)
        .and_then(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM downloads
                 WHERE server_id = ?1 AND state IN (?2, ?3)",
                rusqlite::params![server_id, book_state::WAITING, book_state::DOWNLOADING],
                |row| row.get::<_, i64>(0),
            )
        })
        .map(|count| count > 0)
        .unwrap_or(false)
}

/// The book's downloaded pages as the manifest describes them.
pub fn manifest_pages(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> Result<Vec<ManifestPage>, QueueError> {
    Ok(downloads::pages(conn, server_id, book_id)?
        .iter()
        .filter(|row| row.state == page_state::COMPLETE)
        .map(|row| ManifestPage {
            number: row.number,
            file_name: Path::new(row.file_path.as_deref().unwrap_or(""))
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or_default()
                .to_string(),
            media_type: row.media_type.clone(),
            size_bytes: row.size_bytes,
            width: 0,
            height: 0,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::super::harness::{enqueue_book, mirror_manifest, stamp, FakePages, Fates, Tree};
    use super::*;
    use crate::cache::demo_png;
    use crate::downloads::queue::{page_state, Link, StopReason};
    use crate::downloads::store as downloads;

    fn request<'a>(server: &'a str) -> PassRequest<'a> {
        PassRequest {
            server_id: server,
            free_bytes: 1 << 30,
            link: Link::Unmetered,
            max_pages: 0,
            max_bytes: 0,
            reader: None,
        }
    }

    async fn pump(tree: &Tree, fake: &FakePages) -> PassReport {
        run_pass(
            &tree.db_path,
            &tree.root,
            fake,
            &request("s1"),
            harness_now(),
        )
        .await
        .expect("the pass itself did not fail")
    }

    fn harness_now() -> chrono::DateTime<Utc> {
        super::super::harness::now()
    }

    #[tokio::test]
    async fn a_pass_lands_pages_and_stops_at_its_bound() {
        let tree = Tree::new("pass_bound");
        enqueue_book(&tree, "s1", "b1", 6);
        let fake = FakePages::with_pages(6);
        let mut limited = request("s1");
        limited.max_pages = 3;
        let report = run_pass(&tree.db_path, &tree.root, &fake, &limited, harness_now())
            .await
            .unwrap();
        assert_eq!(report.served, 3);
        assert_eq!(report.stop, StopReason::Budget);
        assert_eq!(
            fake.asked(),
            vec![1, 2, 3],
            "one request per page, in queue order"
        );
        assert_eq!(report.pages_done, 3);
        // A pass that stopped on its own bound leaves the book waiting: it is not
        // finished, and it has not failed, and the UI must not be told either.
        assert_eq!(report.state.as_deref(), Some(book_state::WAITING));
        assert!(report.queue_active, "half a book is not a finished queue");
        assert_eq!(
            tree.page_files("s1", "b1"),
            vec!["0001.png", "0002.png", "0003.png"],
            "files are named by page number, and no staging file survives"
        );
        assert_eq!(
            report.bytes_written,
            downloads::bytes_done_all(&tree.conn).unwrap()
        );
    }

    #[tokio::test]
    async fn the_book_reaches_completed_and_writes_its_manifest() {
        let tree = Tree::new("pass_complete");
        enqueue_book(&tree, "s1", "b1", 5);
        let fake = FakePages::with_pages(5);
        let mut limited = request("s1");
        limited.max_pages = 2;
        let first = run_pass(&tree.db_path, &tree.root, &fake, &limited, harness_now())
            .await
            .unwrap();
        let second = run_pass(&tree.db_path, &tree.root, &fake, &limited, harness_now())
            .await
            .unwrap();
        let third = run_pass(&tree.db_path, &tree.root, &fake, &limited, harness_now())
            .await
            .unwrap();
        assert_eq!((first.served, second.served, third.served), (2, 2, 1));
        assert_eq!(third.state.as_deref(), Some(book_state::COMPLETED));
        assert!(!third.queue_active);
        assert_eq!(fake.asked_count(), 5, "five pages, five requests, no more");
        let document = manifest::read_manifest(&tree.root.manifest_path("s1", "b1"))
            .unwrap()
            .expect("a completed book has a manifest");
        assert_eq!(document.pages_count, 5);
        assert_eq!(document.pages.len(), 5);
        assert!(tree
            .page_files("s1", "b1")
            .iter()
            .all(|name| name.ends_with(".png")));
        // Each file is what its row and its manifest both claim.
        for page in &document.pages {
            let path = tree.root.book_dir("s1", "b1").join(&page.file_name);
            assert_eq!(
                page.size_bytes,
                std::fs::metadata(&path).unwrap().len() as i64
            );
            let row = downloads::page(&tree.conn, "s1", "b1", page.number)
                .unwrap()
                .unwrap();
            assert_eq!(row.size_bytes, page.size_bytes);
            assert_eq!(row.state, page_state::COMPLETE);
        }
    }

    /// An outage is not a failure of the book, and must not spend any of its retries.
    #[tokio::test]
    async fn a_link_failure_burns_no_attempt_and_needs_no_manual_retry() {
        let tree = Tree::new("pass_link");
        enqueue_book(&tree, "s1", "b1", 4);
        let fake = FakePages::with_pages(4);
        fake.set(2, Fates::Unreachable);
        let report = pump(&tree, &fake).await;
        assert_eq!(report.served, 1, "page 1 landed before the route failed");
        assert_eq!(report.stop, StopReason::LinkDown);
        assert_eq!(report.next_in_ms, 2_000);
        let row = downloads::page(&tree.conn, "s1", "b1", 2).unwrap().unwrap();
        assert_eq!(row.attempts, 0, "an outage must not spend a page's retries");
        assert_eq!(row.state, page_state::PENDING);
        assert_eq!(report.state.as_deref(), Some(book_state::WAITING));
        assert!(
            downloads::bytes_done_all(&tree.conn).unwrap() > 0,
            "page 1 was not accounted"
        );

        // The link comes back mid-read: the queue continues with no user gesture.
        fake.set(2, Fates::Good);
        let done = pump(&tree, &fake).await;
        assert_eq!(done.state.as_deref(), Some(book_state::COMPLETED));
        assert_eq!(done.served, 3);
        assert!(
            fake.asked().iter().filter(|n| **n == 2).count() <= 2,
            "page 2 was asked {} times",
            fake.asked().iter().filter(|n| **n == 2).count()
        );
    }

    #[tokio::test]
    async fn a_short_read_fails_only_its_own_page_and_the_book_moves_on() {
        let tree = Tree::new("pass_short");
        enqueue_book(&tree, "s1", "b1", 6);
        let fake = FakePages::with_pages(6);
        fake.set(2, Fates::Short);
        // Three passes is the per-page limit; the other five pages keep landing while
        // page 2 spends its attempts, which is the single-page-retry claim.
        let mut served = 0;
        for _ in 0..4 {
            let report = pump(&tree, &fake).await;
            served += report.served;
        }
        let page2 = downloads::page(&tree.conn, "s1", "b1", 2).unwrap().unwrap();
        assert_eq!(
            page2.attempts, 3,
            "exactly the contracted number of attempts"
        );
        assert_eq!(page2.state, page_state::FAILED);
        assert_eq!(
            page2.last_error.as_deref(),
            Some(describe(Outcome::BadPage))
        );
        assert_eq!(served, 5, "every other page landed across the four passes");
        assert_eq!(
            downloads::complete_pages(&tree.conn, "s1", "b1").unwrap(),
            vec![1, 3, 4, 5, 6]
        );
        let final_report = pump(&tree, &fake).await;
        assert_eq!(
            final_report.stop,
            StopReason::Idle,
            "a failed book is not the queue's to run"
        );
        assert!(!final_report.queue_active);
        let conn = store::open(&tree.db_path).unwrap();
        assert_eq!(
            downloads::state_of(&conn, "s1", "b1").unwrap().as_deref(),
            Some(book_state::FAILED),
            "a book with one unobtainable page is failed, not silently incomplete"
        );
        drop(conn);
        // The one bad page cost exactly its own attempts, and nothing else was
        // re-fetched to pay for it.
        assert_eq!(fake.asked().iter().filter(|n| **n == 1).count(), 1);
    }

    /// A dying server must cost three attempts across the book, not three per page.
    #[tokio::test]
    async fn three_bad_pages_end_the_pass_without_spending_the_rest() {
        let tree = Tree::new("pass_bad_run");
        enqueue_book(&tree, "s1", "b1", 20);
        let fake = FakePages::new();
        fake.set_default(Fates::Garbage);
        let first = pump(&tree, &fake).await;
        assert_eq!(first.served, 0);
        assert_eq!(first.stop, StopReason::BadRun);
        assert_eq!(
            fake.asked_count(),
            3,
            "the pass gave up after the run limit, not at 20"
        );
        assert_eq!(
            first.failed_pages, 0,
            "each page is on its first attempt, so none is spent"
        );
        let conn = store::open(&tree.db_path).unwrap();
        for number in 1..=3 {
            let row = downloads::page(&conn, "s1", "b1", number).unwrap().unwrap();
            assert_eq!(
                row.attempts, 1,
                "the run limit stops the pass, it does not multiply attempts"
            );
            assert_eq!(row.state, page_state::PENDING);
        }
        assert_eq!(
            downloads::page(&conn, "s1", "b1", 4)
                .unwrap()
                .unwrap()
                .attempts,
            0,
            "the fourth page was never asked for"
        );
        drop(conn);
        // Three passes is three attempts each, and only then does a page fail.
        pump(&tree, &fake).await;
        let third = pump(&tree, &fake).await;
        assert_eq!(third.stop, StopReason::BadRun);
        assert_eq!(
            fake.asked_count(),
            9,
            "three requests per pass against a dying server"
        );
        assert_eq!(
            third.failed_pages, 3,
            "all three pages spent their last attempt this pass"
        );
        let conn = store::open(&tree.db_path).unwrap();
        for number in 1..=3 {
            let row = downloads::page(&conn, "s1", "b1", number).unwrap().unwrap();
            assert_eq!((row.attempts, row.state.as_str()), (3, page_state::FAILED));
        }
        assert!(
            downloads::page(&conn, "s1", "b1", 4)
                .unwrap()
                .unwrap()
                .state
                == page_state::PENDING,
            "the pages nobody ever asked for are untouched"
        );
        assert_eq!(
            third.state.as_deref(),
            Some(book_state::WAITING),
            "17 pages left, so the book is not failed yet"
        );
    }

    #[tokio::test]
    async fn a_pause_during_a_pass_costs_only_the_page_in_flight() {
        let tree = Tree::new("pass_pause");
        enqueue_book(&tree, "s1", "b1", 6);
        let fake = FakePages::with_pages(6);
        let db = tree.db_path.clone();
        // The user presses 暂停 while page 2 is on the wire — the only interruption a
        // real download ever actually sees.
        fake.after_request
            .borrow_mut()
            .replace(Box::new(move |count| {
                if count == 2 {
                    let conn = store::open(&db).expect("open");
                    downloads::user_set(&conn, "s1", "b1", book_state::PAUSED, &stamp(5), None)
                        .expect("pause");
                }
            }));
        let report = pump(&tree, &fake).await;
        assert_eq!(report.stop, StopReason::Paused);
        assert_eq!(
            report.served, 1,
            "page 1 landed; page 2's bytes were thrown away"
        );
        assert_eq!(report.state.as_deref(), Some(book_state::PAUSED));
        assert_eq!(tree.page_files("s1", "b1"), vec!["0001.png"]);
        assert_eq!(
            fake.asked(),
            vec![1, 2],
            "the pass stopped rather than continuing"
        );
        // Resuming is the user's, and the queue picks up where it stopped.
        let conn = store::open(&tree.db_path).unwrap();
        downloads::user_set(&conn, "s1", "b1", book_state::WAITING, &stamp(6), None).unwrap();
        drop(conn);
        let resumed = pump(&tree, &fake).await;
        assert_eq!(resumed.served, 4, "pages 2..=5, and never page 1 again");
        assert_eq!(
            resumed.stop,
            StopReason::Budget,
            "the pass bound is what stopped it"
        );
        let finished = pump(&tree, &fake).await;
        assert_eq!(finished.served, 1);
        assert_eq!(finished.state.as_deref(), Some(book_state::COMPLETED));
        assert!(
            fake.asked().iter().filter(|n| **n == 1).count() == 1,
            "page 1 was fetched exactly once"
        );
    }

    #[tokio::test]
    async fn a_complete_page_is_never_fetched_again() {
        let tree = Tree::new("pass_no_refetch");
        enqueue_book(&tree, "s1", "b1", 4);
        // Two pages already on disk under their contract names, rows to match.
        for number in 1..=2 {
            let path = tree.root.page_path("s1", "b1", number, "png");
            std::fs::write(&path, demo_png::demo_page_bytes(number)).unwrap();
            downloads::mark_page_complete(
                &tree.conn,
                "s1",
                "b1",
                number,
                &path.to_string_lossy(),
                std::fs::metadata(&path).unwrap().len() as i64,
                "image/png",
                &stamp(0),
            )
            .unwrap();
        }
        let fake = FakePages::with_pages(4);
        let report = pump(&tree, &fake).await;
        assert_eq!(report.served, 2);
        assert_eq!(
            fake.asked(),
            vec![3, 4],
            "the queue did not re-fetch what is already there"
        );
        assert_eq!(report.state.as_deref(), Some(book_state::COMPLETED));
        assert_eq!(
            downloads::complete_pages(&tree.conn, "s1", "b1").unwrap(),
            vec![1, 2, 3, 4]
        );
    }

    /// A page that lands under a different container than an earlier copy did must
    /// leave exactly one file behind, named after what it now is.
    ///
    /// Driven through `land_page` rather than a pass, and that distinction is the
    /// finding: by the time a pass could re-fetch page 1, the reconciliation sweep has
    /// already adopted the whole file it found under the old name, so the engine never
    /// sees two siblings in practice. The cleanup is defence in depth — four lines that
    /// keep an accumulating `0001.jpg` beside `0001.png` impossible if some future path
    /// does reach it — and this is the only way to exercise it. It is not proof that a
    /// pass needs it today.
    #[test]
    fn a_page_that_lands_under_a_new_name_clears_the_old_one() {
        let tree = Tree::new("pass_rename");
        enqueue_book(&tree, "s1", "b1", 2);
        let stale = tree.root.page_path("s1", "b1", 1, "jpg");
        std::fs::write(&stale, demo_png::demo_page_bytes(1)).unwrap();
        downloads::mark_page_complete(
            &tree.conn,
            "s1",
            "b1",
            1,
            &stale.to_string_lossy(),
            std::fs::metadata(&stale).unwrap().len() as i64,
            "image/jpeg",
            &stamp(0),
        )
        .unwrap();
        downloads::heal_page(&tree.conn, "s1", "b1", 1, &stamp(1)).unwrap();
        let job = queue::Job {
            server_id: "s1".to_string(),
            book_id: "b1".to_string(),
            number: 1,
            declared_bytes: 0,
        };
        let conn = store::open(&tree.db_path).unwrap();
        conn.execute(
            "UPDATE downloads SET state = 'downloading' WHERE book_id = 'b1'",
            [],
        )
        .unwrap();
        let bytes = demo_png::demo_page_bytes(1);
        let verdict = integrity::inspect(&bytes, "image/png", None);
        let size = match land_page(
            &conn,
            &tree.root,
            &job,
            &bytes,
            "image/png",
            verdict.info(),
            &stamp(2),
        ) {
            Ok(Landed::Written(size)) => size,
            other => panic!("the page did not land: {other:?}"),
        };
        assert!(size > 0);
        assert_eq!(
            tree.page_files("s1", "b1"),
            vec!["0001.png"],
            "the old .jpg was orphaned beside the new file"
        );
        assert!(!stale.exists());
        let row = downloads::page(&conn, "s1", "b1", 1).unwrap().unwrap();
        assert_eq!(
            row.media_type, "image/png",
            "the row names what the bytes are"
        );
    }

    /// The reconciliation a killed process depends on has to be reached by the
    /// ordinary first pump. A sweep with no production caller is the defect Stage 8
    /// found twice on this codebase, once on each platform.
    #[tokio::test]
    async fn the_first_pass_of_a_process_reconciles_the_tree() {
        let tree = Tree::new("pass_first_sweep");
        enqueue_book(&tree, "s1", "b1", 4);
        let good = tree.root.page_path("s1", "b1", 2, "png");
        std::fs::write(&good, demo_png::demo_page_bytes(2)).unwrap();
        std::fs::write(
            DownloadRoot::staging_path(&tree.root.page_path("s1", "b1", 3, "png")),
            b"half a page",
        )
        .unwrap();
        recover::forget_swept();
        let fake = FakePages::with_pages(4);
        let first = pump(&tree, &fake).await;
        assert!(
            first.repairs >= 2,
            "the first pass repaired nothing: {first:?}"
        );
        assert_eq!(
            first.parts_swept, 1,
            "the torn write should have been reaped"
        );
        assert_eq!(
            first.adopted, 1,
            "the forgotten file should have been adopted"
        );
        // The second pass in the same process must not repeat the walk.
        let second = pump(&tree, &fake).await;
        assert_eq!(second.repairs, 0, "a sweep that runs every pass is a stall");
    }

    #[tokio::test]
    async fn a_rejected_credential_parks_the_whole_server_queue() {
        let tree = Tree::new("pass_blocked");
        enqueue_book(&tree, "s1", "b1", 3);
        enqueue_book(&tree, "s1", "b2", 3);
        let fake = FakePages::with_pages(3);
        fake.set(1, Fates::Rejected);
        let report = pump(&tree, &fake).await;
        assert_eq!(report.stop, StopReason::Blocked);
        assert_eq!(report.served, 0);
        assert_eq!(report.next_in_ms, 60_000);
        let conn = store::open(&tree.db_path).unwrap();
        for book in ["b1", "b2"] {
            let row = downloads::get(&conn, "s1", book).unwrap().unwrap();
            assert!(
                row.next_retry_at.is_some(),
                "{book} was not parked, so the next pass will discover the 401 again"
            );
        }
        // Both books are parked, so the queue idles instead of hammering.
        let parked = pump(&tree, &fake).await;
        assert_eq!(parked.stop, StopReason::Parked);
        assert_eq!(parked.served, 0);
        assert_eq!(
            fake.asked_count(),
            1,
            "one request proved it for both books"
        );
        // The appointment expires and the queue runs again with no user gesture.
        drop(conn);
        let later = harness_now() + chrono::Duration::seconds(120);
        let mut req = request("s1");
        req.max_pages = 1;
        let revived = run_pass(
            &tree.db_path,
            &tree.root,
            &FakePages::with_pages(3),
            &req,
            later,
        )
        .await
        .unwrap();
        assert_eq!(
            revived.served, 1,
            "after the park expires the queue moves on its own"
        );
    }

    /// A 404 is a fact about the book, not about the page: it must be terminal, and
    /// it must leave every attempt unspent so the user's retry is a real retry.
    #[tokio::test]
    async fn a_missing_book_fails_once_instead_of_forever() {
        let tree = Tree::new("pass_gone");
        mirror_manifest(&tree, "s1", "vanished", &[1, 2, 3]);
        let conn = store::open(&tree.db_path).unwrap();
        downloads::enqueue(
            &conn,
            &downloads::NewDownload {
                server_id: "s1".to_string(),
                book_id: "vanished".to_string(),
                pages_total: 3,
                bytes_total: 3_000,
                manifest_path: tree
                    .root
                    .manifest_path("s1", "vanished")
                    .to_string_lossy()
                    .into_owned(),
                remote_last_modified: None,
                book_title: None,
                series_title: None,
            },
            &[1, 2, 3],
            &stamp(0),
        )
        .unwrap();
        drop(conn);
        crate::downloads::harness::create_tree_for(&tree, "s1", "vanished", 3);
        // `new`, not `with_pages`: a per-page table entry would override the default
        // and this would quietly become a successful download of a book that is gone.
        let fake = FakePages::new();
        fake.set_default(Fates::Missing);
        let report = pump(&tree, &fake).await;
        assert_eq!(report.stop, StopReason::Gone);
        assert_eq!(report.served, 0);
        assert_eq!(
            fake.asked_count(),
            1,
            "one request proved it for the whole book"
        );
        assert_eq!(report.state.as_deref(), Some(book_state::FAILED));
        assert!(
            !report.queue_active,
            "a terminal failure leaves nothing to pump"
        );
        let conn = store::open(&tree.db_path).unwrap();
        assert_eq!(
            downloads::page(&conn, "s1", "vanished", 1)
                .unwrap()
                .unwrap()
                .attempts,
            0,
            "a book that is gone burned no retries"
        );
        drop(conn);
        let again = pump(&tree, &fake).await;
        assert_eq!(
            again.stop,
            StopReason::Idle,
            "the next pass leaves a failed book alone"
        );
        assert_eq!(fake.asked_count(), 1, "and asked for nothing at all");
    }

    #[tokio::test]
    async fn a_metered_link_waits_for_the_users_okay() {
        let tree = Tree::new("pass_metered");
        enqueue_book(&tree, "s1", "b1", 4);
        let fake = FakePages::with_pages(4);
        let mut metered = request("s1");
        metered.link = Link::Metered;
        let report = run_pass(&tree.db_path, &tree.root, &fake, &metered, harness_now())
            .await
            .unwrap();
        assert_eq!(report.stop, StopReason::LinkBlocked);
        assert_eq!(fake.asked_count(), 0, "not one byte spent without consent");
        let conn = store::open(&tree.db_path).unwrap();
        downloads::set_allow_cellular(&conn, "s1", "b1", true, &stamp(1)).unwrap();
        drop(conn);
        let allowed = run_pass(&tree.db_path, &tree.root, &fake, &metered, harness_now())
            .await
            .unwrap();
        assert_eq!(allowed.served, 4);
    }

    #[tokio::test]
    async fn no_space_and_no_word_from_the_platform_stops_a_new_book_only() {
        let tree = Tree::new("pass_space");
        enqueue_book(&tree, "s1", "b1", 4);
        let fake = FakePages::with_pages(4);
        let mut dry = request("s1");
        dry.free_bytes = 0;
        let report = run_pass(&tree.db_path, &tree.root, &fake, &dry, harness_now())
            .await
            .unwrap();
        assert_eq!(report.stop, StopReason::LowSpace);
        assert_eq!(fake.asked_count(), 0);
        // Partway through, the same silence does not stop the book already running.
        dry.free_bytes = 1 << 30;
        dry.max_pages = 1;
        run_pass(&tree.db_path, &tree.root, &fake, &dry, harness_now())
            .await
            .unwrap();
        dry.free_bytes = 0;
        let running = run_pass(&tree.db_path, &tree.root, &fake, &dry, harness_now())
            .await
            .unwrap();
        assert!(
            running.served > 0,
            "a platform that will not talk must not brick a download"
        );
    }

    /// The pass and the reader share a process. This is the measurement that makes
    /// the wall-clock bound a promise rather than a comment.
    #[tokio::test]
    async fn a_pass_returns_inside_its_wall_clock_bound() {
        let tree = Tree::new("pass_elapsed");
        enqueue_book(&tree, "s1", "b1", 8);
        let fake = FakePages::with_pages(8);
        // No sleeping in a unit test: the bound itself is the thing under test, so
        // assert the bound is a real number and that a pass with nothing to do stays
        // inside it. The slow-server version of this claim is the acceptance gate's,
        // where a `--delay-ms` server makes `max_pump_ms` exceed it if the check is
        // removed (see scripts/e2e_stage9.sh).
        assert!(queue::max_elapsed_ms() > 0);
        let report = pump(&tree, &fake).await;
        assert!(
            report.pump_ms < queue::max_elapsed_ms() * 4,
            "a local pass should take milliseconds, got {}",
            report.pump_ms
        );
        assert_eq!(
            report.served, 4,
            "the default page bound is what stopped this pass"
        );
    }
}
