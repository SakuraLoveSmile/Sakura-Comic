//! Reconciliation Sync — converge the local mirror on the server's truth
//! without needing any SSE events.
//!
//! Komga has no changelog and no "deleted ids" endpoint, so the only reliable
//! reconciliation is an **id sweep**: for each entity type page through the
//! remote list, upsert what came back (Added / Changed) and then prune the
//! local ids the server no longer reports (Deleted → cascade + tombstone).
//! That is why this works with SSE completely broken: events are a hint to
//! reconcile sooner, never a source of truth.
//!
//! Safety rule: pruning only happens after a sweep reached its last page. A
//! partial sweep is never evidence that an entity is gone, so a failed
//! reconciliation can only ever delay a deletion — it can never delete local
//! data the server still has. When a sweep resumes from a cursor, the ids of
//! the pages it already committed are seeded from the local rows (they came
//! from the server minutes ago), which keeps the same bias.
//!
//! Triggers (`ReconcileTrigger`): app launch, app becoming active, network
//! recovery, SSE reconnection, manual refresh. Foreground-style triggers are
//! throttled (`should_reconcile`); explicit ones always run.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock};
use tokio::sync::Mutex;

use chrono::{DateTime, Utc};
use rusqlite::Connection;

use crate::api::error::{ApiError, Result};
use crate::api::series::PageRequest;
use crate::store;
use crate::store::prune;
use crate::store::sync_state;
use crate::sync::full::{
    cursor_for, mirrored_series_ids, page_cursor, parse_page, run_step, LibraryFetcher, PAGE_SIZE,
};

/// Why a reconciliation ran. Every one of them is a full sweep: correctness
/// never depends on which trigger fired.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReconcileTrigger {
    /// Cold start of the app.
    AppLaunch,
    /// App came back to the foreground.
    DidBecomeActive,
    /// Connectivity came back.
    NetworkRecovered,
    /// The SSE stream reconnected — events may have been missed while down.
    SseReconnected,
    /// The user pulled to refresh.
    ManualRefresh,
}

impl ReconcileTrigger {
    /// Stable lowercase name (stored in `sync_state`, shown in the UI).
    pub fn as_str(self) -> &'static str {
        match self {
            ReconcileTrigger::AppLaunch => "app_launch",
            ReconcileTrigger::DidBecomeActive => "did_become_active",
            ReconcileTrigger::NetworkRecovered => "network_recovered",
            ReconcileTrigger::SseReconnected => "sse_reconnected",
            ReconcileTrigger::ManualRefresh => "manual_refresh",
        }
    }

    /// Parse a trigger name coming from the UI layer (`manual_refresh`, ...).
    /// Unknown names fall back to `ManualRefresh` — the always-run choice.
    pub fn parse(name: &str) -> Self {
        match name {
            "app_launch" => ReconcileTrigger::AppLaunch,
            "did_become_active" => ReconcileTrigger::DidBecomeActive,
            "network_recovered" => ReconcileTrigger::NetworkRecovered,
            "sse_reconnected" => ReconcileTrigger::SseReconnected,
            _ => ReconcileTrigger::ManualRefresh,
        }
    }

    /// Launch / foreground triggers can fire often; the explicit ones mean
    /// "the user (or the reconnecting stream) wants current data now".
    fn is_background(self) -> bool {
        matches!(
            self,
            ReconcileTrigger::AppLaunch | ReconcileTrigger::DidBecomeActive
        )
    }
}

/// Minimum gap between background-triggered reconciliations.
pub const MIN_RECONCILE_INTERVAL_SECS: i64 = 60;

/// What one reconciliation pass did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReconcileSummary {
    pub server_id: String,
    pub trigger: String,
    pub series_upserted: usize,
    pub series_added: usize,
    pub series_changed: usize,
    pub series_removed: usize,
    pub books_upserted: usize,
    pub books_added: usize,
    pub books_changed: usize,
    pub books_removed: usize,
    pub collections_upserted: usize,
    pub collections_added: usize,
    pub collections_changed: usize,
    pub collections_removed: usize,
    pub readlists_upserted: usize,
    pub readlists_added: usize,
    pub readlists_changed: usize,
    pub readlists_removed: usize,
    pub libraries_upserted: usize,
    pub libraries_removed: usize,
    pub read_progress: usize,
    pub pages_swept: u32,
    /// Cover file paths orphaned by delete propagation (the facade removes
    /// them from disk; the SQLite records are already gone).
    pub orphaned_covers: Vec<String>,
    /// True when the mirror already matched the server and nothing changed.
    pub clean: bool,
}

impl ReconcileSummary {
    fn changed_any(&self) -> bool {
        self.series_added
            + self.series_changed
            + self.series_removed
            + self.books_added
            + self.books_changed
            + self.books_removed
            + self.collections_added
            + self.collections_changed
            + self.collections_removed
            + self.readlists_added
            + self.readlists_changed
            + self.readlists_removed
            + self.libraries_removed
            > 0
    }

    /// Rows this pass moved; the smoke output and UI both use it.
    pub fn total_mutations(&self) -> usize {
        self.series_added
            + self.series_changed
            + self.series_removed
            + self.books_added
            + self.books_changed
            + self.books_removed
            + self.collections_added
            + self.collections_changed
            + self.collections_removed
            + self.readlists_added
            + self.readlists_changed
            + self.readlists_removed
            + self.libraries_removed
    }
}

fn db_err(e: rusqlite::Error) -> ApiError {
    ApiError::Database {
        message: e.to_string(),
    }
}

/// Should this trigger actually run a sweep right now?
pub fn should_reconcile(
    conn: &Connection,
    server_id: &str,
    trigger: ReconcileTrigger,
    now: DateTime<Utc>,
) -> rusqlite::Result<bool> {
    if !trigger.is_background() {
        return Ok(true);
    }
    let Some(last) = sync_state::last_synced_at(conn, server_id)? else {
        return Ok(true); // never synced: the first chance is the right chance
    };
    let Ok(last) = DateTime::parse_from_rfc3339(&last) else {
        return Ok(true); // unreadable stamp: re-sync rather than stay stale
    };
    Ok(now
        .signed_duration_since(last.with_timezone(&Utc))
        .num_seconds()
        >= MIN_RECONCILE_INTERVAL_SECS)
}

/// `remote_id → last_modified` for one mirror table, so Added / Changed can be
/// told apart without a per-row query.
fn local_stamps(
    conn: &Connection,
    server_id: &str,
    table: &str,
    stamp_column: &str,
) -> rusqlite::Result<HashMap<String, Option<String>>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT remote_id, {stamp_column} FROM {table} WHERE server_id = ?1"
    ))?;
    let rows = stmt.query_map(rusqlite::params![server_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
    })?;
    rows.collect()
}

/// `book_id → (page, completed, server_updated_at)` currently stored, so a
/// sweep can tell "the server says what we already have" from a real progress
/// change (which does *not* bump the book's own lastModified).
type ProgressState = (Option<i64>, bool, Option<String>);

fn local_progress(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<HashMap<String, ProgressState>> {
    let mut stmt = conn.prepare(
        "SELECT book_id, page, completed, server_updated_at FROM read_progress WHERE server_id = ?1",
    )?;
    let rows = stmt.query_map(rusqlite::params![server_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            (
                row.get::<_, Option<i64>>(1)?,
                row.get::<_, i64>(2)? != 0,
                row.get::<_, Option<String>>(3)?,
            ),
        ))
    })?;
    rows.collect()
}

/// Does this book need writing at all? New or edited metadata always does;
/// otherwise only a read-progress change does.
fn needs_write(
    added: bool,
    changed: bool,
    remote: Option<&crate::model::book::ReadProgress>,
    stored: Option<&ProgressState>,
) -> bool {
    if added || changed {
        return true;
    }
    match (remote, stored) {
        (Some(progress), Some(stored)) => {
            stored.0 != progress.page
                || stored.1 != progress.completed
                || stored.2 != progress.last_modified
        }
        (Some(_), None) => true,
        (None, _) => false,
    }
}

/// The mirrored series columns a sweep can compare against. `booksCount`,
/// the read counters and the names all move without Komga touching
/// `series.lastModified`, so comparing the stamp alone would miss them.
/// The names are compared as the T1 resolution would render them: an old
/// mirror that stored a folder name (`cbz`) is repaired even though its
/// stamp and counters already match the server.
#[derive(Debug, Clone, PartialEq, Eq)]
struct SeriesProjection {
    last_modified: Option<String>,
    books_count: Option<i64>,
    books_read_count: Option<i64>,
    books_unread_count: Option<i64>,
    books_in_progress_count: Option<i64>,
    display_name: String,
    sort_name: String,
}

fn series_projection(series: &crate::model::series::Series) -> SeriesProjection {
    SeriesProjection {
        last_modified: series.last_modified.clone(),
        books_count: series.books_count,
        books_read_count: series.books_read_count,
        books_unread_count: series.books_unread_count,
        books_in_progress_count: series.books_in_progress_count,
        display_name: store::series::display_name(series),
        sort_name: store::series::sort_name(series),
    }
}

fn local_series_projection(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<HashMap<String, SeriesProjection>> {
    // `COALESCE(sort_name, name)` is the effective local sort value (rows
    // written before the title fix may carry no sort_name at all).
    let mut stmt = conn.prepare(
        "SELECT remote_id, last_modified, books_count, books_read_count, books_unread_count,
                books_in_progress_count, name, COALESCE(sort_name, name)
         FROM series WHERE server_id = ?1",
    )?;
    let rows = stmt.query_map(rusqlite::params![server_id], |row| {
        Ok((
            row.get::<_, String>(0)?,
            SeriesProjection {
                last_modified: row.get(1)?,
                books_count: row.get(2)?,
                books_read_count: row.get(3)?,
                books_unread_count: row.get(4)?,
                books_in_progress_count: row.get(5)?,
                display_name: row.get(6)?,
                sort_name: row.get(7)?,
            },
        ))
    })?;
    rows.collect()
}

/// `collection_id → members` as currently mirrored.
fn local_collection_members(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<HashMap<String, Vec<String>>> {
    let mut stmt = conn
        .prepare("SELECT collection_id, series_id FROM collection_series WHERE server_id = ?1")?;
    let rows = stmt.query_map(rusqlite::params![server_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut members: HashMap<String, Vec<String>> = HashMap::new();
    for row in rows {
        let (collection_id, series_id) = row?;
        members.entry(collection_id).or_default().push(series_id);
    }
    for list in members.values_mut() {
        list.sort();
    }
    Ok(members)
}

/// `readlist_id → books` in mirrored order (a readlist is ordered).
fn local_readlist_books(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<HashMap<String, Vec<String>>> {
    let mut stmt = conn.prepare(
        "SELECT readlist_id, book_id FROM readlist_books WHERE server_id = ?1
         ORDER BY readlist_id, position",
    )?;
    let rows = stmt.query_map(rusqlite::params![server_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut books: HashMap<String, Vec<String>> = HashMap::new();
    for row in rows {
        let (readlist_id, book_id) = row?;
        books.entry(readlist_id).or_default().push(book_id);
    }
    Ok(books)
}

fn sorted(values: &[String]) -> Vec<String> {
    let mut sorted = values.to_vec();
    sorted.sort();
    sorted
}

fn classify(
    known: &HashMap<String, Option<String>>,
    id: &str,
    stamp: Option<&str>,
) -> (bool, bool) {
    match known.get(id) {
        None => (true, false),
        Some(known_stamp) => (false, known_stamp.as_deref() != stamp),
    }
}

/// Mutual exclusion lock per database and server to serialize Bootstrap and Reconcile.
pub fn sync_lock(db_path: &str, server_id: &str) -> Arc<Mutex<()>> {
    static LOCKS: OnceLock<std::sync::Mutex<HashMap<String, Arc<Mutex<()>>>>> = OnceLock::new();
    let map = LOCKS.get_or_init(|| std::sync::Mutex::new(HashMap::new()));
    let key = format!("{db_path}:{server_id}");
    let mut guard = map.lock().unwrap();
    guard
        .entry(key)
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

/// Reconcile one server against its current remote state.
pub async fn reconcile(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
    trigger: ReconcileTrigger,
) -> Result<ReconcileSummary> {
    let mutex = sync_lock(db_path, server_id);
    let _lock = mutex.lock().await;
    let mut summary = ReconcileSummary {
        server_id: server_id.to_string(),
        trigger: trigger.as_str().to_string(),
        ..Default::default()
    };

    reconcile_libraries(db_path, server_id, fetcher, &mut summary).await?;
    reconcile_series(db_path, server_id, fetcher, &mut summary).await?;
    reconcile_books(db_path, server_id, fetcher, &mut summary).await?;
    reconcile_collections(db_path, server_id, fetcher, &mut summary).await?;
    reconcile_readlists(db_path, server_id, fetcher, &mut summary).await?;
    reconcile_read_progress(db_path, server_id, fetcher, &mut summary).await?;

    summary.clean = !summary.changed_any();
    let conn = store::open(db_path).map_err(db_err)?;
    sync_state::touch_successful_sync(&conn, server_id).map_err(db_err)?;
    Ok(summary)
}

async fn reconcile_libraries(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
    summary: &mut ReconcileSummary,
) -> Result<()> {
    run_step(db_path, server_id, sync_state::ENTITY_LIBRARIES, async {
        let libraries = fetcher.libraries().await?;
        let remote: HashSet<String> = libraries.iter().map(|l| l.id.clone()).collect();
        let conn = store::open(db_path).map_err(db_err)?;
        summary.libraries_upserted =
            store::libraries::save_libraries_batch(&conn, server_id, &libraries).map_err(db_err)?;
        for id in &remote {
            prune::clear_tombstone(&conn, server_id, sync_state::ENTITY_LIBRARIES, id)
                .map_err(db_err)?;
        }
        summary.libraries_removed = prune::prune(
            &conn,
            server_id,
            sync_state::ENTITY_LIBRARIES,
            &remote,
            prune::CAUSE_RECONCILE,
        )
        .map_err(db_err)?
        .len();
        Ok(())
    })
    .await
}

async fn reconcile_series(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
    summary: &mut ReconcileSummary,
) -> Result<()> {
    run_step(db_path, server_id, sync_state::ENTITY_SERIES, async {
        let conn = store::open(db_path).map_err(db_err)?;
        let known = local_stamps(&conn, server_id, "series", "last_modified").map_err(db_err)?;
        let projected = local_series_projection(&conn, server_id).map_err(db_err)?;
        drop(conn);
        let mut remote = HashSet::new();
        let mut page = 0;
        loop {
            let resp = fetcher
                .series_page(&PageRequest::new(page, PAGE_SIZE))
                .await?;
            let last = resp.last;
            let conn = store::open(db_path).map_err(db_err)?;
            let ids: Vec<String> = resp
                .content
                .iter()
                .map(|series| series.id.clone())
                .collect();
            remote.extend(ids.iter().cloned());
            let mut dirty: Vec<crate::model::series::Series> = Vec::new();
            for series in &resp.content {
                let (added, stamp_changed) =
                    classify(&known, &series.id, series.last_modified.as_deref());
                let remote_projection = series_projection(series);
                let stored = projected.get(&series.id);
                let name_moved = match stored {
                    Some(stored) => {
                        stored.display_name != remote_projection.display_name
                            || stored.sort_name != remote_projection.sort_name
                    }
                    None => true,
                };
                // A name-only correction is a change to report, but a newly
                // added series is already counted as added — never twice.
                let changed = stamp_changed || (!added && name_moved);
                summary.series_added += added as usize;
                summary.series_changed += changed as usize;
                let projection_moved = match stored {
                    Some(stored) => *stored != remote_projection,
                    None => true,
                };
                if added || changed || projection_moved {
                    dirty.push(series.clone());
                }
            }
            if !dirty.is_empty() {
                summary.series_upserted +=
                    store::series::save_series_batch(&conn, server_id, &dirty).map_err(db_err)?;
            }
            // A re-appearing id is not deleted any more.
            prune::clear_tombstones(&conn, server_id, sync_state::ENTITY_SERIES, &ids)
                .map_err(db_err)?;
            summary.pages_swept += 1;
            drop(conn);
            if last {
                break;
            }
            page += 1;
        }
        // Prune only after a complete sweep.
        let conn = store::open(db_path).map_err(db_err)?;
        let removed = prune::prune(
            &conn,
            server_id,
            sync_state::ENTITY_SERIES,
            &remote,
            prune::CAUSE_RECONCILE,
        )
        .map_err(db_err)?;
        summary.series_removed = removed.len();
        summary.orphaned_covers.extend(removed.cover_paths);
        Ok(())
    })
    .await
}

async fn reconcile_books(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
    summary: &mut ReconcileSummary,
) -> Result<()> {
    let resume = cursor_for(db_path, server_id, sync_state::ENTITY_BOOKS)?;
    run_step(db_path, server_id, sync_state::ENTITY_BOOKS, async {
        let series_ids = mirrored_series_ids(db_path, server_id)?;
        let conn = store::open(db_path).map_err(db_err)?;
        let known = local_stamps(&conn, server_id, "books", "last_modified").map_err(db_err)?;
        let stored = local_progress(&conn, server_id).map_err(db_err)?;
        drop(conn);
        // series_id → remote book ids (the scoped prune input).
        let mut swept: HashMap<String, HashSet<String>> = HashMap::new();
        let mut index = 0usize;
        let mut resume_series: Option<String> = None;
        if let Some(cursor) = &resume {
            if let Some((series_id, _)) = crate::sync::full::parse_book_cursor(cursor) {
                // Series before the cursor: their books are already mirrored.
                while index < series_ids.len() && series_ids[index] < series_id {
                    let conn = store::open(db_path).map_err(db_err)?;
                    swept.insert(
                        series_ids[index].clone(),
                        HashSet::from_iter(
                            prune::local_book_ids_for_series(&conn, server_id, &series_ids[index])
                                .map_err(db_err)?,
                        ),
                    );
                    drop(conn);
                    index += 1;
                }
                resume_series = Some(series_id);
            }
        }
        while index < series_ids.len() {
            let series_id = series_ids[index].clone();
            let mut page = match (&resume_series, &resume) {
                (Some(resume_series), Some(cursor)) if *resume_series == series_id => {
                    crate::sync::full::parse_book_cursor(cursor)
                        .map(|(_, p)| p)
                        .unwrap_or(0)
                }
                _ => 0,
            };
            let entry = swept.entry(series_id.clone()).or_default();
            if page > 0 {
                // Mid-series resume: local rows for this series are the ids
                // committed before the interruption.
                let conn = store::open(db_path).map_err(db_err)?;
                entry.extend(
                    prune::local_book_ids_for_series(&conn, server_id, &series_id)
                        .map_err(db_err)?,
                );
                drop(conn);
            }
            loop {
                let resp = fetcher
                    .books_page(&series_id, &PageRequest::new(page, PAGE_SIZE))
                    .await?;
                let last = resp.last;
                let conn = store::open(db_path).map_err(db_err)?;
                let ids: Vec<String> = resp.content.iter().map(|book| book.id.clone()).collect();
                entry.extend(ids.iter().cloned());
                let mut dirty: Vec<crate::model::book::Book> = Vec::new();
                for book in &resp.content {
                    let (added, changed) =
                        classify(&known, &book.id, book.last_modified.as_deref());
                    summary.books_added += added as usize;
                    summary.books_changed += changed as usize;
                    if needs_write(
                        added,
                        changed,
                        book.read_progress.as_ref(),
                        stored.get(&book.id),
                    ) {
                        dirty.push(book.clone());
                    }
                }
                // A converged library costs a read sweep, not 20k redundant
                // upserts (each of which also rewrites its FTS row).
                if !dirty.is_empty() {
                    summary.books_upserted +=
                        store::books::save_books_batch(&conn, server_id, &dirty).map_err(db_err)?;
                }
                prune::clear_tombstones(&conn, server_id, sync_state::ENTITY_BOOKS, &ids)
                    .map_err(db_err)?;
                summary.pages_swept += 1;
                if !last {
                    sync_state::checkpoint_entity(
                        &conn,
                        server_id,
                        sync_state::ENTITY_BOOKS,
                        &crate::sync::full::book_cursor(&series_id, page + 1),
                    )
                    .map_err(db_err)?;
                }
                drop(conn);
                if last {
                    break;
                }
                page += 1;
            }
            index += 1;
            // Same series-boundary checkpoint as Bootstrap: an interrupted
            // sweep resumes at the next series instead of restarting.
            if let Some(next) = series_ids.get(index) {
                let conn = store::open(db_path).map_err(db_err)?;
                sync_state::checkpoint_entity(
                    &conn,
                    server_id,
                    sync_state::ENTITY_BOOKS,
                    &crate::sync::full::book_cursor(next, 0),
                )
                .map_err(db_err)?;
            }
        }
        let conn = store::open(db_path).map_err(db_err)?;
        let pruned =
            prune::prune_books_for_swept_series(&conn, server_id, &swept, prune::CAUSE_RECONCILE)
                .map_err(db_err)?;
        summary.books_removed = pruned.len();
        summary.orphaned_covers.extend(pruned.cover_paths);
        Ok(())
    })
    .await
}

async fn reconcile_collections(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
    summary: &mut ReconcileSummary,
) -> Result<()> {
    run_step(db_path, server_id, sync_state::ENTITY_COLLECTIONS, async {
        let conn = store::open(db_path).map_err(db_err)?;
        let known =
            local_stamps(&conn, server_id, "collections", "last_modified_date").map_err(db_err)?;
        let members = local_collection_members(&conn, server_id).map_err(db_err)?;
        drop(conn);
        let mut remote = HashSet::new();
        let mut page = 0;
        loop {
            let resp = fetcher
                .collections_page(&PageRequest::new(page, PAGE_SIZE))
                .await?;
            let last = resp.last;
            let conn = store::open(db_path).map_err(db_err)?;
            let ids: Vec<String> = resp.content.iter().map(|c| c.id.clone()).collect();
            remote.extend(ids.iter().cloned());
            let mut dirty: Vec<crate::model::collection::Collection> = Vec::new();
            for collection in &resp.content {
                let (added, changed) = classify(
                    &known,
                    &collection.id,
                    collection.last_modified_date.as_deref(),
                );
                summary.collections_added += added as usize;
                summary.collections_changed += changed as usize;
                // Members live in their own table and can be edited without a new
                // lastModifiedDate, so they have to be compared too.
                let members_moved = match members.get(&collection.id) {
                    Some(stored) => *stored != sorted(&collection.series_ids),
                    None => !collection.series_ids.is_empty(),
                };
                if added || changed || members_moved {
                    dirty.push(collection.clone());
                }
            }
            if !dirty.is_empty() {
                summary.collections_upserted +=
                    store::collections::save_collections_batch(&conn, server_id, &dirty)
                        .map_err(db_err)?;
            }
            prune::clear_tombstones(&conn, server_id, sync_state::ENTITY_COLLECTIONS, &ids)
                .map_err(db_err)?;
            summary.pages_swept += 1;
            drop(conn);
            if last {
                break;
            }
            page += 1;
        }
        let conn = store::open(db_path).map_err(db_err)?;
        summary.collections_removed = prune::prune(
            &conn,
            server_id,
            sync_state::ENTITY_COLLECTIONS,
            &remote,
            prune::CAUSE_RECONCILE,
        )
        .map_err(db_err)?
        .len();
        Ok(())
    })
    .await
}

async fn reconcile_readlists(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
    summary: &mut ReconcileSummary,
) -> Result<()> {
    run_step(db_path, server_id, sync_state::ENTITY_READLISTS, async {
        let conn = store::open(db_path).map_err(db_err)?;
        let known =
            local_stamps(&conn, server_id, "readlists", "last_modified_date").map_err(db_err)?;
        let stored_books = local_readlist_books(&conn, server_id).map_err(db_err)?;
        drop(conn);
        let mut remote = HashSet::new();
        let mut page = 0;
        loop {
            let resp = fetcher
                .readlists_page(&PageRequest::new(page, PAGE_SIZE))
                .await?;
            let last = resp.last;
            let conn = store::open(db_path).map_err(db_err)?;
            let ids: Vec<String> = resp.content.iter().map(|r| r.id.clone()).collect();
            remote.extend(ids.iter().cloned());
            let mut dirty: Vec<crate::model::readlist::ReadList> = Vec::new();
            for readlist in &resp.content {
                let (added, changed) =
                    classify(&known, &readlist.id, readlist.last_modified_date.as_deref());
                summary.readlists_added += added as usize;
                summary.readlists_changed += changed as usize;
                let books_moved = match stored_books.get(&readlist.id) {
                    Some(stored) => *stored != readlist.book_ids,
                    None => !readlist.book_ids.is_empty(),
                };
                if added || changed || books_moved {
                    dirty.push(readlist.clone());
                }
            }
            if !dirty.is_empty() {
                summary.readlists_upserted +=
                    store::readlists::save_readlists_batch(&conn, server_id, &dirty)
                        .map_err(db_err)?;
            }
            prune::clear_tombstones(&conn, server_id, sync_state::ENTITY_READLISTS, &ids)
                .map_err(db_err)?;
            summary.pages_swept += 1;
            drop(conn);
            if last {
                break;
            }
            page += 1;
        }
        let conn = store::open(db_path).map_err(db_err)?;
        summary.readlists_removed = prune::prune(
            &conn,
            server_id,
            sync_state::ENTITY_READLISTS,
            &remote,
            prune::CAUSE_RECONCILE,
        )
        .map_err(db_err)?
        .len();
        Ok(())
    })
    .await
}

async fn reconcile_read_progress(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
    summary: &mut ReconcileSummary,
) -> Result<()> {
    run_step(
        db_path,
        server_id,
        sync_state::ENTITY_READ_PROGRESS,
        async {
            let mut page = match cursor_for(db_path, server_id, sync_state::ENTITY_READ_PROGRESS)? {
                Some(cursor) => parse_page(&cursor),
                None => 0,
            };
            loop {
                let resp = fetcher
                    .on_deck_page(&PageRequest::new(page, PAGE_SIZE))
                    .await?;
                let last = resp.last;
                let conn = store::open(db_path).map_err(db_err)?;
                for book in &resp.content {
                    if let Some(progress) = &book.read_progress {
                        store::read_progress::upsert_synced_read_progress(
                            &conn,
                            server_id,
                            &book.id,
                            progress.page,
                            progress.completed,
                            progress.last_modified.clone(),
                        )
                        .map_err(db_err)?;
                        summary.read_progress += 1;
                    }
                }
                summary.pages_swept += 1;
                if !last {
                    sync_state::checkpoint_entity(
                        &conn,
                        server_id,
                        sync_state::ENTITY_READ_PROGRESS,
                        &page_cursor(page + 1),
                    )
                    .map_err(db_err)?;
                }
                drop(conn);
                if last {
                    return Ok(());
                }
                page += 1;
            }
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;
    use crate::sync::full::{full_sync_from, FixtureLibraryFetcher, StartAt};
    use crate::sync::scenario::server_from_snapshot;
    use chrono::Duration;
    use serde_json::json;

    /// Multi-server isolation at the sync-engine level: two servers holding the
    /// *same* remote ids (which is exactly what the shared fixtures produce), one
    /// of them losing a series. The other server's mirrored rows, progress,
    /// covers, search index and sync bookkeeping must not move at all.
    #[tokio::test]
    async fn a_delete_for_one_server_never_touches_another() {
        use crate::store::thumbnails;
        use crate::sync::full::{full_sync_from, FixtureLibraryFetcher, StartAt};
        use crate::sync::scenario::server_from_snapshot;

        let db = temp_db();
        for server in ["A", "B"] {
            full_sync_from(&db, server, &FixtureLibraryFetcher {}, StartAt::Fresh)
                .await
                .unwrap();
        }
        {
            let conn = crate::store::open(&db).unwrap();
            crate::store::read_progress::upsert_local_read_progress(
                &conn, "B", "book-1-1", 21, false,
            )
            .unwrap();
            thumbnails::record_thumbnail(
                &conn,
                "B",
                "series-1",
                "series",
                "/tmp/other-server-cover.png",
                5,
            )
            .unwrap();
        }

        // Server A drops series-3 (and its books + membership); B is unchanged.
        let scenario: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../specs/contracts/fixtures/sync/scenario-reconcile.json"
        ))
        .unwrap();
        let mut snapshot = scenario["snapshots"][0].clone();
        snapshot["series"][0]
            .as_array_mut()
            .unwrap()
            .retain(|item| item["id"] != "series-3");
        let books = snapshot["books"].as_object_mut().unwrap();
        books.remove("series-3");
        for collection in snapshot["collections"][0].as_array_mut().unwrap() {
            if let Some(ids) = collection["seriesIds"].as_array_mut() {
                ids.retain(|id| id != "series-3");
            }
        }
        let server = server_from_snapshot(&snapshot.to_string()).unwrap();
        let summary = reconcile(&db, "A", &server, ReconcileTrigger::ManualRefresh)
            .await
            .unwrap();
        assert_eq!(summary.series_removed, 1, "A mirrored the deletion");

        let conn = crate::store::open(&db).unwrap();
        let count = |sql: &str, server: &str| -> i64 {
            conn.query_row(sql, rusqlite::params![server], |row| row.get(0))
                .unwrap()
        };
        assert_eq!(
            count("SELECT COUNT(*) FROM series WHERE server_id = ?1", "A"),
            2
        );
        assert_eq!(
            count("SELECT COUNT(*) FROM books WHERE server_id = ?1", "A"),
            5
        );

        // B: still the complete library, with its own progress and cover.
        assert_eq!(
            count("SELECT COUNT(*) FROM series WHERE server_id = ?1", "B"),
            3,
            "another server's series must survive"
        );
        assert_eq!(
            count("SELECT COUNT(*) FROM books WHERE server_id = ?1", "B"),
            7
        );
        assert_eq!(
            count(
                "SELECT COUNT(*) FROM series_metadata WHERE server_id = ?1",
                "B"
            ),
            3
        );
        assert_eq!(
            count(
                "SELECT COUNT(*) FROM collection_series WHERE server_id = ?1",
                "B"
            ),
            3
        );
        assert_eq!(
            count("SELECT COUNT(*) FROM readlists WHERE server_id = ?1", "B"),
            2
        );
        assert_eq!(
            count(
                "SELECT COUNT(*) FROM readlist_books WHERE server_id = ?1",
                "B"
            ),
            5
        );
        assert_eq!(
            count(
                "SELECT page FROM read_progress WHERE server_id = ?1 AND book_id = 'book-1-1'",
                "B"
            ),
            21,
            "B's offline progress must not be swept away"
        );
        assert_eq!(
            count("SELECT COUNT(*) FROM thumbnails WHERE server_id = ?1", "B"),
            1,
            "B's cover record must survive"
        );
        assert_eq!(
            count("SELECT COUNT(*) FROM series_fts WHERE server_id = ?1", "B"),
            3,
            "B's search index must survive"
        );
        assert_eq!(
            count("SELECT COUNT(*) FROM book_fts WHERE server_id = ?1", "B"),
            7
        );

        // Tombstones and sync_state are per server too.
        assert_eq!(
            count(
                "SELECT COUNT(*) FROM deleted_entities WHERE server_id = ?1",
                "A"
            ),
            3,
            "series-3 plus its two books; none of them belong to B"
        );
        assert_eq!(
            count(
                "SELECT COUNT(*) FROM deleted_entities WHERE server_id = ?1",
                "B"
            ),
            0
        );
        let b_states = sync_state::list_entity_states(&conn, "B").unwrap();
        assert!(
            b_states.iter().all(|state| state.sync_cursor.is_none()),
            "B's cursors belong to B's own sweeps"
        );
        assert!(b_states
            .iter()
            .all(|state| state.sync_status == sync_state::STATUS_IDLE));
        assert_eq!(
            conn.query_row::<i64, _, _>(
                "SELECT COUNT(*) FROM pending_mutations WHERE server_id = ?1",
                rusqlite::params!["B"],
                |row| row.get(0)
            )
            .unwrap(),
            1,
            "B's queued upload is untouched"
        );
        drop(conn);
        cleanup(&db);
    }
    fn temp_db() -> String {
        let dir = std::env::temp_dir().join(format!("komga_reconcile_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("comic.sqlite").to_string_lossy().into_owned()
    }

    fn cleanup(db: &str) {
        let _ = std::fs::remove_dir_all(std::path::Path::new(db).parent().unwrap());
    }

    fn state_with_last_sync(age_secs: i64) -> Connection {
        let conn = open_in_memory().unwrap();
        sync_state::touch_successful_sync(&conn, "srv-1").unwrap();
        // Backdate the rollup stamp so the throttle window is deterministic.
        let stamp = (Utc::now() - Duration::seconds(age_secs))
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        conn.execute(
            "UPDATE sync_state SET last_sync_at = ?1 WHERE server_id = ?2 AND entity_type = ?3",
            rusqlite::params![stamp, "srv-1", sync_state::ENTITY_FULL],
        )
        .unwrap();
        conn
    }

    #[test]
    fn never_synced_always_runs() {
        let conn = open_in_memory().unwrap();
        for trigger in [
            ReconcileTrigger::AppLaunch,
            ReconcileTrigger::DidBecomeActive,
            ReconcileTrigger::ManualRefresh,
        ] {
            assert!(
                should_reconcile(&conn, "srv-1", trigger, Utc::now()).unwrap(),
                "{trigger:?} must run when nothing has ever synced"
            );
        }
    }

    #[test]
    fn background_triggers_are_throttled() {
        let conn = state_with_last_sync(10);
        assert!(
            !should_reconcile(&conn, "srv-1", ReconcileTrigger::AppLaunch, Utc::now()).unwrap()
        );
        assert!(!should_reconcile(
            &conn,
            "srv-1",
            ReconcileTrigger::DidBecomeActive,
            Utc::now()
        )
        .unwrap());
        // Past the window they run again.
        let conn = state_with_last_sync(MIN_RECONCILE_INTERVAL_SECS + 5);
        assert!(should_reconcile(&conn, "srv-1", ReconcileTrigger::AppLaunch, Utc::now()).unwrap());
    }

    #[test]
    fn explicit_triggers_bypass_the_throttle() {
        let conn = state_with_last_sync(0);
        for trigger in [
            ReconcileTrigger::ManualRefresh,
            ReconcileTrigger::NetworkRecovered,
            ReconcileTrigger::SseReconnected,
        ] {
            assert!(
                should_reconcile(&conn, "srv-1", trigger, Utc::now()).unwrap(),
                "{trigger:?} must always sweep: correctness cannot wait out a window"
            );
        }
    }

    #[test]
    fn unparseable_stamp_re_syncs_rather_than_staying_stale() {
        let conn = state_with_last_sync(5);
        conn.execute(
            "UPDATE sync_state SET last_sync_at = 'not-a-timestamp'
             WHERE server_id = 'srv-1' AND entity_type = 'full'",
            [],
        )
        .unwrap();
        assert!(should_reconcile(&conn, "srv-1", ReconcileTrigger::AppLaunch, Utc::now()).unwrap());
    }

    #[test]
    fn trigger_names_round_trip() {
        for (name, trigger) in [
            ("app_launch", ReconcileTrigger::AppLaunch),
            ("did_become_active", ReconcileTrigger::DidBecomeActive),
            ("network_recovered", ReconcileTrigger::NetworkRecovered),
            ("sse_reconnected", ReconcileTrigger::SseReconnected),
            ("manual_refresh", ReconcileTrigger::ManualRefresh),
        ] {
            assert_eq!(ReconcileTrigger::parse(name), trigger);
            assert_eq!(trigger.as_str(), name);
        }
        // Unknown names land on the always-run choice.
        assert_eq!(
            ReconcileTrigger::parse("?"),
            ReconcileTrigger::ManualRefresh
        );
    }

    /// The whole point of writing incrementally: once the mirror has converged,
    /// a sweep must not rewrite a single row.
    #[tokio::test]
    async fn a_sweep_of_a_converged_library_writes_nothing() {
        let db = temp_db();
        full_sync_from(&db, "srv", &FixtureLibraryFetcher {}, StartAt::Fresh)
            .await
            .unwrap();
        let summary = reconcile(
            &db,
            "srv",
            &FixtureLibraryFetcher {},
            ReconcileTrigger::ManualRefresh,
        )
        .await
        .unwrap();
        assert_eq!(
            summary.series_upserted, 0,
            "no series row should be rewritten"
        );
        assert_eq!(summary.books_upserted, 0, "no book row should be rewritten");
        assert_eq!(summary.collections_upserted, 0);
        assert_eq!(summary.readlists_upserted, 0);
        assert_eq!(
            summary.pages_swept, 7,
            "1 series page + 3 book pages + collections + readlists + on-deck"
        );
        assert!(summary.clean, "{summary:?}");
        cleanup(&db);
    }

    /// A remote read-progress change does *not* bump the book's own
    /// `lastModified`, so skipping "unchanged" books has to compare progress as
    /// well — otherwise reading on another device never reaches this one.
    #[tokio::test]
    async fn a_progress_only_change_still_lands() {
        let fixture = |name: &str| -> serde_json::Value {
            let text = match name {
                "libraries" => {
                    include_str!("../../../../specs/contracts/fixtures/library/libraries.json")
                }
                "series" => {
                    include_str!("../../../../specs/contracts/fixtures/library/series-page.json")
                }
                "books" => {
                    include_str!(
                        "../../../../specs/contracts/fixtures/library/books-by-series.json"
                    )
                }
                "collections" => {
                    include_str!(
                        "../../../../specs/contracts/fixtures/library/collections-page.json"
                    )
                }
                "readlists" => {
                    include_str!("../../../../specs/contracts/fixtures/library/readlists-page.json")
                }
                _ => {
                    include_str!("../../../../specs/contracts/fixtures/library/ondeck-page.json")
                }
            };
            serde_json::from_str(text).unwrap()
        };
        let content = |name: &str| fixture(name)["content"].clone();

        // The library fixture maps seriesId -> Spring page object; the
        // snapshot shape wants seriesId -> [page].
        let mut books = serde_json::Map::new();
        let raw: serde_json::Value = fixture("books");
        for (series_id, page) in raw.as_object().unwrap() {
            books.insert(series_id.clone(), json!([page["content"].clone()]));
        }
        // book-1-3 carries no progress at all; the server now reports page 7
        // while leaving the book's own lastModified untouched.
        for book in books["series-1"][0].as_array_mut().unwrap() {
            if book["id"] == "book-1-3" {
                book["readProgress"] = json!({
                    "page": 7,
                    "completed": false,
                    "lastModified": "2025-05-05T00:00:00Z",
                });
            }
        }
        let snapshot = serde_json::json!({
            "id": "progress-only",
            "libraries": fixture("libraries"),
            "series": [content("series")],
            "books": books,
            "collections": [content("collections")],
            "readlists": [content("readlists")],
            "onDeck": [content("on_deck")],
        });

        let db = temp_db();
        full_sync_from(&db, "srv", &FixtureLibraryFetcher {}, StartAt::Fresh)
            .await
            .unwrap();
        let server = server_from_snapshot(&snapshot.to_string()).unwrap();
        let summary = reconcile(&db, "srv", &server, ReconcileTrigger::ManualRefresh)
            .await
            .unwrap();
        assert_eq!(
            summary.books_upserted, 1,
            "only the book whose progress moved should be written"
        );

        let conn = crate::store::open(&db).unwrap();
        let stored: Option<(Option<i64>, i64)> = conn
            .query_row(
                "SELECT page, completed FROM read_progress WHERE server_id = ?1 AND book_id = ?2",
                rusqlite::params!["srv", "book-1-3"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .ok();
        assert_eq!(
            stored,
            Some((Some(7), 0)),
            "the other device's page 7 must reach this one"
        );
        drop(conn);
        cleanup(&db);
    }

    /// Fixture-backed fetcher whose series sweep fails on demand, modelling a
    /// network drop in the middle of a reconciliation.
    struct FlakySeriesFetcher {
        inner: FixtureLibraryFetcher,
        fail_series: bool,
    }

    impl crate::sync::bootstrap::SeriesFetcher for FlakySeriesFetcher {
        async fn series_page(
            &self,
            request: &crate::api::series::PageRequest,
        ) -> crate::api::error::Result<crate::model::series::SeriesPage> {
            if self.fail_series {
                return Err(ApiError::Network);
            }
            crate::sync::bootstrap::SeriesFetcher::series_page(&self.inner, request).await
        }
    }

    impl crate::api::server::LibrariesFetcher for FlakySeriesFetcher {
        async fn libraries(&self) -> crate::api::error::Result<Vec<crate::model::server::Library>> {
            crate::api::server::LibrariesFetcher::libraries(&self.inner).await
        }
    }

    impl crate::api::book::BookFetcher for FlakySeriesFetcher {
        async fn books_page(
            &self,
            series_id: &str,
            request: &crate::api::series::PageRequest,
        ) -> crate::api::error::Result<crate::model::book::BookPage> {
            crate::api::book::BookFetcher::books_page(&self.inner, series_id, request).await
        }

        async fn on_deck_page(
            &self,
            request: &crate::api::series::PageRequest,
        ) -> crate::api::error::Result<crate::model::book::BookPage> {
            crate::api::book::BookFetcher::on_deck_page(&self.inner, request).await
        }
    }

    impl crate::api::collection::CollectionFetcher for FlakySeriesFetcher {
        async fn collections_page(
            &self,
            request: &crate::api::series::PageRequest,
        ) -> crate::api::error::Result<crate::model::collection::CollectionPage> {
            crate::api::collection::CollectionFetcher::collections_page(&self.inner, request).await
        }
    }

    impl crate::api::readlist::ReadListFetcher for FlakySeriesFetcher {
        async fn readlists_page(
            &self,
            request: &crate::api::series::PageRequest,
        ) -> crate::api::error::Result<crate::model::readlist::ReadListPage> {
            crate::api::readlist::ReadListFetcher::readlists_page(&self.inner, request).await
        }
    }

    /// Overwrite one mirrored series with the pre-fix state: the folder name
    /// used as both the display and sort name, in the row and in the index.
    fn corrupt_series_name(db: &str, server_id: &str, remote_id: &str) {
        let conn = crate::store::open(db).unwrap();
        conn.execute(
            "UPDATE series SET name = 'cbz', sort_name = 'cbz'
             WHERE server_id = ?1 AND remote_id = ?2",
            rusqlite::params![server_id, remote_id],
        )
        .unwrap();
        conn.execute(
            "UPDATE series_fts SET name = 'cbz', sort_name = 'cbz'
             WHERE rowid = (SELECT fts_rowid FROM series WHERE server_id = ?1 AND remote_id = ?2)",
            rusqlite::params![server_id, remote_id],
        )
        .unwrap();
    }

    fn stored_name(db: &str, server_id: &str, remote_id: &str) -> String {
        let conn = crate::store::open(db).unwrap();
        conn.query_row(
            "SELECT name FROM series WHERE server_id = ?1 AND remote_id = ?2",
            rusqlite::params![server_id, remote_id],
            |row| row.get(0),
        )
        .unwrap()
    }

    /// T2: an existing mirror holds the folder name (`cbz`) while the remote
    /// stamp and counters are unchanged. One sweep must repair the row *and*
    /// the search index and report the correction as a change; the next sweep
    /// must not rewrite anything.
    #[tokio::test]
    async fn a_name_only_change_in_the_mirror_is_healed_by_one_sweep() {
        let db = temp_db();
        full_sync_from(&db, "srv", &FixtureLibraryFetcher {}, StartAt::Fresh)
            .await
            .unwrap();
        corrupt_series_name(&db, "srv", "series-1");

        let summary = reconcile(
            &db,
            "srv",
            &FixtureLibraryFetcher {},
            ReconcileTrigger::ManualRefresh,
        )
        .await
        .unwrap();
        assert_eq!(
            summary.series_upserted, 1,
            "only the corrupted series should be rewritten"
        );
        assert_eq!(
            summary.series_changed, 1,
            "the name correction counts as one change"
        );
        assert!(!summary.clean, "{summary:?}");

        assert_eq!(stored_name(&db, "srv", "series-1"), "One Piece");
        {
            let conn = crate::store::open(&db).unwrap();
            let hits = |term: &str| -> i64 {
                conn.query_row(
                    "SELECT COUNT(*) FROM series_fts WHERE series_fts MATCH ?1 AND server_id = 'srv'",
                    rusqlite::params![crate::store::fts::fts_match_query(term)],
                    |row| row.get(0),
                )
                .unwrap()
            };
            assert_eq!(hits("piece"), 1, "the official title is searchable again");
            assert_eq!(hits("cbz"), 0, "the folder name must leave the index");
        }

        // Converged: the second sweep is a pure read.
        let summary = reconcile(
            &db,
            "srv",
            &FixtureLibraryFetcher {},
            ReconcileTrigger::ManualRefresh,
        )
        .await
        .unwrap();
        assert_eq!(summary.series_upserted, 0, "no redundant rewrite");
        assert_eq!(summary.series_changed, 0);
        assert!(summary.clean, "{summary:?}");
        cleanup(&db);
    }

    /// The repair is scoped to one server: another profile's mirror keeps its
    /// own (even wrong) rows until that server is reconciled itself.
    #[tokio::test]
    async fn a_name_fix_for_one_server_leaves_another_alone() {
        let db = temp_db();
        for server in ["A", "B"] {
            full_sync_from(&db, server, &FixtureLibraryFetcher {}, StartAt::Fresh)
                .await
                .unwrap();
            corrupt_series_name(&db, server, "series-1");
        }

        reconcile(
            &db,
            "A",
            &FixtureLibraryFetcher {},
            ReconcileTrigger::ManualRefresh,
        )
        .await
        .unwrap();

        assert_eq!(stored_name(&db, "A", "series-1"), "One Piece");
        assert_eq!(
            stored_name(&db, "B", "series-1"),
            "cbz",
            "another server's mirror must not be touched"
        );
        cleanup(&db);
    }

    /// A failed sweep never guesses: the wrong local name survives, and the
    /// first sweep that succeeds still heals it.
    #[tokio::test]
    async fn a_failed_sweep_keeps_the_old_name_and_the_next_one_repairs_it() {
        let db = temp_db();
        full_sync_from(&db, "srv", &FixtureLibraryFetcher {}, StartAt::Fresh)
            .await
            .unwrap();
        corrupt_series_name(&db, "srv", "series-1");

        let flaky = FlakySeriesFetcher {
            inner: FixtureLibraryFetcher {},
            fail_series: true,
        };
        assert!(
            reconcile(&db, "srv", &flaky, ReconcileTrigger::ManualRefresh)
                .await
                .is_err(),
            "the transport failure must surface"
        );
        assert_eq!(
            stored_name(&db, "srv", "series-1"),
            "cbz",
            "a failed sweep must not invent a name"
        );

        let summary = reconcile(
            &db,
            "srv",
            &FixtureLibraryFetcher {},
            ReconcileTrigger::ManualRefresh,
        )
        .await
        .unwrap();
        assert_eq!(summary.series_upserted, 1);
        assert_eq!(stored_name(&db, "srv", "series-1"), "One Piece");
        cleanup(&db);
    }
}
