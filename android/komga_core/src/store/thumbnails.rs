//! Cover-cache bookkeeping (multi-server safe).
//!
//! The UI resolves a cover's local file path from SQLite instead of
//! scanning the disk (local-first: 本地数据库负责展示). Rows are written by
//! the facade cover pipeline after a successful download; a row whose file
//! disappeared counts as a cache miss and is backfilled on next access.

use chrono::Utc;
use rusqlite::{params, Connection, Row};

/// Thumbnail variants (a book thumbnail may join series covers later).
pub const VARIANT_SERIES: &str = "series";
pub const VARIANT_BOOK: &str = "book";

/// A `thumbnails` row: logical thumbnail -> local file path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThumbnailRow {
    pub server_id: String,
    pub remote_id: String,
    pub variant: String,
    pub local_path: String,
    pub size_bytes: i64,
    pub last_access: String,
}

fn row_to_thumbnail(row: &Row) -> rusqlite::Result<ThumbnailRow> {
    Ok(ThumbnailRow {
        server_id: row.get("server_id")?,
        remote_id: row.get("remote_id")?,
        variant: row.get("variant")?,
        local_path: row.get("local_path")?,
        size_bytes: row.get("size_bytes")?,
        last_access: row.get("last_access")?,
    })
}

/// RFC 3339 with millisecond precision (matches the Swift store).
pub fn now_rfc3339() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// Insert or refresh the cover record for one remote entity.
pub fn record_thumbnail(
    conn: &Connection,
    server_id: &str,
    remote_id: &str,
    variant: &str,
    local_path: &str,
    size_bytes: i64,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO thumbnails (server_id, remote_id, variant, local_path, size_bytes, last_access)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(server_id, remote_id, variant) DO UPDATE SET
           local_path = excluded.local_path,
           size_bytes = excluded.size_bytes,
           last_access = excluded.last_access",
        params![
            server_id,
            remote_id,
            variant,
            local_path,
            size_bytes,
            now_rfc3339(),
        ],
    )?;
    Ok(())
}

/// The cover record for one entity, if any.
pub fn get_thumbnail(
    conn: &Connection,
    server_id: &str,
    remote_id: &str,
    variant: &str,
) -> rusqlite::Result<Option<ThumbnailRow>> {
    let mut stmt = conn.prepare(
        "SELECT * FROM thumbnails WHERE server_id = ?1 AND remote_id = ?2 AND variant = ?3",
    )?;
    let mut rows = stmt.query_map(params![server_id, remote_id, variant], row_to_thumbnail)?;
    rows.next().transpose()
}

/// All cover records for one server (grid rendering reads this once).
pub fn list_thumbnails(conn: &Connection, server_id: &str) -> rusqlite::Result<Vec<ThumbnailRow>> {
    let mut stmt =
        conn.prepare("SELECT * FROM thumbnails WHERE server_id = ?1 ORDER BY remote_id")?;
    let rows = stmt.query_map(params![server_id], row_to_thumbnail)?;
    rows.collect()
}

/// Cover paths for a *set* of entities — what the wall and a series' book list
/// actually need, instead of the server's whole thumbnail table.
///
/// `list_thumbnails` returns every row of the server (both variants) and leaves
/// the caller to filter, which at 20,000 books is 20,000 rows decoded plus a
/// `stat()` per row on every screen load. The primary key
/// `(server_id, remote_id, variant)` covers this lookup, so asking for one page
/// costs one probe per id instead of a full scan.
///
/// Returns `(remote_id, local_path)` for the ids that have a record. The caller
/// decides what to do about files that have since vanished.
pub fn cover_paths(
    conn: &Connection,
    server_id: &str,
    variant: &str,
    remote_ids: &[String],
) -> rusqlite::Result<Vec<(String, String)>> {
    if remote_ids.is_empty() {
        return Ok(Vec::new());
    }
    // One placeholder per id: a page is tens of ids, far inside SQLite's
    // parameter limit, and it keeps the primary key visible to the planner.
    let placeholders = (0..remote_ids.len())
        .map(|i| format!("?{}", i + 3))
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "SELECT remote_id, local_path FROM thumbnails
          WHERE server_id = ?1 AND variant = ?2 AND remote_id IN ({placeholders})"
    );
    let mut values: Vec<&dyn rusqlite::ToSql> = vec![&server_id, &variant];
    for id in remote_ids {
        values.push(id);
    }
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(rusqlite::params_from_iter(values), |row| {
        Ok((row.get(0)?, row.get(1)?))
    })?;
    rows.collect()
}

/// Remove every cover record for a server (profile deletion cascade).
/// Returns the number of rows removed.
pub fn delete_for_server(conn: &Connection, server_id: &str) -> rusqlite::Result<usize> {
    conn.execute(
        "DELETE FROM thumbnails WHERE server_id = ?1",
        params![server_id],
    )
}

/// Remove one entity's cover record (delete propagation). Returns the number
/// of rows removed; the caller deletes the file itself.
pub fn delete_entity(
    conn: &Connection,
    server_id: &str,
    remote_id: &str,
    variant: &str,
) -> rusqlite::Result<usize> {
    conn.execute(
        "DELETE FROM thumbnails WHERE server_id = ?1 AND remote_id = ?2 AND variant = ?3",
        params![server_id, remote_id, variant],
    )
}

/// remote_ids of series (one server) with no recorded thumbnail — the
/// backfill list for "缓存缺失自动补齐" (missing rows are refetched by the
/// cover pipeline; rows whose file vanished are caught by the facade's
/// existence check).
pub fn list_series_missing_cover(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT s.remote_id FROM series s
         LEFT JOIN thumbnails t
           ON t.server_id = s.server_id AND t.remote_id = s.remote_id AND t.variant = ?1
         WHERE s.server_id = ?2 AND t.remote_id IS NULL
         ORDER BY s.name COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![VARIANT_SERIES, server_id], |row| row.get(0))?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    #[test]
    fn record_get_list_roundtrip() {
        let conn = open_in_memory().unwrap();
        record_thumbnail(&conn, "srv-1", "series-1", VARIANT_SERIES, "/cache/a", 1024).unwrap();

        let row = get_thumbnail(&conn, "srv-1", "series-1", VARIANT_SERIES)
            .unwrap()
            .expect("row must exist");
        assert_eq!(row.local_path, "/cache/a");
        assert_eq!(row.size_bytes, 1024);
        assert!(!row.last_access.is_empty());

        // Re-record refreshes the path/size and keeps a single row.
        record_thumbnail(&conn, "srv-1", "series-1", VARIANT_SERIES, "/cache/b", 2048).unwrap();
        let rows = list_thumbnails(&conn, "srv-1").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].local_path, "/cache/b");
        assert_eq!(rows[0].size_bytes, 2048);
    }

    #[test]
    fn multi_server_isolation_and_delete() {
        let conn = open_in_memory().unwrap();
        record_thumbnail(&conn, "srv-1", "s1", VARIANT_SERIES, "/a", 1).unwrap();
        record_thumbnail(&conn, "srv-2", "s1", VARIANT_SERIES, "/b", 1).unwrap();

        assert_eq!(list_thumbnails(&conn, "srv-1").unwrap().len(), 1);
        assert_eq!(list_thumbnails(&conn, "srv-2").unwrap().len(), 1);
        assert_eq!(
            get_thumbnail(&conn, "srv-1", "s1", VARIANT_SERIES)
                .unwrap()
                .unwrap()
                .local_path,
            "/a"
        );

        assert_eq!(delete_for_server(&conn, "srv-1").unwrap(), 1);
        assert!(list_thumbnails(&conn, "srv-1").unwrap().is_empty());
        assert_eq!(list_thumbnails(&conn, "srv-2").unwrap().len(), 1);
    }

    #[test]
    fn missing_record_returns_none() {
        let conn = open_in_memory().unwrap();
        assert!(get_thumbnail(&conn, "srv-1", "nope", VARIANT_SERIES)
            .unwrap()
            .is_none());
    }

    #[test]
    fn cover_paths_answers_only_the_ids_it_was_asked_for() {
        let conn = open_in_memory().unwrap();
        for id in ["s1", "s2", "s3"] {
            record_thumbnail(&conn, "srv-1", id, VARIANT_SERIES, &format!("/c/{id}"), 1).unwrap();
        }
        // Same remote id, other variant: must not leak into a series answer.
        record_thumbnail(&conn, "srv-1", "s1", VARIANT_BOOK, "/c/book-s1", 1).unwrap();
        // Other server: must not leak either.
        record_thumbnail(&conn, "srv-2", "s2", VARIANT_SERIES, "/other/s2", 1).unwrap();

        let asked = vec!["s1".to_string(), "s3".to_string()];
        let mut found = cover_paths(&conn, "srv-1", VARIANT_SERIES, &asked).unwrap();
        found.sort();
        assert_eq!(
            found,
            vec![
                ("s1".to_string(), "/c/s1".to_string()),
                ("s3".to_string(), "/c/s3".to_string()),
            ],
            "unasked ids (s2) must not be returned, and neither must the other variant or server"
        );

        // An empty page asks nothing and gets nothing, rather than everything.
        assert!(cover_paths(&conn, "srv-1", VARIANT_SERIES, &[])
            .unwrap()
            .is_empty());

        // Ids with no record are simply absent, not an error.
        let none = cover_paths(&conn, "srv-1", VARIANT_SERIES, &["ghost".to_string()]).unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn missing_cover_list_tracks_uncovered_series() {
        use crate::model::series::{Series, SeriesMetadata};
        use crate::store::series::save_series_batch;

        let conn = open_in_memory().unwrap();
        let series = |id: &str, name: &str| Series {
            id: id.into(),
            library_id: "lib-1".into(),
            name: name.into(),
            created: None,
            last_modified: None,
            books_count: None,
            books_read_count: None,
            books_unread_count: None,
            books_in_progress_count: None,
            books_metadata: None,
            metadata: Some(SeriesMetadata {
                title: name.into(),
                status: None,
                summary: None,
                publisher: None,
                genres: vec![],
                tags: vec![],
                authors: vec![],
                reading_direction: None,
                language: None,
                age_rating: None,
                title_sort: None,
                total_book_count: None,
            }),
        };
        save_series_batch(
            &conn,
            "srv-1",
            &[series("s1", "One Piece"), series("s2", "Berserk")],
        )
        .unwrap();
        save_series_batch(&conn, "srv-2", &[series("s1", "One Piece")]).unwrap();

        // Nothing covered yet -> both srv-1 series are missing.
        let missing = list_series_missing_cover(&conn, "srv-1").unwrap();
        assert_eq!(missing, vec!["s2".to_string(), "s1".to_string()]); // name order

        record_thumbnail(&conn, "srv-1", "s2", VARIANT_SERIES, "/a", 1).unwrap();
        let missing = list_series_missing_cover(&conn, "srv-1").unwrap();
        assert_eq!(missing, vec!["s1".to_string()]);

        // Server isolation: srv-2's s1 is still uncovered and untouched.
        assert_eq!(
            list_series_missing_cover(&conn, "srv-2").unwrap(),
            vec!["s1".to_string()]
        );
    }
}
