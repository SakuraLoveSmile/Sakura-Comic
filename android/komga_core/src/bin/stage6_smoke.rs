//! stage6_smoke — SSE + Mutation Outbox acceptance over real loopback HTTP.
//!
//! Runs in phases so the driving script can create the exact conditions the
//! stage's acceptance criterion names, including a real `kill -9`:
//!
//!   --phase offline    阅读 / 修改状态 while the server is unreachable, then
//!                      park. The script SIGKILLs this process ( 杀掉 App ).
//!   --phase restart    a fresh process reopens the same SQLite file
//!                      ( 重新启动 ), asserts the queue came back, and uploads
//!                      against the now-live server ( 恢复网络 → 自动上传 ).
//!   --phase fault      drive retry/backoff/failed/auth through injected faults.
//!   --phase sse        consume the fixture's event stream, lose it, reconnect,
//!                      and prove a reconnect reconciles before events apply.
//!   --phase gone       the server confirmed a book is gone: release the row.
//!
//! Every check is an assertion that panics, so the script's evidence is this
//! binary's exit code plus the `ok:` lines it prints.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::{env, fs, thread};

use chrono::{DateTime, Utc};
use komga_core::api::auth::AuthMethod;
use komga_core::api::error::{ApiError, Result as ApiResult};
use komga_core::api::series::KomgaClient;
use komga_core::api::sse::{SseClient, SseEvent, SseStream};
use komga_core::store::{self, outbox, read_progress};
use komga_core::sync::sse::{EventSource, Phase, PumpAction, SseSession};
use komga_core::sync::upload::{self, RunStatus};
use rusqlite::Connection;

#[derive(Default)]
struct Args {
    db: String,
    base_url: String,
    offline_url: String,
    key: String,
    phase: String,
    journal: String,
    fault: String,
}

/// Drive one async core call to completion from this synchronous binary.
///
/// One shared multi-thread runtime, not a fresh one per call: an SSE response
/// owns a connection driver task, so a runtime that goes away between two reads
/// leaves the stream dead even though `connect` succeeded.
fn block_on<F: std::future::Future>(future: F) -> F::Output {
    static RT: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .expect("runtime")
    })
    .block_on(future)
}

type Smoke = std::result::Result<(), Box<dyn std::error::Error>>;

fn main() {
    let args = parse();
    let outcome: Smoke = match args.phase.as_str() {
        "offline" => phase_offline(&args),
        "restart" => phase_restart(&args),
        "fault" => phase_fault(&args),
        "sse" => phase_sse(&args),
        "gone" => phase_gone(&args),
        other => panic!("unknown --phase {other}"),
    };
    match outcome {
        Ok(()) => println!("ok: phase {} passed", args.phase),
        Err(error) => panic!("phase {} failed: {error}", args.phase),
    }
}

fn parse() -> Args {
    let argv: Vec<String> = env::args().collect();
    let mut args = Args::default();
    let mut i = 1;
    while i + 1 < argv.len() {
        match argv[i].as_str() {
            "--db" => args.db = argv[i + 1].clone(),
            "--base-url" => args.base_url = argv[i + 1].clone(),
            "--offline-url" => args.offline_url = argv[i + 1].clone(),
            "--key" => args.key = argv[i + 1].clone(),
            "--phase" => args.phase = argv[i + 1].clone(),
            "--journal" => args.journal = argv[i + 1].clone(),
            "--fault" => args.fault = argv[i + 1].clone(),
            other => panic!("unknown arg {other}"),
        }
        i += 2;
    }
    assert!(!args.db.is_empty(), "--db is required");
    assert!(!args.key.is_empty(), "--key is required");
    args
}

fn open(args: &Args) -> Connection {
    store::open(&args.db).expect("open store")
}

fn client(url: &str, key: &str) -> KomgaClient {
    KomgaClient::new(
        url.to_string(),
        AuthMethod::ApiKey {
            key: key.to_string(),
        },
    )
    .expect("client")
}

fn now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn stamp(text: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(text)
        .expect("rfc3339")
        .with_timezone(&Utc)
}

/// 断网 → 阅读 / 修改状态. Then park: the script kills us.
fn phase_offline(args: &Args) -> Smoke {
    let conn = open(args);
    read_progress::upsert_local_read_progress(&conn, "A", "book-1-1", 30, false)?;
    read_progress::mark_read(&conn, "A", "book-1-2")?;
    read_progress::mark_unread(&conn, "A", "book-1-3")?;
    let queued = outbox::counts(&conn, "A", &now())?.total();
    assert_eq!(queued, 3, "three user actions must be queued");

    // 断网: point at a port nothing listens on. The uploader must defer, not drop.
    let writer = client(&args.offline_url, &args.key);
    let summary = poll(&conn, "A", &writer)?;
    assert_eq!(summary.retried, 3, "every row defers while offline");
    assert_eq!(summary.uploaded, 0);
    assert_eq!(
        outbox::counts(&conn, "A", &now())?.total(),
        3,
        "an offline window must not consume the queue"
    );
    println!("ok: queued {queued} actions survived an offline upload pass");
    // Park so the script can SIGKILL us: nothing above is in memory-only state.
    println!("ready-to-kill");
    thread::sleep(std::time::Duration::from_secs(30));
    Ok(())
}

/// 重新启动 (fresh process, same file) → 恢复网络 → 自动上传.
fn phase_restart(args: &Args) -> Smoke {
    let conn = open(args);
    let mut restored = outbox::all_entries(&conn, "A")?;
    assert_eq!(
        restored.len(),
        3,
        "restart recovery: the queue must come back from SQLite"
    );
    restored.sort_by(|a, b| a.entity_id.cmp(&b.entity_id));
    for entry in &restored {
        assert_eq!(
            entry.retry_count, 1,
            "the offline attempt is charged, not reset by the restart"
        );
        assert!(
            entry.next_retry_at.is_some(),
            "its backoff deadline is on disk"
        );
    }
    fs::remove_file(&args.journal).ok();

    let writer = client(&args.base_url, &args.key);
    // Outrun the recorded deadline rather than sleeping through it.
    let later = (stamp(restored[0].next_retry_at.as_deref().unwrap())
        + chrono::Duration::seconds(60))
    .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let summary = poll_at(&conn, "A", &writer, &later)?;
    assert_eq!(summary.uploaded, 3, "summary: {summary:?}");
    assert_eq!(summary.status, RunStatus::Complete);
    assert_eq!(
        outbox::counts(&conn, "A", &later)?.total(),
        0,
        "成功后清理 Outbox"
    );
    for book in ["book-1-1", "book-1-2", "book-1-3"] {
        let (pending, stamp): (i64, Option<String>) = conn.query_row(
            "SELECT mutation_pending, server_updated_at FROM read_progress
             WHERE server_id = 'A' AND book_id = ?1",
            [book],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        assert_eq!(pending, 0, "{book} must stop blocking sweeps");
        assert_eq!(stamp, None, "204 has no body: no stamp may be invented");
    }

    // The server's own record is the evidence, not our own summary.
    let journal = fs::read_to_string(&args.journal).expect("journal written");
    let lines: Vec<&str> = journal.lines().collect();
    assert_eq!(lines.len(), 3, "journal: {journal}");
    assert!(
        lines
            .iter()
            .any(|line| line.contains("\"method\":\"PATCH\"")
                && line.contains("book-1-1")
                && line.contains(r#"page\":30"#)),
        "the page the user reached must arrive verbatim: {journal}"
    );
    assert!(
        lines
            .iter()
            .any(|line| line.contains("book-1-2") && line.contains(r#""completed\":true"#)),
        "mark-read must arrive as completed=true: {journal}"
    );
    assert!(
        lines
            .iter()
            .any(|line| line.contains("\"method\":\"DELETE\"") && line.contains("book-1-3")),
        "mark-unread must be a DELETE: {journal}"
    );
    println!("ok: 3 queued actions uploaded after a kill + restart");
    Ok(())
}

/// Retry / backoff / failed / authentication, all through injected HTTP faults.
fn phase_fault(args: &Args) -> Smoke {
    let conn = open(args);
    read_progress::upsert_local_read_progress(&conn, "A", "book-1-1", 7, false)?;
    let writer = client(&args.base_url, &args.key);
    let mut seen_deadlines = Vec::new();
    let mut now = now();
    // 503 on every attempt: the row must climb the backoff ladder and give up.
    set_fault(args, "503");
    for attempt in 1..=outbox::MAX_ATTEMPTS {
        let summary = poll_at(&conn, "A", &writer, &now)?;
        assert_eq!(summary.retried, 1, "attempt {attempt} must be retryable");
        let entry = outbox::queued_for_book(&conn, "A", "book-1-1")?.expect("still queued");
        assert_eq!(entry.retry_count, attempt);
        if attempt < outbox::MAX_ATTEMPTS {
            let deadline = entry.next_retry_at.clone().expect("scheduled");
            let gap = stamp(&deadline)
                .signed_duration_since(stamp(&now))
                .num_seconds();
            assert_eq!(
                gap,
                outbox::backoff_seconds(attempt),
                "attempt {attempt} must wait exactly the shared schedule"
            );
            if seen_deadlines.last() == Some(&deadline) {
                panic!("backoff stopped growing at attempt {attempt}");
            }
            seen_deadlines.push(deadline.clone());
            now = deadline;
        } else {
            assert_eq!(entry.state, outbox::STATE_FAILED, "must give up at the cap");
            assert_eq!(entry.next_retry_at, None);
        }
    }
    // A failed row must stop touching the server entirely.
    let summary = poll_at(&conn, "A", &writer, &now)?;
    assert_eq!(
        summary.considered, 0,
        "a failed row may not retry on its own"
    );

    // 400 is not retryable: it goes straight to failed, no attempts burned.
    read_progress::upsert_local_read_progress(&conn, "A", "book-1-2", 3, false)?;
    set_fault(args, "400");
    let summary = poll_at(&conn, "A", &writer, &now)?;
    assert_eq!(summary.rejected, 1);
    let entry = outbox::queued_for_book(&conn, "A", "book-1-2")?.expect("kept for the UI");
    assert_eq!(entry.state, outbox::STATE_FAILED);
    assert_eq!(
        entry.retry_count, 0,
        "a rejection must not look like a retry"
    );

    // 401 stops the run and penalises nobody.
    read_progress::mark_read(&conn, "A", "book-1-3")?;
    set_fault(args, "401");
    let summary = poll_at(&conn, "A", &writer, &now)?;
    assert_eq!(summary.status, RunStatus::BlockedAuthentication);
    assert_eq!(summary.uploaded, 0);
    let entry = outbox::queued_for_book(&conn, "A", "book-1-3")?.expect("still queued");
    assert_eq!(
        entry.retry_count, 0,
        "a credential problem is not the user's fault"
    );
    assert_eq!(entry.state, outbox::STATE_PENDING);
    set_fault(args, "off");
    println!(
        "ok: backoff ladder {:?} then failed; 400 and 401 classified differently",
        seen_deadlines.len()
    );
    Ok(())
}

/// The server confirmed a book is gone: the queued action is released. This is
/// the only place a `pending_mutations` row may be dropped without a 204.
fn phase_gone(args: &Args) -> Smoke {
    let conn = open(args);
    read_progress::upsert_local_read_progress(&conn, "A", "book-does-not-exist", 9, false)?;
    let writer = client(&args.base_url, &args.key);
    let summary = poll_at(&conn, "A", &writer, &now())?;
    assert_eq!(summary.gone, 1, "summary: {summary:?}");
    assert_eq!(summary.uploaded, 0, "a gone book must not be written to");
    assert!(outbox::queued_for_book(&conn, "A", "book-does-not-exist")?.is_none());
    println!("ok: a server-confirmed deletion released its queued action");
    Ok(())
}

/// Event stream: connect, consume, lose it, reconnect, and prove the ordering.
fn phase_sse(args: &Args) -> Smoke {
    let mut session = SseSession::new();
    let mut source = LiveSource::new(&args.base_url, &args.key);

    // 1. connect
    let action = pump(&mut session, &mut source, &now());
    assert_eq!(action, PumpAction::Applied, "first connect owes no sweep");
    assert_eq!(session.phase, Phase::Connected);

    // 2. consume until the fixture closes the stream
    let mut kinds = Vec::new();
    let mut hints = 0usize;
    for _ in 0..64 {
        let action = pump(&mut session, &mut source, &now());
        match action {
            PumpAction::Applied => {
                if let Some(kind) = source.last_kind() {
                    kinds.push(kind);
                }
                let dirty = session.take_dirty();
                hints += dirty.hint_count();
            }
            PumpAction::BackingOff => break,
            other => panic!("unexpected action while streaming: {other:?}"),
        }
    }
    assert!(
        kinds.iter().any(|kind| kind == "BookChanged"),
        "the fixture's events must arrive: {kinds:?}"
    );
    assert!(
        !kinds.iter().any(|kind| kind == "Heartbeat"),
        "a comment frame must never become an event"
    );
    assert!(
        !kinds.contains(&"HalfFrame".to_string()),
        "the trailing half frame must NOT be dispatched: {kinds:?}"
    );
    assert!(hints > 0, "events must produce hints");
    // The fixture closed the stream after its frames, which is the "break"
    // every client eventually sees: one charged attempt, a deadline scheduled.
    assert_eq!(
        session.attempts, 1,
        "the lost stream is what owes the sweep"
    );

    // 3. losing the stream owes a sweep before anything is trusted again
    assert!(
        session.reconcile_required,
        "a gap can never be assumed empty"
    );
    let scheduled = session.next_attempt_at.clone().expect("backoff scheduled");
    assert!(
        !session.due(&now()),
        "reconnecting immediately is a retry storm"
    );
    let frames_before = source.frames_read();
    // 4. reconnect after the schedule (the fixture's second connection replays
    // the same frames, one of them buffered while we sweep)
    thread::sleep(std::time::Duration::from_millis(
        (stamp(&scheduled) - Utc::now()).num_milliseconds().max(0) as u64 + 50,
    ));
    let action = pump(&mut session, &mut source, &now());
    assert_eq!(
        action,
        PumpAction::Reconcile,
        "a reconnect must reconcile before consuming"
    );
    assert_eq!(session.phase, Phase::Reconciling);
    // While the sweep is owed, pumping reads NOTHING and applies nothing.
    for _ in 0..32 {
        assert_eq!(
            pump(&mut session, &mut source, &now()),
            PumpAction::Reconcile
        );
    }
    assert!(
        session.take_dirty().is_empty() && source.frames_read() == frames_before,
        "no event may be read or applied while the sweep is owed"
    );
    session.reconcile_done();
    assert_eq!(session.phase, Phase::Connected);
    // Only now does the client resume consuming.
    let mut consumed = 0;
    for _ in 0..64 {
        match pump(&mut session, &mut source, &now()) {
            PumpAction::Applied => consumed += 1,
            PumpAction::BackingOff => break,
            other => panic!("unexpected action after the sweep: {other:?}"),
        }
    }
    assert!(
        consumed > 0,
        "the stream must be consumable again after reconciling"
    );
    let after = session.take_dirty();
    assert!(
        !after.is_empty(),
        "events consumed after the sweep must still produce hints"
    );
    println!(
        "ok: {} events parsed, {} hints coalesced, reconnect reconciled before consuming",
        kinds.len(),
        hints + after.hint_count()
    );
    Ok(())
}

/// `pump` is async; this binary has no runtime of its own beyond what the
/// client needs, so drive it with a current-thread runtime.
fn pump(session: &mut SseSession, source: &mut LiveSource, now: &str) -> PumpAction {
    block_on(komga_core::sync::sse::pump(session, source, now))
}

fn poll(
    conn: &Connection,
    server_id: &str,
    writer: &KomgaClient,
) -> rusqlite::Result<upload::UploadSummary> {
    block_on(upload::upload_outbox(conn, server_id, writer, &now()))
}

fn poll_at(
    conn: &Connection,
    server_id: &str,
    writer: &KomgaClient,
    now: &str,
) -> rusqlite::Result<upload::UploadSummary> {
    block_on(upload::upload_outbox(conn, server_id, writer, now))
}

fn set_fault(args: &Args, value: &str) {
    assert!(!args.fault.is_empty(), "--fault is required by this phase");
    fs::write(&args.fault, value).expect("fault file writable");
}

/// The real socket behind the injectable `EventSource` seam.
struct LiveSource {
    client: SseClient,
    stream: Option<SseStream>,
    last: Mutex<VecDeque<String>>,
}

impl LiveSource {
    fn new(base_url: &str, key: &str) -> Self {
        Self {
            client: SseClient::new(
                base_url.to_string(),
                AuthMethod::ApiKey {
                    key: key.to_string(),
                },
            )
            .expect("sse client"),
            stream: None,
            last: Mutex::new(VecDeque::new()),
        }
    }

    fn frames_read(&self) -> usize {
        self.last.lock().unwrap().len()
    }

    fn last_kind(&self) -> Option<String> {
        self.last.lock().unwrap().back().cloned()
    }
}

impl EventSource for LiveSource {
    async fn open(&mut self, last_event_id: Option<&str>) -> ApiResult<()> {
        self.stream = Some(self.client.connect(last_event_id).await?);
        Ok(())
    }

    async fn next(&mut self) -> ApiResult<Option<SseEvent>> {
        let Some(stream) = self.stream.as_mut() else {
            return Err(ApiError::Network);
        };
        match stream.next_event().await {
            Ok(Some(event)) => {
                self.last.lock().unwrap().push_back(event.kind.clone());
                Ok(Some(event))
            }
            Ok(None) => Err(ApiError::Network),
            Err(error) => Err(error),
        }
    }

    fn close(&mut self) {
        self.stream = None;
    }
}
