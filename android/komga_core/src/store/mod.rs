//! rusqlite-backed local store. All database access goes through Rust Core
//! (no Flutter SQLite plugin).

pub mod schema;
pub mod series;
pub mod servers;

use rusqlite::Connection;
use std::path::Path;

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
