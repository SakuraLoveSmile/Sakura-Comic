//! `reader_position` — what the screen was showing (schema v8).
//!
//! This is NOT `read_progress`. `read_progress.page` is the value that syncs to
//! Komga and is subject to the Stage 6 conflict rules; `reader_position` is
//! local display state — the page the reader landed on plus the mode and
//! direction it was rendered with — and it is never uploaded.
//!
//! Keeping them apart is what makes restore exact: opening a book that was
//! closed on a double-page spread in RTL must come back as that spread in RTL,
//! not as page N in whatever the global default is.

use rusqlite::{params, Connection, OptionalExtension};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Position {
    pub page: i64,
    pub mode: String,
    pub direction: String,
    pub updated_at: String,
}

#[allow(clippy::too_many_arguments)]
pub fn save(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    page: u32,
    mode: &str,
    direction: &str,
    now: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO reader_position (server_id, book_id, page, mode, direction, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(server_id, book_id) DO UPDATE SET page = excluded.page,
                                                       mode = excluded.mode,
                                                       direction = excluded.direction,
                                                       updated_at = excluded.updated_at",
        params![server_id, book_id, page as i64, mode, direction, now],
    )?;
    Ok(())
}

pub fn get(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Option<Position>> {
    conn.query_row(
        "SELECT page, mode, direction, updated_at FROM reader_position
         WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
        |row| {
            Ok(Position {
                page: row.get(0)?,
                mode: row.get(1)?,
                direction: row.get(2)?,
                updated_at: row.get(3)?,
            })
        },
    )
    .optional()
}

pub fn delete(conn: &Connection, server_id: &str, book_id: &str) -> rusqlite::Result<usize> {
    conn.execute(
        "DELETE FROM reader_position WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
    )
}

pub fn delete_server(conn: &Connection, server_id: &str) -> rusqlite::Result<usize> {
    conn.execute(
        "DELETE FROM reader_position WHERE server_id = ?1",
        params![server_id],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    #[test]
    fn one_row_per_book_and_it_is_overwritten() {
        let conn = open_in_memory().unwrap();
        assert_eq!(get(&conn, "s1", "b1").unwrap(), None);
        save(
            &conn,
            "s1",
            "b1",
            12,
            "double",
            "rtl",
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        save(
            &conn,
            "s1",
            "b1",
            14,
            "webtoon",
            "vertical",
            "2026-01-02T00:00:00.000Z",
        )
        .unwrap();
        let position = get(&conn, "s1", "b1").unwrap().unwrap();
        assert_eq!(
            position,
            Position {
                page: 14,
                mode: "webtoon".to_string(),
                direction: "vertical".to_string(),
                updated_at: "2026-01-02T00:00:00.000Z".to_string(),
            }
        );
        assert_eq!(delete(&conn, "s1", "b1").unwrap(), 1);
        assert_eq!(get(&conn, "s1", "b1").unwrap(), None);
    }

    #[test]
    fn positions_are_server_scoped() {
        let conn = open_in_memory().unwrap();
        save(&conn, "s1", "b1", 5, "single", "ltr", "t").unwrap();
        save(&conn, "s2", "b1", 9, "single", "ltr", "t").unwrap();
        assert_eq!(get(&conn, "s1", "b1").unwrap().unwrap().page, 5);
        assert_eq!(get(&conn, "s2", "b1").unwrap().unwrap().page, 9);
        delete_server(&conn, "s1").unwrap();
        assert_eq!(get(&conn, "s1", "b1").unwrap(), None);
        assert_eq!(get(&conn, "s2", "b1").unwrap().unwrap().page, 9);
    }
}
