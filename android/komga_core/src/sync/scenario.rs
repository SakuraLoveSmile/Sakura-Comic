//! Sync scenario replay — the Stage 5 acceptance battery.
//!
//! A scenario file (`specs/contracts/fixtures/sync/*.json`) scripts a Komga
//! side history: named server snapshots plus the actions the client takes
//! against them (`bootstrap` / `reconcile`), optionally with an injected
//! transport failure. After every step the local SQLite mirror is compared
//! with the snapshot the server currently serves, so a green scenario *is*
//! the claim "SQLite 与 Komga 一致".
//!
//! The same JSON drives the Swift tests (`SyncScenario.swift`) and
//! `stage5_smoke`, so both platforms are held to one contract.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{Arc, Mutex};

use serde::Deserialize;

use crate::api::book::BookFetcher;
use crate::api::collection::CollectionFetcher;
use crate::api::error::{ApiError, Result};
use crate::api::readlist::ReadListFetcher;
use crate::api::series::PageRequest;
use crate::api::server::LibrariesFetcher;
use crate::model::book::Book;
use crate::model::collection::Collection;
use crate::model::readlist::ReadList;
use crate::model::series::Series;
use crate::model::server::Library;
use crate::store;
use crate::store::prune;
use crate::store::sync_state;
use crate::sync::bootstrap::SeriesFetcher;
use crate::sync::full::{full_sync_from, StartAt};
use crate::sync::reconcile::{reconcile, ReconcileTrigger};

/// One point-in-time view of what the server serves. Lists of items are
/// **pages**, so a snapshot controls how many round-trips a sweep needs.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub id: String,
    #[serde(default)]
    pub libraries: Vec<Library>,
    #[serde(default)]
    pub series: Vec<Vec<Series>>,
    /// series id → book pages
    #[serde(default)]
    pub books: BTreeMap<String, Vec<Vec<Book>>>,
    #[serde(default)]
    pub collections: Vec<Vec<Collection>>,
    #[serde(default)]
    pub readlists: Vec<Vec<ReadList>>,
    #[serde(default)]
    pub on_deck: Vec<Vec<Book>>,
}

/// Injected transport failure.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fault {
    /// Only `network` is modelled: the request fails as if the server were
    /// unreachable.
    #[serde(default = "default_fault_kind")]
    pub kind: String,
    /// Entity whose requests fail; `None` fails every request (offline).
    pub entity: Option<String>,
    /// Fail after this many successful page requests of that entity.
    #[serde(default)]
    pub after_pages: u32,
}

fn default_fault_kind() -> String {
    "network".to_string()
}

/// Extra per-step expectations beyond snapshot equality.
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Expect {
    /// entity type → ids that must be tombstoned locally.
    #[serde(default)]
    pub tombstoned: BTreeMap<String, Vec<String>>,
    /// Steps the run must report as continued from a cursor.
    #[serde(default)]
    pub resumed_steps: Vec<String>,
    /// Steps the run must report as already finished.
    #[serde(default)]
    pub skipped_steps: Vec<String>,
    /// entity type → exact page-request counts, to prove a resumed sweep did
    /// not redo committed work.
    #[serde(default)]
    pub requests: BTreeMap<String, u32>,
    /// entity types that must be left in `error` with their cursor intact.
    #[serde(default)]
    pub failed_entities: Vec<String>,
    /// entity type → the exact resume cursor the step must leave behind.
    #[serde(default)]
    pub cursors: BTreeMap<String, String>,
    /// The mirror must equal this snapshot (defaults to the step's snapshot).
    pub mirror: Option<String>,
    /// Reconcile must report "nothing changed".
    pub clean: Option<bool>,
    /// Reconcile must report these tallies (Added / Changed / Removed).
    #[serde(default)]
    pub tallies: BTreeMap<String, usize>,
    /// The server-level rollup row must be flagged `error`.
    pub rollup_error: Option<bool>,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub label: String,
    /// `bootstrap` | `bootstrap_fresh` | `reconcile`
    pub action: String,
    pub snapshot: Option<String>,
    pub trigger: Option<String>,
    pub fault: Option<Fault>,
    #[serde(default)]
    pub expect: Expect,
    /// Whether the step is expected to succeed when a fault is injected.
    #[serde(default = "default_true")]
    pub expect_success: bool,
}

/// Build a scripted server from one snapshot JSON object. Used by the facade
/// tests (and any host tooling) that need a controllable "server".
pub fn server_from_snapshot(json: &str) -> std::result::Result<ScriptedServer, String> {
    let snapshot: Snapshot = serde_json::from_str(json).map_err(|e| format!("snapshot: {e}"))?;
    Ok(ScriptedServer::new(snapshot))
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Scenario {
    pub name: String,
    #[serde(default)]
    pub description: String,
    /// `disabled` means no SSE events are delivered at all — the whole point
    /// of the Stage 5 completion criterion.
    #[serde(default)]
    pub sse: Option<String>,
    pub server_id: String,
    pub snapshots: Vec<Snapshot>,
    pub steps: Vec<Step>,
}

/// Entity types a scenario step can talk about.
const ENTITIES: &[&str] = &[
    "libraries",
    "series",
    "books",
    "collections",
    "readlists",
    "read_progress",
];

/// Everything in a snapshot that carries a remote id.
pub trait RemoteId {
    fn remote_id(&self) -> &str;
}

impl RemoteId for Series {
    fn remote_id(&self) -> &str {
        &self.id
    }
}

impl RemoteId for Book {
    fn remote_id(&self) -> &str {
        &self.id
    }
}

impl RemoteId for Collection {
    fn remote_id(&self) -> &str {
        &self.id
    }
}

impl RemoteId for ReadList {
    fn remote_id(&self) -> &str {
        &self.id
    }
}

/// A Komga server scripted by a snapshot, with request accounting and faults.
#[derive(Clone)]
pub struct ScriptedServer {
    state: Arc<Mutex<ServerState>>,
    calls: Arc<Mutex<BTreeMap<String, u32>>>,
}

struct ServerState {
    snapshot: Snapshot,
    fault: Option<Fault>,
    served: BTreeMap<String, u32>,
}

impl ScriptedServer {
    fn new(snapshot: Snapshot) -> Self {
        Self {
            state: Arc::new(Mutex::new(ServerState {
                snapshot,
                fault: None,
                served: BTreeMap::new(),
            })),
            calls: Arc::new(Mutex::new(BTreeMap::new())),
        }
    }

    fn set_snapshot(&self, snapshot: Snapshot) {
        let mut state = self.state.lock().unwrap();
        state.snapshot = snapshot;
        state.served.clear();
    }

    /// Per-step request accounting (the scenario asserts one step at a time).
    fn reset_calls(&self) {
        self.calls.lock().unwrap().clear();
    }

    fn set_fault(&self, fault: Option<Fault>) {
        self.state.lock().unwrap().fault = fault;
    }

    /// Count the request and fail it when the scripted fault applies.
    fn gate(&self, entity: &str) -> Result<()> {
        let mut state = self.state.lock().unwrap();
        let served = state.served.get(entity).copied().unwrap_or(0);
        if let Some(fault) = &state.fault {
            let matches = fault.entity.as_deref().map_or(true, |e| e == entity);
            if matches && fault.kind == "network" && served >= fault.after_pages {
                return Err(ApiError::Network);
            }
        }
        *state.served.entry(entity.to_string()).or_insert(0) += 1;
        let mut calls = self.calls.lock().unwrap();
        *calls.entry(entity.to_string()).or_insert(0) += 1;
        Ok(())
    }

    fn request_counts(&self) -> BTreeMap<String, u32> {
        self.calls.lock().unwrap().clone()
    }

    /// Snapshot page helper: pages beyond the scripted list are empty+last.
    fn page<T: Clone>(pages: &[Vec<T>], number: u32) -> (Vec<T>, bool, i64, i64) {
        let total_pages = pages.len() as i64;
        let total_elements: i64 = pages.iter().map(|p| p.len() as i64).sum();
        let index = number as usize;
        let content = pages.get(index).cloned().unwrap_or_default();
        let last = index + 1 >= total_pages as usize;
        (content, last, total_elements, total_pages)
    }
}

impl LibrariesFetcher for ScriptedServer {
    async fn libraries(&self) -> Result<Vec<Library>> {
        self.gate("libraries")?;
        Ok(self.state.lock().unwrap().snapshot.libraries.clone())
    }
}

impl SeriesFetcher for ScriptedServer {
    async fn series_page(&self, request: &PageRequest) -> Result<crate::model::series::SeriesPage> {
        self.gate("series")?;
        let pages = self.state.lock().unwrap().snapshot.series.clone();
        let (content, last, total_elements, total_pages) = Self::page(&pages, request.page);
        Ok(crate::model::series::SeriesPage {
            content,
            total_elements,
            total_pages,
            number: request.page as i64,
            size: request.size as i64,
            first: request.page == 0,
            last,
        })
    }
}

impl BookFetcher for ScriptedServer {
    async fn books_page(
        &self,
        series_id: &str,
        request: &PageRequest,
    ) -> Result<crate::model::book::BookPage> {
        self.gate("books")?;
        let pages: Vec<Vec<Book>> = self
            .state
            .lock()
            .unwrap()
            .snapshot
            .books
            .get(series_id)
            .cloned()
            .unwrap_or_default();
        let (content, last, total_elements, total_pages) = Self::page(&pages, request.page);
        Ok(crate::model::book::BookPage {
            content,
            total_elements,
            total_pages,
            number: request.page as i64,
            size: request.size as i64,
            first: request.page == 0,
            last,
        })
    }

    async fn on_deck_page(&self, request: &PageRequest) -> Result<crate::model::book::BookPage> {
        self.gate("read_progress")?;
        let pages = self.state.lock().unwrap().snapshot.on_deck.clone();
        let (content, last, total_elements, total_pages) = Self::page(&pages, request.page);
        Ok(crate::model::book::BookPage {
            content,
            total_elements,
            total_pages,
            number: request.page as i64,
            size: request.size as i64,
            first: request.page == 0,
            last,
        })
    }
}

impl CollectionFetcher for ScriptedServer {
    async fn collections_page(
        &self,
        request: &PageRequest,
    ) -> Result<crate::model::collection::CollectionPage> {
        self.gate("collections")?;
        let pages = self.state.lock().unwrap().snapshot.collections.clone();
        let (content, last, total_elements, total_pages) = Self::page(&pages, request.page);
        Ok(crate::model::collection::CollectionPage {
            content,
            total_elements,
            total_pages,
            number: request.page as i64,
            size: request.size as i64,
            first: request.page == 0,
            last,
        })
    }
}

impl ReadListFetcher for ScriptedServer {
    async fn readlists_page(
        &self,
        request: &PageRequest,
    ) -> Result<crate::model::readlist::ReadListPage> {
        self.gate("readlists")?;
        let pages = self.state.lock().unwrap().snapshot.readlists.clone();
        let (content, last, total_elements, total_pages) = Self::page(&pages, request.page);
        Ok(crate::model::readlist::ReadListPage {
            content,
            total_elements,
            total_pages,
            number: request.page as i64,
            size: request.size as i64,
            first: request.page == 0,
            last,
        })
    }
}

/// Compare the local mirror with a snapshot; every mismatch is one line.
pub fn diff_mirror(db_path: &str, server_id: &str, snap: &Snapshot) -> Vec<String> {
    let mut problems = Vec::new();
    let conn = match store::open(db_path) {
        Ok(conn) => conn,
        Err(e) => return vec![format!("cannot open db: {e}")],
    };
    let ids = |entity: &str| -> Vec<String> {
        prune::local_ids(&conn, server_id, entity).unwrap_or_default()
    };

    let mut want: Vec<String> = snap.libraries.iter().map(|l| l.id.clone()).collect();
    want.sort();
    let mut got = ids(sync_state::ENTITY_LIBRARIES);
    got.sort();
    if want != got {
        problems.push(format!(
            "libraries: server {:?} != local {:?}",
            want.join(","),
            got.join(",")
        ));
    }

    want = paged_ids(&snap.series);
    got = ids(sync_state::ENTITY_SERIES);
    got.sort();
    if want != got {
        problems.push(format!(
            "series: server {:?} != local {:?}",
            want.join(","),
            got.join(",")
        ));
    }

    let mut want_books: Vec<String> = all_snapshot_books(snap)
        .into_iter()
        .map(|b| b.id.clone())
        .collect();
    want_books.sort();
    want_books.dedup();
    want_books.sort();
    let mut got_books = ids(sync_state::ENTITY_BOOKS);
    got_books.sort();
    if want_books != got_books {
        problems.push(format!(
            "books: server {:?} != local {:?}",
            want_books.join(","),
            got_books.join(",")
        ));
    }

    want = paged_ids(&snap.collections);
    got = ids(sync_state::ENTITY_COLLECTIONS);
    got.sort();
    if want != got {
        problems.push(format!(
            "collections: server {:?} != local {:?}",
            want.join(","),
            got.join(",")
        ));
    }

    want = paged_ids(&snap.readlists);
    got = ids(sync_state::ENTITY_READLISTS);
    got.sort();
    if want != got {
        problems.push(format!(
            "readlists: server {:?} != local {:?}",
            want.join(","),
            got.join(",")
        ));
    }

    // Values, not just identity: name / status / lastModified must match.
    for series in snap.series.iter().flat_map(|p| p.iter()) {
        let row: Option<(String, Option<String>, Option<String>)> = conn
            .query_row(
                "SELECT name, status, last_modified FROM series WHERE server_id = ?1 AND remote_id = ?2",
                rusqlite::params![server_id, series.id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .ok();
        match row {
            None => problems.push(format!("series {}: missing locally", series.id)),
            Some((name, status, last_modified)) => {
                if name != series.name {
                    problems.push(format!(
                        "series {}: name local {name:?} != server {:?}",
                        series.id, series.name
                    ));
                }
                let want_status = series.metadata.as_ref().and_then(|m| m.status.clone());
                if status != want_status {
                    problems.push(format!(
                        "series {}: status local {status:?} != server {want_status:?}",
                        series.id
                    ));
                }
                if last_modified != series.last_modified {
                    problems.push(format!(
                        "series {}: lastModified local {last_modified:?} != server {:?}",
                        series.id, series.last_modified
                    ));
                }
                // Metadata edits must reach the normalized filter tables.
                if let Some(meta) = &series.metadata {
                    let genres: Vec<String> = {
                        let mut stmt = conn
                            .prepare(
                                "SELECT genre FROM series_genres WHERE server_id = ?1 AND series_id = ?2 ORDER BY genre",
                            )
                            .unwrap();
                        stmt.query_map(rusqlite::params![server_id, series.id], |r| r.get(0))
                            .unwrap()
                            .collect::<rusqlite::Result<_>>()
                            .unwrap()
                    };
                    if genres != sorted(&meta.genres) {
                        problems.push(format!(
                            "series {}: genres local {genres:?} != server {:?}",
                            series.id,
                            sorted(&meta.genres)
                        ));
                    }
                    let summary: Option<String> = conn
                        .query_row(
                            "SELECT summary FROM series_metadata WHERE server_id = ?1 AND series_id = ?2",
                            rusqlite::params![server_id, series.id],
                            |r| r.get(0),
                        )
                        .ok();
                    if summary != meta.summary {
                        problems.push(format!(
                            "series {}: summary local {summary:?} != server {:?}",
                            series.id, meta.summary
                        ));
                    }
                }
            }
        }
    }

    for book in all_snapshot_books(snap) {
        let title: Option<String> = conn
            .query_row(
                "SELECT title FROM books WHERE server_id = ?1 AND remote_id = ?2",
                rusqlite::params![server_id, book.id],
                |r| r.get(0),
            )
            .ok();
        if title.as_deref() != Some(book.name.as_str()) {
            problems.push(format!(
                "book {}: title local {title:?} != server {:?}",
                book.id, book.name
            ));
        }
    }

    // Collection / readlist membership.
    for collection in snap.collections.iter().flat_map(|p| p.iter()) {
        let members: Vec<String> = {
            let mut stmt = conn
                .prepare(
                    "SELECT series_id FROM collection_series WHERE server_id = ?1 AND collection_id = ?2",
                )
                .unwrap();
            stmt.query_map(rusqlite::params![server_id, collection.id], |r| r.get(0))
                .unwrap()
                .collect::<rusqlite::Result<_>>()
                .unwrap()
        };
        if members.len() != collection.series_ids.len()
            || !members.iter().all(|m| collection.series_ids.contains(m))
        {
            problems.push(format!(
                "collection {}: members local {members:?} != server {:?}",
                collection.id, collection.series_ids
            ));
        }
    }
    for readlist in snap.readlists.iter().flat_map(|p| p.iter()) {
        let books: Vec<String> = {
            let mut stmt = conn
                .prepare(
                    "SELECT book_id FROM readlist_books WHERE server_id = ?1 AND readlist_id = ?2 ORDER BY position",
                )
                .unwrap();
            stmt.query_map(rusqlite::params![server_id, readlist.id], |r| r.get(0))
                .unwrap()
                .collect::<rusqlite::Result<_>>()
                .unwrap()
        };
        if books != readlist.book_ids {
            problems.push(format!(
                "readlist {}: books local {books:?} != server {:?}",
                readlist.id, readlist.book_ids
            ));
        }
    }

    // Search index must not keep ghosts of pruned rows.
    let fts_series: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM series_fts WHERE server_id = ?1",
            rusqlite::params![server_id],
            |r| r.get(0),
        )
        .unwrap();
    if fts_series != snap.series.iter().map(|p| p.len() as i64).sum::<i64>() {
        problems.push(format!(
            "series_fts rows {fts_series} != server series count {}",
            snap.series.iter().map(|p| p.len()).sum::<usize>()
        ));
    }
    let fts_books: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM book_fts WHERE server_id = ?1",
            rusqlite::params![server_id],
            |r| r.get(0),
        )
        .unwrap();
    if fts_books != want_books.len() as i64 {
        problems.push(format!(
            "book_fts rows {fts_books} != server book count {}",
            want_books.len()
        ));
    }

    // Read progress: exactly the books the server reports progress for.
    let mut want_progress: Vec<String> = all_snapshot_books(snap)
        .into_iter()
        .filter(|b| b.read_progress.is_some())
        .map(|b| b.id.clone())
        .collect();
    want_progress.sort();
    want_progress.dedup();
    let got_progress: Vec<String> = conn
        .prepare("SELECT book_id FROM read_progress WHERE server_id = ?1 ORDER BY book_id")
        .unwrap()
        .query_map(rusqlite::params![server_id], |r| r.get(0))
        .unwrap()
        .collect::<rusqlite::Result<_>>()
        .unwrap();
    if got_progress != want_progress {
        problems.push(format!(
            "read_progress: server {:?} != local {:?}",
            want_progress.join(","),
            got_progress.join(",")
        ));
    }

    // Orphans: a book under a series the server no longer has.
    let orphans: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM books b WHERE b.server_id = ?1 AND NOT EXISTS
               (SELECT 1 FROM series s WHERE s.server_id = b.server_id AND s.remote_id = b.series_id)",
            rusqlite::params![server_id],
            |r| r.get(0),
        )
        .unwrap();
    if orphans != 0 {
        problems.push(format!("{orphans} orphan books survived the cascade"));
    }
    problems
}

/// Every book the snapshot serves, across series and pages.
fn all_snapshot_books(snap: &Snapshot) -> Vec<&Book> {
    snap.books
        .values()
        .flat_map(|pages| pages.iter())
        .flat_map(|page| page.iter())
        .chain(snap.on_deck.iter().flat_map(|page| page.iter()))
        .collect()
}

/// Sorted remote ids across every page of a snapshot list.
fn paged_ids<T: RemoteId>(pages: &[Vec<T>]) -> Vec<String> {
    let mut v: Vec<String> = pages
        .iter()
        .flat_map(|page| page.iter().map(|item| item.remote_id().to_string()))
        .collect();
    v.sort();
    v
}

fn sorted(values: &[String]) -> Vec<String> {
    let mut v = values.to_vec();
    v.sort();
    v
}

fn trigger_of(name: Option<&str>) -> ReconcileTrigger {
    match name {
        Some("app_launch") => ReconcileTrigger::AppLaunch,
        Some("did_become_active") => ReconcileTrigger::DidBecomeActive,
        Some("network_recovered") => ReconcileTrigger::NetworkRecovered,
        Some("sse_reconnected") => ReconcileTrigger::SseReconnected,
        _ => ReconcileTrigger::ManualRefresh,
    }
}

/// What a step did, as the scenario runner observed it.
#[derive(Debug, Default)]
pub struct StepOutcome {
    pub resumed: Vec<String>,
    pub skipped: Vec<String>,
    pub clean: bool,
    pub tallies: BTreeMap<String, usize>,
}

/// One executed step, reported by the smoke binary and asserted by tests.
#[derive(Debug, Clone)]
pub struct StepReport {
    pub label: String,
    pub ok: bool,
    pub detail: Vec<String>,
}

/// Replay a scenario: run each step and check it against its expectations.
pub async fn run_scenario(db_path: &str, scenario: &Scenario) -> Vec<StepReport> {
    let snapshots: HashMap<String, Snapshot> = scenario
        .snapshots
        .iter()
        .map(|s| (s.id.clone(), s.clone()))
        .collect();
    let first = scenario
        .snapshots
        .first()
        .expect("scenario needs at least one snapshot");
    let server = ScriptedServer::new(first.clone());
    let server_id = &scenario.server_id;
    let mut reports = Vec::new();

    for step in &scenario.steps {
        let mut problems: Vec<String> = Vec::new();
        if let Some(id) = &step.snapshot {
            match snapshots.get(id) {
                Some(snap) => server.set_snapshot(snap.clone()),
                None => problems.push(format!("unknown snapshot {id}")),
            }
        }
        server.set_fault(step.fault.clone());
        server.reset_calls();

        let mut outcome_rows = StepOutcome::default();
        let outcome: Result<()> = match step.action.as_str() {
            "bootstrap" => match full_sync_from(db_path, server_id, &server, StartAt::Resume).await
            {
                Ok(summary) => {
                    outcome_rows.resumed = summary.resumed_steps.clone();
                    outcome_rows.skipped = summary.skipped_steps.clone();
                    outcome_rows
                        .tallies
                        .insert("series_written".into(), summary.series);
                    outcome_rows
                        .tallies
                        .insert("books_written".into(), summary.books);
                    Ok(())
                }
                Err(e) => Err(e),
            },
            "bootstrap_fresh" => {
                match full_sync_from(db_path, server_id, &server, StartAt::Fresh).await {
                    Ok(summary) => {
                        outcome_rows.resumed = summary.resumed_steps.clone();
                        outcome_rows.skipped = summary.skipped_steps.clone();
                        outcome_rows
                            .tallies
                            .insert("series_written".into(), summary.series);
                        outcome_rows
                            .tallies
                            .insert("books_written".into(), summary.books);
                        Ok(())
                    }
                    Err(e) => Err(e),
                }
            }
            "reconcile" => match reconcile(
                db_path,
                server_id,
                &server,
                trigger_of(step.trigger.as_deref()),
            )
            .await
            {
                Ok(summary) => {
                    outcome_rows.clean = summary.clean;
                    outcome_rows
                        .tallies
                        .insert("series_added".into(), summary.series_added);
                    outcome_rows
                        .tallies
                        .insert("series_changed".into(), summary.series_changed);
                    outcome_rows
                        .tallies
                        .insert("series_removed".into(), summary.series_removed);
                    outcome_rows
                        .tallies
                        .insert("books_added".into(), summary.books_added);
                    outcome_rows
                        .tallies
                        .insert("books_changed".into(), summary.books_changed);
                    outcome_rows
                        .tallies
                        .insert("books_removed".into(), summary.books_removed);
                    outcome_rows
                        .tallies
                        .insert("collections_removed".into(), summary.collections_removed);
                    outcome_rows
                        .tallies
                        .insert("readlists_removed".into(), summary.readlists_removed);
                    Ok(())
                }
                Err(e) => Err(e),
            },
            other => {
                problems.push(format!("unknown action {other}"));
                Ok(())
            }
        };

        match (&outcome, step.expect_success) {
            (Ok(()), true) => {}
            (Err(error), false) => {
                // Injected failure: the error is expected, but the mirror must
                // still be usable and the step must be resumable.
                let _ = error;
            }
            (Err(error), true) => problems.push(format!("step failed: {error}")),
            (Ok(()), false) => problems.push("expected the step to fail, it succeeded".to_string()),
        }

        // `expect.mirror` is always asserted — including after a failed step,
        // where it proves the outage lost nothing. Without it, a successful
        // step must match the snapshot the server served.
        let mirror_id = step
            .expect
            .mirror
            .clone()
            .or_else(|| step.snapshot.clone().filter(|_| step.expect_success));
        if let Some(id) = mirror_id {
            match snapshots.get(&id) {
                Some(snap) => problems.extend(diff_mirror(db_path, server_id, snap)),
                None => problems.push(format!("unknown mirror snapshot {id}")),
            }
        }

        problems.extend(check_sync_state(
            db_path,
            server_id,
            &step.expect,
            &outcome_rows,
            &server,
        ));
        reports.push(StepReport {
            label: step.label.clone(),
            ok: problems.is_empty(),
            detail: problems,
        });
    }
    reports
}

fn check_sync_state(
    db_path: &str,
    server_id: &str,
    expect: &Expect,
    outcome: &StepOutcome,
    server: &ScriptedServer,
) -> Vec<String> {
    let mut problems = Vec::new();
    let conn = match store::open(db_path) {
        Ok(conn) => conn,
        Err(e) => return vec![format!("cannot open db: {e}")],
    };

    if !expect.resumed_steps.is_empty() && outcome.resumed != expect.resumed_steps {
        problems.push(format!(
            "resumed_steps {:?} != expected {:?}",
            outcome.resumed, expect.resumed_steps
        ));
    }
    if !expect.skipped_steps.is_empty() && outcome.skipped != expect.skipped_steps {
        problems.push(format!(
            "skipped_steps {:?} != expected {:?}",
            outcome.skipped, expect.skipped_steps
        ));
    }
    if let Some(want) = expect.clean {
        if outcome.clean != want {
            problems.push(format!("clean {} != expected {want}", outcome.clean));
        }
    }
    for (key, want) in &expect.tallies {
        let got = outcome.tallies.get(key).copied().unwrap_or(usize::MAX);
        if got != *want {
            problems.push(format!("tally {key}: got {got}, want {want}"));
        }
    }
    for (entity, want_cursor) in &expect.cursors {
        let got = sync_state::get_entity_state(&conn, server_id, entity)
            .ok()
            .flatten()
            .and_then(|state| state.sync_cursor);
        if got.as_deref() != Some(want_cursor.as_str()) {
            problems.push(format!(
                "sync_cursor[{entity}]: got {got:?}, want {want_cursor:?}"
            ));
        }
    }
    for (entity, ids) in &expect.tombstoned {
        let got: Vec<String> = prune::list_tombstones(&conn, server_id, entity)
            .unwrap_or_default()
            .into_iter()
            .map(|t| t.remote_id)
            .collect();
        // Tombstones are stored newest-first; the scenario asserts a set.
        let got = sorted(&got);
        let want = sorted(ids);
        if got != want {
            problems.push(format!("tombstones[{entity}]: got {got:?}, want {want:?}"));
        }
    }
    for entity in &expect.failed_entities {
        let state = sync_state::get_entity_state(&conn, server_id, entity)
            .ok()
            .flatten();
        match state {
            Some(state) => {
                if state.sync_status != sync_state::STATUS_ERROR {
                    problems.push(format!("{entity}: status {} != error", state.sync_status));
                }
                // The libraries step is one request: a failure there leaves
                // nothing partial, so only the paged sweeps must keep a cursor.
                if *entity != "libraries" && state.sync_cursor.is_none() {
                    problems.push(format!("{entity}: error left no resume cursor"));
                }
            }
            None => problems.push(format!("{entity}: no sync_state row")),
        }
    }
    if let Some(want) = expect.rollup_error {
        let rollup = sync_state::get_sync_state(&conn, server_id).ok().flatten();
        let is_error = rollup
            .map(|r| r.sync_status == sync_state::STATUS_ERROR)
            .unwrap_or(false);
        if is_error != want {
            problems.push(format!(
                "rollup sync_status error {is_error} != expected {want}"
            ));
        }
    }
    let calls = server.request_counts();
    for (entity, want) in &expect.requests {
        let got = calls.get(entity).copied().unwrap_or(0);
        if got != *want {
            problems.push(format!("requests[{entity}]: got {got}, want {want}"));
        }
    }
    // No step may be left claiming it is still running with no cursor.
    for entity in ENTITIES {
        if let Ok(Some(state)) = sync_state::get_entity_state(&conn, server_id, entity) {
            if state.sync_status == sync_state::STATUS_IDLE && state.sync_cursor.is_some() {
                problems.push(format!("{entity}: idle row still holds a cursor"));
            }
        }
    }
    let _ = HashSet::<String>::new();
    problems
}

/// Parse a scenario JSON (shared with the Swift tests verbatim).
pub fn parse_scenario(json: &str) -> std::result::Result<Scenario, String> {
    serde_json::from_str(json).map_err(|e| format!("scenario decode: {e}"))
}

/// Scenarios shipped with the contract fixtures.
pub const SCENARIOS: &[(&str, &str)] = &[
    (
        "sre-reconcile",
        include_str!("../../../../specs/contracts/fixtures/sync/scenario-reconcile.json"),
    ),
    (
        "sre-interrupt",
        include_str!("../../../../specs/contracts/fixtures/sync/scenario-interrupt.json"),
    ),
];

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_db() -> String {
        let dir = std::env::temp_dir().join(format!("komga_scenario_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("comic.sqlite").to_string_lossy().into_owned()
    }

    /// Run a shipped scenario and report every failing step with its detail.
    async fn run_shipped(name: &str) -> Vec<String> {
        let json = SCENARIOS
            .iter()
            .find(|(n, _)| *n == name)
            .expect("shipped scenario")
            .1;
        let scenario = parse_scenario(json).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(
            scenario.sse.as_deref(),
            Some("disabled"),
            "{name} must run with SSE unavailable — that is the Stage 5 criterion"
        );
        let db = temp_db();
        let reports = run_scenario(&db, &scenario).await;
        for report in &reports {
            eprintln!(
                "[{}] {}",
                if report.ok { "ok" } else { "FAIL" },
                report.label
            );
            for line in &report.detail {
                eprintln!("      - {line}");
            }
        }
        let failures: Vec<String> = reports
            .iter()
            .filter(|report| !report.ok)
            .map(|report| format!("{}: {}", report.label, report.detail.join("; ")))
            .collect();
        let _ = std::fs::remove_dir_all(std::path::Path::new(&db).parent().unwrap());
        failures
    }

    #[tokio::test]
    async fn reconcile_converges_with_sse_disabled() {
        let failures = run_shipped("sre-reconcile").await;
        assert!(failures.is_empty(), "{failures:#?}");
    }

    #[tokio::test]
    async fn interrupt_resumes_and_offline_recovers() {
        let failures = run_shipped("sre-interrupt").await;
        assert!(failures.is_empty(), "{failures:#?}");
    }
}
