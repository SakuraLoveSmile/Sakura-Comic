//! `book_pages` — the mirrored page manifest (schema v8).
//!
//! Local-first applies to pixels too: once a book's page list has been seen it
//! lives here, so opening the book again is a database read and a book that was
//! opened once can be re-read with the server unreachable.

use rusqlite::{params, Connection};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageRow {
    pub number: i64,
    pub file_name: String,
    pub media_type: String,
    pub width: i64,
    pub height: i64,
    pub size_bytes: i64,
}

/// Replace the whole manifest for one book. The manifest has no partial
/// updates — a page list is only meaningful as a set, and a half-written one
/// would shift every canonical number.
pub fn replace(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    rows: &[PageRow],
    now: &str,
) -> rusqlite::Result<usize> {
    // `unchecked_transaction` is the project's idiom for a write started from a
    // shared connection (see `store::read_progress`): the reader opens one
    // connection per call, so no second transaction can be in flight.
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "DELETE FROM book_pages WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
    )?;
    let mut inserted = 0usize;
    {
        let mut statement = tx.prepare(
            "INSERT INTO book_pages (server_id, book_id, number, file_name, media_type,
                                     width, height, size_bytes, fetched_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        )?;
        for row in rows {
            statement.execute(params![
                server_id,
                book_id,
                row.number,
                row.file_name,
                row.media_type,
                row.width,
                row.height,
                row.size_bytes,
                now
            ])?;
            inserted += 1;
        }
    }
    tx.commit()?;
    Ok(inserted)
}

pub fn list(conn: &Connection, server_id: &str, book_id: &str) -> rusqlite::Result<Vec<PageRow>> {
    let mut statement = conn.prepare(
        "SELECT number, file_name, media_type, width, height, size_bytes
         FROM book_pages WHERE server_id = ?1 AND book_id = ?2 ORDER BY number ASC",
    )?;
    let rows = statement.query_map(params![server_id, book_id], |row| {
        Ok(PageRow {
            number: row.get(0)?,
            file_name: row.get(1)?,
            media_type: row.get(2)?,
            width: row.get(3)?,
            height: row.get(4)?,
            size_bytes: row.get(5)?,
        })
    })?;
    Ok(rows.filter_map(Result::ok).collect())
}

pub fn count(conn: &Connection, server_id: &str, book_id: &str) -> rusqlite::Result<u32> {
    let count: i64 = conn.query_row(
        "SELECT COUNT(*) FROM book_pages WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
        |row| row.get(0),
    )?;
    Ok(count as u32)
}

/// When this mirror was last refreshed, for a staleness policy.
pub fn fetched_at(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Option<String>> {
    conn.query_row(
        "SELECT MAX(fetched_at) FROM book_pages WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
        |row| row.get::<_, Option<String>>(0),
    )
}

pub fn delete_book(conn: &Connection, server_id: &str, book_id: &str) -> rusqlite::Result<usize> {
    conn.execute(
        "DELETE FROM book_pages WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
    )
}

pub fn delete_server(conn: &Connection, server_id: &str) -> rusqlite::Result<usize> {
    conn.execute(
        "DELETE FROM book_pages WHERE server_id = ?1",
        params![server_id],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    fn row(number: i64) -> PageRow {
        PageRow {
            number,
            file_name: format!("p{number}.jpg"),
            media_type: "image/jpeg".to_string(),
            width: 1000,
            height: 1500,
            size_bytes: 1024,
        }
    }

    #[test]
    fn replace_is_wholesale_and_order_preserving() {
        let conn = open_in_memory().unwrap();
        replace(
            &conn,
            "s1",
            "b1",
            &[row(1), row(2), row(3)],
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        assert_eq!(count(&conn, "s1", "b1").unwrap(), 3);
        assert_eq!(
            fetched_at(&conn, "s1", "b1").unwrap().as_deref(),
            Some("2026-01-01T00:00:00.000Z")
        );

        // A shorter new manifest must not leave the tail of the old one behind:
        // stale trailing pages would shift every canonical number.
        replace(&conn, "s1", "b1", &[row(1)], "2026-01-02T00:00:00.000Z").unwrap();
        let pages = list(&conn, "s1", "b1").unwrap();
        assert_eq!(pages.len(), 1);
        assert_eq!(pages[0].number, 1);
    }

    #[test]
    fn mirrors_are_server_scoped() {
        let conn = open_in_memory().unwrap();
        replace(&conn, "s1", "b1", &[row(1)], "t").unwrap();
        replace(&conn, "s2", "b1", &[row(1), row(2)], "t").unwrap();
        assert_eq!(count(&conn, "s1", "b1").unwrap(), 1);
        assert_eq!(count(&conn, "s2", "b1").unwrap(), 2);
        delete_server(&conn, "s1").unwrap();
        assert_eq!(count(&conn, "s1", "b1").unwrap(), 0);
        assert_eq!(count(&conn, "s2", "b1").unwrap(), 2);
    }
}
