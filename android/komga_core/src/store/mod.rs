//! rusqlite-backed local store. All database access goes through Rust Core
//! (no Flutter SQLite plugin). 网络负责同步，本地数据库负责展示。

pub mod app_state;
pub mod auth_state;
pub mod books;
pub mod cache;
pub mod collections;
pub mod fts;
pub mod libraries;
pub mod outbox;
pub mod pages;
pub mod position;
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
        "book_pages",
        "reader_position",
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
    ] {
        // `downloads` and `download_pages` are deliberately NOT in this list. They
        // are the index to files the user asked to keep, and dropping a server is a
        // gesture about the connection, not about the bookshelf: with the rows gone
        // the files on disk have no name anybody can delete them by, because the
        // directory is spelled with a sanitised id and only the row remembers the
        // raw one. Manage them from the Downloads and Storage screens instead.
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
    // Wait rather than fail when another connection is mid-write. The reader opens
    // a fresh connection per FFI call, and a prefetch pass commits a batch of
    // `cache_entries` rows while position writes and the sync tick can be running:
    // without a busy timeout SQLite returns SQLITE_BUSY *immediately*, the
    // transaction is dropped, and the page files already written become orphans
    // that the next sweep deletes — so the same pages get downloaded again on
    // every resume. Observed on an Android device as 20 reads for 4 distinct pages.
    conn.pragma_update(None, "busy_timeout", "5000")?;
    conn.pragma_update(None, "temp_store", "MEMORY")?;
    conn.pragma_update(None, "cache_size", "-8000")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The setting that stops a contended commit from silently discarding work.
    #[test]
    fn a_connection_waits_for_another_writer_instead_of_failing() {
        let conn = open_in_memory().unwrap();
        let timeout: i64 = conn
            .query_row("PRAGMA busy_timeout", [], |row| row.get(0))
            .unwrap();
        assert_eq!(timeout, 5000, "busy_timeout is what makes WAL usable");
    }

    /// WAL has to be checked on a file: SQLite refuses it for `:memory:` and
    /// answers `memory` no matter what `configure` asked for, so an in-memory
    /// assertion here would be testing a mode the production store never uses.
    #[test]
    fn a_file_backed_connection_runs_in_wal() {
        let dir = std::env::temp_dir().join(format!("komga_store_wal_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("komga.db");
        let conn = open(&path).unwrap();
        let mode: String = conn
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .unwrap();
        let sync: i64 = conn
            .query_row("PRAGMA synchronous", [], |row| row.get(0))
            .unwrap();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(mode.to_lowercase(), "wal");
        // 1 == NORMAL: the fsync-per-commit that made a no-op reconcile take 11s.
        assert_eq!(
            sync, 1,
            "WAL without NORMAL loses the speedup it exists for"
        );
    }

    #[test]
    fn open_in_memory_migrates() {
        let conn = open_in_memory().unwrap();
        let version: i64 = conn
            .query_row("PRAGMA user_version", rusqlite::params![], |row| row.get(0))
            .unwrap();
        assert_eq!(version, schema::SCHEMA_VERSION);
    }

    /// The two download tables exactly as v8 created them. Written out here
    /// rather than derived from `CREATE_STATEMENTS`, because the point of the
    /// test is what a database written *before* Stage 9 looks like.
    const V8_DOWNLOADS: &str = "CREATE TABLE downloads (
        server_id TEXT NOT NULL,
        book_id TEXT NOT NULL,
        manifest_path TEXT,
        pages_total INTEGER,
        pages_done INTEGER,
        state TEXT NOT NULL,
        PRIMARY KEY (server_id, book_id)
    )";
    const V8_DOWNLOAD_PAGES: &str = "CREATE TABLE download_pages (
        server_id TEXT NOT NULL,
        book_id TEXT NOT NULL,
        page_number INTEGER NOT NULL,
        file_path TEXT,
        state TEXT NOT NULL,
        PRIMARY KEY (server_id, book_id, page_number)
    )";

    /// A v8 database is one the user already put downloads in. The migration must
    /// add its columns without disturbing what was there: this is the only
    /// migration in the project whose failure mode is losing a user's bookkeeping
    /// rather than missing a column, and a download row is the only evidence of
    /// what the user asked for.
    #[test]
    fn a_v8_download_row_survives_the_v9_migration_untouched() {
        let conn = Connection::open_in_memory().unwrap();
        schema::migrate(&conn).unwrap();
        // Become a v8 database again, then rebuild the two tables in that shape.
        conn.pragma_update(None, "user_version", 8_i64).unwrap();
        conn.execute("DROP TABLE downloads", []).unwrap();
        conn.execute("DROP TABLE download_pages", []).unwrap();
        conn.execute(V8_DOWNLOADS, []).unwrap();
        conn.execute(V8_DOWNLOAD_PAGES, []).unwrap();
        conn.execute(
            "INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done, state)
             VALUES ('s1', 'b1', '/dwn/s1/b1/manifest.json', 120, 40, 'paused')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO download_pages (server_id, book_id, page_number, file_path, state)
             VALUES ('s1', 'b1', 7, '/dwn/s1/b1/0007.png', 'complete')",
            [],
        )
        .unwrap();

        schema::migrate(&conn).unwrap();

        let row: (String, i64, i64, i64, i64, i64) = conn
            .query_row(
                "SELECT state, COALESCE(pages_total, -1), COALESCE(pages_done, -1),
                        position, bytes_total, allow_cellular
                 FROM downloads WHERE server_id = 's1' AND book_id = 'b1'",
                [],
                |r| {
                    Ok((
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(
            row,
            ("paused".to_string(), 120, 40, 0, 0, 0),
            "a paused download's own columns must survive v9 with its new ones defaulted"
        );
        let pages: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM download_pages
                 WHERE server_id = 's1' AND book_id = 'b1' AND page_number = 7
                   AND state = 'complete'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            pages, 1,
            "the completed page row is the proof it is on disk"
        );
        let version: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(version, schema::SCHEMA_VERSION);
    }

    fn table_shape(conn: &Connection, table: &str) -> Vec<(String, String, i64, String)> {
        let mut stmt = conn
            .prepare(&format!(
                "SELECT name, type, \"notnull\", COALESCE(dflt_value, '<none>')
                 FROM pragma_table_info('{table}') ORDER BY cid"
            ))
            .unwrap();
        stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
            ))
        })
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap()
    }

    /// The guarded-ALTER route and the `CREATE_STATEMENTS` route must land on one
    /// shape. A column added to the fresh DDL but not to `V9_ALTER_STATEMENTS`
    /// otherwise compiles and passes every other test, then makes an upgrading
    /// user's downloads query a column that is not there.
    #[test]
    fn a_migrated_v8_download_table_has_the_fresh_shape() {
        let upgraded = Connection::open_in_memory().unwrap();
        schema::migrate(&upgraded).unwrap();
        upgraded.pragma_update(None, "user_version", 8_i64).unwrap();
        upgraded.execute("DROP TABLE downloads", []).unwrap();
        upgraded.execute("DROP TABLE download_pages", []).unwrap();
        upgraded.execute(V8_DOWNLOADS, []).unwrap();
        upgraded.execute(V8_DOWNLOAD_PAGES, []).unwrap();
        schema::migrate(&upgraded).unwrap();

        let fresh = open_in_memory().unwrap();
        for table in ["downloads", "download_pages"] {
            assert_eq!(
                table_shape(&upgraded, table),
                table_shape(&fresh, table),
                "{table}: a v8 database converged on a different shape than a fresh one"
            );
        }
    }
}
