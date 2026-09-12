//! `reader_position` — what the screen was showing (schema v10).
//!
//! This is NOT `read_progress`. `read_progress.page` is the value that syncs to
//! Komga and is subject to the Stage 6 conflict rules; `reader_position` is
//! local display state — where the reader was when the book was closed — and it
//! is never uploaded.
//!
//! `mode` / `direction` are still written, but since v10 they no longer decide
//! anything: the reading mode and direction come from the two-level rule
//! (series override → global setting), so that changing a mode inside one book
//! cannot leak into the next. They stay in the row because they are a record of
//! what the user actually did, and dropping history to save a decision is a
//! trade this project does not make.
//!
//! `page_offset_ratio` is the part that *is* still read: a webtoon is one tall
//! column, so the page number alone does not say where the reader was.

use rusqlite::{params, Connection, OptionalExtension};

#[derive(Clone, Debug, PartialEq)]
pub struct Position {
    pub page: i64,
    /// How far into `page` the reader was, 0..1. `None` for single/double page
    /// modes and for every row written before v10 — which is a different fact
    /// from "the top of the page", so it is not stored as `0.0`.
    pub page_offset_ratio: Option<f64>,
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
    save_with_offset(conn, server_id, book_id, page, mode, direction, None, now)
}

/// [`save`] plus the webtoon scroll offset.
///
/// The ratio is clamped rather than rejected: a reader that scrolled to 1.02
/// because of an overscroll bounce is still at the bottom of the page, and
/// failing the save would throw away the page number too.
#[allow(clippy::too_many_arguments)]
pub fn save_with_offset(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    page: u32,
    mode: &str,
    direction: &str,
    page_offset_ratio: Option<f64>,
    now: &str,
) -> rusqlite::Result<()> {
    let ratio = page_offset_ratio.map(|r| r.clamp(0.0, 1.0));
    conn.execute(
        "INSERT INTO reader_position
             (server_id, book_id, page, mode, direction, page_offset_ratio, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(server_id, book_id) DO UPDATE SET page = excluded.page,
                                                       mode = excluded.mode,
                                                       direction = excluded.direction,
                                                       page_offset_ratio = excluded.page_offset_ratio,
                                                       updated_at = excluded.updated_at",
        params![server_id, book_id, page as i64, mode, direction, ratio, now],
    )?;
    Ok(())
}

pub fn get(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Option<Position>> {
    conn.query_row(
        "SELECT page, mode, direction, page_offset_ratio, updated_at FROM reader_position
         WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
        |row| {
            Ok(Position {
                page: row.get(0)?,
                mode: row.get(1)?,
                direction: row.get(2)?,
                page_offset_ratio: row.get(3)?,
                updated_at: row.get(4)?,
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
                page_offset_ratio: None,
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

    #[test]
    fn a_webtoon_offset_round_trips_and_a_page_mode_leaves_it_null() {
        let conn = open_in_memory().unwrap();

        save_with_offset(
            &conn,
            "s1",
            "b1",
            62,
            "webtoon",
            "ltr",
            Some(0.42),
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        let row = get(&conn, "s1", "b1").unwrap().unwrap();
        assert_eq!(row.page_offset_ratio, Some(0.42));

        // A single-page save of the same book clears it: the reader is no longer
        // in a scrolling mode, and a stale offset would restore a scroll that
        // does not exist.
        save(
            &conn,
            "s1",
            "b1",
            63,
            "single",
            "ltr",
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        let row = get(&conn, "s1", "b1").unwrap().unwrap();
        assert_eq!(row.page_offset_ratio, None, "page modes have no offset");
    }

    #[test]
    fn an_out_of_range_offset_is_clamped_not_rejected() {
        let conn = open_in_memory().unwrap();

        // An overscroll bounce can report past the end; the page number is still
        // worth saving, so the ratio is clamped instead of failing the write.
        save_with_offset(
            &conn,
            "s1",
            "b1",
            5,
            "webtoon",
            "ltr",
            Some(1.4),
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        assert_eq!(
            get(&conn, "s1", "b1").unwrap().unwrap().page_offset_ratio,
            Some(1.0)
        );

        save_with_offset(
            &conn,
            "s1",
            "b2",
            5,
            "webtoon",
            "ltr",
            Some(-0.3),
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        assert_eq!(
            get(&conn, "s1", "b2").unwrap().unwrap().page_offset_ratio,
            Some(0.0)
        );
    }
}
