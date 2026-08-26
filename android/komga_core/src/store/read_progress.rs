//! Read progress local store (本地优先：先写本地 + Outbox，后台上传属后续阶段).
//!
//! Two writers:
//! - `upsert_synced_read_progress` — remote truth mirrored from BookDto /
//!   on-deck payloads (`mutation_pending` stays 0, `server_updated_at` set).
//! - local mutations (`upsert_local_read_progress` / `mark_read` /
//!   `mark_unread`) — write the local row AND a `pending_mutations` row so
//!   the Mutation Outbox never loses an action.

use rusqlite::{params, Connection};

use crate::store::thumbnails::now_rfc3339;

/// Remote-truth upsert (sync path).
pub fn upsert_synced_read_progress(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    page: Option<i64>,
    completed: bool,
    server_updated_at: Option<String>,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO read_progress (server_id, book_id, page, completed, server_updated_at, mutation_pending)
         VALUES (?1, ?2, ?3, ?4, ?5, 0)
         ON CONFLICT(server_id, book_id) DO UPDATE SET
           page = excluded.page,
           completed = excluded.completed,
           server_updated_at = excluded.server_updated_at,
           mutation_pending = 0",
        params![server_id, book_id, page, completed, server_updated_at],
    )?;
    Ok(())
}

/// Local page update: write the local row + an outbox row (READ_PROGRESS).
pub fn upsert_local_read_progress(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    page: i64,
    completed: bool,
) -> rusqlite::Result<()> {
    let tx = conn.unchecked_transaction()?;
    let now = now_rfc3339();
    tx.execute(
        "INSERT INTO read_progress (server_id, book_id, page, completed, local_updated_at, mutation_pending)
         VALUES (?1, ?2, ?3, ?4, ?5, 1)
         ON CONFLICT(server_id, book_id) DO UPDATE SET
           page = excluded.page,
           completed = excluded.completed,
           local_updated_at = excluded.local_updated_at,
           mutation_pending = 1",
        params![server_id, book_id, page, completed, now],
    )?;
    enqueue_mutation(
        &tx,
        server_id,
        book_id,
        "READ_PROGRESS",
        &serde_json::json!({
            "bookId": book_id, "page": page, "completed": completed,
        }),
        &now,
    )?;
    tx.commit()?;
    Ok(())
}

/// Explicit mark-read (priority over passive progress; outbox row
/// MARK_READ so the upload phase can apply it verbatim).
pub fn mark_read(conn: &Connection, server_id: &str, book_id: &str) -> rusqlite::Result<()> {
    local_mutation(conn, server_id, book_id, "MARK_READ", true, None)
}

/// Explicit mark-unread: cannot be overridden by max(page)-style merges.
pub fn mark_unread(conn: &Connection, server_id: &str, book_id: &str) -> rusqlite::Result<()> {
    local_mutation(conn, server_id, book_id, "MARK_UNREAD", false, Some(0))
}

fn local_mutation(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    mutation_type: &str,
    completed: bool,
    page: Option<i64>,
) -> rusqlite::Result<()> {
    let tx = conn.unchecked_transaction()?;
    let now = now_rfc3339();
    tx.execute(
        "INSERT INTO read_progress (server_id, book_id, page, completed, local_updated_at, mutation_pending)
         VALUES (?1, ?2, ?3, ?4, ?5, 1)
         ON CONFLICT(server_id, book_id) DO UPDATE SET
           page = excluded.page,
           completed = excluded.completed,
           local_updated_at = excluded.local_updated_at,
           mutation_pending = 1",
        params![server_id, book_id, page, completed, now],
    )?;
    enqueue_mutation(
        &tx,
        server_id,
        book_id,
        mutation_type,
        &serde_json::json!({
            "bookId": book_id, "completed": completed,
        }),
        &now,
    )?;
    tx.commit()?;
    Ok(())
}

fn enqueue_mutation(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    mutation_type: &str,
    payload: &serde_json::Value,
    created_at: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO pending_mutations (id, server_id, entity_id, mutation_type, payload, created_at, retry_count)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0)",
        params![
            uuid::Uuid::new_v4().to_string(),
            server_id,
            book_id,
            mutation_type,
            payload.to_string(),
            created_at,
        ],
    )?;
    Ok(())
}

/// The continue-reading shelf: books read partially (page > 0, not
/// completed), newest local activity first. 断开网络后依旧可用：
/// 完全由 read_progress + books 本地查询构成。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContinueReadingRow {
    pub book_id: String,
    pub book_title: String,
    pub number: Option<String>,
    pub series_id: String,
    pub series_name: String,
    pub page: Option<i64>,
    pub total_pages: Option<i64>,
    /// Progress 0–100 when total pages are known (UI progress bar).
    pub progress_pct: Option<i64>,
    pub local_updated_at: Option<String>,
}

pub fn continue_reading(
    conn: &Connection,
    server_id: &str,
    limit: i64,
) -> rusqlite::Result<Vec<ContinueReadingRow>> {
    let mut stmt = conn.prepare(
        "SELECT b.remote_id AS book_id, b.title AS book_title, b.number, b.series_id,
                COALESCE(s.name, b.series_title) AS series_name,
                rp.page, b.pages_count AS total_pages,
                CASE WHEN b.pages_count IS NOT NULL AND b.pages_count > 0 AND rp.page IS NOT NULL
                     THEN (rp.page * 100 / b.pages_count) END AS progress_pct,
                rp.local_updated_at
           FROM read_progress rp
           JOIN books b ON b.server_id = rp.server_id AND b.remote_id = rp.book_id
           LEFT JOIN series s ON s.server_id = b.server_id AND s.remote_id = b.series_id
          WHERE rp.server_id = ?1 AND rp.completed = 0 AND rp.page IS NOT NULL AND rp.page > 0
          ORDER BY COALESCE(rp.local_updated_at, rp.server_updated_at) DESC
          LIMIT ?2",
    )?;
    let rows = stmt.query_map(params![server_id, limit], |row| {
        Ok(ContinueReadingRow {
            book_id: row.get("book_id")?,
            book_title: row.get("book_title")?,
            number: row.get("number")?,
            series_id: row.get("series_id")?,
            series_name: row.get("series_name")?,
            page: row.get("page")?,
            total_pages: row.get("total_pages")?,
            progress_pct: row.get("progress_pct")?,
            local_updated_at: row.get("local_updated_at")?,
        })
    })?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::book::Book;
    use crate::model::book::BookMetadata;
    use crate::store::books::save_books_batch;
    use crate::store::open_in_memory;

    fn book(id: &str, series_id: &str, title: &str) -> Book {
        Book {
            id: id.into(),
            series_id: series_id.into(),
            series_title: Some("One Piece".into()),
            name: title.into(),
            number: None,
            oneshot: false,
            media: Some(crate::model::book::Media {
                media_type: Some("application/pdf".into()),
                pages_count: Some(20),
            }),
            metadata: Some(BookMetadata {
                title: title.into(),
                number: None,
                number_sort: None,
                summary: None,
                isbn: None,
                release_date: None,
                authors: vec![],
                tags: vec![],
            }),
            read_progress: None,
            created: None,
            last_modified: None,
            size_bytes: None,
        }
    }

    #[test]
    fn synced_progress_overwritten_by_local_and_outbox_rows_written() {
        let conn = open_in_memory().unwrap();
        save_books_batch(&conn, "server-1", &[book("b1", "s1", "Book 1")]).unwrap();

        // Remote truth arrives.
        upsert_synced_read_progress(
            &conn,
            "server-1",
            "b1",
            Some(5),
            false,
            Some("2025-01-01T00:00:00Z".into()),
        )
        .unwrap();
        // Local update wins locally, mutation queued.
        upsert_local_read_progress(&conn, "server-1", "b1", 8, false).unwrap();

        let conn2 = &conn;
        let (page, pending): (Option<i64>, i64) = conn2
            .query_row(
                "SELECT page, mutation_pending FROM read_progress WHERE server_id = ?1 AND book_id = ?2",
                params!["server-1", "b1"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(page, Some(8));
        assert_eq!(pending, 1);
        let outbox: i64 = conn2
            .query_row(
                "SELECT COUNT(*) FROM pending_mutations WHERE server_id = ?1 AND entity_id = ?2",
                params!["server-1", "b1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(outbox, 1);
    }

    #[test]
    fn mark_read_and_unread_are_explicit() {
        let conn = open_in_memory().unwrap();
        save_books_batch(&conn, "server-1", &[book("b1", "s1", "Book 1")]).unwrap();
        mark_read(&conn, "server-1", "b1").unwrap();
        let row = crate::store::books::get_book(&conn, "server-1", "b1")
            .unwrap()
            .unwrap();
        assert!(row.progress_completed);
        // completed=1 drops the book off continue reading AND mark_unread flips it back.
        assert!(continue_reading(&conn, "server-1", 10).unwrap().is_empty());
        mark_unread(&conn, "server-1", "b1").unwrap();
        assert!(continue_reading(&conn, "server-1", 10).unwrap().is_empty());
    }

    #[test]
    fn continue_reading_lists_partial_books_only() {
        let conn = open_in_memory().unwrap();
        save_books_batch(
            &conn,
            "server-1",
            &[
                book("b1", "s1", "Book 1"),
                book("b2", "s1", "Book 2"),
                book("b3", "s1", "Book 3"),
            ],
        )
        .unwrap();
        upsert_synced_read_progress(&conn, "server-1", "b1", Some(20), true, None).unwrap();
        upsert_local_read_progress(&conn, "server-1", "b2", 5, false).unwrap();
        // b3: untouched.

        let rows = continue_reading(&conn, "server-1", 10).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].book_id, "b2");
        assert_eq!(rows[0].book_title, "Book 2");
        assert_eq!(rows[0].page, Some(5));
        assert_eq!(rows[0].total_pages, Some(20));
        assert_eq!(rows[0].progress_pct, Some(25));
        assert_eq!(rows[0].series_name, "One Piece");
    }
}
