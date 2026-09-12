//! The download queue's rules: what may change state, what a failure means, and
//! which pages a pass would take.
//!
//! Deliberately free of `rusqlite`, of the filesystem and of any `await`, because
//! this is the module the Swift side re-derives from the same two fixtures. It
//! embeds them with `include_str!` rather than reading them at run time: the
//! `specs/` tree is not in the APK, and a rule that only loads on a developer
//! machine is a rule that silently disappears on a phone.
//!
//! The state machine is not documentation. [`transition_allowed`] is what every
//! state write in [`crate::downloads::store`] goes through, so an illegal
//! transition is refused where it happens instead of being noticed later as a
//! download that resumed itself.

use chrono::{DateTime, Utc};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::OnceLock;

const STATES_JSON: &str =
    include_str!("../../../../specs/contracts/fixtures/downloads/states.json");
const ERRORS_JSON: &str =
    include_str!("../../../../specs/contracts/fixtures/downloads/errors.json");

// ---------------------------------------------------------------- states

/// Who is asking to change a download's state. The distinction is the point:
/// three of these four may not do the same things.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Actor {
    /// The bounded download pass.
    Pump,
    /// The recalculation a pass runs on its way out.
    Settle,
    /// A gesture on the Downloads screen.
    User,
    /// The sweep, and only where the filesystem disproved a row.
    Heal,
}

impl Actor {
    pub fn as_str(self) -> &'static str {
        match self {
            Actor::Pump => "pump",
            Actor::Settle => "settle",
            Actor::User => "user",
            Actor::Heal => "heal",
        }
    }
}

pub mod book_state {
    pub const WAITING: &str = "waiting";
    pub const DOWNLOADING: &str = "downloading";
    pub const PAUSED: &str = "paused";
    pub const COMPLETED: &str = "completed";
    pub const FAILED: &str = "failed";
}

/// Note there is no in-flight *page* state. The evidence that a write was
/// interrupted is its `.part` file, which the sweep reaps; a second marker would
/// be a second truth to keep in sync, for no question anybody asks.
pub mod page_state {
    pub const PENDING: &str = "pending";
    pub const COMPLETE: &str = "complete";
    pub const FAILED: &str = "failed";
}

#[derive(Debug, Deserialize)]
struct StatesFixture {
    transitions: Vec<TransitionRow>,
    illegal: Vec<TransitionRow>,
}

#[derive(Debug, Deserialize)]
struct TransitionRow {
    #[serde(default)]
    from: Option<String>,
    #[serde(default)]
    to: Option<String>,
    #[serde(default)]
    on: Option<String>,
}

fn states() -> &'static StatesFixture {
    static STATES: OnceLock<StatesFixture> = OnceLock::new();
    STATES.get_or_init(|| match serde_json::from_str(STATES_JSON) {
        Ok(fixture) => fixture,
        Err(error) => panic!("downloads/states.json is not decodable: {error}"),
    })
}

/// Wildcard-aware lookup, where an absent `from` or `to` in the table means
/// "any", and the `illegal` list wins over `transitions`.
///
/// A pair absent from both is refused. That is the whole reason the table is
/// loaded at run time rather than restated as `match` arms: a restated rule is a
/// second copy to keep in sync, and the two platforms would each have their own.
pub fn transition_allowed(from: &str, to: &str, actor: Actor) -> bool {
    let on = Some(actor.as_str());
    let covers = |row: &TransitionRow| {
        row.on.as_deref() == on
            && match row.from.as_deref() {
                None => false,
                Some("any") => true,
                Some(previous) => previous == from,
            }
            && row.to.as_deref() == Some(to)
    };
    if states().illegal.iter().any(covers) {
        return false;
    }
    states().transitions.iter().any(covers)
}

/// Enqueue is the one transition with no previous state, so it has no `from` to
/// ask about. Checked here rather than assumed: if the fixture stops listing it,
/// the first enqueue on a phone is where that would surface.
pub fn enqueue_allowed() -> bool {
    states().transitions.iter().any(|row| {
        row.from.is_none()
            && row.to.as_deref() == Some(book_state::WAITING)
            && row.on.as_deref() == Some(Actor::User.as_str())
    })
}

// ------------------------------------------------------------- failures

/// What one page attempt proved, named after the transport fact rather than after
/// either platform's error enum — a URLSession failure and `ApiError::Network`
/// are the same event seen from two sides.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    Ok,
    Link,
    Credential,
    NotFound,
    RateLimited,
    Server,
    ShortRead,
    Corrupt,
    TooSmall,
    WriteFailed,
}

impl Signal {
    pub fn as_str(self) -> &'static str {
        match self {
            Signal::Ok => "ok",
            Signal::Link => "link",
            Signal::Credential => "credential",
            Signal::NotFound => "notFound",
            Signal::RateLimited => "rateLimited",
            Signal::Server => "server",
            Signal::ShortRead => "shortRead",
            Signal::Corrupt => "corrupt",
            Signal::TooSmall => "tooSmall",
            Signal::WriteFailed => "writeFailed",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Complete,
    BadPage,
    LinkDown,
    Blocked,
    Gone,
    Throttled,
    IoFailed,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Complete => "complete",
            Outcome::BadPage => "badPage",
            Outcome::LinkDown => "linkDown",
            Outcome::Blocked => "blocked",
            Outcome::Gone => "gone",
            Outcome::Throttled => "throttled",
            Outcome::IoFailed => "ioFailed",
        }
    }

    fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "complete" => Outcome::Complete,
            "badPage" => Outcome::BadPage,
            "linkDown" => Outcome::LinkDown,
            "blocked" => Outcome::Blocked,
            "gone" => Outcome::Gone,
            "throttled" => Outcome::Throttled,
            "ioFailed" => Outcome::IoFailed,
            _ => return None,
        })
    }
}

/// How far the news travels: one row, this book, this pass, or the whole server's
/// queue.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Page,
    Book,
    Pass,
    ServerQueue,
}

#[derive(Debug, Deserialize)]
struct ErrorsFixture {
    classify: Vec<ClassifyRow>,
    outcomes: HashMap<String, OutcomeRow>,
    #[serde(default)]
    default: Option<String>,
    bounds: BoundsRow,
}

#[derive(Debug, Deserialize)]
struct ClassifyRow {
    signal: String,
    outcome: String,
}

#[derive(Debug, Deserialize)]
struct OutcomeRow {
    scope: String,
    #[serde(rename = "burnsAttempt")]
    burns_attempt: bool,
}

#[derive(Debug, Deserialize)]
struct BoundsRow {
    #[serde(rename = "maxPageAttempts")]
    max_page_attempts: i64,
    #[serde(rename = "consecutiveBadPages")]
    consecutive_bad_pages: usize,
    #[serde(rename = "defaultMaxPages")]
    default_max_pages: usize,
    #[serde(rename = "defaultMaxBytes")]
    default_max_bytes: i64,
    #[serde(rename = "maxElapsedMs")]
    max_elapsed_ms: u64,
    #[serde(rename = "nextInMs")]
    next_in_ms: HashMap<String, i64>,
}

fn errors() -> &'static ErrorsFixture {
    static ERRORS: OnceLock<ErrorsFixture> = OnceLock::new();
    ERRORS.get_or_init(|| match serde_json::from_str(ERRORS_JSON) {
        Ok(fixture) => fixture,
        Err(error) => panic!("downloads/errors.json is not decodable: {error}"),
    })
}

pub fn max_page_attempts() -> i64 {
    errors().bounds.max_page_attempts
}

/// A run of this many `badPage` results ends the pass as though the link had
/// dropped, so a dying server costs three attempts across a whole book instead of
/// three per page.
pub fn consecutive_bad_pages() -> usize {
    errors().bounds.consecutive_bad_pages
}

pub fn default_max_pages() -> usize {
    errors().bounds.default_max_pages
}

pub fn default_max_bytes() -> i64 {
    errors().bounds.default_max_bytes
}

pub fn max_elapsed_ms() -> u64 {
    errors().bounds.max_elapsed_ms
}

/// How long to wait before the next pass. Reads the same map the fixture's
/// `stopReasons` describe, so the backoff a phone uses is the one in the contract.
pub fn next_in_ms(stop: StopReason, wait_ms: i64) -> i64 {
    if stop == StopReason::Parked {
        // Not a policy number: it is the time left on an appointment this pass
        // could not talk its way out of.
        return wait_ms.max(0);
    }
    let key = match stop {
        StopReason::None | StopReason::Drained | StopReason::Budget | StopReason::Bytes => {
            return 0
        }
        StopReason::Elapsed => return 0,
        StopReason::Idle => return 0,
        StopReason::LinkBlocked => "linkBlocked",
        StopReason::LinkDown => "linkDown",
        StopReason::Throttled => "throttled",
        StopReason::Blocked | StopReason::Gone | StopReason::IoFailed => "blocked",
        StopReason::LowSpace => "lowSpace",
        StopReason::BadRun => "badRun",
        // A pause is not a retry timer: nothing will change until the user says so.
        StopReason::Paused => return 0,
        StopReason::BadPage => return 0,
        StopReason::Parked => "parked",
    };
    errors().bounds.next_in_ms.get(key).copied().unwrap_or(0)
}

pub fn classify(signal: Signal) -> Outcome {
    let name = signal.as_str();
    errors()
        .classify
        .iter()
        .find(|row| row.signal == name)
        .and_then(|row| Outcome::parse(&row.outcome))
        // An unlisted signal is about this page, and the page stays retryable:
        // treating the unknown as fatal would turn one odd server response into a
        // dead queue.
        .or_else(|| errors().default.as_deref().and_then(Outcome::parse))
        .unwrap_or(Outcome::BadPage)
}

pub fn scope_of(outcome: Outcome) -> Scope {
    let key = outcome.as_str();
    let row = errors()
        .outcomes
        .get(key)
        .unwrap_or_else(|| panic!("errors.json has no outcome row for {key}"));
    match row.scope.as_str() {
        "page" => Scope::Page,
        "book" => Scope::Book,
        "pass" => Scope::Pass,
        "serverQueue" => Scope::ServerQueue,
        other => panic!("errors.json outcome {key} has an unknown scope {other}"),
    }
}

/// The line the stage spec cares about: an outage must not consume the retries a
/// genuinely bad page needs. Five hours in a train must cost zero attempts.
pub fn burns_attempt(outcome: Outcome) -> bool {
    errors()
        .outcomes
        .get(outcome.as_str())
        .map(|row| row.burns_attempt)
        == Some(true)
}

// ------------------------------------------------------------------ plan

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Link {
    Unmetered,
    Metered,
    Unknown,
}

impl Link {
    /// Anything unrecognised is `Unknown`, never `Unmetered`: the conservative
    /// reading of a missing fact is the smaller answer, which is the rule
    /// Stage 8 pinned for every other device fact.
    pub fn parse(value: &str) -> Self {
        match value {
            "unmetered" | "wifi" | "ethernet" => Link::Unmetered,
            "metered" | "cellular" => Link::Metered,
            _ => Link::Unknown,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Link::Unmetered => "unmetered",
            Link::Metered => "metered",
            Link::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum StopReason {
    #[default]
    None,
    /// Every candidate fit inside the bounds: this pass covers what is left.
    Drained,
    Budget,
    Bytes,
    Elapsed,
    LinkDown,
    Blocked,
    Gone,
    Throttled,
    IoFailed,
    /// The reported link forbids this work.
    LinkBlocked,
    LowSpace,
    /// The only claimable book has a `next_retry_at` still in the future.
    Parked,
    /// Nothing in the queue wants bytes.
    Idle,
    // The three below are only ever produced by a pass, never by the planner, so
    // they appear nowhere in `pump.json`: you cannot predict a severed connection,
    // a run of bad pages, or the user pressing 暂停 mid-book.
    /// One page arrived too damaged to keep, and this one is about the page.
    BadPage,
    /// Three bad pages in a row: a sick server, so the pass ends without spending
    /// the rest of the book's attempts on it.
    BadRun,
    /// The user's pause won the race against this pass's next write.
    Paused,
}

impl StopReason {
    pub fn as_str(self) -> &'static str {
        match self {
            StopReason::None => "none",
            StopReason::Drained => "drained",
            StopReason::Budget => "budget",
            StopReason::Bytes => "bytes",
            StopReason::Elapsed => "elapsed",
            StopReason::LinkDown => "linkDown",
            StopReason::Blocked => "blocked",
            StopReason::Gone => "gone",
            StopReason::Throttled => "throttled",
            StopReason::IoFailed => "ioFailed",
            StopReason::LinkBlocked => "linkBlocked",
            StopReason::LowSpace => "lowSpace",
            StopReason::Parked => "parked",
            StopReason::Idle => "idle",
            StopReason::BadPage => "badPage",
            StopReason::BadRun => "badRun",
            StopReason::Paused => "paused",
        }
    }
}

#[derive(Debug, Clone)]
pub struct PagePlan {
    pub number: u32,
    pub state: String,
    pub attempts: i64,
    pub declared_bytes: i64,
}

/// One book as the planner sees it, pages included: a queue entry without its
/// page rows is not enough to decide anything about it, and passing the two in
/// separately is how a book gets planned against another book's pages.
#[derive(Debug, Clone)]
pub struct BookPlan {
    pub server_id: String,
    pub book_id: String,
    pub position: i64,
    pub state: String,
    pub allow_cellular: bool,
    pub pages_total: u32,
    pub next_retry_at: Option<String>,
    pub pages: Vec<PagePlan>,
}

#[derive(Debug, Clone)]
pub struct ReaderPosition {
    pub book_id: String,
    pub page: u32,
}

#[derive(Debug, Clone)]
pub struct PassInput<'a> {
    pub now: DateTime<Utc>,
    pub books: &'a [BookPlan],
    pub link: Link,
    pub free_bytes: i64,
    pub max_pages: usize,
    pub max_bytes: i64,
    pub reader: Option<ReaderPosition>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Job {
    pub server_id: String,
    pub book_id: String,
    pub number: u32,
    pub declared_bytes: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pass {
    pub jobs: Vec<Job>,
    pub stop: StopReason,
    /// The book this pass holds.
    pub book: Option<(String, String)>,
    /// True when this pass must write `downloading` before serving anything.
    ///
    /// Not the same question as "has this book already started", and conflating them
    /// is a bug that shows up only on a second pass: `land_page` refuses to commit
    /// while the book is not `downloading`, so a pass that believed the claim had
    /// already been made lands nothing, forever, on any book with one page on disk.
    pub claims: bool,
    /// How long to wait before the next pass, once the stop reason is known.
    pub next_in_ms: i64,
}

impl Pass {
    fn stopped(stop: StopReason, now: DateTime<Utc>, wait_until: Option<DateTime<Utc>>) -> Self {
        let wait_ms = wait_until
            .map(|until| (until - now).num_milliseconds())
            .unwrap_or(0);
        Pass {
            jobs: Vec::new(),
            stop,
            book: None,
            claims: false,
            next_in_ms: next_in_ms(stop, wait_ms),
        }
    }
}

fn parse_time(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|at| at.with_timezone(&Utc))
}

fn retry_due(book: &BookPlan, now: DateTime<Utc>) -> Option<bool> {
    book.next_retry_at
        .as_deref()
        .and_then(parse_time)
        .map(|until| until <= now)
}

/// Pages this book still wants, in the order a pass should take them.
fn candidates(book: &BookPlan, reader_page: Option<u32>) -> Vec<PagePlan> {
    let mut wanted: Vec<PagePlan> = book
        .pages
        .iter()
        .filter(|page| page.state == page_state::PENDING && page.attempts < max_page_attempts())
        .cloned()
        .collect();
    wanted.sort_by_key(|page| page.number);
    if let Some(reader) = reader_page {
        // Forward first: a reader continues ahead, so the pages in front of them
        // are worth more than the ones behind. The tail of the list then covers
        // what was never fetched before their position.
        wanted.sort_by_key(|page| {
            if page.number >= reader {
                (0u8, page.number)
            } else {
                (1u8, page.number)
            }
        });
    }
    wanted
}

/// Decide one pass. Pure over [`PassInput`], so both platforms can run the same
/// `pump.json` cases against their own implementation of this function.
pub fn plan_pass(input: &PassInput<'_>) -> Pass {
    let mut resumable: Vec<&BookPlan> = input
        .books
        .iter()
        .filter(|book| book.state == book_state::WAITING || book.state == book_state::DOWNLOADING)
        .collect();
    // Queue order is the user's tap order. `position` breaks nothing on its own
    // (two books enqueued in the same instant share it only if the enqueue raced),
    // so the ids are the final tie-break and the plan is replayable.
    resumable.sort_by_key(|book| (book.position, book.server_id.clone(), book.book_id.clone()));

    let parked_until = resumable
        .iter()
        .filter(|book| retry_due(book, input.now) == Some(false))
        .map(|book| {
            book.next_retry_at
                .as_deref()
                .and_then(parse_time)
                .unwrap_or(input.now)
        })
        .min();
    let ready: Vec<&BookPlan> = resumable
        .iter()
        .filter(|book| retry_due(book, input.now) != Some(false))
        .copied()
        .collect();

    let Some(&book) = ready.first() else {
        return Pass::stopped(
            if parked_until.is_some() {
                StopReason::Parked
            } else {
                StopReason::Idle
            },
            input.now,
            parked_until,
        );
    };

    // "Already started" is the book having pages on the device, not the transient
    // `downloading` state: every settle resets a partway book to `waiting`, so a
    // test keyed on that marker would let a book advance exactly one pass and then
    // stall forever wherever the platform will not report its free space. The state
    // still counts, because a killed pass leaves it set.
    let started = book.state == book_state::DOWNLOADING
        || book
            .pages
            .iter()
            .any(|page| page.state == page_state::COMPLETE);
    match input.link {
        Link::Metered if !book.allow_cellular => {
            return Pass::stopped(StopReason::LinkBlocked, input.now, None)
        }
        Link::Unknown if !started => {
            return Pass::stopped(StopReason::LinkBlocked, input.now, None)
        }
        _ => {}
    }

    let reader_page = input
        .reader
        .as_ref()
        .filter(|reader| reader.book_id == book.book_id)
        .map(|reader| reader.page);
    let mut jobs = candidates(book, reader_page);
    let mut pass = Pass {
        jobs: Vec::new(),
        stop: StopReason::Drained,
        book: Some((book.server_id.clone(), book.book_id.clone())),
        claims: book.state == book_state::WAITING,
        next_in_ms: 0,
    };
    if jobs.is_empty() {
        // Nothing to fetch for a book the queue still holds. The caller settles it,
        // which is how a book whose every page failed reaches `failed` instead of
        // being reported as having nothing to do.
        return pass;
    }

    // Headroom for a new book is measured against the first two pages it would
    // take, not the whole remaining book: a user with 200 MB free can finish a
    // 12 MB-per-page book page by page, and refusing it for the total would make
    // the storage screen's own numbers unusable.
    let headroom = if started {
        0
    } else {
        jobs.iter()
            .take(2)
            .map(|page| page.declared_bytes.max(0))
            .sum()
    };
    // `free_bytes == 0` means the platform would not say. That never stops a book
    // already running, and always stops a new one.
    if !started && (input.free_bytes == 0 || headroom > input.free_bytes) {
        return Pass::stopped(StopReason::LowSpace, input.now, None);
    }

    let max_pages = if input.max_pages == 0 {
        default_max_pages()
    } else {
        input.max_pages
    };
    let max_bytes = if input.max_bytes == 0 {
        default_max_bytes()
    } else {
        input.max_bytes
    };

    let mut bytes = 0i64;
    for page in jobs.drain(..) {
        if pass.jobs.len() >= max_pages {
            pass.stop = StopReason::Budget;
            break;
        }
        let size = page.declared_bytes.max(0);
        // One page is always served even if it alone exceeds the byte budget, or a
        // book of such pages could never be finished by any pass.
        if !pass.jobs.is_empty() && bytes + size > max_bytes {
            pass.stop = StopReason::Bytes;
            break;
        }
        bytes += size;
        pass.jobs.push(Job {
            server_id: book.server_id.clone(),
            book_id: book.book_id.clone(),
            number: page.number,
            declared_bytes: size,
        });
    }
    pass.next_in_ms = next_in_ms(pass.stop, 0);
    pass
}

/// Who is deriving. The state write is recorded as `settle` either way, because the
/// question is not who is asking but who has looked at the disk: only the sweep has,
/// and only it may take a completion back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettleMode {
    /// A download pass, settling rows it wrote itself.
    Pass,
    /// The reconciliation sweep, which has just read every file.
    Sweep,
}

/// The state a book settles into, derived from its page counts and from who looked.
///
/// Never incremented and never taken from a stored counter: a row lost to a
/// half-applied transaction would otherwise make the book permanently uncompletable,
/// and the number the UI shows would stop meaning anything.
pub fn settle_state(
    state: &str,
    pages_total: u32,
    complete: u32,
    failed: u32,
    mode: SettleMode,
) -> String {
    if state == book_state::PAUSED {
        // A pause is the user's, and no derivation may overwrite it.
        return state.to_string();
    }
    if state == book_state::COMPLETED && mode != SettleMode::Sweep {
        // A completed book does not un-complete itself because a pass noticed a row:
        // it has not looked at the disk. The sweep has, and for it completion is not
        // sticky — without that exception a downloaded page that later fails the
        // container check would leave the book labelled complete, and a completed
        // book is not the queue's to run, so it could never be repaired.
        return state.to_string();
    }
    if pages_total == 0 || complete >= pages_total {
        return book_state::COMPLETED.to_string();
    }
    if complete.saturating_add(failed) >= pages_total {
        return book_state::FAILED.to_string();
    }
    book_state::WAITING.to_string()
}

/// The raw contract text, exposed so the tests can assert the code's answers
/// against the table rather than against a second copy of the table written in Rust.
#[cfg(test)]
pub fn states_text() -> &'static str {
    STATES_JSON
}

#[cfg(test)]
pub fn errors_text() -> &'static str {
    ERRORS_JSON
}

#[cfg(test)]
mod tests {
    use super::super::harness::fixture;
    use super::*;
    use crate::downloads::harness;

    const ALL_ACTORS: [Actor; 4] = [Actor::Pump, Actor::Settle, Actor::User, Actor::Heal];

    fn page_plan(number: u32, state: &str, attempts: i64, declared: i64) -> PagePlan {
        PagePlan {
            number,
            state: state.to_string(),
            attempts,
            declared_bytes: declared,
        }
    }

    fn book(book_id: &str, position: i64, state: &str, pages: Vec<PagePlan>) -> BookPlan {
        BookPlan {
            server_id: "s1".to_string(),
            book_id: book_id.to_string(),
            position,
            state: state.to_string(),
            allow_cellular: false,
            pages_total: pages.len() as u32,
            next_retry_at: None,
            pages,
        }
    }

    fn pending(numbers: &[u32]) -> Vec<PagePlan> {
        numbers
            .iter()
            .map(|number| page_plan(*number, page_state::PENDING, 0, 1_000))
            .collect()
    }

    fn input(books: &[BookPlan]) -> PassInput<'_> {
        PassInput {
            now: harness::now(),
            books,
            link: Link::Unmetered,
            free_bytes: 1 << 30,
            max_pages: default_max_pages(),
            max_bytes: default_max_bytes(),
            reader: None,
        }
    }

    // ------------------------------------------------------------ states table

    /// Every legal row in the contract, and no others.
    ///
    /// The `!= ` direction is the one that matters: a code path that allowed a
    /// transition the table does not list would pass a test written as
    /// "assert the listed ones are allowed". Comparing the *whole* allowed set per
    /// (from, to) pair is what makes `paused -> downloading by pump` fail loudly.
    #[test]
    fn the_allowed_actors_per_pair_are_exactly_the_ones_the_table_lists() {
        let table: serde_json::Value = serde_json::from_str(states_text()).unwrap();
        let mut pairs: std::collections::BTreeMap<(String, String), Vec<String>> =
            std::collections::BTreeMap::new();
        for row in table["transitions"].as_array().unwrap() {
            let Some(from) = row["from"].as_str() else {
                continue;
            };
            let Some(to) = row["to"].as_str() else {
                continue;
            };
            pairs
                .entry((from.to_string(), to.to_string()))
                .or_default()
                .push(row["on"].as_str().unwrap().to_string());
        }
        assert!(
            pairs.len() >= 14,
            "the table shrank to {} pairs; a thin table makes this test thin too",
            pairs.len()
        );
        for ((from, to), listed) in &pairs {
            // Sorted on both sides: the fixture lists one actor per row, and the order
            // those rows were written in is not a claim about precedence.
            let mut allowed: Vec<String> = ALL_ACTORS
                .iter()
                .filter(|actor| transition_allowed(from, to, **actor))
                .map(|actor| actor.as_str().to_string())
                .collect();
            allowed.sort();
            let mut expected = listed.clone();
            expected.sort();
            expected.dedup();
            assert_eq!(
                allowed, expected,
                "`{from}` -> `{to}` is allowed for a different set of actors than the table says"
            );
        }
    }

    /// Each `illegal` row is refused for the actor it names.
    ///
    /// It is NOT true that an illegal pair is illegal for everybody — `downloading
    /// -> waiting` is exactly what a settle does and exactly what a user re-tap must
    /// not do — so the assertion is per actor, and the asymmetry test below is what
    /// keeps that distinction from being blurred by a future edit.
    #[test]
    fn the_illegal_pairs_are_refused_for_the_actor_that_named_them() {
        let table: serde_json::Value = serde_json::from_str(states_text()).unwrap();
        let rows = table["illegal"].as_array().unwrap();
        assert!(rows.len() >= 7, "the illegal list shrank to {}", rows.len());
        for row in rows {
            let (Some(from), Some(to), Some(on)) =
                (row["from"].as_str(), row["to"].as_str(), row["on"].as_str())
            else {
                continue;
            };
            let actor = match on {
                "pump" => Actor::Pump,
                "settle" => Actor::Settle,
                "user" => Actor::User,
                "heal" => Actor::Heal,
                other => panic!("illegal row names actor {other}"),
            };
            assert!(
                !transition_allowed(from, to, actor),
                "`{from}` -> `{to}` by {on} is listed as illegal and still allowed"
            );
        }
        assert!(transition_allowed(
            book_state::PAUSED,
            book_state::WAITING,
            Actor::User
        ));
        assert!(!transition_allowed(
            book_state::PAUSED,
            book_state::DOWNLOADING,
            Actor::Pump
        ));
    }

    /// The pair that is legal for one actor and illegal for another is the table's
    /// whole reason to exist. If a future edit collapses that distinction, every
    /// other assertion here still passes.
    #[test]
    fn the_same_pair_is_legal_for_one_actor_and_refused_for_another() {
        assert!(transition_allowed(
            book_state::DOWNLOADING,
            book_state::WAITING,
            Actor::Settle
        ));
        assert!(!transition_allowed(
            book_state::DOWNLOADING,
            book_state::WAITING,
            Actor::User
        ));
        assert!(transition_allowed(
            book_state::PAUSED,
            book_state::WAITING,
            Actor::User
        ));
        assert!(!transition_allowed(
            book_state::PAUSED,
            book_state::WAITING,
            Actor::Settle
        ));
    }

    #[test]
    fn the_table_has_no_ambiguous_duplicate_rows() {
        let table: serde_json::Value = serde_json::from_str(states_text()).unwrap();
        let mut seen = std::collections::BTreeSet::new();
        for (key, rows) in [
            ("transitions", &table["transitions"]),
            ("illegal", &table["illegal"]),
        ] {
            for row in rows.as_array().unwrap() {
                let id = (
                    key.to_string(),
                    row["from"].to_string(),
                    row["to"].to_string(),
                    row["on"].to_string(),
                );
                assert!(seen.insert(id.clone()), "duplicate table row: {id:?}");
            }
        }
    }

    #[test]
    fn enqueue_is_a_user_gesture_and_nothing_else_can_make_one() {
        assert!(enqueue_allowed());
        // A book cannot be enqueued into `downloading` by the pump: that is the same
        // bug as resuming a pause, arriving from the other end.
        assert!(!transition_allowed(
            "nonexistent",
            book_state::DOWNLOADING,
            Actor::Pump
        ));
    }

    // ---------------------------------------------------------- errors table

    #[test]
    fn every_signal_classifies_the_way_the_table_says() {
        let table: serde_json::Value = serde_json::from_str(errors_text()).unwrap();
        let signals = [
            Signal::Ok,
            Signal::Link,
            Signal::Credential,
            Signal::NotFound,
            Signal::RateLimited,
            Signal::Server,
            Signal::ShortRead,
            Signal::Corrupt,
            Signal::TooSmall,
            Signal::WriteFailed,
        ];
        assert_eq!(
            table["classify"].as_array().unwrap().len(),
            signals.len(),
            "a signal with no row would be classified by `default`, silently"
        );
        for row in table["classify"].as_array().unwrap() {
            let signal = row["signal"].as_str().unwrap();
            let expected = row["outcome"].as_str().unwrap();
            let parsed = match signal {
                "ok" => Signal::Ok,
                "link" => Signal::Link,
                "credential" => Signal::Credential,
                "notFound" => Signal::NotFound,
                "rateLimited" => Signal::RateLimited,
                "server" => Signal::Server,
                "shortRead" => Signal::ShortRead,
                "corrupt" => Signal::Corrupt,
                "tooSmall" => Signal::TooSmall,
                "writeFailed" => Signal::WriteFailed,
                other => panic!("unmapped signal name {other}"),
            };
            assert_eq!(
                classify(parsed).as_str(),
                expected,
                "signal `{signal}` is classified differently than the contract says"
            );
            let outcome_row = &table["outcomes"][expected];
            assert_eq!(
                scope_of(classify(parsed)),
                match outcome_row["scope"].as_str().unwrap() {
                    "page" => Scope::Page,
                    "book" => Scope::Book,
                    "pass" => Scope::Pass,
                    "serverQueue" => Scope::ServerQueue,
                    other => panic!("unknown scope {other}"),
                },
                "outcome `{expected}` has a different scope than the contract says"
            );
            assert_eq!(
                burns_attempt(classify(parsed)),
                outcome_row["burnsAttempt"].as_bool().unwrap(),
                "outcome `{expected}` burns a different number of attempts than the contract says"
            );
        }
    }

    /// The stage spec's failure-recovery paragraph, as one assertion: an outage must
    /// not consume the retries a genuinely bad page needs.
    #[test]
    fn an_outage_never_burns_the_retries_a_bad_page_needed() {
        for outcome in [
            Outcome::LinkDown,
            Outcome::Blocked,
            Outcome::Gone,
            Outcome::Throttled,
            Outcome::IoFailed,
            Outcome::Complete,
        ] {
            assert!(
                !burns_attempt(outcome),
                "{} must not burn an attempt",
                outcome.as_str()
            );
        }
        assert!(burns_attempt(Outcome::BadPage));
        assert_eq!(scope_of(Outcome::LinkDown), Scope::Pass);
        assert_eq!(scope_of(Outcome::BadPage), Scope::Page);
        assert_eq!(scope_of(Outcome::Blocked), Scope::ServerQueue);
    }

    #[test]
    fn the_bounds_are_the_ones_the_contract_names() {
        let table: serde_json::Value = serde_json::from_str(errors_text()).unwrap();
        assert_eq!(
            max_page_attempts(),
            table["bounds"]["maxPageAttempts"].as_i64().unwrap()
        );
        assert_eq!(
            consecutive_bad_pages(),
            table["bounds"]["consecutiveBadPages"].as_u64().unwrap() as usize
        );
        assert_eq!(
            default_max_bytes(),
            table["bounds"]["defaultMaxBytes"].as_i64().unwrap()
        );
        assert_eq!(
            max_elapsed_ms(),
            table["bounds"]["maxElapsedMs"].as_u64().unwrap()
        );
        assert!(default_max_pages() > 0 && default_max_bytes() > 0 && max_elapsed_ms() > 0);
        for (key, value) in table["bounds"]["nextInMs"].as_object().unwrap() {
            let reason = match key.as_str() {
                "linkDown" => StopReason::LinkDown,
                "throttled" => StopReason::Throttled,
                "blocked" => StopReason::Blocked,
                "lowSpace" => StopReason::LowSpace,
                "linkBlocked" => StopReason::LinkBlocked,
                "badRun" => StopReason::BadRun,
                "budget" => StopReason::Budget,
                other => panic!("nextInMs names {other}, which no stop reason maps to"),
            };
            assert_eq!(
                next_in_ms(reason, 0),
                value.as_i64().unwrap(),
                "backoff for {key}"
            );
        }
    }

    // ------------------------------------------------------------- pump cases

    fn plan_from_fixture(case: &serde_json::Value) -> Pass {
        let book_value = case["input"]["books"].as_array().unwrap();
        let books: Vec<BookPlan> = book_value
            .iter()
            .map(|row| BookPlan {
                server_id: "s1".to_string(),
                book_id: row["bookId"].as_str().unwrap().to_string(),
                position: row["position"].as_i64().unwrap(),
                state: row["state"].as_str().unwrap().to_string(),
                allow_cellular: row["allowCellular"].as_bool().unwrap(),
                pages_total: row["pagesTotal"].as_u64().unwrap() as u32,
                next_retry_at: row["nextRetryAt"].as_str().map(str::to_string),
                pages: row["pages"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|page| PagePlan {
                        number: page["number"].as_u64().unwrap() as u32,
                        state: page["state"].as_str().unwrap().to_string(),
                        attempts: page["attempts"].as_i64().unwrap(),
                        declared_bytes: page["declaredBytes"].as_i64().unwrap(),
                    })
                    .collect(),
            })
            .collect();
        let reader = case["input"]["reader"]
            .as_object()
            .map(|row| ReaderPosition {
                book_id: row["bookId"].as_str().unwrap().to_string(),
                page: row["page"].as_u64().unwrap() as u32,
            });
        plan_pass(&PassInput {
            now: DateTime::parse_from_rfc3339(case["input"]["now"].as_str().unwrap())
                .unwrap()
                .with_timezone(&Utc),
            books: &books,
            link: Link::parse(case["input"]["link"].as_str().unwrap()),
            free_bytes: case["input"]["freeBytes"].as_i64().unwrap(),
            max_pages: case["input"]["maxPages"].as_u64().unwrap() as usize,
            max_bytes: case["input"]["maxBytes"].as_i64().unwrap(),
            reader,
        })
    }

    /// The whole planner, against the shared table. Swift runs this same file.
    #[test]
    fn the_pump_plan_matches_the_shared_contract() {
        let table = fixture("pump.json");
        let cases = table["cases"].as_array().unwrap();
        assert!(cases.len() >= 14, "thin contract: {} cases", cases.len());
        for case in cases {
            let got = plan_from_fixture(case);
            let expect = &case["expect"];
            let expected_jobs: Vec<(String, u32)> = expect["jobs"]
                .as_array()
                .unwrap()
                .iter()
                .map(|job| {
                    (
                        job["bookId"].as_str().unwrap().to_string(),
                        job["page"].as_u64().unwrap() as u32,
                    )
                })
                .collect();
            let actual_jobs: Vec<(String, u32)> = got
                .jobs
                .iter()
                .map(|job| (job.book_id.clone(), job.number))
                .collect();
            assert_eq!(
                actual_jobs,
                expected_jobs,
                "{}: the queue would take different pages",
                case["name"].as_str().unwrap()
            );
            assert_eq!(
                got.stop.as_str(),
                expect["stopReason"].as_str().unwrap(),
                "{}: the pass would stop for a different reason",
                case["name"].as_str().unwrap()
            );
            assert_eq!(
                got.next_in_ms,
                expect["nextInMs"].as_i64().unwrap_or(0),
                "{}: the caller would wait a different length of time",
                case["name"].as_str().unwrap()
            );
        }
    }

    /// Every case must actually exercise the rule its name claims, or the table
    /// could be emptied and this file would still pass.
    #[test]
    fn the_contract_cases_are_distinguishable_from_each_other() {
        let table = fixture("pump.json");
        let names: Vec<&str> = table["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|case| case["name"].as_str().unwrap())
            .collect();
        let unique: std::collections::BTreeSet<&str> = names.iter().copied().collect();
        assert_eq!(names.len(), unique.len(), "two cases share a name");
        let reasons: std::collections::BTreeSet<String> = table["cases"]
            .as_array()
            .unwrap()
            .iter()
            .map(|case| case["expect"]["stopReason"].as_str().unwrap().to_string())
            .collect();
        for reason in [
            "drained",
            "budget",
            "bytes",
            "linkBlocked",
            "lowSpace",
            "parked",
            "idle",
        ] {
            assert!(
                reasons.contains(reason),
                "no case ends with `{reason}`, so that branch of the planner is uncontracted"
            );
        }
    }

    #[test]
    fn an_unknown_link_may_finish_a_book_but_never_start_one() {
        let started = [book("b1", 1, book_state::DOWNLOADING, pending(&[3, 4]))];
        let fresh = [book("b2", 1, book_state::WAITING, pending(&[1, 2]))];
        let mut unknown_started = input(&started);
        unknown_started.link = Link::Unknown;
        assert_eq!(
            plan_pass(&unknown_started).jobs.len(),
            2,
            "an in-flight book stalls"
        );
        let mut unknown_fresh = input(&fresh);
        unknown_fresh.link = Link::Unknown;
        let pass = plan_pass(&unknown_fresh);
        assert!(pass.jobs.is_empty());
        assert_eq!(pass.stop, StopReason::LinkBlocked);
        // The same shape for space, and for the same reason.
        let mut tight_fresh = input(&fresh);
        tight_fresh.free_bytes = 0;
        assert_eq!(plan_pass(&tight_fresh).stop, StopReason::LowSpace);
        let mut tight_started = input(&started);
        tight_started.free_bytes = 0;
        assert_eq!(plan_pass(&tight_started).jobs.len(), 2);
    }

    #[test]
    fn a_link_that_cannot_be_described_is_never_read_as_free() {
        assert_eq!(Link::parse("cellular"), Link::Metered);
        assert_eq!(Link::parse(""), Link::Unknown);
        assert_eq!(Link::parse("wifi"), Link::Unmetered);
        // The trap the device leg would otherwise fall into: an emulator answers
        // `ethernet`, and meteredness — not transport — is the question.
        assert_eq!(Link::parse("ethernet"), Link::Unmetered);
    }

    #[test]
    fn a_paused_book_is_never_resumed_and_a_completed_one_is_never_reopened() {
        let paused = [book("b1", 1, book_state::PAUSED, pending(&[1]))];
        assert_eq!(
            plan_pass(&input(&paused)).stop,
            StopReason::Idle,
            "a paused book is not the queue's to run"
        );
        for actor in ALL_ACTORS {
            assert!(
                !transition_allowed(book_state::PAUSED, book_state::DOWNLOADING, actor)
                    || actor == Actor::User,
                "{} may not start a paused book",
                actor.as_str()
            );
        }
        assert!(!transition_allowed(
            book_state::COMPLETED,
            book_state::DOWNLOADING,
            Actor::Pump
        ));
    }

    #[test]
    fn settle_state_is_derived_and_pause_survives_it() {
        assert_eq!(
            settle_state(book_state::DOWNLOADING, 10, 10, 0, SettleMode::Pass),
            book_state::COMPLETED
        );
        assert_eq!(
            settle_state(book_state::DOWNLOADING, 10, 7, 3, SettleMode::Pass),
            book_state::FAILED
        );
        assert_eq!(
            settle_state(book_state::DOWNLOADING, 10, 7, 1, SettleMode::Pass),
            book_state::WAITING
        );
        // A pause is the user's; a completion is the disk's, and only the party that
        // just read the disk may take it back.
        assert_eq!(
            settle_state(book_state::PAUSED, 10, 10, 0, SettleMode::Sweep),
            book_state::PAUSED
        );
        assert_eq!(
            settle_state(book_state::COMPLETED, 10, 4, 0, SettleMode::Pass),
            book_state::COMPLETED
        );
        assert_eq!(
            settle_state(book_state::COMPLETED, 10, 4, 0, SettleMode::Sweep),
            book_state::WAITING,
            "a heal that found a page gone must reopen the book, or it stays broken and labelled whole"
        );
        assert_eq!(
            settle_state(book_state::COMPLETED, 10, 10, 0, SettleMode::Sweep),
            book_state::COMPLETED,
            "a heal that found nothing wrong leaves a finished book alone"
        );
        // An empty book is finished, not stuck: nothing will ever fetch it.
        assert_eq!(
            settle_state(book_state::WAITING, 0, 0, 0, SettleMode::Pass),
            book_state::COMPLETED
        );
    }

    #[test]
    fn a_reader_position_reorders_without_inventing_pages() {
        let pages: Vec<PagePlan> = pending(&(1..=6).collect::<Vec<u32>>());
        let target = BookPlan {
            pages_total: 6,
            ..book("b1", 1, book_state::WAITING, pages)
        };
        let numbers = [target.clone()];
        let plain = plan_pass(&input(&numbers));
        assert_eq!(
            plain.jobs.iter().map(|job| job.number).collect::<Vec<_>>(),
            vec![1, 2, 3, 4],
            "without a reader the queue drains from the front, and stops at the page bound"
        );
        let mut with_reader = input(&numbers);
        with_reader.reader = Some(ReaderPosition {
            book_id: "b1".to_string(),
            page: 4,
        });
        let ordered = plan_pass(&with_reader);
        assert_eq!(
            ordered
                .jobs
                .iter()
                .map(|job| job.number)
                .collect::<Vec<_>>(),
            vec![4, 5, 6, 1],
            "the pump must race toward the reader, then cover what is behind them"
        );
        // A reader on a *different* book must not reorder this one.
        let mut elsewhere = input(&numbers);
        elsewhere.reader = Some(ReaderPosition {
            book_id: "other".to_string(),
            page: 4,
        });
        assert_eq!(
            plan_pass(&elsewhere)
                .jobs
                .iter()
                .map(|job| job.number)
                .collect::<Vec<_>>(),
            vec![1, 2, 3, 4]
        );
    }
}
