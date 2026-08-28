//! Event Driven Sync (Stage 6) — the SSE session, not the socket.
//!
//! The rule this module exists to enforce
//! (`specs/contracts/reconnect/README.md`): an event is a *hint* that data may
//! have changed. It never carries truth into SQLite — it names an entity, and
//! `apply_dirty` re-fetches that entity through the API. Consequently:
//!
//! - losing events is survivable (the dirty set is a coalescing hint list, and
//!   a reconnect reconciles anyway);
//! - a reconnect must reconcile *before* consuming events, because we can never
//!   know what the gap contained;
//! - an unreachable or absent `/sse/v1/events` degrades freshness only: the
//!   session parks in `ReconcileOnly` and the mirror keeps converging on the
//!   other triggers.

use std::collections::BTreeSet;

use rusqlite::Connection;
use serde::Deserialize;

use crate::api::error::Result;
use crate::api::mutation::ProgressWriter;
use crate::api::sse::SseEvent;
use crate::store::books;
use crate::store::outbox::{at_offset, backoff_seconds};
use crate::store::prune;

/// What a hint points at.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Target {
    Book(String),
    Series(String),
    Collection(String),
    ReadList(String),
}

/// An event decoded into "go look at this". `Global` means we could not name an
/// entity, which is always safe: it costs one reconciliation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hint {
    pub targets: Vec<Target>,
    pub global: bool,
    pub deleted: bool,
}

impl Hint {
    pub fn global() -> Self {
        Hint {
            targets: Vec::new(),
            global: true,
            deleted: false,
        }
    }

    /// An event that says nothing about mirrored data.
    pub fn ignore() -> Self {
        Hint {
            targets: Vec::new(),
            global: false,
            deleted: false,
        }
    }
}

/// The id fields a Komga event may carry. `id` is deliberately absent: on the
/// wire that is the *event* id, not an entity id, and reading it as one would
/// make every event look like a change to a nonexistent entity. `libraryId` and
/// `taskId` are absent too — a library or task event means a full sweep, which
/// needs no id out of the payload.
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct EventIds {
    #[serde(default)]
    book_id: Option<String>,
    #[serde(default)]
    series_id: Option<String>,
    #[serde(default)]
    collection_id: Option<String>,
    #[serde(default)]
    read_list_id: Option<String>,
}

/// Map a verified Komga event name onto the entity it says changed.
///
/// The names come from `SseController` / the `emitSse("...")` literals in Komga
/// 1.26.3 source, catalogued in `specs/events/komga-sse-events.md`. Two facts
/// from that source read shaped this function:
///
/// - the wire name is a literal, not a class name (`BookUpdated` → `BookChanged`),
///   and the JSON body carries no type discriminator — `event:` is the only name;
/// - `ReadProgressChanged` carries a `bookId` but no "book" in its name, so a
///   keyword-only matcher would send every remote read into a full sweep.
///
/// Anything unrecognised becomes a global hint, which is always safe.
pub fn classify(event: &SseEvent) -> Hint {
    let ids: EventIds = event.json().unwrap_or_default();
    let (target, deleted) = match event.kind.as_str() {
        // A `Deleted` event means the entity itself is gone server-side.
        "BookDeleted" => (ids.book_id.map(Target::Book), true),
        "SeriesDeleted" => (ids.series_id.map(Target::Series), true),
        "CollectionDeleted" => (ids.collection_id.map(Target::Collection), true),
        "ReadListDeleted" => (ids.read_list_id.map(Target::ReadList), true),
        // Note `*Thumbnail*Deleted` is about the thumbnail record, not the entity.
        "BookAdded"
        | "BookChanged"
        | "ThumbnailBookAdded"
        | "ThumbnailBookDeleted"
        | "ReadProgressChanged"
        | "ReadProgressDeleted"
        | "BookImported" => (ids.book_id.map(Target::Book), false),
        "SeriesAdded"
        | "SeriesChanged"
        | "ThumbnailSeriesAdded"
        | "ThumbnailSeriesDeleted"
        | "ReadProgressSeriesChanged"
        | "ReadProgressSeriesDeleted" => (ids.series_id.map(Target::Series), false),
        "CollectionAdded"
        | "CollectionChanged"
        | "ThumbnailSeriesCollectionAdded"
        | "ThumbnailSeriesCollectionDeleted" => (ids.collection_id.map(Target::Collection), false),
        "ReadListAdded"
        | "ReadListChanged"
        | "ThumbnailReadListAdded"
        | "ThumbnailReadListDeleted" => (ids.read_list_id.map(Target::ReadList), false),
        // Server bookkeeping: not mirrored data at all.
        "TaskQueueStatus" | "SessionExpired" => return Hint::ignore(),
        _ => (None, false),
    };
    match target {
        Some(target) => Hint {
            targets: vec![target],
            global: false,
            deleted,
        },
        // A read-progress event with no usable id, an import with no book id, a
        // library event, a name from a newer Komga: sweep. Costs one pass.
        None => Hint::global(),
    }
}

/// Coalescing hint list: N events for one book cost one re-fetch.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct DirtySet {
    pub books: BTreeSet<String>,
    pub deleted_books: BTreeSet<String>,
    pub series: BTreeSet<String>,
    pub deleted_series: BTreeSet<String>,
    pub collections: BTreeSet<String>,
    pub readlists: BTreeSet<String>,
    pub global: bool,
}

impl DirtySet {
    pub fn is_empty(&self) -> bool {
        !self.global
            && self.books.is_empty()
            && self.deleted_books.is_empty()
            && self.series.is_empty()
            && self.deleted_series.is_empty()
            && self.collections.is_empty()
            && self.readlists.is_empty()
    }

    pub fn merge(&mut self, hint: &Hint) {
        if hint.global {
            self.global = true;
        }
        for target in &hint.targets {
            match (target, hint.deleted) {
                (Target::Book(id), false) => {
                    self.books.insert(id.clone());
                }
                (Target::Book(id), true) => {
                    // A delete wins over any pending change for the same id.
                    self.books.remove(id);
                    self.deleted_books.insert(id.clone());
                }
                (Target::Series(id), false) => {
                    self.series.insert(id.clone());
                }
                (Target::Series(id), true) => {
                    self.series.remove(id);
                    self.deleted_series.insert(id.clone());
                }
                (Target::Collection(id), _) => {
                    self.collections.insert(id.clone());
                }
                (Target::ReadList(id), _) => {
                    self.readlists.insert(id.clone());
                }
            }
        }
    }

    /// Anything beyond a bare book touch needs the full id sweep: series
    /// membership, derived counters and deletions cannot be patched locally.
    pub fn needs_sweep(&self) -> bool {
        self.global
            || !self.series.is_empty()
            || !self.deleted_series.is_empty()
            || !self.collections.is_empty()
            || !self.readlists.is_empty()
    }

    pub fn hint_count(&self) -> usize {
        self.books.len()
            + self.deleted_books.len()
            + self.series.len()
            + self.deleted_series.len()
            + self.collections.len()
            + self.readlists.len()
            + usize::from(self.global)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Phase {
    /// Never connected, or waiting for our next attempt.
    #[default]
    Disconnected,
    /// Socket open but the post-reconnect reconciliation has not run yet.
    /// Events are buffered, not applied.
    Reconciling,
    /// Streaming and applying hints.
    Connected,
    /// The handshake proved there is no usable event stream.
    ReconcileOnly,
}

/// Session state for one server's event stream. Owns no thread: the app drives
/// it (`pump` per tick), which is what lets backgrounding stop it and
/// foregrounding / network recovery restart it immediately.
#[derive(Debug, Default)]
pub struct SseSession {
    pub phase: Phase,
    pub attempts: i64,
    pub next_attempt_at: Option<String>,
    pub last_event_id: Option<String>,
    pub retry_floor_ms: Option<u64>,
    pub buffered: Vec<SseEvent>,
    pub dirty: DirtySet,
    /// Set once a connection has been lost or (re)established: the gap is
    /// unknowable, so a sweep is mandatory before trusting hints again.
    pub reconcile_required: bool,
    pub reason: Option<String>,
}

impl SseSession {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn disconnected(&self) -> bool {
        matches!(self.phase, Phase::Disconnected | Phase::Reconciling)
    }

    /// Time to try the socket again?
    pub fn due(&self, now: &str) -> bool {
        if self.phase == Phase::ReconcileOnly {
            return false;
        }
        if self.phase != Phase::Disconnected {
            return false;
        }
        match (&self.next_attempt_at, now) {
            (None, _) => true,
            (Some(scheduled), now) => scheduled.as_str() <= now,
        }
    }

    /// Seconds until the next attempt, for the UI and for tests.
    pub fn retry_in_seconds(&self, now: &str) -> Option<i64> {
        let scheduled = self.next_attempt_at.as_ref()?;
        let then = chrono::DateTime::parse_from_rfc3339(scheduled).ok()?;
        let now = chrono::DateTime::parse_from_rfc3339(now).ok()?;
        Some((then - now).num_seconds().max(0))
    }

    /// The socket came up. First time: start applying. Afterwards: the missed
    /// window is unknown, so demand a sweep before a single hint is trusted.
    pub fn note_connected(&mut self, _now: &str) {
        let had_connection = self.attempts > 0 || self.reconcile_required;
        self.attempts = 0;
        self.next_attempt_at = None;
        self.phase = if had_connection {
            self.reconcile_required = true;
            Phase::Reconciling
        } else {
            Phase::Connected
        };
    }

    /// The socket broke (or the app backgrounded it). Never a failure of data
    /// correctness — only of freshness.
    pub fn note_disconnected(&mut self, now: &str, penalise: bool) {
        if self.phase == Phase::Connected || self.phase == Phase::Reconciling {
            self.reconcile_required = true;
        }
        self.phase = Phase::Disconnected;
        if penalise {
            self.attempts += 1;
            let mut delay = backoff_seconds(self.attempts);
            if let Some(floor) = self.retry_floor_ms {
                delay = delay.max((floor / 1000) as i64);
            }
            self.next_attempt_at = at_offset(now, delay);
        } else {
            self.next_attempt_at = None;
        }
    }

    /// The app came back to the foreground: retry now, and sweep first.
    pub fn resume(&mut self, now: &str) {
        if self.phase == Phase::ReconcileOnly {
            return;
        }
        self.attempts = 0;
        self.next_attempt_at = Some(now.to_string());
        if !self.dirty.is_empty() || self.reconcile_required {
            self.reconcile_required = true;
        }
    }

    /// Handshake said there is no event stream we can use. Stop attempting; the
    /// mirror still converges through every other Reconcile trigger.
    pub fn into_reconcile_only(&mut self, reason: impl Into<String>) {
        self.phase = Phase::ReconcileOnly;
        self.next_attempt_at = None;
        self.reason = Some(reason.into());
    }

    /// Record one dispatched event: its resume token, its `retry:` suggestion,
    /// and its hint. While reconciling, events are only buffered.
    pub fn note_event(&mut self, event: &SseEvent) {
        if let Some(id) = &event.id {
            self.last_event_id = Some(id.clone());
        }
        if let Some(retry) = event.retry_ms {
            self.retry_floor_ms = Some(retry);
        }
        if self.phase == Phase::Reconciling {
            self.buffered.push(event.clone());
            return;
        }
        let hint = classify(event);
        self.dirty.merge(&hint);
    }

    /// The sweep finished: it is safe to consume again, and whatever the gap
    /// contained has been re-read from the API.
    pub fn reconcile_done(&mut self) {
        self.reconcile_required = false;
        self.phase = Phase::Connected;
        let buffered = std::mem::take(&mut self.buffered);
        for event in buffered {
            let hint = classify(&event);
            self.dirty.merge(&hint);
        }
    }

    pub fn take_dirty(&mut self) -> DirtySet {
        std::mem::take(&mut self.dirty)
    }
}

/// The socket side, injectable so the reconnect/reconcile ordering is testable
/// without a server.
#[allow(async_fn_in_trait)]
pub trait EventSource {
    async fn open(&mut self, last_event_id: Option<&str>) -> Result<()>;
    /// `Ok(None)` = the stream ended; `Err` = it broke. Both are expected paths.
    async fn next(&mut self) -> Result<Option<SseEvent>>;
    fn close(&mut self);
}

/// What the caller must do after one `pump` step.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PumpAction {
    /// Nothing was due.
    Idle,
    /// Run a full Reconcile with `ReconcileTrigger::SseReconnected`, then call
    /// `session.reconcile_done()` and pump again.
    Reconcile,
    /// Applied hints, and the stream is still up.
    Applied,
    /// The stream is down; the next attempt is scheduled.
    BackingOff,
    /// No usable event stream — keep converging through Reconcile alone.
    ReconcileOnly,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ApplyReport {
    pub books_fetched: usize,
    pub books_written: usize,
    /// Hints we refused to apply because the re-fetch failed. A refused hint is
    /// re-queued by the caller, so the next sweep picks it up — dropping it
    /// would be trusting the event stream to be a queue.
    pub books_deferred: usize,
    pub books_deleted: usize,
    pub sweeps_requested: usize,
}

/// `SSE Event → Entity ID → API 重新拉取 → SQLite 更新`.
///
/// Book hints are re-fetched one by one; anything broader is left to the
/// caller's sweep. Writes go through the ordinary sync path, so an unuploaded
/// local mutation still outranks the server (`read_progress::sync_write_for`).
pub async fn apply_dirty<W: ProgressWriter + Sync>(
    conn: &Connection,
    server_id: &str,
    dirty: &DirtySet,
    writer: &W,
) -> (ApplyReport, Vec<String>) {
    let mut report = ApplyReport::default();
    let mut orphaned_covers = Vec::new();
    for book_id in &dirty.books {
        report.books_fetched += 1;
        match writer.book(book_id).await {
            Ok(Some(book)) => {
                if let Ok(written) =
                    books::save_books_batch(conn, server_id, std::slice::from_ref(&book))
                {
                    report.books_written += written;
                } else {
                    report.books_deferred += 1;
                }
            }
            // The server says it is gone: that is the confirmation Stage 5 said
            // was required before an Outbox row may be dropped.
            Ok(None) => orphaned_covers
                .extend(note_book_deleted(conn, server_id, book_id).unwrap_or_default()),
            Err(_) => report.books_deferred += 1,
        }
    }
    for book_id in &dirty.deleted_books {
        orphaned_covers.extend(note_book_deleted(conn, server_id, book_id).unwrap_or_default());
        report.books_deleted += 1;
    }
    report.sweeps_requested = usize::from(dirty.needs_sweep());
    (report, orphaned_covers)
}

/// Delete one book the server confirmed is gone, with an `event`-caused
/// tombstone. Returns cover files that became orphaned (the facade removes them
/// from disk). Queued Outbox rows for it survive until the upload phase sees a
/// 404 of its own (Stage 5 rule).
pub fn note_book_deleted(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Vec<String>> {
    prune::record_tombstone(conn, server_id, "book", book_id, "event")?;
    prune::delete_book(conn, server_id, book_id)
}

/// One bounded step of the event loop. The app calls this on a timer (or after
/// a lifecycle / connectivity change); it never blocks longer than one frame
/// read, which is what keeps pause/resume honest.
pub async fn pump<S: EventSource + Sync>(
    session: &mut SseSession,
    source: &mut S,
    now: &str,
) -> PumpAction {
    if session.phase == Phase::Reconciling {
        return PumpAction::Reconcile;
    }
    if session.phase == Phase::Connected {
        match source.next().await {
            Ok(Some(event)) => {
                session.note_event(&event);
                return PumpAction::Applied;
            }
            Ok(None) => {
                source.close();
                session.note_disconnected(now, true);
                return PumpAction::BackingOff;
            }
            Err(_) => {
                source.close();
                session.note_disconnected(now, true);
                return PumpAction::BackingOff;
            }
        }
    }
    if !session.due(now) {
        return PumpAction::Idle;
    }
    match source.open(session.last_event_id.as_deref()).await {
        Ok(()) => {
            session.note_connected(now);
            if session.reconcile_required {
                PumpAction::Reconcile
            } else {
                PumpAction::Applied
            }
        }
        Err(crate::api::error::ApiError::ApiCompatibility { message }) => {
            session.into_reconcile_only(message);
            PumpAction::ReconcileOnly
        }
        Err(_) => {
            session.note_disconnected(now, true);
            PumpAction::BackingOff
        }
    }
}
