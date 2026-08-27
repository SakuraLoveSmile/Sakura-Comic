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

/// Reconcile one server against its current remote state.
pub async fn reconcile(
    db_path: &str,
    server_id: &str,
    fetcher: &(impl LibraryFetcher + Sync),
    trigger: ReconcileTrigger,
) -> Result<ReconcileSummary> {
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
    let seeded: HashSet<String> = match cursor_for(db_path, server_id, sync_state::ENTITY_SERIES)? {
        // Resuming: pages before the cursor were already committed locally.
        Some(_) => crate::sync::full::mirrored_ids(db_path, server_id, sync_state::ENTITY_SERIES)?,
        None => HashSet::new(),
    };
    run_step(db_path, server_id, sync_state::ENTITY_SERIES, async {
        let conn = store::open(db_path).map_err(db_err)?;
        let known = local_stamps(&conn, server_id, "series", "last_modified").map_err(db_err)?;
        drop(conn);
        let mut remote = seeded.clone();
        let mut page = match cursor_for(db_path, server_id, sync_state::ENTITY_SERIES)? {
            Some(cursor) => parse_page(&cursor),
            None => 0,
        };
        loop {
            let resp = fetcher
                .series_page(&PageRequest::new(page, PAGE_SIZE))
                .await?;
            let last = resp.last;
            let conn = store::open(db_path).map_err(db_err)?;
            for series in &resp.content {
                let (added, changed) =
                    classify(&known, &series.id, series.last_modified.as_deref());
                summary.series_added += added as usize;
                summary.series_changed += changed as usize;
                // A re-appearing id is not deleted any more.
                prune::clear_tombstone(&conn, server_id, sync_state::ENTITY_SERIES, &series.id)
                    .map_err(db_err)?;
                remote.insert(series.id.clone());
            }
            summary.series_upserted +=
                store::series::save_series_batch(&conn, server_id, &resp.content)
                    .map_err(db_err)?;
            summary.pages_swept += 1;
            if !last {
                sync_state::checkpoint_entity(
                    &conn,
                    server_id,
                    sync_state::ENTITY_SERIES,
                    &page_cursor(page + 1),
                )
                .map_err(db_err)?;
            }
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
                for book in &resp.content {
                    let (added, changed) =
                        classify(&known, &book.id, book.last_modified.as_deref());
                    summary.books_added += added as usize;
                    summary.books_changed += changed as usize;
                    prune::clear_tombstone(&conn, server_id, sync_state::ENTITY_BOOKS, &book.id)
                        .map_err(db_err)?;
                    entry.insert(book.id.clone());
                }
                summary.books_upserted +=
                    store::books::save_books_batch(&conn, server_id, &resp.content)
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
    let seeded: HashSet<String> =
        match cursor_for(db_path, server_id, sync_state::ENTITY_COLLECTIONS)? {
            Some(_) => {
                crate::sync::full::mirrored_ids(db_path, server_id, sync_state::ENTITY_COLLECTIONS)?
            }
            None => HashSet::new(),
        };
    run_step(db_path, server_id, sync_state::ENTITY_COLLECTIONS, async {
        let conn = store::open(db_path).map_err(db_err)?;
        let known =
            local_stamps(&conn, server_id, "collections", "last_modified_date").map_err(db_err)?;
        drop(conn);
        let mut remote = seeded.clone();
        let mut page = match cursor_for(db_path, server_id, sync_state::ENTITY_COLLECTIONS)? {
            Some(cursor) => parse_page(&cursor),
            None => 0,
        };
        loop {
            let resp = fetcher
                .collections_page(&PageRequest::new(page, PAGE_SIZE))
                .await?;
            let last = resp.last;
            let conn = store::open(db_path).map_err(db_err)?;
            for collection in &resp.content {
                let (added, changed) = classify(
                    &known,
                    &collection.id,
                    collection.last_modified_date.as_deref(),
                );
                summary.collections_added += added as usize;
                summary.collections_changed += changed as usize;
                remote.insert(collection.id.clone());
                prune::clear_tombstone(
                    &conn,
                    server_id,
                    sync_state::ENTITY_COLLECTIONS,
                    &collection.id,
                )
                .map_err(db_err)?;
            }
            summary.collections_upserted +=
                store::collections::save_collections_batch(&conn, server_id, &resp.content)
                    .map_err(db_err)?;
            summary.pages_swept += 1;
            if !last {
                sync_state::checkpoint_entity(
                    &conn,
                    server_id,
                    sync_state::ENTITY_COLLECTIONS,
                    &page_cursor(page + 1),
                )
                .map_err(db_err)?;
            }
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
    let seeded: HashSet<String> =
        match cursor_for(db_path, server_id, sync_state::ENTITY_READLISTS)? {
            Some(_) => {
                crate::sync::full::mirrored_ids(db_path, server_id, sync_state::ENTITY_READLISTS)?
            }
            None => HashSet::new(),
        };
    run_step(db_path, server_id, sync_state::ENTITY_READLISTS, async {
        let conn = store::open(db_path).map_err(db_err)?;
        let known =
            local_stamps(&conn, server_id, "readlists", "last_modified_date").map_err(db_err)?;
        drop(conn);
        let mut remote = seeded.clone();
        let mut page = match cursor_for(db_path, server_id, sync_state::ENTITY_READLISTS)? {
            Some(cursor) => parse_page(&cursor),
            None => 0,
        };
        loop {
            let resp = fetcher
                .readlists_page(&PageRequest::new(page, PAGE_SIZE))
                .await?;
            let last = resp.last;
            let conn = store::open(db_path).map_err(db_err)?;
            for readlist in &resp.content {
                let (added, changed) =
                    classify(&known, &readlist.id, readlist.last_modified_date.as_deref());
                summary.readlists_added += added as usize;
                summary.readlists_changed += changed as usize;
                remote.insert(readlist.id.clone());
                prune::clear_tombstone(
                    &conn,
                    server_id,
                    sync_state::ENTITY_READLISTS,
                    &readlist.id,
                )
                .map_err(db_err)?;
            }
            summary.readlists_upserted +=
                store::readlists::save_readlists_batch(&conn, server_id, &resp.content)
                    .map_err(db_err)?;
            summary.pages_swept += 1;
            if !last {
                sync_state::checkpoint_entity(
                    &conn,
                    server_id,
                    sync_state::ENTITY_READLISTS,
                    &page_cursor(page + 1),
                )
                .map_err(db_err)?;
            }
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
