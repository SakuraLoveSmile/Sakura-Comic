//! Stage 6 event-driven sync, driven through the crate's public API.
//!
//! No socket here: a scripted `EventSource` plays back exactly the sequences the
//! contract says must be survivable (`specs/contracts/reconnect/README.md`).

use std::collections::VecDeque;
use std::sync::Mutex;

use komga_core::api::error::{ApiError, Result};
use komga_core::api::sse::SseEvent;
use komga_core::sync::reconcile::ReconcileTrigger;
use komga_core::sync::sse::{classify, EventSource, Phase, PumpAction, SseSession, Target};

fn event(kind: &str, data: &str) -> SseEvent {
    SseEvent {
        kind: kind.to_string(),
        data: data.to_string(),
        id: None,
        retry_ms: None,
    }
}

fn says_nothing(hint: &komga_core::sync::sse::Hint) -> bool {
    hint.targets.is_empty() && !hint.global
}

#[derive(Default)]
struct FakeSource {
    /// One entry per `open` call: `None` = success, `Some(error)` = handshake failure.
    opens: Mutex<Vec<Option<ApiError>>>,
    /// Events handed out by `next`; running out means the stream broke.
    events: Mutex<VecDeque<SseEvent>>,
    /// The `Last-Event-ID` values we were asked to resume from.
    resumed_with: Mutex<Vec<Option<String>>>,
    closes: Mutex<usize>,
}

impl FakeSource {
    fn allow_opens(&self, n: usize) {
        self.opens.lock().unwrap().extend((0..n).map(|_| None));
    }

    fn queue(&self, events: Vec<SseEvent>) {
        self.events.lock().unwrap().extend(events);
    }

    fn resumes(&self) -> Vec<Option<String>> {
        self.resumed_with.lock().unwrap().clone()
    }
}

impl EventSource for FakeSource {
    async fn open(&mut self, last_event_id: Option<&str>) -> Result<()> {
        self.resumed_with
            .lock()
            .unwrap()
            .push(last_event_id.map(str::to_string));
        match self.opens.lock().unwrap().remove(0) {
            None => Ok(()),
            Some(error) => Err(error),
        }
    }

    async fn next(&mut self) -> Result<Option<SseEvent>> {
        match self.events.lock().unwrap().pop_front() {
            Some(event) => Ok(Some(event)),
            None => Err(ApiError::Network),
        }
    }

    fn close(&mut self) {
        *self.closes.lock().unwrap() += 1;
    }
}

/// Every name Komga puts on the wire, from the source-read catalogue in
/// `specs/events/komga-sse-events.md`. The wire names are string literals in
/// `SseController`, not class names, and the JSON body carries no discriminator.
#[test]
fn the_verified_catalogue_maps_to_the_right_target() {
    let book_events = [
        (
            "BookAdded",
            r#"{"bookId":"b1","seriesId":"s1","libraryId":"l1"}"#,
        ),
        (
            "BookChanged",
            r#"{"bookId":"b1","seriesId":"s1","libraryId":"l1"}"#,
        ),
        (
            "ThumbnailBookAdded",
            r#"{"bookId":"b1","seriesId":"s1","selected":true}"#,
        ),
        ("ReadProgressChanged", r#"{"bookId":"b1","userId":"u1"}"#),
        ("ReadProgressDeleted", r#"{"bookId":"b1","userId":"u1"}"#),
        (
            "BookImported",
            r#"{"bookId":"b1","sourceFile":"/f","success":true}"#,
        ),
    ];
    for (name, data) in book_events {
        let hint = classify(&event(name, data));
        assert_eq!(
            hint.targets,
            vec![Target::Book("b1".into())],
            "{name} must point at the book, not at a full sweep"
        );
        assert!(!hint.global, "{name} must not force a sweep");
        assert!(!hint.deleted, "{name} is not a deletion");
    }

    // The counter-example that keyword matching would have got wrong: a
    // read-progress event carries no "book" in its *name*, only in its payload.
    let series = classify(&event(
        "ReadProgressSeriesChanged",
        r#"{"seriesId":"s1","userId":"u1"}"#,
    ));
    assert_eq!(series.targets, vec![Target::Series("s1".into())]);

    let deletions = [
        (
            "BookDeleted",
            r#"{"bookId":"b1","seriesId":"s1","libraryId":"l1"}"#,
            Target::Book("b1".into()),
        ),
        (
            "SeriesDeleted",
            r#"{"seriesId":"s1","libraryId":"l1"}"#,
            Target::Series("s1".into()),
        ),
        (
            "CollectionDeleted",
            r#"{"collectionId":"c1","seriesIds":[]}"#,
            Target::Collection("c1".into()),
        ),
        (
            "ReadListDeleted",
            r#"{"readListId":"r1","bookIds":[]}"#,
            Target::ReadList("r1".into()),
        ),
    ];
    for (name, data, target) in deletions {
        let hint = classify(&event(name, data));
        assert_eq!(hint.targets, vec![target], "{name} target");
        assert!(hint.deleted, "{name} must propagate the deletion");
    }

    // A thumbnail record going away is not the entity going away.
    let thumbnail = classify(&event(
        "ThumbnailBookDeleted",
        r#"{"bookId":"b1","seriesId":"s1","selected":false}"#,
    ));
    assert!(
        !thumbnail.deleted,
        "losing a thumbnail must not delete a book"
    );
    assert_eq!(thumbnail.targets, vec![Target::Book("b1".into())]);

    // Container membership cannot be patched locally: it needs the sweep.
    let collection = classify(&event("CollectionChanged", r#"{"collectionId":"c1"}"#));
    assert_eq!(collection.targets, vec![Target::Collection("c1".into())]);
    let library = classify(&event("LibraryChanged", r#"{"libraryId":"l1"}"#));
    assert!(library.global, "a library change is a full sweep");

    // Server bookkeeping is not mirrored data at all.
    for name in ["TaskQueueStatus", "SessionExpired"] {
        assert!(
            says_nothing(&classify(&event(name, "{}"))),
            "{name} must not trigger any work"
        );
    }

    // Unknown names and unreadable payloads degrade to one sweep — never to a
    // crash, and never to silence.
    assert!(classify(&event("SomethingNewInKomga2", "{}")).global);
    assert!(classify(&event("BookChanged", "not json")).global);
    assert!(classify(&event("BookChanged", r#"{"userId":"u1"}"#)).global);
}

/// N events for one book cost one re-fetch, and a delete outranks a change.
#[test]
fn hints_coalesce() {
    let mut dirty: komga_core::sync::sse::DirtySet = Default::default();
    for _ in 0..50 {
        dirty.merge(&classify(&event(
            "ReadProgressChanged",
            r#"{"bookId":"b1","userId":"u1"}"#,
        )));
    }
    dirty.merge(&classify(&event(
        "BookChanged",
        r#"{"bookId":"b1","seriesId":"s1"}"#,
    )));
    assert_eq!(dirty.books.len(), 1);
    assert_eq!(dirty.hint_count(), 1, "51 events, one thing to look at");
    assert!(
        !dirty.needs_sweep(),
        "book hints alone are a targeted re-fetch"
    );
    dirty.merge(&classify(&event(
        "BookDeleted",
        r#"{"bookId":"b1","seriesId":"s1"}"#,
    )));
    assert!(
        dirty.books.is_empty(),
        "a delete wins over the pending change"
    );
    assert_eq!(dirty.deleted_books.len(), 1);
    dirty.merge(&classify(&event("SeriesChanged", r#"{"seriesId":"s1"}"#)));
    assert!(
        dirty.needs_sweep(),
        "a series hint cannot be patched locally"
    );
}

#[tokio::test]
async fn a_reconnect_reconciles_before_any_event_is_applied() {
    let mut session = SseSession::new();
    let mut source = FakeSource::default();
    source.allow_opens(1);
    // First connection: nothing was missed, so no sweep is owed.
    assert_eq!(
        pump(&mut session, &mut source, "2026-08-28T10:00:00Z").await,
        PumpAction::Applied
    );
    assert_eq!(session.phase, Phase::Connected);

    source.queue(vec![event("BookChanged", r#"{"bookId":"b1"}"#)]);
    assert_eq!(
        pump(&mut session, &mut source, "2026-08-28T10:00:01Z").await,
        PumpAction::Applied
    );
    assert_eq!(session.take_dirty().books.len(), 1);

    // The stream breaks: the gap is now unknowable.
    assert_eq!(
        pump(&mut session, &mut source, "2026-08-28T10:00:02Z").await,
        PumpAction::BackingOff
    );
    assert!(session.reconcile_required, "a lost connection owes a sweep");
    assert_eq!(
        session.next_attempt_at.as_deref(),
        Some("2026-08-28T10:00:04Z"),
        "backoff(1) = 2s"
    );
    // The backoff is respected: pumping early does nothing.
    assert_eq!(
        pump(&mut session, &mut source, "2026-08-28T10:00:03Z").await,
        PumpAction::Idle
    );
    assert_eq!(session.retry_in_seconds("2026-08-28T10:00:03Z"), Some(1));

    // Reconnect. Frames arriving now must NOT be trusted yet.
    source.allow_opens(3);
    source.queue(vec![
        event("BookChanged", r#"{"bookId":"b2"}"#),
        event("BookChanged", r#"{"bookId":"b3"}"#),
    ]);
    assert_eq!(
        pump(&mut session, &mut source, "2026-08-28T10:00:04Z").await,
        PumpAction::Reconcile,
        "reconnect must reconcile first"
    );
    assert_eq!(session.phase, Phase::Reconciling);
    // While the sweep is owed, pumping reads NOTHING from the socket: the frames
    // stay in the stream and the session applies nothing.
    for _ in 0..8 {
        assert_eq!(
            pump(&mut session, &mut source, "2026-08-28T10:00:05Z").await,
            PumpAction::Reconcile
        );
    }
    assert!(
        session.take_dirty().is_empty(),
        "nothing may be applied while the sweep is owed"
    );
    assert_eq!(
        source.events.lock().unwrap().len(),
        2,
        "the socket must not even be read before the gap is closed"
    );
    assert!(
        session.buffered.is_empty(),
        "nothing was read, so nothing was buffered"
    );

    // The caller's sweep is the SSE-triggered one, which is never throttled
    // (proven in `a_sse_reconnect_is_never_throttled`).
    assert_eq!(ReconcileTrigger::SseReconnected.as_str(), "sse_reconnected");

    session.reconcile_done();
    assert_eq!(session.phase, Phase::Connected);
    // Only now does the client resume consuming.
    let mut consumed = 0;
    for _ in 0..8 {
        match pump(&mut session, &mut source, "2026-08-28T10:00:06Z").await {
            PumpAction::Applied => consumed += 1,
            other => panic!("expected to consume after the sweep, got {other:?}"),
        }
        if consumed == 2 {
            break;
        }
    }
    assert_eq!(
        consumed, 2,
        "both frames must be readable once the sweep ran"
    );
    let after = session.take_dirty();
    assert_eq!(
        after.books.len(),
        2,
        "the post-reconnect frames still have to be honoured"
    );
    assert!(!session.reconcile_required);
}

/// A caller that does read while the sweep is owed must not lose those frames
/// either: they are held, then folded into the dirty set.
#[test]
fn events_read_during_a_sweep_are_held_then_applied() {
    let mut session = SseSession::new();
    session.note_disconnected("2026-08-28T10:00:00Z", true);
    session.note_connected("2026-08-28T10:00:02Z");
    assert_eq!(session.phase, Phase::Reconciling);
    for book in ["b1", "b2"] {
        session.note_event(&event("BookChanged", &format!(r#"{{"bookId":"{book}"}}"#)));
    }
    assert!(
        session.take_dirty().is_empty(),
        "held back while the sweep is owed"
    );
    assert_eq!(session.buffered.len(), 2, "buffered, not dropped");
    session.reconcile_done();
    assert_eq!(session.take_dirty().books.len(), 2);
}

/// A reconnect owes a sweep *now*; a launch trigger must still wait out the
/// throttle window, or a flapping network would hammer the server.
#[test]
fn a_sse_reconnect_is_never_throttled() {
    use chrono::{TimeZone, Utc};
    use komga_core::store::{open_in_memory, sync_state};
    use komga_core::sync::reconcile::{should_reconcile, MIN_RECONCILE_INTERVAL_SECS};

    let conn = open_in_memory().unwrap();
    let just_now = Utc.with_ymd_and_hms(2026, 8, 28, 10, 0, 0).unwrap();
    conn.execute(
        "INSERT INTO sync_state (server_id, entity_type, last_sync_at, sync_status)
         VALUES ('A','full',?,'idle')",
        [just_now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)],
    )
    .unwrap();
    assert_eq!(
        sync_state::last_synced_at(&conn, "A").unwrap().as_deref(),
        Some("2026-08-28T10:00:00Z"),
        "the stamp we seeded is the one the throttle reads"
    );

    let one_second_later = just_now + chrono::Duration::seconds(1);
    assert!(
        !should_reconcile(&conn, "A", ReconcileTrigger::AppLaunch, one_second_later).unwrap(),
        "a background launch inside the window waits"
    );
    assert!(
        should_reconcile(
            &conn,
            "A",
            ReconcileTrigger::SseReconnected,
            one_second_later
        )
        .unwrap(),
        "an SSE reconnect never waits"
    );
    assert!(
        should_reconcile(
            &conn,
            "A",
            ReconcileTrigger::NetworkRecovered,
            one_second_later
        )
        .unwrap(),
        "connectivity recovery is likewise immediate"
    );
    // Outside the window even a launch trigger runs.
    assert!(should_reconcile(
        &conn,
        "A",
        ReconcileTrigger::AppLaunch,
        just_now + chrono::Duration::seconds(MIN_RECONCILE_INTERVAL_SECS)
    )
    .unwrap());
}

#[tokio::test]
async fn a_missing_route_parks_in_reconcile_only_without_a_retry_storm() {
    let mut session = SseSession::new();
    let mut source = FakeSource::default();
    source
        .opens
        .lock()
        .unwrap()
        .push(Some(ApiError::ApiCompatibility {
            message: "/sse/v1/events answered with application/json".into(),
        }));
    assert_eq!(
        pump(&mut session, &mut source, "2026-08-28T10:00:00Z").await,
        PumpAction::ReconcileOnly
    );
    assert_eq!(session.phase, Phase::ReconcileOnly);
    assert_eq!(source.resumes().len(), 1);
    // Months later it still does not dial the server.
    assert_eq!(
        pump(&mut session, &mut source, "2026-12-01T00:00:00Z").await,
        PumpAction::Idle
    );
    assert_eq!(source.resumes().len(), 1, "no retry storm");
    assert!(session.reason.is_some(), "the UI needs to say why");
}

#[test]
fn the_server_retry_field_only_raises_the_floor() {
    let mut session = SseSession::new();
    session.note_connected("2026-08-28T10:00:00Z");
    // Komga 1.26.3 never sends retry:, but honour it if a later version starts.
    let mut with_retry = event("BookChanged", r#"{"bookId":"b1"}"#);
    with_retry.retry_ms = Some(20_000);
    session.note_event(&with_retry);
    session.note_disconnected("2026-08-28T10:00:10Z", true);
    assert_eq!(
        session.next_attempt_at.as_deref(),
        Some("2026-08-28T10:00:30Z"),
        "a 20s floor beats the 2s base"
    );
    session.note_connected("2026-08-28T10:00:30Z");
    session.note_disconnected("2026-08-28T10:00:31Z", true);
    assert_eq!(
        session.attempts, 1,
        "a successful connect resets the ladder — which is why the floor matters"
    );
    assert_eq!(
        session.next_attempt_at.as_deref(),
        Some("2026-08-28T10:00:51Z"),
        "backoff(1) = 2s is still under the floor"
    );
}

#[test]
fn backgrounding_stops_it_and_foreground_retries_immediately() {
    let mut session = SseSession::new();
    session.note_connected("2026-08-28T10:00:00Z");
    // App goes to the background: drop the socket without a penalty.
    session.note_disconnected("2026-08-28T10:05:00Z", false);
    assert_eq!(session.attempts, 0);
    assert_eq!(session.next_attempt_at, None);
    assert!(
        session.reconcile_required,
        "the background window hid events"
    );
    assert!(session.due("2026-08-28T10:05:01Z"));
    // Coming back to the foreground reschedules an immediate attempt.
    session.resume("2026-08-28T12:00:00Z");
    assert!(session.due("2026-08-28T12:00:00Z"));
    assert_eq!(session.retry_in_seconds("2026-08-28T12:00:00Z"), Some(0));
}

#[tokio::test]
async fn a_resume_token_is_offered_back_even_though_komga_never_issues_one() {
    let mut session = SseSession::new();
    let mut source = FakeSource::default();
    source.allow_opens(2);
    pump(&mut session, &mut source, "2026-08-28T10:00:00Z").await;
    let mut id_event = event("BookChanged", r#"{"bookId":"b1"}"#);
    id_event.id = Some("42".to_string());
    source.queue(vec![id_event]);
    pump(&mut session, &mut source, "2026-08-28T10:00:01Z").await;
    assert_eq!(session.last_event_id.as_deref(), Some("42"));
    // The stream breaks; the reconnect carries the token.
    pump(&mut session, &mut source, "2026-08-28T10:00:02Z").await;
    assert_eq!(
        pump(&mut session, &mut source, "2026-08-28T10:00:04Z").await,
        PumpAction::Reconcile
    );
    assert_eq!(
        source.resumes(),
        vec![None, Some("42".to_string())],
        "the token is replayed if the server ever sends one"
    );
    // ...and the sweep is still owed, because a server that emits no ids cannot
    // be assumed to have replayed anything.
    assert_eq!(session.phase, Phase::Reconciling);
}

/// Bridge to the free function so the tests above read as `pump(...)`.
async fn pump<S: EventSource + Sync>(
    session: &mut SseSession,
    source: &mut S,
    now: &str,
) -> PumpAction {
    komga_core::sync::sse::pump(session, source, now).await
}
