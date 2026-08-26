//! FTS5 search-index maintenance + query-string building.
//!
//! `series_fts` / `book_fts` are standalone FTS5 tables carrying a
//! `server_id UNINDEXED` column; `series.fts_rowid` / `books.fts_rowid`
//! track each row so updates stay incremental (a full rebuild would be
//! O(batches × library)). 搜索基于 SQLite：用户输入被转义成安全的
//! FTS5 MATCH 表达式，绝不经由网络。

use rusqlite::{params, Connection};

/// Build a safe FTS5 MATCH expression from free-text user input.
///
/// `"one piece"` → `"one"* AND "piece"*` — each whitespace-separated term
/// becomes a double-quoted prefix query (quotes and FTS5 metacharacters are
/// stripped). Terms without alphanumerics are dropped, so an empty input
/// yields an expression that matches nothing (the caller treats it as
/// "no search").
pub fn fts_match_query(raw: &str) -> String {
    let terms: Vec<String> = raw
        .split_whitespace()
        .map(|term| {
            term.chars()
                .filter(|c| c.is_alphanumeric())
                .collect::<String>()
        })
        .filter(|term| !term.is_empty())
        .collect();
    if terms.is_empty() {
        return String::new();
    }
    terms
        .iter()
        .map(|term| format!("\"{term}\"*"))
        .collect::<Vec<_>>()
        .join(" AND ")
}

/// Upsert one series' search row; records the FTS rowid on `series`.
#[allow(clippy::too_many_arguments)]
pub fn upsert_series_fts(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
    fts_rowid: Option<i64>,
    name: &str,
    sort_name: &str,
    authors: &str,
    publisher: &str,
    tags: &str,
    summary: &str,
) -> rusqlite::Result<()> {
    let rowid = match fts_rowid {
        Some(rid) => {
            conn.execute(
                "UPDATE series_fts SET name=?1, sort_name=?2, authors=?3, publisher=?4, tags=?5, summary=?6 WHERE rowid=?7",
                params![name, sort_name, authors, publisher, tags, summary, rid],
            )?;
            rid
        }
        None => {
            conn.execute(
                "INSERT INTO series_fts(server_id, name, sort_name, authors, publisher, tags, summary)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![server_id, name, sort_name, authors, publisher, tags, summary],
            )?;
            conn.last_insert_rowid()
        }
    };
    conn.execute(
        "UPDATE series SET fts_rowid = ?1 WHERE server_id = ?2 AND remote_id = ?3",
        params![rowid, server_id, series_id],
    )?;
    Ok(())
}

/// Upsert one book's search row; records the FTS rowid on `books`.
#[allow(clippy::too_many_arguments)]
pub fn upsert_book_fts(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    fts_rowid: Option<i64>,
    title: &str,
    authors: &str,
    tags: &str,
    summary: &str,
) -> rusqlite::Result<()> {
    let rowid = match fts_rowid {
        Some(rid) => {
            conn.execute(
                "UPDATE book_fts SET title=?1, authors=?2, tags=?3, summary=?4 WHERE rowid=?5",
                params![title, authors, tags, summary, rid],
            )?;
            rid
        }
        None => {
            conn.execute(
                "INSERT INTO book_fts(server_id, title, authors, tags, summary)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![server_id, title, authors, tags, summary],
            )?;
            conn.last_insert_rowid()
        }
    };
    conn.execute(
        "UPDATE books SET fts_rowid = ?1 WHERE server_id = ?2 AND remote_id = ?3",
        params![rowid, server_id, book_id],
    )?;
    Ok(())
}

/// Drop every search row for one server (profile deletion cascade).
pub fn delete_fts_for_server(conn: &Connection, server_id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM series_fts WHERE server_id = ?1",
        params![server_id],
    )?;
    conn.execute(
        "DELETE FROM book_fts WHERE server_id = ?1",
        params![server_id],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fts_query_escapes_and_prefixes_terms() {
        assert_eq!(fts_match_query("one piece"), "\"one\"* AND \"piece\"*");
        assert_eq!(fts_match_query("  berserk  "), "\"berserk\"*");
        assert_eq!(
            fts_match_query("a \"quoted\" (term)"),
            "\"a\"* AND \"quoted\"* AND \"term\"*"
        );
        assert_eq!(fts_match_query("*!!!***"), "");
        assert_eq!(fts_match_query(""), "");
        // CJK terms survive (unicode61 treats runs as tokens).
        assert_eq!(fts_match_query("海贼王"), "\"海贼王\"*");
    }

    #[test]
    fn fts_rows_upsert_incrementally() {
        let conn = crate::store::open_in_memory().unwrap();
        let page = crate::model::series::SeriesPage {
            content: vec![crate::model::series::Series {
                id: "s1".into(),
                library_id: "lib-1".into(),
                name: "One Piece".into(),
                created: None,
                last_modified: None,
                books_count: None,
                books_read_count: None,
                books_unread_count: None,
                books_in_progress_count: None,
                books_metadata: None,
                metadata: None,
            }],
            total_elements: 1,
            total_pages: 1,
            number: 0,
            size: 100,
            first: true,
            last: true,
        };
        crate::store::series::save_series_batch(&conn, "server-1", &page.content).unwrap();

        let rowid: Option<i64> = conn
            .query_row(
                "SELECT fts_rowid FROM series WHERE server_id = ?1 AND remote_id = ?2",
                params!["server-1", "s1"],
                |row| row.get(0),
            )
            .unwrap();
        assert!(rowid.is_some(), "fts_rowid must be tracked");

        // The row is searchable, and the update path keeps it searchable.
        upsert_series_fts(
            &conn,
            "server-1",
            "s1",
            rowid,
            "One Piece",
            "One Piece",
            "Eiichiro Oda",
            "Shueisha",
            "Manga, Shonen",
            "A pirate adventure.",
        )
        .unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM series_fts WHERE series_fts MATCH ?1 AND server_id = ?2",
                params![fts_match_query("oda"), "server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
        // Second series on another server must not leak in.
        let count2: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM series_fts WHERE series_fts MATCH ?1 AND server_id = ?2",
                params![fts_match_query("oda"), "server-2"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count2, 0);
    }
}
