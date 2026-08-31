//! Sync state — one row per `(server_id, entity_type)`.
//!
//! This is the Stage 5 sync-state record: `serverId`, `entityType`,
//! `lastSyncAt` (`last_sync_at`), `syncCursor` (`sync_cursor`) and
//! `syncStatus` (`sync_status`). Bootstrap writes a cursor checkpoint after
//! every page it has committed, so an interrupted run resumes from that page
//! instead of re-downloading the library; a failure keeps the cursor and
//! flags `error` so the next attempt can recover.
//!
//! Status vocabulary: `idle` (nothing running / step complete) | `syncing`
//! (in flight, or interrupted with a resume point) | `error` (last attempt
//! failed; the cursor is still usable). RFC 3339 timestamps with millisecond
//! precision match the Swift store.

use rusqlite::{params, Connection, Row};
use serde::{Deserialize, Serialize};

pub const STATUS_IDLE: &str = "idle";
pub const STATUS_SYNCING: &str = "syncing";
pub const STATUS_ERROR: &str = "error";

/// Entity types tracked in `sync_state`. `full` is the server-level rollup
/// written when a whole mirror run completes.
pub const ENTITY_LIBRARIES: &str = "libraries";
pub const ENTITY_SERIES: &str = "series";
pub const ENTITY_BOOKS: &str = "books";
pub const ENTITY_COLLECTIONS: &str = "collections";
pub const ENTITY_READLISTS: &str = "readlists";
pub const ENTITY_READ_PROGRESS: &str = "read_progress";
pub const ENTITY_FULL: &str = "full";

/// Bootstrap order from the initial-sync contract
/// (`specs/contracts/initial-sync/README.md`).
pub const BOOTSTRAP_ORDER: &[&str] = &[
    ENTITY_LIBRARIES,
    ENTITY_SERIES,
    ENTITY_BOOKS,
    ENTITY_COLLECTIONS,
    ENTITY_READLISTS,
    ENTITY_READ_PROGRESS,
];

/// One `sync_state` row.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EntitySyncState {
    pub server_id: String,
    pub entity_type: String,
    pub last_sync_at: Option<String>,
    pub sync_cursor: Option<String>,
    pub sync_status: String,
    pub last_error: Option<String>,
    pub last_full_sync: Option<String>,
    pub last_successful_sync: Option<String>,
}

/// Server-level rollup view (the `full` row) — kept for the UI surfaces that
/// only care about "last synced".
pub type SyncStateRow = EntitySyncState;

fn row_to_state(row: &Row) -> rusqlite::Result<EntitySyncState> {
    Ok(EntitySyncState {
        server_id: row.get("server_id")?,
        entity_type: row.get("entity_type")?,
        last_sync_at: row.get("last_sync_at")?,
        sync_cursor: row.get("sync_cursor")?,
        sync_status: row.get("sync_status")?,
        last_error: row.get("last_error")?,
        last_full_sync: row.get("last_full_sync")?,
        last_successful_sync: row.get("last_successful_sync")?,
    })
}

/// RFC 3339 with millisecond precision (matches the Swift store).
fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

pub fn get_entity_state(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
) -> rusqlite::Result<Option<EntitySyncState>> {
    let mut stmt =
        conn.prepare("SELECT * FROM sync_state WHERE server_id = ?1 AND entity_type = ?2")?;
    let mut rows = stmt.query_map(params![server_id, entity_type], row_to_state)?;
    rows.next().transpose()
}

/// Every sync-state row for one server, bootstrap order first.
pub fn list_entity_states(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<Vec<EntitySyncState>> {
    let mut stmt = conn.prepare(
        "SELECT * FROM sync_state WHERE server_id = ?1
         ORDER BY last_sync_at IS NULL, last_sync_at, entity_type",
    )?;
    let rows = stmt.query_map(params![server_id], row_to_state)?;
    rows.collect()
}

/// Mark a step as running, keeping any resume cursor it already has.
pub fn begin_entity(conn: &Connection, server_id: &str, entity_type: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO sync_state (server_id, entity_type, sync_status)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(server_id, entity_type) DO UPDATE SET sync_status = excluded.sync_status",
        params![server_id, entity_type, STATUS_SYNCING],
    )?;
    Ok(())
}

/// Commit a resume point: the cursor of the next page still to fetch.
pub fn checkpoint_entity(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
    cursor: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO sync_state (server_id, entity_type, last_sync_at, sync_cursor, sync_status)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(server_id, entity_type) DO UPDATE SET
           last_sync_at = excluded.last_sync_at,
           sync_cursor = excluded.sync_cursor,
           sync_status = excluded.sync_status",
        params![
            server_id,
            entity_type,
            now_rfc3339(),
            cursor,
            STATUS_SYNCING
        ],
    )?;
    Ok(())
}

/// The stored resume cursor, if a previous run was interrupted mid-sweep.
pub fn resume_cursor(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
) -> rusqlite::Result<Option<String>> {
    Ok(get_entity_state(conn, server_id, entity_type)?.and_then(|s| s.sync_cursor))
}

/// Mark a step done: cursor cleared, timestamp stamped, status idle.
pub fn complete_entity(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO sync_state (server_id, entity_type, last_sync_at, sync_cursor, sync_status, last_error)
         VALUES (?1, ?2, ?3, NULL, ?4, NULL)
         ON CONFLICT(server_id, entity_type) DO UPDATE SET
           last_sync_at = excluded.last_sync_at,
           sync_cursor = NULL,
           sync_status = excluded.sync_status,
           last_error = NULL",
        params![server_id, entity_type, now_rfc3339(), STATUS_IDLE],
    )?;
    Ok(())
}

/// Mark a step failed. The resume cursor stays so the next attempt can pick
/// up where this one stopped.
pub fn fail_entity(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
    error: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO sync_state (server_id, entity_type, sync_status, last_error)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(server_id, entity_type) DO UPDATE SET
           sync_status = excluded.sync_status,
           last_error = excluded.last_error",
        params![server_id, entity_type, STATUS_ERROR, error],
    )?;
    Ok(())
}

/// True when a step is mid-sweep (interrupted or crashed run) and has work
/// left to do — Bootstrap resumes it instead of skipping it.
pub fn is_resumable(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
) -> rusqlite::Result<bool> {
    let Some(state) = get_entity_state(conn, server_id, entity_type)? else {
        return Ok(false);
    };
    Ok(state.sync_cursor.is_some())
}

/// Record a successful sync: timestamp + status back to idle, error cleared.
pub fn touch_successful_sync(conn: &Connection, server_id: &str) -> rusqlite::Result<()> {
    let now = now_rfc3339();
    conn.execute(
        "INSERT INTO sync_state (server_id, entity_type, last_sync_at, sync_status, last_successful_sync)
         VALUES (?1, ?2, ?3, ?4, ?3)
         ON CONFLICT(server_id, entity_type) DO UPDATE SET
           last_sync_at = excluded.last_sync_at,
           sync_status = excluded.sync_status,
           last_error = NULL,
           last_successful_sync = excluded.last_successful_sync",
        params![server_id, ENTITY_FULL, now, STATUS_IDLE],
    )?;
    Ok(())
}

/// Record a completed full mirror sync: `last_full_sync` + success stamp.
pub fn record_full_sync(conn: &Connection, server_id: &str) -> rusqlite::Result<()> {
    let now = now_rfc3339();
    conn.execute(
        "INSERT INTO sync_state (server_id, entity_type, last_sync_at, sync_status, last_full_sync, last_successful_sync)
         VALUES (?1, ?2, ?3, ?4, ?3, ?3)
         ON CONFLICT(server_id, entity_type) DO UPDATE SET
           last_sync_at = excluded.last_sync_at,
           sync_status = excluded.sync_status,
           last_error = NULL,
           last_full_sync = excluded.last_full_sync,
           last_successful_sync = excluded.last_successful_sync",
        params![server_id, ENTITY_FULL, now, STATUS_IDLE],
    )?;
    Ok(())
}

/// Record a failed sync: status + error message on the rollup row.
pub fn touch_failed_sync(conn: &Connection, server_id: &str, error: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO sync_state (server_id, entity_type, sync_status, last_error)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(server_id, entity_type) DO UPDATE SET
           sync_status = excluded.sync_status,
           last_error = excluded.last_error",
        params![server_id, ENTITY_FULL, STATUS_ERROR, error],
    )?;
    Ok(())
}

pub fn get_sync_state(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<Option<SyncStateRow>> {
    get_entity_state(conn, server_id, ENTITY_FULL)
}

/// Timestamp of the last completed full mirror, for reconcile throttling.
pub fn last_synced_at(conn: &Connection, server_id: &str) -> rusqlite::Result<Option<String>> {
    Ok(get_entity_state(conn, server_id, ENTITY_FULL)?.and_then(|s| s.last_sync_at))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    #[test]
    fn touch_successful_creates_and_updates_row() {
        let conn = open_in_memory().unwrap();
        touch_successful_sync(&conn, "srv-1").unwrap();

        let row = get_sync_state(&conn, "srv-1")
            .unwrap()
            .expect("row must exist");
        assert_eq!(row.entity_type, ENTITY_FULL);
        assert_eq!(row.sync_status, STATUS_IDLE);
        assert!(row.last_successful_sync.is_some());
        assert!(row.last_error.is_none());

        touch_failed_sync(&conn, "srv-1", "network error").unwrap();
        let row = get_sync_state(&conn, "srv-1").unwrap().unwrap();
        assert_eq!(row.sync_status, STATUS_ERROR);
        assert_eq!(row.last_error.as_deref(), Some("network error"));

        // Success clears the error.
        touch_successful_sync(&conn, "srv-1").unwrap();
        let row = get_sync_state(&conn, "srv-1").unwrap().unwrap();
        assert_eq!(row.sync_status, STATUS_IDLE);
        assert!(row.last_error.is_none());
    }

    #[test]
    fn missing_row_returns_none() {
        let conn = open_in_memory().unwrap();
        assert!(get_sync_state(&conn, "srv-1").unwrap().is_none());
    }

    #[test]
    fn per_entity_rows_are_independent() {
        let conn = open_in_memory().unwrap();
        begin_entity(&conn, "srv-1", ENTITY_SERIES).unwrap();
        checkpoint_entity(&conn, "srv-1", ENTITY_SERIES, "page=3").unwrap();
        complete_entity(&conn, "srv-1", ENTITY_BOOKS).unwrap();

        let series = get_entity_state(&conn, "srv-1", ENTITY_SERIES)
            .unwrap()
            .unwrap();
        assert_eq!(series.sync_cursor.as_deref(), Some("page=3"));
        assert_eq!(series.sync_status, STATUS_SYNCING);
        assert!(series.last_sync_at.is_some());
        assert!(is_resumable(&conn, "srv-1", ENTITY_SERIES).unwrap());

        let books = get_entity_state(&conn, "srv-1", ENTITY_BOOKS)
            .unwrap()
            .unwrap();
        assert_eq!(books.sync_status, STATUS_IDLE);
        assert!(books.sync_cursor.is_none());
        assert!(!is_resumable(&conn, "srv-1", ENTITY_BOOKS).unwrap());
        // Untouched entity types have no row at all.
        assert!(get_entity_state(&conn, "srv-1", ENTITY_READLISTS)
            .unwrap()
            .is_none());
        assert_eq!(list_entity_states(&conn, "srv-1").unwrap().len(), 2);
    }

    #[test]
    fn failure_keeps_the_resume_cursor() {
        let conn = open_in_memory().unwrap();
        checkpoint_entity(&conn, "srv-1", ENTITY_BOOKS, "series-2|page=1").unwrap();
        fail_entity(&conn, "srv-1", ENTITY_BOOKS, "boom").unwrap();
        let books = get_entity_state(&conn, "srv-1", ENTITY_BOOKS)
            .unwrap()
            .unwrap();
        assert_eq!(books.sync_status, STATUS_ERROR);
        assert_eq!(books.sync_cursor.as_deref(), Some("series-2|page=1"));
        assert!(is_resumable(&conn, "srv-1", ENTITY_BOOKS).unwrap());
    }

    #[test]
    fn multi_server_isolation() {
        let conn = open_in_memory().unwrap();
        checkpoint_entity(&conn, "srv-1", ENTITY_SERIES, "page=2").unwrap();
        checkpoint_entity(&conn, "srv-2", ENTITY_SERIES, "page=7").unwrap();
        assert_eq!(
            resume_cursor(&conn, "srv-1", ENTITY_SERIES).unwrap(),
            Some("page=2".into())
        );
        assert_eq!(
            resume_cursor(&conn, "srv-2", ENTITY_SERIES).unwrap(),
            Some("page=7".into())
        );
    }
}
