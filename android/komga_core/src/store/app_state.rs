//! Single-value app state (active server, ...).

use rusqlite::{params, Connection, OptionalExtension};

/// Key for the currently active server profile id.
pub const ACTIVE_SERVER_KEY: &str = "active_server_id";

pub fn get_active_server(conn: &Connection) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT value FROM app_state WHERE key = ?1",
        params![ACTIVE_SERVER_KEY],
        |row| row.get::<_, String>(0),
    )
    .optional()
}

/// Set the active server id (replaces any previous value).
pub fn set_active_server(conn: &Connection, server_id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO app_state (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![ACTIVE_SERVER_KEY, server_id],
    )?;
    Ok(())
}

/// Remove the active server id (e.g. after deleting the server).
pub fn clear_active_server(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM app_state WHERE key = ?1",
        params![ACTIVE_SERVER_KEY],
    )?;
    Ok(())
}

/// Returns true when `server_id` is the currently active server.
pub fn is_active_server(conn: &Connection, server_id: &str) -> rusqlite::Result<bool> {
    Ok(get_active_server(conn)?.as_deref() == Some(server_id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    #[test]
    fn active_server_roundtrip() {
        let conn = open_in_memory().unwrap();
        assert_eq!(get_active_server(&conn).unwrap(), None);
        assert!(!is_active_server(&conn, "s1").unwrap());

        set_active_server(&conn, "s1").unwrap();
        assert_eq!(get_active_server(&conn).unwrap().as_deref(), Some("s1"));
        assert!(is_active_server(&conn, "s1").unwrap());

        set_active_server(&conn, "s2").unwrap();
        assert_eq!(get_active_server(&conn).unwrap().as_deref(), Some("s2"));

        clear_active_server(&conn).unwrap();
        assert_eq!(get_active_server(&conn).unwrap(), None);
    }
}
