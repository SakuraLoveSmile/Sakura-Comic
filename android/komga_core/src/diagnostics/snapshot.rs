//! The database's own account of itself.
//!
//! Every hardening claim in the final acceptance list — "a database upgrade
//! loses nothing", "cache corruption is recoverable", "sync is stable over a
//! long run" — is a claim about the store. This module is how the core answers
//! those questions about itself, so a gate can compare the answer against an
//! outside witness (`sqlite3` on the command line, or `find`) instead of
//! trusting a number the code printed about its own work.
//!
//! Reads only. Nothing here repairs, prunes or migrates.

use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

/// Row count for one table.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TableRows {
    pub table: String,
    pub rows: i64,
}

/// The pragmas that decide whether this connection is the one the store was
/// configured to open, plus the mirror's size per table.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DbHealth {
    /// `PRAGMA user_version`, i.e. the schema the migrations left behind.
    pub schema_version: i64,
    /// `"ok"`, or the first complaint from `PRAGMA integrity_check`.
    pub integrity: String,
    pub journal_mode: String,
    pub page_size: i64,
    pub page_count: i64,
    /// Pages held on the free list — the file's own record of reusable space.
    pub freelist_count: i64,
    pub busy_timeout_ms: i64,
    pub foreign_keys_on: bool,
    /// Bytes in the main database file, from `page_size * page_count`. The
    /// `-wal` and `-shm` siblings are deliberately not counted: their size
    /// depends on when the last checkpoint ran, which is not a fact about the
    /// data.
    pub file_bytes: i64,
    /// Every user table and how full it is, in name order.
    pub tables: Vec<TableRows>,
}

/// Suffixes SQLite gives the shadow tables of an FTS5 index. They are physical
/// storage, not content, and a gate that counted them beside `series` and
/// `books` would be comparing a mirror against its own index.
const FTS_SHADOW_SUFFIXES: [&str; 5] = ["_content", "_idx", "_docsize", "_config", "_data"];

/// Double-quote an identifier. Every name passed here comes out of
/// `sqlite_master` for this very database, so it is a real table; the quoting
/// is for the ones whose names contain characters that need it, not for trust.
fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

fn pragma_i64(conn: &Connection, pragma: &str) -> rusqlite::Result<i64> {
    conn.query_row(pragma, [], |row| row.get::<_, i64>(0))
}

fn pragma_text(conn: &Connection, pragma: &str) -> rusqlite::Result<String> {
    conn.query_row(pragma, [], |row| row.get::<_, String>(0))
}

/// User tables only, in name order, with FTS5's shadow tables folded away.
pub fn list_user_tables(conn: &Connection) -> rusqlite::Result<Vec<String>> {
    let mut statement = conn.prepare(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' \
         ORDER BY name",
    )?;
    let names: Vec<String> = statement
        .query_map([], |row| row.get::<_, String>(0))?
        .filter_map(Result::ok)
        .filter(|name| {
            !FTS_SHADOW_SUFFIXES
                .iter()
                .any(|suffix| name.ends_with(suffix))
        })
        .collect();
    Ok(names)
}

/// `count(*)` for one table.
pub fn count_rows(conn: &Connection, table: &str) -> rusqlite::Result<i64> {
    let sql = format!("SELECT count(*) FROM {}", quote_ident(table));
    conn.query_row(&sql, [], |row| row.get::<_, i64>(0))
}

/// Row counts for every user table — the shape the acceptance gates diff
/// against the server's own snapshot.
pub fn table_counts(conn: &Connection) -> rusqlite::Result<Vec<TableRows>> {
    let mut counts = Vec::new();
    for table in list_user_tables(conn)? {
        counts.push(TableRows {
            rows: count_rows(conn, &table)?,
            table,
        });
    }
    Ok(counts)
}

/// `PRAGMA integrity_check`, reduced to a single word. SQLite answers `ok` when
/// the b-trees, page assignments and pointer map all agree; anything else is a
/// list of complaints, and the first one is what a human should read first.
pub fn integrity_check(conn: &Connection) -> rusqlite::Result<String> {
    let verdict: Option<String> = conn
        .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
        .optional()?;
    Ok(verdict.unwrap_or_else(|| "no verdict".to_string()))
}

/// Everything above in one read, plus the settings a connection is only correct
/// if `store::configure` actually ran.
pub fn db_health(conn: &Connection) -> rusqlite::Result<DbHealth> {
    let page_size = pragma_i64(conn, "PRAGMA page_size")?;
    let page_count = pragma_i64(conn, "PRAGMA page_count")?;
    Ok(DbHealth {
        schema_version: pragma_i64(conn, "PRAGMA user_version")?,
        integrity: integrity_check(conn)?,
        journal_mode: pragma_text(conn, "PRAGMA journal_mode")?.to_ascii_lowercase(),
        page_size,
        page_count,
        freelist_count: pragma_i64(conn, "PRAGMA freelist_count")?,
        busy_timeout_ms: pragma_i64(conn, "PRAGMA busy_timeout")?,
        foreign_keys_on: pragma_i64(conn, "PRAGMA foreign_keys")? == 1,
        file_bytes: page_size * page_count,
        tables: table_counts(conn)?,
    })
}

/// Row count for one table, or `None` when the table does not exist. Lets a
/// diagnostic ask about a table a given schema version may not have introduced
/// without turning "not there yet" into an error.
pub fn count_rows_if_table(conn: &Connection, table: &str) -> rusqlite::Result<Option<i64>> {
    let exists: Option<String> = conn
        .query_row(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if exists.is_some() {
        count_rows(conn, table).map(Some)
    } else {
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store;

    #[test]
    fn a_fresh_store_reports_the_schema_it_ships_and_an_intact_file() {
        let conn = store::open_in_memory().unwrap();
        let health = db_health(&conn).unwrap();
        assert_eq!(health.schema_version, crate::store::schema::SCHEMA_VERSION);
        assert_eq!(health.integrity, "ok");
        // The pragmas `configure` sets are part of the health report because a
        // connection that skipped them is a different database wearing the same
        // filename: slower, and far more ready to fail on a contended commit.
        assert_eq!(health.busy_timeout_ms, 5000);
        assert!(health.foreign_keys_on);
        assert_eq!(health.journal_mode, "memory");
        assert!(health.page_size > 0);
        assert_eq!(health.file_bytes, health.page_size * health.page_count);
    }

    #[test]
    fn the_download_tables_are_in_the_table_report() {
        let conn = store::open_in_memory().unwrap();
        let tables = list_user_tables(&conn).unwrap();
        assert!(tables.iter().any(|name| name == "downloads"));
        assert!(tables.iter().any(|name| name == "download_pages"));
        assert!(tables.iter().any(|name| name == "cache_entries"));
    }

    #[test]
    fn fts_shadow_tables_are_folded_away_but_the_index_itself_is_counted() {
        let conn = store::open_in_memory().unwrap();
        let tables = list_user_tables(&conn).unwrap();
        // The search index is real content by this store's reckoning...
        assert!(tables.iter().any(|name| name == "series_fts"));
        // ...while the five shadow tables it physically consists of are not.
        // Without the filter, `series_fts_*` rows would land beside `series`
        // in a gate that is trying to compare a mirror against a server.
        for suffix in FTS_SHADOW_SUFFIXES {
            assert!(
                !tables.iter().any(|name| name.ends_with(suffix)),
                "a shadow table survived the filter: {suffix}"
            );
        }
    }

    #[test]
    fn a_table_name_needing_quotes_is_still_countable() {
        let conn = store::open_in_memory().unwrap();
        conn.execute("CREATE TABLE \"odd\"\"name\" (x INTEGER)", [])
            .unwrap();
        conn.execute("INSERT INTO \"odd\"\"name\" VALUES (1), (2)", [])
            .unwrap();
        assert_eq!(count_rows(&conn, "odd\"name").unwrap(), 2);
        assert!(list_user_tables(&conn)
            .unwrap()
            .iter()
            .any(|name| name == "odd\"name"));
    }

    #[test]
    fn a_missing_table_reads_as_none_rather_than_an_error() {
        let conn = store::open_in_memory().unwrap();
        assert_eq!(count_rows_if_table(&conn, "downloads").unwrap(), Some(0));
        assert_eq!(count_rows_if_table(&conn, "not_a_table").unwrap(), None);
    }

    #[test]
    fn row_counts_move_when_the_mirror_grows() {
        let conn = store::open_in_memory().unwrap();
        let before = count_rows(&conn, "series").unwrap();
        conn.execute(
            "INSERT INTO servers (id, display_name, base_url, auth_type, credential_ref)
             VALUES ('s1','S','http://x','API_KEY','ref')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO series (server_id, remote_id, library_id, name)
             VALUES ('s1','r1','l1','A')",
            [],
        )
        .unwrap();
        assert_eq!(count_rows(&conn, "series").unwrap(), before + 1);
        // And the whole-table report agrees with the single-table answer.
        let report = table_counts(&conn).unwrap();
        assert_eq!(
            report
                .iter()
                .find(|entry| entry.table == "series")
                .map(|entry| entry.rows),
            Some(before + 1)
        );
    }
}
