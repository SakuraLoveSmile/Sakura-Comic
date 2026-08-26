//! Series local store — batch upsert + paged query (local-first).

use rusqlite::{params, Connection, Row};

use crate::model::series::Series;

/// Locally stored series row (subset of the remote SeriesDto).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeriesRow {
    pub server_id: String,
    pub remote_id: String,
    pub library_id: String,
    pub name: String,
    pub sort_name: Option<String>,
    pub status: Option<String>,
    pub created_at: Option<String>,
    pub last_modified: Option<String>,
}

fn row_to_series(row: &Row) -> rusqlite::Result<SeriesRow> {
    Ok(SeriesRow {
        server_id: row.get("server_id")?,
        remote_id: row.get("remote_id")?,
        library_id: row.get("library_id")?,
        name: row.get("name")?,
        sort_name: row.get("sort_name")?,
        status: row.get("status")?,
        created_at: row.get("created_at")?,
        last_modified: row.get("last_modified")?,
    })
}

/// Batch upsert; returns the number of rows written.
pub fn save_series_batch(
    conn: &Connection,
    server_id: &str,
    series: &[Series],
) -> rusqlite::Result<usize> {
    let mut written = 0;
    for item in series {
        conn.execute(
            "INSERT INTO series (server_id, remote_id, library_id, name, sort_name, status, created_at, last_modified)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(server_id, remote_id) DO UPDATE SET
               library_id = excluded.library_id,
               name = excluded.name,
               sort_name = excluded.sort_name,
               status = excluded.status,
               created_at = excluded.created_at,
               last_modified = excluded.last_modified",
            params![
                server_id,
                item.id,
                item.library_id,
                item.name,
                None::<String>, // sort_name: metadata-driven in Phase 1
                item.metadata.as_ref().and_then(|m| m.status.clone()),
                item.created,
                item.last_modified,
            ],
        )?;
        written += 1;
    }
    Ok(written)
}

/// Paged query ordered by name (case-insensitive).
pub fn list_series(
    conn: &Connection,
    server_id: &str,
    limit: i64,
    offset: i64,
) -> rusqlite::Result<Vec<SeriesRow>> {
    let mut stmt = conn.prepare(
        "SELECT * FROM series WHERE server_id = ?1 ORDER BY name COLLATE NOCASE LIMIT ?2 OFFSET ?3",
    )?;
    let rows = stmt.query_map(params![server_id, limit, offset], row_to_series)?;
    rows.collect()
}

pub fn count_series(conn: &Connection, server_id: &str) -> rusqlite::Result<i64> {
    conn.query_row(
        "SELECT COUNT(*) FROM series WHERE server_id = ?1",
        params![server_id],
        |row| row.get(0),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::series::{Series, SeriesMetadata};
    use crate::store::open_in_memory;

    fn sample_series(id: &str, name: &str) -> Series {
        Series {
            id: id.into(),
            library_id: "lib-1".into(),
            name: name.into(),
            created: Some("2025-01-01T00:00:00Z".into()),
            last_modified: Some("2025-01-02T00:00:00Z".into()),
            books_count: Some(10),
            metadata: Some(SeriesMetadata {
                title: name.into(),
                status: Some("ONGOING".into()),
                summary: None,
                publishers: vec![],
            }),
        }
    }

    #[test]
    fn batch_upsert_and_page() {
        let conn = open_in_memory().unwrap();
        let batch = vec![
            sample_series("s1", "One Piece"),
            sample_series("s2", "Berserk"),
        ];
        assert_eq!(save_series_batch(&conn, "server-1", &batch).unwrap(), 2);
        assert_eq!(count_series(&conn, "server-1").unwrap(), 2);

        let rows = list_series(&conn, "server-1", 10, 0).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].name, "Berserk"); // COLLATE NOCASE ordering
        assert_eq!(rows[0].status.as_deref(), Some("ONGOING"));
    }

    #[test]
    fn upsert_is_idempotent() {
        let conn = open_in_memory().unwrap();
        let mut s = sample_series("s1", "One Piece");
        save_series_batch(&conn, "server-1", &[s.clone()]).unwrap();
        s.name = "One Piece (Revised)".into();
        save_series_batch(&conn, "server-1", &[s]).unwrap();
        assert_eq!(count_series(&conn, "server-1").unwrap(), 1);
        let rows = list_series(&conn, "server-1", 10, 0).unwrap();
        assert_eq!(rows[0].name, "One Piece (Revised)");
    }

    #[test]
    fn multi_server_isolation() {
        let conn = open_in_memory().unwrap();
        save_series_batch(&conn, "server-1", &[sample_series("s1", "One Piece")]).unwrap();
        save_series_batch(&conn, "server-2", &[sample_series("s1", "One Piece")]).unwrap();
        assert_eq!(count_series(&conn, "server-1").unwrap(), 1);
        assert_eq!(count_series(&conn, "server-2").unwrap(), 1);
    }
}
