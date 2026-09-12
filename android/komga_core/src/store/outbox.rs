//! Mutation Outbox consumer side (Stage 6).
//!
//! Everything here is the *read/decide* half of
//! `specs/contracts/offline-mutation/README.md`; the enqueue half lives in
//! `store::read_progress` (local-first writes) and calls [`coalesce`] so a
//! device only ever uploads the user's last statement per book.
//!
//! The uploader deliberately holds no in-flight state: a Komga
//! `read-progress` write is idempotent, so "at-least-once + replay after a
//! kill" is the whole recovery story (contract: 重启恢复).

use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;

use crate::api::error::ApiError;
use crate::store::read_progress::newer;

/// Read-progress mutation family — the kinds that collapse into one another.
pub const FAMILY: [&str; 3] = ["READ_PROGRESS", "MARK_READ", "MARK_UNREAD"];

pub const STATE_PENDING: &str = "pending";
pub const STATE_FAILED: &str = "failed";

/// Backoff policy, mirrored from `fixtures/outbox/backoff.json#policy`.
pub const BASE_SECONDS: i64 = 2;
pub const MAX_SECONDS: i64 = 300;
pub const MAX_ATTEMPTS: i64 = 8;

/// One queued client write waiting for the server.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboxEntry {
    pub id: String,
    pub server_id: String,
    pub entity_id: String,
    pub mutation_type: String,
    pub payload: String,
    pub created_at: String,
    pub retry_count: i64,
    pub last_error: Option<String>,
    pub state: String,
    pub next_retry_at: Option<String>,
}

/// Drop the queued entries this new one supersedes (contract: Mutation 合并).
///
/// Same server, same entity, same family — the user's newest statement wins,
/// including over a row that had already given up (`failed`). Different
/// entities are never merged.
pub fn coalesce(conn: &Connection, server_id: &str, entity_id: &str) -> rusqlite::Result<usize> {
    let removed = conn.execute(
        "DELETE FROM pending_mutations
         WHERE server_id = ?1 AND entity_id = ?2 AND mutation_type IN (?3, ?4, ?5)",
        params![server_id, entity_id, FAMILY[0], FAMILY[1], FAMILY[2]],
    )?;
    Ok(removed)
}

/// Entries eligible for upload right now, in the order the user made them.
pub fn due_entries(
    conn: &Connection,
    server_id: &str,
    now: &str,
) -> rusqlite::Result<Vec<OutboxEntry>> {
    let mut stmt = conn.prepare(
        "SELECT id, server_id, entity_id, mutation_type, payload, created_at, retry_count,
                last_error, state, next_retry_at
         FROM pending_mutations
         WHERE server_id = ?1 AND state = 'pending'
           AND (next_retry_at IS NULL OR next_retry_at <= ?2)
         ORDER BY created_at ASC, id ASC",
    )?;
    let rows = stmt.query_map(params![server_id, now], row_to_entry)?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
}

/// Everything queued, including entries still backing off or given up.
pub fn all_entries(conn: &Connection, server_id: &str) -> rusqlite::Result<Vec<OutboxEntry>> {
    let mut stmt = conn.prepare(
        "SELECT id, server_id, entity_id, mutation_type, payload, created_at, retry_count,
                last_error, state, next_retry_at
         FROM pending_mutations WHERE server_id = ?1
         ORDER BY created_at ASC, id ASC",
    )?;
    let rows = stmt.query_map([server_id], row_to_entry)?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
}

fn row_to_entry(row: &rusqlite::Row) -> rusqlite::Result<OutboxEntry> {
    Ok(OutboxEntry {
        id: row.get("id")?,
        server_id: row.get("server_id")?,
        entity_id: row.get("entity_id")?,
        mutation_type: row.get("mutation_type")?,
        payload: row.get("payload")?,
        created_at: row.get("created_at")?,
        retry_count: row.get("retry_count")?,
        last_error: row.get("last_error")?,
        state: row.get("state")?,
        next_retry_at: row.get("next_retry_at")?,
    })
}

/// How a single upload attempt ended (contract: 结果分类).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Attempt {
    /// 204 — the server has it; the row is deleted.
    Succeeded,
    /// 404 / 410 — the server confirmed the entity is gone; drop the row.
    Gone,
    /// 400 — the payload was rejected; give up without burning retries.
    Rejected,
    /// 408 / 429 / 5xx / transport — try again after the backoff.
    Retryable,
    /// 401 / 403 — a credential problem is global: stop the run, penalise nothing.
    BlockedAuthentication,
}

impl Attempt {
    pub fn classify(error: &ApiError) -> Self {
        match error {
            ApiError::Authentication => Attempt::BlockedAuthentication,
            ApiError::Server {
                status_code: 404 | 410,
            } => Attempt::Gone,
            ApiError::Server { status_code: 400 } => Attempt::Rejected,
            ApiError::Server { .. } => Attempt::Retryable,
            // A decode failure means the write may well have landed; retrying an
            // idempotent progress write is cheaper than losing the user action.
            _ => Attempt::Retryable,
        }
    }

    pub fn from_status(status: u16) -> Self {
        match status {
            401 | 403 => Attempt::BlockedAuthentication,
            404 | 410 => Attempt::Gone,
            400 => Attempt::Rejected,
            _ => Attempt::Retryable,
        }
    }
}

/// Exponential backoff in seconds after `retry_count` failures (>= 1).
pub fn backoff_seconds(retry_count: i64) -> i64 {
    let exponent = retry_count.saturating_sub(1).min(16);
    let raw = BASE_SECONDS.saturating_mul(1i64 << exponent);
    raw.min(MAX_SECONDS)
}

/// `now + seconds` as an RFC 3339 UTC stamp (second precision). Shared with the
/// SSE reconnect scheduler so both schedule off one clock.
pub fn at_offset(now: &str, seconds: i64) -> Option<String> {
    let at = chrono::DateTime::parse_from_rfc3339(now).ok()?;
    let at = at.with_timezone(&chrono::Utc) + chrono::Duration::seconds(seconds);
    Some(at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

/// `now + backoff(retry_count)`, or `None` when the row has given up.
pub fn next_retry_at(now: &str, retry_count: i64) -> Option<String> {
    at_offset(now, backoff_seconds(retry_count))
}

/// Record the outcome of one attempt. Returns the row's new state.
pub fn record_outcome(
    conn: &Connection,
    entry: &OutboxEntry,
    attempt: &Attempt,
    now: &str,
    error: &str,
) -> rusqlite::Result<()> {
    match attempt {
        Attempt::Succeeded | Attempt::Gone => {
            conn.execute(
                "DELETE FROM pending_mutations WHERE id = ?1",
                [entry.id.as_str()],
            )?;
        }
        Attempt::BlockedAuthentication => {
            // Deliberate no-op: 401 must not advance the penalty of the user's action.
        }
        Attempt::Rejected => {
            conn.execute(
                "UPDATE pending_mutations SET state = 'failed', next_retry_at = NULL, last_error = ?2
                 WHERE id = ?1",
                params![entry.id, error],
            )?;
        }
        Attempt::Retryable => {
            let attempts = entry.retry_count + 1;
            if attempts >= MAX_ATTEMPTS {
                conn.execute(
                    "UPDATE pending_mutations SET retry_count = ?2, state = 'failed',
                       next_retry_at = NULL, last_error = ?3
                     WHERE id = ?1",
                    params![entry.id, attempts, error],
                )?;
            } else {
                conn.execute(
                    "UPDATE pending_mutations SET retry_count = ?2, state = 'pending',
                       next_retry_at = ?3, last_error = ?4
                     WHERE id = ?1",
                    params![entry.id, attempts, next_retry_at(now, attempts), error],
                )?;
            }
        }
    }
    Ok(())
}

/// Hand a given-up row back to the retry machine (UI "retry now", or the user
/// acting on the book again — which supersedes it instead).
pub fn retry_failed(
    conn: &Connection,
    server_id: &str,
    entity_id: &str,
) -> rusqlite::Result<usize> {
    conn.execute(
        "UPDATE pending_mutations SET state = 'pending', retry_count = 0,
           next_retry_at = NULL, last_error = NULL
         WHERE server_id = ?1 AND entity_id = ?2 AND state = 'failed'",
        params![server_id, entity_id],
    )
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OutboxCounts {
    pub pending: i64,
    pub waiting: i64,
    pub failed: i64,
}

impl OutboxCounts {
    pub fn total(&self) -> i64 {
        self.pending + self.waiting + self.failed
    }
}

pub fn counts(conn: &Connection, server_id: &str, now: &str) -> rusqlite::Result<OutboxCounts> {
    let mut result = OutboxCounts::default();
    let mut stmt = conn.prepare(
        "SELECT state, CASE WHEN next_retry_at IS NULL OR next_retry_at <= ?2 THEN 0 ELSE 1 END,
                COUNT(*)
         FROM pending_mutations WHERE server_id = ?1 GROUP BY 1, 2",
    )?;
    let rows = stmt.query_map(params![server_id, now], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, i64>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })?;
    for row in rows {
        let (state, waiting, n) = row?;
        match (state.as_str(), waiting) {
            (STATE_FAILED, _) => result.failed += n,
            (_, 1) => result.waiting += n,
            _ => result.pending += n,
        }
    }
    Ok(result)
}

/// The server side of one book's progress, as of the mandatory re-fetch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteProgress {
    pub page: Option<i64>,
    pub completed: bool,
    pub last_modified: Option<String>,
    /// `media.mediaType` of the same BookDto. Which write endpoint is legal
    /// depends on it (contract R8), so the re-fetch has to carry it.
    pub media_type: Option<String>,
}

/// Reflowable formats: Komga refuses a page-based `read-progress` write for
/// these ("epub book is not Divina compatible") and expects the Progression API
/// instead. Measured on the live server, not read off the OpenAPI.
pub fn is_reflowable(media_type: Option<&str>) -> bool {
    matches!(
        media_type.unwrap_or_default(),
        "application/epub+zip" | "application/pdf"
    )
}

/// Outcome of the Targeted Re-fetch that must precede every upload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refetch {
    Found(RemoteProgress),
    NotFound,
    /// 401 / 403 — never penalise the row, and stop the run.
    Unauthorized,
    /// Transport failure — we cannot see the server, so we must not write blind.
    Unreachable,
}

/// What the user actually said, decoded from the queued payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Intent {
    /// Passive page progress.
    Progress {
        page: Option<i64>,
        completed: bool,
    },
    /// Explicit statements: never overridden by a remote passive value.
    MarkRead,
    MarkUnread,
}

#[derive(Debug, Clone, Deserialize)]
struct ProgressPayload {
    #[serde(default)]
    page: Option<i64>,
    #[serde(default)]
    completed: bool,
}

pub fn intent_of(mutation_type: &str, payload: &str) -> Option<Intent> {
    match mutation_type {
        "MARK_READ" => Some(Intent::MarkRead),
        "MARK_UNREAD" => Some(Intent::MarkUnread),
        "READ_PROGRESS" => {
            let parsed: ProgressPayload = serde_json::from_str(payload).ok()?;
            Some(Intent::Progress {
                page: parsed.page,
                completed: parsed.completed,
            })
        }
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    Patch,
    Delete,
}

impl Method {
    pub fn as_str(self) -> &'static str {
        match self {
            Method::Patch => "PATCH",
            Method::Delete => "DELETE",
        }
    }
}

/// The wire call an intent turns into (spec: PATCH body `ReadProgressUpdateDto`,
/// mark-unread is a DELETE with no body).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireRequest {
    pub method: Method,
    pub path: String,
    pub body: Option<String>,
}

pub fn request_for(book_id: &str, intent: &Intent) -> WireRequest {
    let path = format!("/api/v1/books/{book_id}/read-progress");
    match intent {
        Intent::MarkUnread => WireRequest {
            method: Method::Delete,
            path,
            body: None,
        },
        // `page` is omitted: an explicit mark must not rewrite the server's page.
        Intent::MarkRead => WireRequest {
            method: Method::Patch,
            path,
            body: Some("{\"completed\":true}".to_string()),
        },
        Intent::Progress { page, completed } => {
            let mut pairs = Vec::new();
            // A page is only sent when it means something: the endpoint rejects
            // 0 outright (R7 keeps that from ever being reached).
            if let Some(page) = page.filter(|page| *page > 0) {
                pairs.push(format!("\"page\":{page}"));
            }
            pairs.push(format!("\"completed\":{completed}"));
            WireRequest {
                method: Method::Patch,
                path,
                body: Some(format!("{{{}}}", pairs.join(","))),
            }
        }
    }
}

/// A conflict decision (contract rules R1-R5) plus whether it costs an attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Send [`WireRequest`].
    Upload(WireRequest),
    /// The server already has it — clean up without spending a request.
    DropSuccess,
    /// Rule R4: a strictly later remote action wins (never `max(page)`).
    DropRemoteWins,
    /// Rule R1: the server confirmed the entity is gone.
    DropGone,
    /// Rule R7: nothing the server can accept (no page / page 0, not completed).
    /// Neither a success nor a failure; nothing is sent.
    DropNoOp,
    /// Rule R8: a passive page progress on a reflowable book, which this
    /// endpoint refuses by format. Parked with a reason instead of retried.
    UnsupportedFormat { reason: String },
    /// Do nothing, keep the row. `penalised` rows advance the backoff.
    Defer { penalised: bool },
}

/// Rules R1-R5 of `specs/contracts/offline-mutation/README.md`, matched in
/// order. Pure function so both platforms can be pinned by the same fixture.
pub fn decide(
    book_id: &str,
    intent: &Intent,
    local_updated_at: &str,
    refetch: &Refetch,
) -> Decision {
    match refetch {
        Refetch::NotFound => Decision::DropGone,
        Refetch::Unauthorized => Decision::Defer { penalised: false },
        Refetch::Unreachable => Decision::Defer { penalised: true },
        Refetch::Found(remote) => {
            // R2: an explicit mark is uploaded unconditionally — including over a
            // server value that is strictly newer. R3's shortcut deliberately
            // does not apply: the point of a mark is that the server holds it now.
            // Marks are also the only thing the endpoint takes for a reflowable
            // book, so they are decided before R7/R8.
            if matches!(intent, Intent::MarkRead | Intent::MarkUnread) {
                return Decision::Upload(request_for(book_id, intent));
            }
            let page = match intent {
                Intent::Progress { page, .. } => *page,
                _ => None,
            };
            // R7, both measured on the live server: `page:0` answers 400
            // "must be greater than 0", and `{"completed":false}` answers 400
            // with no violations at all. Neither is a user action worth keeping.
            if page.unwrap_or(0) < 1 {
                return Decision::DropNoOp;
            }
            // R8: for epub (and non-Divina pdf) a page number cannot go through
            // this endpoint at all, whatever its value.
            if is_reflowable(remote.media_type.as_deref()) {
                return Decision::UnsupportedFormat {
                    reason: format!(
                        "{} 的翻页进度需走 Progression API",
                        remote.media_type.as_deref().unwrap_or("该格式")
                    ),
                };
            }
            // R3
            if remote_matches(remote, intent) {
                return Decision::DropSuccess;
            }
            // R4 — strictly newer remote stamp, decided by time, never by page.
            let remote_newer = remote
                .last_modified
                .as_deref()
                .is_some_and(|stamp| newer(stamp, local_updated_at));
            if remote_newer {
                return Decision::DropRemoteWins;
            }
            // R5
            Decision::Upload(request_for(book_id, intent))
        }
    }
}

fn remote_matches(remote: &RemoteProgress, intent: &Intent) -> bool {
    match intent {
        Intent::Progress { page, completed } => {
            remote.completed == *completed
                && match (remote.page, page) {
                    (Some(remote), Some(local)) => remote == *local,
                    // "no page recorded" and "page 0" are the same statement.
                    (None, None) | (None, Some(0)) | (Some(0), None) => true,
                    _ => false,
                }
        }
        Intent::MarkRead => remote.completed,
        Intent::MarkUnread => !remote.completed && remote.page.unwrap_or(0) == 0,
    }
}

/// Clear the local "waiting for the server" flag after a confirmed upload.
/// `server_updated_at` goes NULL: 204 carries no body, so guessing a server
/// stamp would make rule R4 lie on the next round.
pub fn apply_uploaded(conn: &Connection, server_id: &str, book_id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE read_progress SET mutation_pending = 0, server_updated_at = NULL
         WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
    )?;
    Ok(())
}

/// Park a row the server cannot take in its current form: it stops being
/// retried, keeps its payload, and carries a human-readable reason.
pub fn park_unsupported(conn: &Connection, id: &str, reason: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE pending_mutations SET state = 'failed', next_retry_at = NULL, last_error = ?2
         WHERE id = ?1",
        params![id, reason],
    )?;
    Ok(())
}

/// Completes a single mutation by its ID.
///
/// Deletes only the mutation specified by `mutation_id`. If there are no
/// remaining mutations for this book on this server, `read_progress.mutation_pending`
/// is cleared and `server_updated_at` goes NULL. If there are still pending
/// mutations (e.g. user performed another action while upload was in flight),
/// `mutation_pending` remains 1.
pub fn complete_mutation(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    mutation_id: &str,
) -> rusqlite::Result<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "DELETE FROM pending_mutations WHERE id = ?1",
        params![mutation_id],
    )?;
    let remaining: i64 = tx.query_row(
        "SELECT COUNT(*) FROM pending_mutations WHERE server_id = ?1 AND entity_id = ?2",
        params![server_id, book_id],
        |row| row.get(0),
    )?;
    if remaining == 0 {
        apply_uploaded(&tx, server_id, book_id)?;
    }
    tx.commit()?;
    Ok(())
}

/// Take the row out of the queue and let the mirror own the local value again.
///
/// Used by all three "the server side is settled" outcomes: the write was
/// confirmed, the server already had it, or rule R4 gave the round to a later
/// remote action. In every case the local row must stop blocking sweeps.
pub fn forget(conn: &Connection, server_id: &str, book_id: &str) -> rusqlite::Result<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "DELETE FROM pending_mutations WHERE server_id = ?1 AND entity_id = ?2",
        params![server_id, book_id],
    )?;
    apply_uploaded(&tx, server_id, book_id)?;
    tx.commit()?;
    Ok(())
}

/// Queued mutations for one book (UI badge + tests).
pub fn queued_for_book(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Option<OutboxEntry>> {
    conn.query_row(
        "SELECT id, server_id, entity_id, mutation_type, payload, created_at, retry_count,
                last_error, state, next_retry_at
         FROM pending_mutations WHERE server_id = ?1 AND entity_id = ?2
         ORDER BY created_at DESC LIMIT 1",
        params![server_id, book_id],
        row_to_entry,
    )
    .optional()
}

/// The Behavior Contract, enforced: `specs/contracts/fixtures/outbox/*.json` is
/// the same file the Swift side asserts (`OutboxContractTests`). Anything that
/// drifts here drifts there, so the fixture has to be edited first.
#[cfg(test)]
mod contract_tests {
    use super::*;
    use crate::store::{open_in_memory, read_progress};
    use serde::Deserialize;

    fn fixture<T: serde::de::DeserializeOwned>(relative: &str) -> T {
        let path = format!(
            "{}/../../specs/contracts/fixtures/outbox/{}",
            env!("CARGO_MANIFEST_DIR"),
            relative
        );
        let raw = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("shared fixture {path} must be readable: {e}"));
        serde_json::from_str(&raw).unwrap_or_else(|e| {
            panic!("shared fixture {relative} must decode into the test shape: {e}")
        })
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct ConflictFixture {
        cases: Vec<ConflictCase>,
    }

    #[derive(Deserialize)]
    struct ConflictCase {
        name: String,
        intent: IntentJson,
        local_updated_at: String,
        refetch: RefetchJson,
        expected: ExpectedConflict,
    }

    #[derive(Deserialize)]
    struct IntentJson {
        #[serde(rename = "type")]
        kind: String,
        #[serde(default)]
        page: Option<i64>,
        #[serde(default)]
        completed: Option<bool>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct RefetchJson {
        status: u16,
        #[serde(default)]
        page: Option<i64>,
        #[serde(default)]
        completed: Option<bool>,
        #[serde(default)]
        progress_last_modified: Option<String>,
        #[serde(default)]
        media_type: Option<String>,
    }

    #[derive(Deserialize)]
    struct ExpectedConflict {
        decision: String,
        #[serde(default)]
        packets: Vec<PacketJson>,
        #[serde(default)]
        effect: Option<EffectJson>,
        #[serde(default)]
        reason: Option<String>,
    }

    #[derive(Deserialize)]
    struct PacketJson {
        method: String,
        path: String,
        #[serde(default)]
        body: Option<serde_json::Value>,
    }

    #[derive(Deserialize)]
    struct EffectJson {
        #[serde(default)]
        retry_count: Option<String>,
    }

    fn intent_of_json(value: &IntentJson) -> Intent {
        match value.kind.as_str() {
            "MARK_READ" => Intent::MarkRead,
            "MARK_UNREAD" => Intent::MarkUnread,
            "READ_PROGRESS" => Intent::Progress {
                page: value.page,
                completed: value.completed.unwrap_or(false),
            },
            other => panic!("fixture intent {other} is not one of the three known kinds"),
        }
    }

    fn refetch_of(value: &RefetchJson) -> Refetch {
        match value.status {
            200 => Refetch::Found(RemoteProgress {
                page: value.page,
                completed: value.completed.unwrap_or(false),
                last_modified: value.progress_last_modified.clone(),
                media_type: value.media_type.clone(),
            }),
            404 | 410 => Refetch::NotFound,
            401 | 403 => Refetch::Unauthorized,
            _ => Refetch::Unreachable,
        }
    }

    /// R1-R6, including the two cases that prove this is not `max(page)`.
    #[test]
    fn conflict_rules_match_the_shared_fixture() {
        let fixture: ConflictFixture = fixture("conflict.json");
        assert!(
            fixture.cases.len() >= 10,
            "the conflict fixture lost cases: {}",
            fixture.cases.len()
        );
        for case in &fixture.cases {
            let intent = intent_of_json(&case.intent);
            let decision = decide(
                "book-1",
                &intent,
                &case.local_updated_at,
                &refetch_of(&case.refetch),
            );
            match case.expected.decision.as_str() {
                "upload" => {
                    let Decision::Upload(request) = &decision else {
                        panic!("case {:?}: expected upload, got {decision:?}", case.name)
                    };
                    let packet = case
                        .expected
                        .packets
                        .first()
                        .unwrap_or_else(|| panic!("case {:?} must send something", case.name));
                    assert_eq!(
                        request.method.as_str(),
                        packet.method,
                        "case {:?}",
                        case.name
                    );
                    assert_eq!(request.path, packet.path, "case {:?}", case.name);
                    let got = request.body.as_deref().map(|body| {
                        serde_json::from_str::<serde_json::Value>(body).expect("body is json")
                    });
                    assert_eq!(got, packet.body, "case {:?}", case.name);
                }
                "drop_success" => {
                    assert_eq!(decision, Decision::DropSuccess, "case {:?}", case.name)
                }
                "drop_remote_wins" => {
                    assert_eq!(decision, Decision::DropRemoteWins, "case {:?}", case.name)
                }
                "drop_gone" => assert_eq!(decision, Decision::DropGone, "case {:?}", case.name),
                "drop_no_op" => assert_eq!(decision, Decision::DropNoOp, "case {:?}", case.name),
                "unsupported_format" => {
                    let want = case.expected.reason.as_deref().unwrap_or("epub");
                    assert!(
                        matches!(&decision, Decision::UnsupportedFormat { reason } if reason.contains(want)),
                        "case {:?}: expected unsupported_format mentioning {want}, got {decision:?}",
                        case.name
                    );
                }
                "defer" => {
                    let penalised = case
                        .expected
                        .effect
                        .as_ref()
                        .map(|effect| effect.retry_count.as_deref() == Some("+1"))
                        .unwrap_or(false);
                    assert_eq!(
                        decision,
                        Decision::Defer { penalised },
                        "case {:?} (penalised={penalised})",
                        case.name
                    );
                }
                other => panic!("unknown fixture decision {other}"),
            }
        }
    }

    /// No fixture case may be decided by comparing page numbers. This is the
    /// machine-check for 「不能统一采用 max(page)」.
    #[test]
    fn the_losing_side_is_never_chosen_because_its_page_is_bigger() {
        // Same two rows, page order reversed: the decision must not flip.
        let older_local_low = decide(
            "b",
            &Intent::Progress {
                page: Some(3),
                completed: false,
            },
            "2026-08-28T11:00:00Z",
            &Refetch::Found(RemoteProgress {
                page: Some(90),
                completed: false,
                last_modified: Some("2026-08-28T10:00:00Z".into()),
                media_type: Some("application/zip".into()),
            }),
        );
        let older_local_high = decide(
            "b",
            &Intent::Progress {
                page: Some(90),
                completed: false,
            },
            "2026-08-28T11:00:00Z",
            &Refetch::Found(RemoteProgress {
                page: Some(3),
                completed: false,
                last_modified: Some("2026-08-28T10:00:00Z".into()),
                media_type: Some("application/zip".into()),
            }),
        );
        assert!(matches!(older_local_low, Decision::Upload(_)));
        assert!(matches!(older_local_high, Decision::Upload(_)));
        // And the mirror image: a later remote action wins whatever the pages are.
        for (local_page, remote_page) in [(90, 3), (3, 90)] {
            assert_eq!(
                decide(
                    "b",
                    &Intent::Progress {
                        page: Some(local_page),
                        completed: false,
                    },
                    "2026-08-28T10:00:00Z",
                    &Refetch::Found(RemoteProgress {
                        page: Some(remote_page),
                        completed: false,
                        last_modified: Some("2026-08-28T11:00:00Z".into()),
                        media_type: Some("application/zip".into()),
                    }),
                ),
                Decision::DropRemoteWins,
                "page order must not decide R4"
            );
        }
    }

    #[derive(Deserialize)]
    struct BackoffFixture {
        policy: PolicyJson,
        schedule: Vec<ScheduleRow>,
        cases: Vec<serde_json::Value>,
    }

    #[derive(Deserialize)]
    struct PolicyJson {
        base_seconds: i64,
        max_seconds: i64,
        max_attempts: i64,
    }

    #[derive(Deserialize)]
    struct ScheduleRow {
        retry_count: i64,
        delay_seconds: i64,
    }

    #[test]
    fn backoff_policy_matches_the_fixture() {
        let fixture: BackoffFixture = fixture("backoff.json");
        assert_eq!(fixture.policy.base_seconds, BASE_SECONDS);
        assert_eq!(fixture.policy.max_seconds, MAX_SECONDS);
        assert_eq!(fixture.policy.max_attempts, MAX_ATTEMPTS);
        for row in &fixture.schedule {
            assert_eq!(
                backoff_seconds(row.retry_count),
                row.delay_seconds,
                "retry_count {}",
                row.retry_count
            );
        }
        // The cap holds far past the schedule table.
        assert_eq!(backoff_seconds(30), MAX_SECONDS);
        assert!(!fixture.cases.is_empty(), "backoff fixture lost its cases");
    }

    fn seeded_in(conn: &Connection, retry_count: i64, next_retry_at: Option<&str>) {
        conn.execute(
            "INSERT INTO pending_mutations (id, server_id, entity_id, mutation_type, payload,
                                            created_at, retry_count, state, next_retry_at)
             VALUES ('m-1','A','book-1','READ_PROGRESS','{}','2026-08-28T10:00:00Z',?1,'pending',?2)",
            params![retry_count, next_retry_at],
        )
        .unwrap();
    }

    /// A restart must not buy the queue a fresh head start: the deadline is an
    /// absolute stamp in the database, not a timer in memory.
    #[test]
    fn an_absolute_deadline_survives_a_restart() {
        let path =
            std::env::temp_dir().join(format!("komga-outbox-{}.sqlite", uuid::Uuid::new_v4()));
        {
            let conn = crate::store::open(&path).unwrap();
            seeded_in(&conn, 3, Some("2026-08-28T10:01:04Z"));
        }
        // Same process, fresh connection — what an app relaunch gets.
        let conn = crate::store::open(&path).unwrap();
        let stored = all_entries(&conn, "A").unwrap();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].retry_count, 3);
        assert_eq!(
            stored[0].next_retry_at.as_deref(),
            Some("2026-08-28T10:01:04Z")
        );
        for (now, due) in [
            ("2026-08-28T10:00:31Z", false),
            ("2026-08-28T10:01:03Z", false),
            ("2026-08-28T10:01:04Z", true),
        ] {
            assert_eq!(
                !due_entries(&conn, "A", now).unwrap().is_empty(),
                due,
                "due check at {now}"
            );
        }
        drop(conn);
        let _ = std::fs::remove_file(&path);
    }

    /// Eight retryable failures and the row stops asking for the network.
    #[test]
    fn retryable_failures_walk_into_failed() {
        let conn = open_in_memory().unwrap();
        conn.execute(
            "INSERT INTO pending_mutations (id, server_id, entity_id, mutation_type, payload,
                                            created_at, retry_count, state)
             VALUES ('m-1','A','book-1','READ_PROGRESS','{}','2026-08-28T10:00:00Z',0,'pending')",
            [],
        )
        .unwrap();
        let mut now = "2026-08-28T10:00:00Z".to_string();
        for attempt in 1..=7 {
            let stored = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
            record_outcome(&conn, &stored, &Attempt::Retryable, &now, "503").unwrap();
            let stored = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
            assert_eq!(stored.retry_count, attempt);
            assert_eq!(stored.state, STATE_PENDING);
            assert_eq!(
                stored.next_retry_at.as_deref(),
                next_retry_at(&now, attempt).as_deref(),
                "attempt {attempt} must be scheduled by the shared schedule"
            );
            // Time travel: only after the deadline is the row due again.
            assert!(due_entries(&conn, "A", &now).unwrap().is_empty());
            now = stored.next_retry_at.clone().unwrap();
            assert_eq!(due_entries(&conn, "A", &now).unwrap().len(), 1);
        }
        let stored = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
        record_outcome(&conn, &stored, &Attempt::Retryable, &now, "503").unwrap();
        let stored = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
        assert_eq!(stored.state, STATE_FAILED);
        assert_eq!(stored.retry_count, MAX_ATTEMPTS);
        assert_eq!(stored.next_retry_at, None);
        assert!(
            due_entries(&conn, "A", "2030-01-01T00:00:00Z")
                .unwrap()
                .is_empty(),
            "a failed row must never come back on its own"
        );

        // A new user action revives it (coalescing replaces the row).
        read_progress::upsert_local_read_progress(&conn, "A", "book-1", 12, false).unwrap();
        let stored = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
        assert_eq!(stored.state, STATE_PENDING);
        assert_eq!(stored.retry_count, 0);
    }

    #[test]
    fn rejected_payload_gives_up_without_burning_the_schedule() {
        let conn = open_in_memory().unwrap();
        seeded_in(&conn, 2, None);
        let stored = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
        record_outcome(
            &conn,
            &stored,
            &Attempt::Rejected,
            "2026-08-28T10:00:00Z",
            "400",
        )
        .unwrap();
        let stored = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
        assert_eq!(stored.state, STATE_FAILED);
        assert_eq!(stored.retry_count, 2, "a rejection is not a retry");
        assert_eq!(stored.next_retry_at, None);
    }

    #[test]
    fn authentication_penalises_nothing() {
        let conn = open_in_memory().unwrap();
        seeded_in(&conn, 2, Some("2026-08-28T10:00:08Z"));
        let stored = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
        record_outcome(
            &conn,
            &stored,
            &Attempt::BlockedAuthentication,
            "2026-08-28T10:00:00Z",
            "401",
        )
        .unwrap();
        let after = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
        assert_eq!(after, stored, "a 401 must leave the row exactly as it was");
    }

    #[test]
    fn a_failed_row_can_be_handed_back_to_the_retry_machine() {
        let conn = open_in_memory().unwrap();
        seeded_in(&conn, 8, None);
        conn.execute(
            "UPDATE pending_mutations SET state = 'failed', last_error = '503'",
            [],
        )
        .unwrap();
        assert_eq!(retry_failed(&conn, "A", "book-1").unwrap(), 1);
        let stored = queued_for_book(&conn, "A", "book-1").unwrap().unwrap();
        assert_eq!(stored.state, STATE_PENDING);
        assert_eq!(stored.retry_count, 0);
        assert_eq!(stored.next_retry_at, None);
        assert_eq!(stored.last_error, None);
    }

    #[test]
    fn the_documented_route_shapes_are_the_ones_we_send() {
        assert_eq!(
            Attempt::classify(&ApiError::Server { status_code: 410 }),
            Attempt::Gone
        );
        // Mark-unread is a DELETE with no body; everything else is a PATCH.
        assert_eq!(
            request_for("b1", &Intent::MarkUnread).method,
            Method::Delete
        );
        assert_eq!(request_for("b1", &Intent::MarkUnread).body, None);
        assert_eq!(
            request_for("b1", &Intent::MarkRead).body.as_deref(),
            Some(r#"{"completed":true}"#)
        );
    }

    #[derive(Deserialize)]
    struct CoalescingFixture {
        family: Vec<String>,
        cases: Vec<CoalescingCase>,
    }

    #[derive(Deserialize)]
    struct CoalescingCase {
        name: String,
        steps: Vec<Step>,
        expected: ExpectedQueue,
    }

    #[derive(Deserialize)]
    struct Step {
        op: String,
        #[serde(default)]
        entity: Option<String>,
        #[serde(default, rename = "type")]
        kind: Option<String>,
        #[serde(default)]
        page: Option<i64>,
        #[serde(default)]
        completed: Option<bool>,
        #[serde(default)]
        retry_count: Option<i64>,
        #[serde(default)]
        state: Option<String>,
        #[serde(default)]
        error: Option<String>,
    }

    #[derive(Deserialize)]
    struct ExpectedQueue {
        queue: Vec<QueuedJson>,
    }

    #[derive(Deserialize)]
    struct QueuedJson {
        #[serde(rename = "type")]
        kind: String,
        entity: String,
        #[serde(default)]
        page: Option<i64>,
        #[serde(default)]
        completed: Option<bool>,
        #[serde(default)]
        state: Option<String>,
        #[serde(default)]
        retry_count: Option<i64>,
    }

    /// The queue is written through the production entry points, so this also
    /// proves `enqueue_mutation` really does coalesce.
    #[test]
    fn coalescing_matches_the_shared_fixture() {
        let fixture: CoalescingFixture = fixture("coalescing.json");
        assert_eq!(
            fixture.family.clone(),
            FAMILY.iter().copied().map(String::from).collect::<Vec<_>>(),
            "the fixture family list must match the code"
        );
        for case in &fixture.cases {
            let conn = open_in_memory().unwrap();
            for step in &case.steps {
                let entity = step.entity.clone().expect("fixture step names an entity");
                match step.op.as_str() {
                    "enqueue" => match step.kind.as_deref() {
                        Some("MARK_READ") => read_progress::mark_read(&conn, "A", &entity).unwrap(),
                        Some("MARK_UNREAD") => {
                            read_progress::mark_unread(&conn, "A", &entity).unwrap()
                        }
                        Some("READ_PROGRESS") => read_progress::upsert_local_read_progress(
                            &conn,
                            "A",
                            &entity,
                            step.page.unwrap_or(0),
                            step.completed.unwrap_or(false),
                        )
                        .unwrap(),
                        Some(other) => panic!("fixture enqueue type {other} is unknown"),
                        None => panic!("enqueue step without a type"),
                    },
                    "fail_outbox" => {
                        conn.execute(
                            "UPDATE pending_mutations SET retry_count = ?1, state = ?2,
                               last_error = ?3 WHERE entity_id = ?4",
                            params![
                                step.retry_count.unwrap_or(MAX_ATTEMPTS),
                                step.state.as_deref().unwrap_or(STATE_PENDING),
                                step.error.clone(),
                                entity
                            ],
                        )
                        .unwrap();
                    }
                    other => panic!("unknown fixture op {other}"),
                }
            }
            let mut queued = all_entries(&conn, "A").unwrap();
            queued.sort_by(|a, b| a.entity_id.cmp(&b.entity_id));
            let mut expected: Vec<&QueuedJson> = case.expected.queue.iter().collect();
            expected.sort_by(|a, b| a.entity.cmp(&b.entity));
            assert_eq!(
                queued.len(),
                expected.len(),
                "case {:?} left the wrong number of rows: {queued:?}",
                case.name
            );
            for (got, want) in queued.iter().zip(expected) {
                assert_eq!(got.mutation_type, want.kind, "case {:?}", case.name);
                assert_eq!(got.entity_id, want.entity, "case {:?}", case.name);
                if let Some(page) = want.page {
                    assert!(
                        got.payload.contains(&format!("\"page\":{page}")),
                        "case {:?}: payload lost the newest page: {}",
                        case.name,
                        got.payload
                    );
                }
                if let Some(completed) = want.completed {
                    assert!(
                        got.payload.contains(&format!("\"completed\":{completed}")),
                        "case {:?}: payload lost the newest completed flag: {}",
                        case.name,
                        got.payload
                    );
                }
                if let Some(state) = &want.state {
                    assert_eq!(&got.state, state, "case {:?}", case.name);
                }
                if let Some(retry_count) = want.retry_count {
                    assert_eq!(got.retry_count, retry_count, "case {:?}", case.name);
                }
            }
        }
    }
}
