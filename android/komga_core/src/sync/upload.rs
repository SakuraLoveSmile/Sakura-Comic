//! Mutation Upload Sync (Stage 6) — the Outbox consumer.
//!
//! ```text
//! UI → SQLite → pending_mutations → this module → Komga
//! ```
//!
//! Every rule it applies is pinned by `specs/contracts/fixtures/outbox/`:
//! coalescing happens on the enqueue side, and here we do the Targeted Re-fetch,
//! the R1-R5 conflict decision, the retry/backoff/failed state machine and the
//! cleanup after the server confirmed. A queued action is only ever dropped
//! after a 204, a 404/410, or a decision that the server already has it.

use rusqlite::{params, Connection, OptionalExtension};

use crate::api::mutation::ProgressWriter;
use crate::store::outbox::{self, Attempt, Decision, OutboxCounts, OutboxEntry, Refetch};

/// Why an upload run stopped early.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum RunStatus {
    /// Every eligible row was processed.
    #[default]
    Complete,
    /// A 401/403 ended the run; the rest of the queue is untouched.
    BlockedAuthentication,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UploadSummary {
    pub server_id: String,
    pub considered: usize,
    pub uploaded: usize,
    /// Converged without a request (rule R3).
    pub already_applied: usize,
    /// Rule R4: a strictly later remote action won.
    pub remote_wins: usize,
    /// Rule R1: the server confirmed the entity is gone.
    pub gone: usize,
    /// Rule R7: the intent said nothing uploadable; cleared without a request.
    pub no_op: usize,
    /// Rule R8: the server cannot take this write for this format.
    pub unsupported_format: usize,
    pub retried: usize,
    pub rejected: usize,
    /// Rows still waiting for their backoff to elapse when the run started.
    pub waiting: usize,
    pub blocked_authentication: usize,
    pub status: RunStatus,
}

/// Counts the uploader leaves behind for the UI (Outbox badge / settings row).
pub fn outbox_counts(
    conn: &Connection,
    server_id: &str,
    now: &str,
) -> rusqlite::Result<OutboxCounts> {
    outbox::counts(conn, server_id, now)
}

use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use tokio::sync::Mutex;

fn upload_lock(conn: &Connection, server_id: &str) -> Arc<Mutex<()>> {
    static LOCKS: OnceLock<std::sync::Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();
    let map = LOCKS.get_or_init(|| std::sync::Mutex::new(HashMap::new()));
    let key = match conn.path() {
        Some(p) => format!("file:{p}:{server_id}"),
        None => format!("mem:{conn:p}:{server_id}"),
    };
    let mut guard = map.lock().unwrap();
    guard
        .entry(key)
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

/// One pass over everything due right now. `now` is injected so the backoff
/// schedule is testable (and so a restart cannot reschedule anything).
pub async fn upload_outbox<W: ProgressWriter + Sync>(
    conn: &Connection,
    server_id: &str,
    writer: &W,
    now: &str,
) -> rusqlite::Result<UploadSummary> {
    let lock = upload_lock(conn, server_id);
    let _guard = lock.lock().await;

    let due = outbox::due_entries(conn, server_id, now);
    let due = due?;
    let waiting = outbox::counts(conn, server_id, now)?.waiting;
    let mut summary = UploadSummary {
        server_id: server_id.to_string(),
        considered: due.len(),
        waiting: waiting as usize,
        ..UploadSummary::default()
    };

    for entry in due {
        let Some(intent) = outbox::intent_of(&entry.mutation_type, &entry.payload) else {
            // An unknown mutation type is not ours to interpret: leave it queued.
            summary.considered -= 1;
            continue;
        };
        let local_action_at = local_action_time(conn, server_id, &entry)?;
        let refetch = writer.refetch(&entry.entity_id).await;

        // F03: Check if entry still exists before proceeding with upload or decision
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM pending_mutations WHERE id = ?1",
                params![entry.id],
                |row| row.get::<_, i64>(0),
            )
            .map(|count| count > 0)
            .unwrap_or(false);
        if !exists {
            // Stale entry: superseded by coalesce or deleted while refetching
            continue;
        }

        match outbox::decide(&entry.entity_id, &intent, &local_action_at, &refetch) {
            Decision::DropGone => {
                outbox::complete_mutation(conn, server_id, &entry.entity_id, &entry.id)?;
                summary.gone += 1;
            }
            Decision::DropNoOp => {
                outbox::complete_mutation(conn, server_id, &entry.entity_id, &entry.id)?;
                summary.no_op += 1;
            }
            Decision::UnsupportedFormat { reason } => {
                // Park it with the reason rather than spend the retry ladder on
                // a 400 the server will keep giving.
                outbox::park_unsupported(conn, &entry.id, &reason)?;
                summary.unsupported_format += 1;
            }
            Decision::DropSuccess => {
                outbox::complete_mutation(conn, server_id, &entry.entity_id, &entry.id)?;
                summary.already_applied += 1;
            }
            Decision::DropRemoteWins => {
                // Our intent loses on purpose. Clearing the queue lets the next
                // mirror sweep take the server value, so both sides converge.
                outbox::complete_mutation(conn, server_id, &entry.entity_id, &entry.id)?;
                summary.remote_wins += 1;
            }
            Decision::Defer { penalised } => {
                if penalised {
                    outbox::record_outcome(
                        conn,
                        &entry,
                        &Attempt::Retryable,
                        now,
                        "refetch failed",
                    )?;
                    summary.retried += 1;
                }
                if matches!(refetch, Refetch::Unauthorized) {
                    summary.status = RunStatus::BlockedAuthentication;
                    break;
                }
            }
            Decision::Upload(request) => {
                let attempt = writer.apply(&request).await;
                match attempt {
                    Attempt::Succeeded => {
                        outbox::complete_mutation(conn, server_id, &entry.entity_id, &entry.id)?;
                        summary.uploaded += 1;
                    }
                    Attempt::Gone => {
                        outbox::complete_mutation(conn, server_id, &entry.entity_id, &entry.id)?;
                        summary.gone += 1;
                    }
                    Attempt::BlockedAuthentication => {
                        summary.blocked_authentication += 1;
                        summary.status = RunStatus::BlockedAuthentication;
                        outbox::record_outcome(conn, &entry, &attempt, now, "401")?;
                        break;
                    }
                    other => {
                        outbox::record_outcome(conn, &entry, &other, now, &format!("{other:?}"))?;
                        match other {
                            Attempt::Retryable => summary.retried += 1,
                            Attempt::Rejected => summary.rejected += 1,
                            _ => {}
                        }
                    }
                }
            }
        }
    }
    Ok(summary)
}

/// When the user actually did this. `local_updated_at` is the authoritative
/// answer; a queue row that outlived its local row falls back to its own
/// creation time so R4 still has something honest to compare against.
fn local_action_time(
    conn: &Connection,
    server_id: &str,
    entry: &OutboxEntry,
) -> rusqlite::Result<String> {
    let stamp: Option<String> = conn
        .query_row(
            "SELECT local_updated_at FROM read_progress WHERE server_id = ?1 AND book_id = ?2",
            params![server_id, entry.entity_id],
            |row| row.get(0),
        )
        .optional()?;
    Ok(stamp.unwrap_or_else(|| entry.created_at.clone()))
}

/// Stage 6 acceptance, in-process: 断网 → 阅读 → 杀掉 App → 重启 → 恢复网络 → 自动上传.
///
/// The "server" is scripted, so every wire call this asserts is one the real
/// `KomgaClient` makes the same way (see `bin/stage6_smoke.rs` for the HTTP leg).
#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::error::ApiError;
    use crate::api::mutation::remote_of;
    use crate::model::book::{Book, BookMetadata, ReadProgress};
    use crate::store::open_in_memory;
    use crate::store::outbox::RemoteProgress;
    use crate::store::outbox::WireRequest;
    use crate::store::read_progress;
    use std::collections::{HashMap, VecDeque};
    use std::sync::Mutex;

    #[derive(Default)]
    struct ScriptedServer {
        /// Per-book answers, consumed oldest first; the last one repeats.
        refetches: Mutex<HashMap<String, VecDeque<Refetch>>>,
        /// Outcomes for `apply`, consumed in call order.
        applies: Mutex<VecDeque<Attempt>>,
        sent: Mutex<Vec<(String, String, Option<String>)>>,
    }

    impl ScriptedServer {
        fn serve(&self, book: &str, answers: Vec<Refetch>) {
            self.refetches
                .lock()
                .unwrap()
                .insert(book.to_string(), answers.into());
        }
        fn then(&self, outcomes: Vec<Attempt>) {
            *self.applies.lock().unwrap() = outcomes.into();
        }
        fn sent(&self) -> Vec<(String, String, Option<String>)> {
            self.sent.lock().unwrap().clone()
        }
    }

    impl ProgressWriter for ScriptedServer {
        async fn refetch(&self, book_id: &str) -> Refetch {
            let mut queue = self.refetches.lock().unwrap();
            let answers = match queue.get_mut(book_id) {
                Some(answers) if answers.len() > 1 => answers.remove(1),
                Some(answers) => answers.front().cloned(),
                None => Some(Refetch::Unreachable),
            };
            answers.unwrap_or(Refetch::Unreachable)
        }

        async fn apply(&self, request: &WireRequest) -> Attempt {
            self.sent.lock().unwrap().push((
                request.method.as_str().to_string(),
                request.path.clone(),
                request.body.clone(),
            ));
            let mut outcomes = self.applies.lock().unwrap();
            if outcomes.len() > 1 {
                outcomes.remove(0).unwrap_or(Attempt::Succeeded)
            } else {
                outcomes.front().cloned().unwrap_or(Attempt::Succeeded)
            }
        }

        async fn book(&self, book_id: &str) -> std::result::Result<Option<Book>, ApiError> {
            match self.refetch(book_id).await {
                Refetch::Found(progress) => Ok(Some(book_with_progress(book_id, progress))),
                Refetch::NotFound => Ok(None),
                _ => Err(ApiError::Network),
            }
        }
    }

    fn book_with_progress(book_id: &str, found: RemoteProgress) -> Book {
        Book {
            id: book_id.to_string(),
            series_id: "s1".to_string(),
            series_title: None,
            name: "Book".to_string(),
            number: None,
            oneshot: false,
            media: None,
            metadata: Some(BookMetadata {
                title: "Book".to_string(),
                number: None,
                number_sort: None,
                summary: None,
                isbn: None,
                release_date: None,
                authors: Vec::new(),
                tags: Vec::new(),
            }),
            read_progress: Some(ReadProgress {
                page: found.page,
                completed: found.completed,
                last_modified: found.last_modified,
            }),
            created: None,
            last_modified: None,
            size_bytes: None,
        }
    }

    fn remote(page: i64, completed: bool, stamp: &str) -> Refetch {
        Refetch::Found(RemoteProgress {
            page: Some(page),
            completed,
            last_modified: Some(stamp.to_string()),
            media_type: Some("application/zip".to_string()),
        })
    }

    /// A reflowable book: same shape, different format (contract R8).
    fn remote_epub(page: i64, stamp: &str) -> Refetch {
        Refetch::Found(RemoteProgress {
            page: Some(page),
            completed: false,
            last_modified: Some(stamp.to_string()),
            media_type: Some("application/epub+zip".to_string()),
        })
    }

    fn at(server_updated_at: Option<i64>) -> RemoteProgress {
        RemoteProgress {
            page: server_updated_at,
            completed: false,
            last_modified: None,
            media_type: None,
        }
    }

    /// The full 验收标准, one test, in order.
    #[tokio::test]
    async fn offline_actions_survive_a_kill_and_upload_after_recovery() {
        let path =
            std::env::temp_dir().join(format!("komga-stage6-{}.sqlite", uuid::Uuid::new_v4()));
        // 1. 断网: the server cannot be reached at all.
        let server = ScriptedServer::default();
        for book in ["b1", "b2", "b3"] {
            server.serve(book, vec![Refetch::Unreachable]);
        }

        // 2. 阅读 / 修改状态 — all three local actions are recorded, on disk.
        {
            let conn = crate::store::open(&path).unwrap();
            read_progress::upsert_local_read_progress(&conn, "A", "b1", 30, false).unwrap();
            read_progress::mark_read(&conn, "A", "b2").unwrap();
            read_progress::mark_unread(&conn, "A", "b3").unwrap();
            assert_eq!(
                outbox_counts(&conn, "A", "2026-08-28T10:00:00Z")
                    .unwrap()
                    .total(),
                3,
                "the UI actions must land in the Outbox"
            );
            let blocked = upload_outbox(&conn, "A", &server, "2026-08-28T10:00:00Z")
                .await
                .unwrap();
            assert_eq!(blocked.retried, 3, "every row is deferred, none is lost");
            assert_eq!(blocked.uploaded, 0);
            assert!(
                server.sent().is_empty(),
                "nothing reaches an offline network"
            );
            assert_eq!(
                outbox_counts(&conn, "A", "2026-08-28T10:00:00Z")
                    .unwrap()
                    .total(),
                3,
                "an offline window must not consume the queue"
            );
            // 3. 杀掉 App: the connection goes away mid-flight, no clean shutdown.
        }

        // 4. 重新启动: a fresh process opens the same file.
        let conn = crate::store::open(&path).unwrap();
        let mut restored = outbox::all_entries(&conn, "A").unwrap();
        restored.sort_by(|a, b| a.entity_id.cmp(&b.entity_id));
        assert_eq!(
            restored.len(),
            3,
            "restart recovery: the queue must come back from SQLite"
        );
        for (entry, book) in restored.iter().zip(["b1", "b2", "b3"]) {
            assert_eq!(entry.entity_id, book);
            assert_eq!(entry.retry_count, 1, "the offline attempt is still charged");
            assert_ne!(entry.next_retry_at, None, "and its deadline is on disk");
        }

        // 5. 恢复网络: the server answers again.
        server.serve("b1", vec![remote(5, false, "2026-08-28T09:00:00Z")]);
        server.serve("b2", vec![remote(1, false, "2026-08-28T09:00:00Z")]);
        server.serve("b3", vec![remote(50, true, "2026-08-28T09:00:00Z")]);
        server.then(vec![Attempt::Succeeded; 3]);

        // 6. Mutation 自动上传.
        let summary = upload_outbox(&conn, "A", &server, "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.uploaded, 3, "summary: {summary:?}");
        assert_eq!(summary.status, RunStatus::Complete);
        let mut sent = server.sent();
        sent.sort_by(|a, b| a.1.cmp(&b.1));
        assert_eq!(
            sent,
            vec![
                (
                    "PATCH".to_string(),
                    "/api/v1/books/b1/read-progress".to_string(),
                    Some(r#"{"page":30,"completed":false}"#.to_string())
                ),
                (
                    "PATCH".to_string(),
                    "/api/v1/books/b2/read-progress".to_string(),
                    Some(r#"{"completed":true}"#.to_string())
                ),
                (
                    "DELETE".to_string(),
                    "/api/v1/books/b3/read-progress".to_string(),
                    None
                ),
            ],
            "the actions must reach the server exactly as the user made them"
        );
        // 成功后清理 Outbox.
        assert_eq!(
            outbox_counts(&conn, "A", "2026-08-28T12:00:00Z")
                .unwrap()
                .total(),
            0
        );
        for book in ["b1", "b2", "b3"] {
            let (pending, stamp): (i64, Option<String>) = conn
                .query_row(
                    "SELECT mutation_pending, server_updated_at FROM read_progress
                     WHERE server_id = 'A' AND book_id = ?1",
                    [book],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap();
            assert_eq!(pending, 0, "{book} must stop blocking sweeps");
            assert_eq!(stamp, None, "204 has no body: the server stamp is unknown");
        }
        drop(conn);
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn a_later_remote_action_wins_and_the_local_row_then_converges() {
        let conn = open_in_memory().unwrap();
        read_progress::upsert_local_read_progress(&conn, "A", "b1", 90, false).unwrap();
        let server = ScriptedServer::default();
        // Another device read further, later than us. "Later" has to be relative
        // to the wall clock, because `upsert_local_read_progress` stamps our own
        // intent with `now_rfc3339()` — a fixed date here silently stops being
        // in the future the day after the test is written.
        let later = {
            let when = chrono::Utc::now() + chrono::TimeDelta::hours(1);
            when.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
        };
        server.serve("b1", vec![remote(91, false, &later)]);
        server.then(vec![Attempt::Succeeded]);
        let summary = upload_outbox(&conn, "A", &server, "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.remote_wins, 1);
        assert!(server.sent().is_empty(), "R4 must not send a packet");
        assert_eq!(
            outbox_counts(&conn, "A", "2026-08-28T12:00:00Z")
                .unwrap()
                .total(),
            0
        );
        // With the queue drained, the next mirror write is allowed again.
        read_progress::upsert_synced_read_progress(&conn, "A", "b1", Some(91), false, None)
            .unwrap();
        let page: i64 = conn
            .query_row(
                "SELECT page FROM read_progress WHERE server_id='A' AND book_id='b1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(page, 91, "the local row converges on the server value");
    }

    /// R8, at the uploader level: an epub page turn is parked with a reason and
    /// never sent, so it cannot burn the retry ladder on a guaranteed 400.
    #[tokio::test]
    async fn a_reflowable_page_progress_is_parked_not_sent() {
        let conn = open_in_memory().unwrap();
        read_progress::upsert_local_read_progress(&conn, "A", "b1", 12, false).unwrap();
        let server = ScriptedServer::default();
        server.serve("b1", vec![remote_epub(2, "2026-08-28T09:00:00Z")]);
        server.then(vec![Attempt::Succeeded]);
        let summary = upload_outbox(&conn, "A", &server, "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.unsupported_format, 1, "summary: {summary:?}");
        assert_eq!(summary.uploaded, 0);
        assert!(
            server.sent().is_empty(),
            "R8 must not put a packet on the wire"
        );
        let entry = outbox::queued_for_book(&conn, "A", "b1")
            .unwrap()
            .expect("kept for the UI");
        assert_eq!(entry.state, outbox::STATE_FAILED);
        assert!(entry.last_error.unwrap().contains("epub"));
    }

    /// R7: opening a book and putting it down again is not an upload, and it is
    /// not a failure either — the queue must simply go quiet.
    #[tokio::test]
    async fn a_progress_with_nothing_to_say_is_dropped_quietly() {
        let conn = open_in_memory().unwrap();
        read_progress::upsert_local_read_progress(&conn, "A", "b1", 0, false).unwrap();
        let server = ScriptedServer::default();
        server.serve("b1", vec![remote(0, false, "2026-08-28T09:00:00Z")]);
        let summary = upload_outbox(&conn, "A", &server, "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.no_op, 1, "summary: {summary:?}");
        assert!(server.sent().is_empty());
        assert_eq!(
            outbox::counts(&conn, "A", "2026-08-28T12:00:00Z")
                .unwrap()
                .total(),
            0
        );
    }

    #[tokio::test]
    async fn a_book_the_server_deleted_releases_its_queued_action() {
        let conn = open_in_memory().unwrap();
        read_progress::upsert_local_read_progress(&conn, "A", "b1", 12, false).unwrap();
        let server = ScriptedServer::default();
        server.serve("b1", vec![Refetch::NotFound]);
        let summary = upload_outbox(&conn, "A", &server, "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.gone, 1);
        assert_eq!(
            outbox_counts(&conn, "A", "2026-08-28T12:00:00Z")
                .unwrap()
                .total(),
            0
        );
    }

    #[tokio::test]
    async fn an_already_applied_action_converges_without_a_request() {
        let conn = open_in_memory().unwrap();
        read_progress::upsert_local_read_progress(&conn, "A", "b1", 30, false).unwrap();
        let server = ScriptedServer::default();
        server.serve("b1", vec![remote(30, false, "2026-08-28T11:00:00Z")]);
        let summary = upload_outbox(&conn, "A", &server, "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.already_applied, 1);
        assert!(server.sent().is_empty(), "R3 must not spend a request");
    }

    #[tokio::test]
    async fn a_rejected_credential_stops_the_run_without_penalising_anyone() {
        let conn = open_in_memory().unwrap();
        read_progress::mark_read(&conn, "A", "b1").unwrap();
        // A second row the run must never reach. Its `created_at` is in the far
        // future so the ordering is deterministic — same-tick rows have none.
        conn.execute(
            "INSERT INTO pending_mutations (id, server_id, entity_id, mutation_type, payload,
                                            created_at, retry_count, state)
             VALUES ('m-later','A','b2','READ_PROGRESS','{\"bookId\":\"b2\",\"page\":4,\"completed\":false}',
                     '2099-01-01T00:00:00Z', 0, 'pending')",
            [],
        )
        .unwrap();
        let server = ScriptedServer::default();
        server.serve("b1", vec![Refetch::Unauthorized]);
        server.serve("b2", vec![remote(0, false, "2026-08-28T09:00:00Z")]);
        let summary = upload_outbox(&conn, "A", &server, "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.status, RunStatus::BlockedAuthentication);
        assert_eq!(summary.uploaded, 0);
        assert_eq!(summary.considered, 2, "both were queued, one was reached");
        assert!(
            server.sent().is_empty(),
            "a credential refusal must not send anything"
        );
        for book in ["b1", "b2"] {
            let entry = outbox::queued_for_book(&conn, "A", book)
                .unwrap()
                .unwrap_or_else(|| panic!("{book} must still be queued"));
            assert_eq!(entry.retry_count, 0, "{book} was not our fault");
            assert_eq!(entry.next_retry_at, None);
            assert_eq!(entry.state, outbox::STATE_PENDING);
        }
    }

    #[tokio::test]
    async fn repeated_failures_end_in_failed_and_stop_hitting_the_server() {
        let conn = open_in_memory().unwrap();
        read_progress::upsert_local_read_progress(&conn, "A", "b1", 1, false).unwrap();
        let server = ScriptedServer::default();
        server.serve("b1", vec![remote(0, false, "2026-08-28T09:00:00Z")]);
        server.then(vec![Attempt::Retryable; 32]);
        let mut now = "2026-08-28T12:00:00Z".to_string();
        for attempt in 1..=8 {
            let summary = upload_outbox(&conn, "A", &server, &now).await.unwrap();
            assert_eq!(summary.retried, 1, "attempt {attempt}");
            let entry = outbox::queued_for_book(&conn, "A", "b1").unwrap();
            if attempt < 8 {
                let entry = entry.unwrap();
                assert_eq!(entry.retry_count, attempt);
                now = entry.next_retry_at.clone().unwrap();
            } else {
                assert!(entry.unwrap().state == outbox::STATE_FAILED);
            }
        }
        // A failed row is never retried on its own, not even years later.
        let summary = upload_outbox(&conn, "A", &server, "2030-01-01T00:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.considered, 0);
        assert_eq!(summary.retried, 0);
        // Until the user acts again — which is a new statement, not a retry.
        read_progress::upsert_local_read_progress(&conn, "A", "b1", 2, false).unwrap();
        server.then(vec![Attempt::Succeeded]);
        let summary = upload_outbox(&conn, "A", &server, "2030-01-01T00:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.uploaded, 1, "a fresh action gets a fresh schedule");
    }

    #[test]
    fn the_remote_shape_we_read_is_the_progress_not_the_book() {
        // Guards the R4 input: the stamp must come from readProgress, because
        // book.lastModified does not move when progress changes.
        let book = book_with_progress(
            "b1",
            RemoteProgress {
                page: Some(7),
                completed: true,
                last_modified: Some("2026-08-28T10:00:00Z".to_string()),
                media_type: Some("application/zip".to_string()),
            },
        );
        let progress = remote_of(&book);
        assert_eq!(progress.page, Some(7));
        assert!(progress.completed);
        assert_eq!(
            progress.last_modified.as_deref(),
            Some("2026-08-28T10:00:00Z")
        );
        assert_eq!(
            book.last_modified, None,
            "the book stamp is a different thing"
        );
    }

    #[test]
    fn a_missing_progress_row_has_no_stamp_to_lose_to() {
        let book = Book {
            id: "b1".to_string(),
            series_id: "s1".to_string(),
            series_title: None,
            name: "n".to_string(),
            number: None,
            oneshot: false,
            media: None,
            metadata: None,
            read_progress: None,
            created: None,
            last_modified: Some("2020-01-01T00:00:00Z".to_string()),
            size_bytes: None,
        };
        assert_eq!(remote_of(&book), at(None));
        assert_eq!(remote_of(&book).last_modified, None);
    }

    #[tokio::test]
    async fn f01_concurrent_page_turn_during_upload_is_not_cleared_by_complete_mutation() {
        let path = std::env::temp_dir().join(format!("komga-f01-{}.sqlite", uuid::Uuid::new_v4()));
        let conn = crate::store::open(&path).unwrap();
        read_progress::upsert_local_read_progress(&conn, "A", "b1", 10, false).unwrap();
        assert_eq!(
            outbox::counts(&conn, "A", "2026-08-28T12:00:00Z")
                .unwrap()
                .total(),
            1
        );

        struct InFlightWriter {
            path: std::path::PathBuf,
        }
        impl ProgressWriter for InFlightWriter {
            async fn refetch(&self, _book_id: &str) -> Refetch {
                remote(5, false, "2026-08-28T09:00:00Z")
            }
            async fn apply(&self, _request: &WireRequest) -> Attempt {
                // User turns page to 11 while upload is in flight!
                let conn = crate::store::open(&self.path).unwrap();
                read_progress::upsert_local_read_progress(&conn, "A", "b1", 11, false).unwrap();
                Attempt::Succeeded
            }
            async fn book(&self, _book_id: &str) -> std::result::Result<Option<Book>, ApiError> {
                Ok(None)
            }
        }

        let writer = InFlightWriter { path: path.clone() };
        let summary = upload_outbox(&conn, "A", &writer, "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        assert_eq!(summary.uploaded, 1);

        // After pass 1, the new mutation (page 11) must NOT be deleted, and mutation_pending must STILL be 1!
        let counts = outbox::counts(&conn, "A", "2026-08-28T12:00:00Z").unwrap();
        assert_eq!(counts.total(), 1, "page 11 mutation must survive");
        let (pending, page): (i64, i64) = conn
            .query_row(
                "SELECT mutation_pending, page FROM read_progress WHERE server_id = 'A' AND book_id = 'b1'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            pending, 1,
            "mutation_pending must stay 1 because page 11 is waiting"
        );
        assert_eq!(page, 11);

        // Pass 2: plain server accepts page 11
        let server = ScriptedServer::default();
        server.serve("b1", vec![remote(10, false, "2026-08-28T12:00:00Z")]);
        server.then(vec![Attempt::Succeeded]);
        let summary2 = upload_outbox(&conn, "A", &server, "2026-08-28T12:01:00Z")
            .await
            .unwrap();
        assert_eq!(summary2.uploaded, 1);
        assert_eq!(
            outbox::counts(&conn, "A", "2026-08-28T12:01:00Z")
                .unwrap()
                .total(),
            0
        );
        let pending_after: i64 = conn
            .query_row(
                "SELECT mutation_pending FROM read_progress WHERE server_id = 'A' AND book_id = 'b1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            pending_after, 0,
            "now that all mutations are uploaded, mutation_pending is 0"
        );
        drop(conn);
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn f03_stale_entry_superseded_during_refetch_is_skipped() {
        let path = std::env::temp_dir().join(format!("komga-f03-{}.sqlite", uuid::Uuid::new_v4()));
        let conn = crate::store::open(&path).unwrap();
        read_progress::upsert_local_read_progress(&conn, "A", "b1", 10, false).unwrap();

        struct SupersedingWriter {
            path: std::path::PathBuf,
            applied: std::sync::atomic::AtomicBool,
        }
        impl ProgressWriter for SupersedingWriter {
            async fn refetch(&self, _book_id: &str) -> Refetch {
                // While refetch is happening, user turns to page 20, which coalesces (deletes old entry)
                let conn = crate::store::open(&self.path).unwrap();
                read_progress::upsert_local_read_progress(&conn, "A", "b1", 20, false).unwrap();
                remote(5, false, "2026-08-28T09:00:00Z")
            }
            async fn apply(&self, _request: &WireRequest) -> Attempt {
                self.applied
                    .store(true, std::sync::atomic::Ordering::SeqCst);
                Attempt::Succeeded
            }
            async fn book(&self, _book_id: &str) -> std::result::Result<Option<Book>, ApiError> {
                Ok(None)
            }
        }

        let writer = SupersedingWriter {
            path: path.clone(),
            applied: std::sync::atomic::AtomicBool::new(false),
        };
        let summary = upload_outbox(&conn, "A", &writer, "2026-08-28T12:00:00Z")
            .await
            .unwrap();
        // The stale entry was skipped!
        assert_eq!(summary.uploaded, 0);
        assert!(
            !writer.applied.load(std::sync::atomic::Ordering::SeqCst),
            "stale request must not be sent to wire"
        );

        // The new entry (page 20) is still in the queue!
        let counts = outbox::counts(&conn, "A", "2026-08-28T12:00:00Z").unwrap();
        assert_eq!(counts.total(), 1);
        drop(conn);
        let _ = std::fs::remove_file(&path);
    }
}
