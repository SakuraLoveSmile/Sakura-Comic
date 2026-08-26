//! Sync state — one row per server: last sync timestamps + status.
//!
//! Written by the sync engine (BootstrapSync touches it on success); read
//! by the UI for "last synced" surfaces. Status vocabulary:
//! `idle` | `syncing` | `error` (lowercase, matches the schema default).

use rusqlite::{params, Connection, Row};

pub const STATUS_IDLE: &str = "idle";
pub const STATUS_SYNCING: &str = "syncing";
pub const STATUS_ERROR: &str = "error";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncStateRow {
    pub server_id: String,
    pub last_full_sync: Option<String>,
    pub last_successful_sync: Option<String>,
    pub last_error: Option<String>,
    pub sync_status: String,
}

fn row_to_sync_state(row: &Row) -> rusqlite::Result<SyncStateRow> {
    Ok(SyncStateRow {
        server_id: row.get("server_id")?,
        last_full_sync: row.get("last_full_sync")?,
        last_successful_sync: row.get("last_successful_sync")?,
        last_error: row.get("last_error")?,
        sync_status: row.get("sync_status")?,
    })
}

/// RFC 3339 with millisecond precision (matches the Swift store).
fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// Record a successful sync: timestamp + status back to idle, error cleared.
pub fn touch_successful_sync(conn: &Connection, server_id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO sync_state (server_id, last_successful_sync, sync_status)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(server_id) DO UPDATE SET
           last_successful_sync = excluded.last_successful_sync,
           sync_status = excluded.sync_status,
           last_error = NULL",
        params![server_id, now_rfc3339(), STATUS_IDLE],
    )?;
    Ok(())
}

/// Record a completed full mirror sync: `last_full_sync` + success stamp.
pub fn record_full_sync(conn: &Connection, server_id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO sync_state (server_id, last_full_sync, last_successful_sync, sync_status)
         VALUES (?1, ?2, ?2, ?3)
         ON CONFLICT(server_id) DO UPDATE SET
           last_full_sync = excluded.last_full_sync,
           last_successful_sync = excluded.last_successful_sync,
           sync_status = excluded.sync_status,
           last_error = NULL",
        params![server_id, now_rfc3339(), STATUS_IDLE],
    )?;
    Ok(())
}

/// Record a failed sync: status + error message.
pub fn touch_failed_sync(conn: &Connection, server_id: &str, error: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO sync_state (server_id, last_error, sync_status)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(server_id) DO UPDATE SET
           last_error = excluded.last_error,
           sync_status = excluded.sync_status",
        params![server_id, error, STATUS_ERROR],
    )?;
    Ok(())
}

pub fn get_sync_state(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<Option<SyncStateRow>> {
    let mut stmt = conn.prepare("SELECT * FROM sync_state WHERE server_id = ?1")?;
    let mut rows = stmt.query_map(params![server_id], row_to_sync_state)?;
    rows.next().transpose()
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
}
