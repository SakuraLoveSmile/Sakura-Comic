//! rusqlite-backed local store. All database access goes through Rust Core
//! (no Flutter SQLite plugin). 网络负责同步，本地数据库负责展示。

pub mod app_state;
pub mod books;
pub mod collections;
pub mod fts;
pub mod libraries;
pub mod prune;
pub mod query;
pub mod read_progress;
pub mod readlists;
pub mod schema;
pub mod series;
pub mod servers;
pub mod sync_state;
pub mod thumbnails;

use rusqlite::{Connection, Row};
use std::path::Path;

/// Author row shared by series/book detail reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthorRow {
    pub name: String,
    pub role: String,
}

pub(in crate::store) fn author_row(row: &Row) -> rusqlite::Result<AuthorRow> {
    Ok(AuthorRow {
        name: row.get("name")?,
        role: row.get("role")?,
    })
}

/// Remove every mirrored row for one server (profile deletion cascade).
/// Covers all per-server tables + the FTS search index; cover files on
/// disk are removed by the facade (it collects the paths first).
pub fn delete_server_mirror(conn: &Connection, server_id: &str) -> rusqlite::Result<()> {
    for table in [
        "series",
        "books",
        "series_metadata",
        "book_metadata",
        "series_tags",
        "series_genres",
        "series_authors",
        "book_tags",
        "book_authors",
        "collections",
        "collection_series",
        "readlists",
        "readlist_books",
        "read_progress",
        "libraries",
        "sync_state",
        "deleted_entities",
        "pending_mutations",
        "thumbnails",
        "downloads",
        "download_pages",
    ] {
        conn.execute(
            &format!("DELETE FROM {table} WHERE server_id = ?1"),
            [server_id],
        )?;
    }
    fts::delete_fts_for_server(conn, server_id)?;
    Ok(())
}

/// Open (or create) the database at `path` and apply migrations.
pub fn open(path: impl AsRef<Path>) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    configure(&conn)?;
    schema::migrate(&conn)?;
    Ok(conn)
}

/// Open an in-memory database (tests / ephemeral use).
pub fn open_in_memory() -> rusqlite::Result<Connection> {
    let conn = Connection::open_in_memory()?;
    configure(&conn)?;
    schema::migrate(&conn)?;
    Ok(conn)
}

fn configure(conn: &Connection) -> rusqlite::Result<()> {
    conn.pragma_update(None, "foreign_keys", "ON")?;
    // WAL + NORMAL: the sync engine writes page by page, and the default
    // rollback journal fsyncs on every commit. This store is a mirror that can
    // always be re-derived from the server, so paying an fsync per statement is
    // the wrong trade — at 1,000 series / 20,000 books it made a *no-op*
    // reconcile take 11s, which is far too slow for a foreground trigger.
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.pragma_update(None, "temp_store", "MEMORY")?;
    conn.pragma_update(None, "cache_size", "-8000")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_in_memory_migrates() {
        let conn = open_in_memory().unwrap();
        let version: i64 = conn
            .query_row("PRAGMA user_version", rusqlite::params![], |row| row.get(0))
            .unwrap();
        assert_eq!(version, schema::SCHEMA_VERSION);
    }
}
