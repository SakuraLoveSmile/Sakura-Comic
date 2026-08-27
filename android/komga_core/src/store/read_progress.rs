//! Read progress local store (本地优先：先写本地 + Outbox，后台上传属后续阶段).
//!
//! Two writers:
//! - `upsert_synced_read_progress` — remote truth mirrored from BookDto /
//!   on-deck payloads (`mutation_pending` stays 0, `server_updated_at` set).
//! - local mutations (`upsert_local_read_progress` / `mark_read` /
//!   `mark_unread`) — write the local row AND a `pending_mutations` row so
//!   the Mutation Outbox never loses an action.

use rusqlite::{params, Connection, OptionalExtension};

use crate::store::thumbnails::now_rfc3339;

/// What a mirror sweep may do to one book's read progress.
#[derive(Debug, PartialEq, Eq)]
enum SyncWrite {
    /// An unuploaded local action wins; the sweep must not touch the row.
    Block,
    /// No local intent outstanding: mirror the server value.
    Write,
    /// The server is newer, but a passive local mutation is still queued: take
    /// the server value and keep the queue entry (dropping it here would
    /// silently discard a user action that never reached the server).
    WriteKeepPending,
}

/// Decide whether a sync write may move this book's read progress, following
/// `specs/contracts/fixtures/read-progress/offline-priority.json`:
/// explicit marks outrank any remote passive value, and a pending passive
/// progress is only replaced by a strictly newer server stamp.
fn sync_write_for(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    server_updated_at: Option<&str>,
) -> rusqlite::Result<SyncWrite> {
    let pending: Option<String> = conn
        .query_row(
            "SELECT mutation_type FROM pending_mutations
             WHERE server_id = ?1 AND entity_id = ?2
               AND mutation_type IN ('MARK_READ', 'MARK_UNREAD', 'READ_PROGRESS')
             ORDER BY created_at DESC LIMIT 1",
            params![server_id, book_id],
            |row| row.get(0),
        )
        .optional()?;
    match pending.as_deref() {
        // An explicit mark that never got uploaded outranks the server.
        Some("MARK_READ") | Some("MARK_UNREAD") => Ok(SyncWrite::Block),
        Some("READ_PROGRESS") => {
            let local: Option<String> = conn
                .query_row(
                    "SELECT local_updated_at FROM read_progress
                     WHERE server_id = ?1 AND book_id = ?2",
                    params![server_id, book_id],
                    |row| row.get(0),
                )
                .optional()?;
            let remote_newer = match (local.as_deref(), server_updated_at) {
                (Some(local), Some(remote)) => newer(remote, local),
                // No server stamp to compare against: keep what the user did.
                (Some(_), None) => false,
                (None, _) => true,
            };
            Ok(if remote_newer {
                SyncWrite::WriteKeepPending
            } else {
                SyncWrite::Block
            })
        }
        _ => Ok(SyncWrite::Write),
    }
}

/// RFC 3339 comparison that does not depend on fractional-second padding.
fn newer(candidate: &str, current: &str) -> bool {
    match (
        chrono::DateTime::parse_from_rfc3339(candidate),
        chrono::DateTime::parse_from_rfc3339(current),
    ) {
        (Ok(candidate), Ok(current)) => candidate > current,
        _ => false,
    }
}

/// Remote-truth upsert (sync path). Refuses to overwrite unuploaded local
/// intent — see `sync_write_for`.
pub fn upsert_synced_read_progress(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    page: Option<i64>,
    completed: bool,
    server_updated_at: Option<String>,
) -> rusqlite::Result<()> {
    let allowed = match sync_write_for(conn, server_id, book_id, server_updated_at.as_deref())? {
        SyncWrite::Block => return Ok(()),
        SyncWrite::Write => true,
        SyncWrite::WriteKeepPending => false,
    };
    conn.execute(
        "INSERT INTO read_progress (server_id, book_id, page, completed, server_updated_at, mutation_pending)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(server_id, book_id) DO UPDATE SET
           page = excluded.page,
           completed = excluded.completed,
           server_updated_at = excluded.server_updated_at,
           mutation_pending = excluded.mutation_pending",
        params![
            server_id,
            book_id,
            page,
            completed,
            server_updated_at,
            // 1 = keep the queued local mutation alive alongside the new value.
            if allowed { 0 } else { 1 }
        ],
    )?;
    Ok(())
}

/// The queued local intent for one book, if any (tests + the upload phase).
pub fn pending_mutation_for(conn: &Connection, server_id: &str, book_id: &str) -> Option<String> {
    conn.query_row(
        "SELECT mutation_type FROM pending_mutations
         WHERE server_id = ?1 AND entity_id = ?2
           AND mutation_type IN ('MARK_READ', 'MARK_UNREAD', 'READ_PROGRESS')
         ORDER BY created_at DESC LIMIT 1",
        params![server_id, book_id],
        |row| row.get::<_, String>(0),
    )
    .ok()
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
    /// The shared contract fixture: an offline page that never got uploaded
    /// must survive a sweep that still carries the older server value.
    #[test]
    fn offline_priority_fixture_is_enforced() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../specs/contracts/fixtures/read-progress/offline-priority.json"
        ))
        .unwrap();
        let conn = open_in_memory().unwrap();
        let book_id = fixture["remote"]["bookId"].as_str().unwrap();
        upsert_local_read_progress(&conn, "srv", book_id, 23, false).unwrap();
        // Pin the stamps the fixture describes.
        conn.execute(
            "UPDATE read_progress SET local_updated_at = ?1 WHERE server_id = ?2 AND book_id = ?3",
            params!["2025-01-02T00:00:00Z", "srv", book_id],
        )
        .unwrap();
        conn.execute(
            "UPDATE pending_mutations SET created_at = ?1 WHERE server_id = ?2 AND entity_id = ?3",
            params!["2025-01-02T00:00:00Z", "srv", book_id],
        )
        .unwrap();

        upsert_synced_read_progress(
            &conn,
            "srv",
            book_id,
            Some(fixture["remote"]["page"].as_i64().unwrap()),
            fixture["remote"]["completed"].as_bool().unwrap(),
            Some(
                fixture["remote"]["serverUpdatedAt"]
                    .as_str()
                    .unwrap()
                    .to_string(),
            ),
        )
        .unwrap();

        let (page, completed, pending): (Option<i64>, i64, i64) = conn
            .query_row(
                "SELECT page, completed, mutation_pending FROM read_progress
                 WHERE server_id = ?1 AND book_id = ?2",
                params!["srv", book_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(
            page,
            fixture["expected"]["page"].as_i64(),
            "local page must survive"
        );
        assert_eq!(
            completed == 1,
            fixture["expected"]["completed"].as_bool().unwrap()
        );
        assert_eq!(pending, 1, "the mutation must stay queued for upload");
        assert_eq!(
            fixture["expected"]["uploadRequired"].as_bool().unwrap(),
            pending_mutation_for(&conn, "srv", book_id).is_some()
        );
    }

    /// An explicit mark is user intent: a remote passive value never outranks
    /// it while the mutation is still queued.
    #[test]
    fn explicit_marks_outrank_remote_progress() {
        let conn = open_in_memory().unwrap();
        mark_read(&conn, "srv", "b1").unwrap();
        upsert_synced_read_progress(
            &conn,
            "srv",
            "b1",
            Some(40),
            false,
            Some("2027-01-01T00:00:00Z".into()),
        )
        .unwrap();
        let row: (Option<i64>, i64) = conn
            .query_row(
                "SELECT page, completed FROM read_progress WHERE server_id = ?1 AND book_id = ?2",
                params!["srv", "b1"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            row,
            (None, 1),
            "mark-read must survive even a newer server value"
        );

        // Mark-unread must not be outvoted by a bigger page number either.
        mark_unread(&conn, "srv", "b2").unwrap();
        upsert_synced_read_progress(
            &conn,
            "srv",
            "b2",
            Some(40),
            true,
            Some("2027-01-01T00:00:00Z".into()),
        )
        .unwrap();
        let row: (Option<i64>, i64) = conn
            .query_row(
                "SELECT page, completed FROM read_progress WHERE server_id = ?1 AND book_id = ?2",
                params!["srv", "b2"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            row,
            (Some(0), 0),
            "mark-unread must not be overridden by max(page)"
        );
    }

    /// With only a passive local progress queued, a genuinely newer server
    /// value is adopted — but the queued mutation is kept, because dropping it
    /// here would discard a user action the server never saw.
    #[test]
    fn newer_server_progress_wins_and_keeps_the_queue() {
        let conn = open_in_memory().unwrap();
        upsert_local_read_progress(&conn, "srv", "b1", 5, false).unwrap();
        conn.execute(
            "UPDATE read_progress SET local_updated_at = '2025-01-01T00:00:00Z'
             WHERE server_id = 'srv' AND book_id = 'b1'",
            [],
        )
        .unwrap();
        upsert_synced_read_progress(
            &conn,
            "srv",
            "b1",
            Some(9),
            false,
            Some("2025-06-01T00:00:00Z".into()),
        )
        .unwrap();
        let (page, pending): (Option<i64>, i64) = conn
            .query_row(
                "SELECT page, mutation_pending FROM read_progress WHERE server_id = ?1 AND book_id = ?2",
                params!["srv", "b1"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(page, Some(9), "the newer server value is mirrored");
        assert_eq!(
            pending, 1,
            "the queued local mutation is not silently dropped"
        );
        assert!(pending_mutation_for(&conn, "srv", "b1").is_some());
    }

    /// No local intent: the sweep mirrors the server as usual.
    #[test]
    fn remote_progress_without_local_intent_is_mirrored() {
        let conn = open_in_memory().unwrap();
        upsert_synced_read_progress(
            &conn,
            "srv",
            "b1",
            Some(12),
            false,
            Some("2025-06-01T00:00:00Z".into()),
        )
        .unwrap();
        let (page, pending): (Option<i64>, i64) = conn
            .query_row(
                "SELECT page, mutation_pending FROM read_progress WHERE server_id = ?1 AND book_id = ?2",
                params!["srv", "b1"],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!((page, pending), (Some(12), 0));
    }

    /// The whole point of the guard on the sync path: a bootstrap or reconcile
    /// sweep that carries an older server value must not lose offline progress.
    #[test]
    fn a_sweep_cannot_lose_offline_progress() {
        let conn = open_in_memory().unwrap();
        upsert_synced_read_progress(
            &conn,
            "srv",
            "b1",
            Some(3),
            false,
            Some("2025-01-01T00:00:00Z".into()),
        )
        .unwrap();
        upsert_local_read_progress(&conn, "srv", "b1", 21, false).unwrap();
        conn.execute(
            "UPDATE read_progress SET local_updated_at = '2025-06-01T00:00:00Z'
             WHERE server_id = 'srv' AND book_id = 'b1'",
            [],
        )
        .unwrap();
        // The server still reports page 3 (its upload never landed).
        upsert_synced_read_progress(
            &conn,
            "srv",
            "b1",
            Some(3),
            false,
            Some("2025-01-01T00:00:00Z".into()),
        )
        .unwrap();
        let page: Option<i64> = conn
            .query_row(
                "SELECT page FROM read_progress WHERE server_id = ?1 AND book_id = ?2",
                params!["srv", "b1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(page, Some(21), "offline progress survived the sweep");
    }

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
