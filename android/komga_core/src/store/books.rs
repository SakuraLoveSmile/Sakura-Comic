//! Books local store — batch upsert (row + metadata + tags + authors +
//! read progress + FTS row) and detail reads. Filtering / sorting /
//! pagination lives in `store::query` (本地查询).

use rusqlite::{params, Connection, Row};

use crate::model::book::{Book, BookMetadata};
use crate::store::fts;

/// Locally stored book row (read progress comes from a LEFT JOIN so the
/// book list and read-status filters read one table set).
#[derive(Debug, Clone, PartialEq)]
pub struct BookRow {
    pub server_id: String,
    pub remote_id: String,
    pub series_id: String,
    pub series_title: Option<String>,
    pub title: String,
    pub number: Option<String>,
    pub number_sort: Option<f64>,
    pub file_size: Option<i64>,
    pub media_type: Option<String>,
    pub pages_count: Option<i64>,
    pub created_at: Option<String>,
    pub last_modified: Option<String>,
    pub progress_page: Option<i64>,
    pub progress_completed: bool,
    /// FTS rowid (incremental search-index updates); internal.
    pub fts_rowid: Option<i64>,
}

pub fn row_to_book(row: &Row) -> rusqlite::Result<BookRow> {
    Ok(BookRow {
        server_id: row.get("server_id")?,
        remote_id: row.get("remote_id")?,
        series_id: row.get("series_id")?,
        series_title: row.get("series_title")?,
        title: row.get("title")?,
        number: row.get("number")?,
        number_sort: row.get("number_sort")?,
        file_size: row.get("file_size")?,
        media_type: row.get("media_type")?,
        pages_count: row.get("pages_count")?,
        created_at: row.get("created_at")?,
        last_modified: row.get("last_modified")?,
        progress_page: row.get("progress_page")?,
        progress_completed: row.get("progress_completed")?,
        fts_rowid: row.get("fts_rowid")?,
    })
}

/// The SELECT shape every book query uses (books LEFT JOIN read_progress).
pub const BOOK_SELECT: &str =
    "SELECT b.server_id, b.remote_id, b.series_id, b.series_title, b.title,
       b.number, b.number_sort, b.file_size, b.media_type, b.pages_count,
       b.created_at, b.last_modified, b.fts_rowid,
       rp.page AS progress_page, COALESCE(rp.completed, 0) AS progress_completed
  FROM books b LEFT JOIN read_progress rp
    ON rp.server_id = b.server_id AND rp.book_id = b.remote_id";

fn authors_text(names: &[crate::model::author::Author]) -> String {
    names
        .iter()
        .map(|a| a.name.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Batch upsert: book row + book_metadata + normalized tags/authors +
/// remote read progress + incremental FTS row, in one transaction.
pub fn save_books_batch(
    conn: &Connection,
    server_id: &str,
    books: &[Book],
) -> rusqlite::Result<usize> {
    let tx = conn.unchecked_transaction()?;
    let mut written = 0;
    for item in books {
        let md: Option<&BookMetadata> = item.metadata.as_ref();
        let title = md
            .map(|m| m.title.clone())
            .unwrap_or_else(|| item.name.clone());
        let number = md
            .and_then(|m| m.number.clone())
            .or_else(|| item.number.map(|n| n.to_string()));
        let number_sort = md
            .and_then(|m| m.number_sort)
            .or_else(|| item.number.map(|n| n as f64));
        tx.execute(
            "INSERT INTO books (server_id, remote_id, series_id, series_title, title, number, number_sort,
                                file_size, media_type, pages_count, created_at, last_modified, oneshot)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
             ON CONFLICT(server_id, remote_id) DO UPDATE SET
               series_id = excluded.series_id,
               series_title = excluded.series_title,
               title = excluded.title,
               number = excluded.number,
               number_sort = excluded.number_sort,
               file_size = excluded.file_size,
               media_type = excluded.media_type,
               pages_count = excluded.pages_count,
               created_at = excluded.created_at,
               last_modified = excluded.last_modified,
               oneshot = excluded.oneshot",
            params![
                server_id,
                item.id,
                item.series_id,
                item.series_title,
                title,
                number,
                number_sort,
                item.size_bytes,
                item.media.as_ref().and_then(|m| m.media_type.clone()),
                item.media.as_ref().and_then(|m| m.pages_count),
                item.created,
                item.last_modified,
                item.oneshot,
            ],
        )?;

        tx.execute(
            "INSERT INTO book_metadata (server_id, book_id, summary, number, number_sort, isbn, release_date)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(server_id, book_id) DO UPDATE SET
               summary = excluded.summary,
               number = excluded.number,
               number_sort = excluded.number_sort,
               isbn = excluded.isbn,
               release_date = excluded.release_date",
            params![
                server_id,
                item.id,
                md.and_then(|m| m.summary.clone()),
                number,
                number_sort,
                md.and_then(|m| m.isbn.clone()),
                md.and_then(|m| m.release_date.clone()),
            ],
        )?;

        let tags = md.map(|m| m.tags.clone()).unwrap_or_default();
        let authors = md.map(|m| m.authors.clone()).unwrap_or_default();
        tx.execute(
            "DELETE FROM book_tags WHERE server_id = ?1 AND book_id = ?2",
            params![server_id, item.id],
        )?;
        for tag in &tags {
            tx.execute(
                "INSERT OR IGNORE INTO book_tags (server_id, book_id, tag) VALUES (?1, ?2, ?3)",
                params![server_id, item.id, tag],
            )?;
        }
        tx.execute(
            "DELETE FROM book_authors WHERE server_id = ?1 AND book_id = ?2",
            params![server_id, item.id],
        )?;
        for author in &authors {
            tx.execute(
                "INSERT OR IGNORE INTO book_authors (server_id, book_id, name, role)
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    server_id,
                    item.id,
                    author.name,
                    author.role.clone().unwrap_or_default(),
                ],
            )?;
        }

        // Remote read progress rides along on the BookDto (local-first;
        // `mutation_pending` belongs to locally-made mutations only).
        if let Some(progress) = &item.read_progress {
            crate::store::read_progress::upsert_synced_read_progress(
                &tx,
                server_id,
                &item.id,
                progress.page,
                progress.completed,
                progress.last_modified.clone(),
            )?;
        }

        let fts_rowid: Option<i64> = tx.query_row(
            "SELECT fts_rowid FROM books WHERE server_id = ?1 AND remote_id = ?2",
            params![server_id, item.id],
            |row| row.get(0),
        )?;
        fts::upsert_book_fts(
            &tx,
            server_id,
            &item.id,
            fts_rowid,
            &title,
            &authors_text(&authors),
            &tags.join(", "),
            &md.and_then(|m| m.summary.clone()).unwrap_or_default(),
        )?;

        written += 1;
    }
    tx.commit()?;
    Ok(written)
}

/// One book row (detail endpoint); None when missing.
pub fn get_book(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Option<BookRow>> {
    let mut stmt = conn.prepare(&format!(
        "{BOOK_SELECT} WHERE b.server_id = ?1 AND b.remote_id = ?2"
    ))?;
    let mut rows = stmt.query_map(params![server_id, book_id], row_to_book)?;
    rows.next().transpose()
}

/// All remote_ids of books (one server, one series) — the book-cover
/// backfill list ("缓存缺失自动补齐" for `variant = 'book'`).
pub fn list_series_books(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT remote_id FROM books WHERE server_id = ?1 AND series_id = ?2 ORDER BY number_sort, title COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id, series_id], |row| row.get(0))?;
    rows.collect()
}

/// Distinct book tags for one server (filter chips).
pub fn list_book_tags(conn: &Connection, server_id: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT DISTINCT tag FROM book_tags WHERE server_id = ?1 ORDER BY tag COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id], |row| row.get(0))?;
    rows.collect()
}

/// tags / authors of one book (detail screen).
pub fn book_tags(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT tag FROM book_tags WHERE server_id = ?1 AND book_id = ?2 ORDER BY tag COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id, book_id], |row| row.get(0))?;
    rows.collect()
}

pub fn book_authors(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Vec<crate::store::AuthorRow>> {
    let mut stmt = conn.prepare(
        "SELECT name, role FROM book_authors WHERE server_id = ?1 AND book_id = ?2 ORDER BY name COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id, book_id], crate::store::author_row)?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::author::Author;
    use crate::model::book::{BookMetadata, Media, ReadProgress};
    use crate::store::open_in_memory;

    fn sample_book(id: &str, series_id: &str, number: i64) -> Book {
        Book {
            id: id.into(),
            series_id: series_id.into(),
            series_title: Some("One Piece".into()),
            name: format!("Book {number}"),
            number: Some(number),
            oneshot: false,
            media: Some(Media {
                media_type: Some("application/pdf".into()),
                pages_count: Some(20),
            }),
            metadata: Some(BookMetadata {
                title: format!("Book {number}"),
                number: Some(number.to_string()),
                number_sort: Some(number as f64),
                summary: Some("A chapter.".into()),
                isbn: None,
                release_date: Some("2025-01-01".into()),
                authors: vec![Author {
                    name: "Author One".into(),
                    role: Some("STORY_ART".into()),
                }],
                tags: vec!["Manga".into(), "Pirate".into()],
            }),
            read_progress: if number == 1 {
                Some(ReadProgress {
                    page: Some(20),
                    completed: true,
                    last_modified: Some("2025-01-10T00:00:00Z".into()),
                })
            } else {
                None
            },
            created: Some("2025-01-01T00:00:00Z".into()),
            last_modified: Some("2025-01-02T00:00:00Z".into()),
            size_bytes: Some(12345),
        }
    }

    #[test]
    fn batch_upsert_and_detail() {
        let conn = open_in_memory().unwrap();
        let batch = vec![sample_book("b1", "s1", 1), sample_book("b2", "s1", 2)];
        assert_eq!(save_books_batch(&conn, "server-1", &batch).unwrap(), 2);

        let row = get_book(&conn, "server-1", "b1").unwrap().unwrap();
        assert_eq!(row.title, "Book 1");
        assert_eq!(row.number.as_deref(), Some("1"));
        assert_eq!(row.number_sort, Some(1.0));
        assert_eq!(row.pages_count, Some(20));
        assert!(row.progress_completed);
        assert_eq!(row.progress_page, Some(20));

        // Unread book: no progress joined.
        let unread = get_book(&conn, "server-1", "b2").unwrap().unwrap();
        assert!(!unread.progress_completed);
        assert_eq!(unread.progress_page, None);

        // Tags / authors / FTS.
        assert_eq!(
            book_tags(&conn, "server-1", "b1").unwrap(),
            vec!["Manga", "Pirate"]
        );
        let authors = book_authors(&conn, "server-1", "b1").unwrap();
        assert_eq!(authors[0].name, "Author One");
        let hits: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM book_fts WHERE book_fts MATCH ?1 AND server_id = ?2",
                params![fts::fts_match_query("chapter"), "server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(hits, 2);
    }

    #[test]
    fn upsert_refreshes_children_and_read_progress() {
        let conn = open_in_memory().unwrap();
        save_books_batch(&conn, "server-1", &[sample_book("b1", "s1", 1)]).unwrap();
        let mut b = sample_book("b1", "s1", 1);
        b.metadata.as_mut().unwrap().tags = vec!["Revised".into()];
        b.read_progress = Some(ReadProgress {
            page: None,
            completed: false,
            last_modified: None,
        });
        save_books_batch(&conn, "server-1", &[b]).unwrap();
        let row = get_book(&conn, "server-1", "b1").unwrap().unwrap();
        assert!(!row.progress_completed);
        assert_eq!(row.progress_page, None);
        assert_eq!(book_tags(&conn, "server-1", "b1").unwrap(), vec!["Revised"]);
    }
}
