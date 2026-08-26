//! Libraries local store — mirrored from GET /api/v1/libraries.
//!
//! Compound key (server_id, remote_id) — never shared between servers.

use crate::model::server::Library;
use rusqlite::{params, Connection, Row};

/// Locally stored library row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryRow {
    pub server_id: String,
    pub remote_id: String,
    pub name: String,
}

fn row_to_library(row: &Row) -> rusqlite::Result<LibraryRow> {
    Ok(LibraryRow {
        server_id: row.get("server_id")?,
        remote_id: row.get("remote_id")?,
        name: row.get("name")?,
    })
}

/// Batch upsert; returns the number of rows written.
pub fn save_libraries_batch(
    conn: &Connection,
    server_id: &str,
    libraries: &[Library],
) -> rusqlite::Result<usize> {
    let mut written = 0;
    for library in libraries {
        conn.execute(
            "INSERT INTO libraries (server_id, remote_id, name) VALUES (?1, ?2, ?3)
             ON CONFLICT(server_id, remote_id) DO UPDATE SET name = excluded.name",
            params![server_id, library.id, library.name],
        )?;
        written += 1;
    }
    Ok(written)
}

/// All libraries for one server, ordered by name.
pub fn list_libraries(conn: &Connection, server_id: &str) -> rusqlite::Result<Vec<LibraryRow>> {
    let mut stmt =
        conn.prepare("SELECT * FROM libraries WHERE server_id = ?1 ORDER BY name COLLATE NOCASE")?;
    let rows = stmt.query_map(params![server_id], row_to_library)?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::server::Library;
    use crate::store::open_in_memory;

    fn library(id: &str, name: &str) -> Library {
        Library {
            id: id.into(),
            name: name.into(),
            root: "/mnt/media".into(),
            unavailable: Some(false),
        }
    }

    #[test]
    fn libraries_are_scoped_per_server() {
        let conn = open_in_memory().unwrap();
        save_libraries_batch(
            &conn,
            "server-1",
            &[library("l1", "Manga"), library("l2", "Comics")],
        )
        .unwrap();
        save_libraries_batch(&conn, "server-2", &[library("l1", "European")]).unwrap();

        let s1 = list_libraries(&conn, "server-1").unwrap();
        assert_eq!(s1.len(), 2);
        // Same remote id on another server must not collide.
        let manga = s1.iter().find(|row| row.name == "Manga").unwrap();
        assert_eq!(manga.remote_id, "l1");
        assert_eq!(manga.server_id, "server-1");
        // Ordered by name COLLATE NOCASE.
        assert_eq!(s1[0].name, "Comics");
        assert_eq!(s1[1].name, "Manga");

        let s2 = list_libraries(&conn, "server-2").unwrap();
        assert_eq!(s2.len(), 1);
        assert_eq!(s2[0].name, "European");
    }

    #[test]
    fn upsert_updates_name_in_place() {
        let conn = open_in_memory().unwrap();
        save_libraries_batch(&conn, "s", &[library("l1", "Old")]).unwrap();
        save_libraries_batch(&conn, "s", &[library("l1", "New")]).unwrap();
        let rows = list_libraries(&conn, "s").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "New");
    }

    #[test]
    fn decodes_shared_fixture() {
        let json = include_str!("../../../../specs/contracts/fixtures/connection/libraries.json");
        let libraries: Vec<Library> =
            serde_json::from_str(json).expect("shared fixture must decode");
        assert_eq!(libraries.len(), 2);
        assert_eq!(libraries[0].name, "Manga");
    }
}
