//! Series local store — batch upsert (row + metadata + genres + tags +
//! authors + FTS row) and paged query (local-first: 本地数据库负责展示).

use rusqlite::{params, Connection, Row};

use crate::model::series::{Series, SeriesMetadata};
use crate::store::fts;

/// Locally stored series row (mirrors the remote SeriesDto subset).
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
    pub books_count: Option<i64>,
    pub books_read_count: Option<i64>,
    pub books_unread_count: Option<i64>,
    pub books_in_progress_count: Option<i64>,
    /// FTS rowid (incremental search-index updates); internal.
    pub fts_rowid: Option<i64>,
}

pub(crate) fn row_to_series(row: &Row) -> rusqlite::Result<SeriesRow> {
    Ok(SeriesRow {
        server_id: row.get("server_id")?,
        remote_id: row.get("remote_id")?,
        library_id: row.get("library_id")?,
        name: row.get("name")?,
        sort_name: row.get("sort_name")?,
        status: row.get("status")?,
        created_at: row.get("created_at")?,
        last_modified: row.get("last_modified")?,
        books_count: row.get("books_count")?,
        books_read_count: row.get("books_read_count")?,
        books_unread_count: row.get("books_unread_count")?,
        books_in_progress_count: row.get("books_in_progress_count")?,
        fts_rowid: row.get("fts_rowid")?,
    })
}

fn join_names(names: &[String]) -> String {
    names.join(", ")
}

fn authors_text(names: &[crate::model::author::Author]) -> String {
    names
        .iter()
        .map(|a| a.name.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Batch upsert: series row + series_metadata + normalized genres/tags/
/// authors + incremental FTS row. Runs inside one transaction so the
/// replace-children and index writes stay consistent. Returns the number
/// of series written.
pub fn save_series_batch(
    conn: &Connection,
    server_id: &str,
    series: &[Series],
) -> rusqlite::Result<usize> {
    let tx = conn.unchecked_transaction()?;
    let mut written = 0;
    for item in series {
        let md: Option<&SeriesMetadata> = item.metadata.as_ref();
        let sort_name = md
            .and_then(|m| m.title_sort.clone())
            .unwrap_or_else(|| item.name.clone());
        tx.execute(
            "INSERT INTO series (server_id, remote_id, library_id, name, sort_name, status, created_at, last_modified,
                                 books_count, books_read_count, books_unread_count, books_in_progress_count)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
             ON CONFLICT(server_id, remote_id) DO UPDATE SET
               library_id = excluded.library_id,
               name = excluded.name,
               sort_name = excluded.sort_name,
               status = excluded.status,
               created_at = excluded.created_at,
               last_modified = excluded.last_modified,
               books_count = excluded.books_count,
               books_read_count = excluded.books_read_count,
               books_unread_count = excluded.books_unread_count,
               books_in_progress_count = excluded.books_in_progress_count",
            params![
                server_id,
                item.id,
                item.library_id,
                item.name,
                sort_name,
                md.and_then(|m| m.status.clone()),
                item.created,
                item.last_modified,
                item.books_count,
                item.books_read_count,
                item.books_unread_count,
                item.books_in_progress_count,
            ],
        )?;

        // Metadata row (full series metadata: summary/publisher/…).
        tx.execute(
            "INSERT INTO series_metadata (server_id, series_id, summary, publisher, reading_direction, language, age_rating, title_sort, total_book_count)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
             ON CONFLICT(server_id, series_id) DO UPDATE SET
               summary = excluded.summary,
               publisher = excluded.publisher,
               reading_direction = excluded.reading_direction,
               language = excluded.language,
               age_rating = excluded.age_rating,
               title_sort = excluded.title_sort,
               total_book_count = excluded.total_book_count",
            params![
                server_id,
                item.id,
                md.and_then(|m| m.summary.clone()),
                md.and_then(|m| m.publisher.clone()),
                md.and_then(|m| m.reading_direction.clone()),
                md.and_then(|m| m.language.clone()),
                md.and_then(|m| m.age_rating.clone()),
                md.and_then(|m| m.title_sort.clone()),
                md.and_then(|m| m.total_book_count),
            ],
        )?;

        // Normalized filter tables: replace membership on every save
        // (remote DTOs are the authority).
        let tags = md.map(|m| m.tags.clone()).unwrap_or_default();
        let genres = md.map(|m| m.genres.clone()).unwrap_or_default();
        let mut authors = md.map(|m| m.authors.clone()).unwrap_or_default();
        if authors.is_empty() {
            // The series list endpoint aggregates authors under
            // `booksMetadata` (SeriesMetadataDto has no authors field).
            authors = item
                .books_metadata
                .as_ref()
                .map(|agg| agg.authors.clone())
                .unwrap_or_default();
        }
        tx.execute(
            "DELETE FROM series_tags WHERE server_id = ?1 AND series_id = ?2",
            params![server_id, item.id],
        )?;
        for tag in &tags {
            tx.execute(
                "INSERT OR IGNORE INTO series_tags (server_id, series_id, tag) VALUES (?1, ?2, ?3)",
                params![server_id, item.id, tag],
            )?;
        }
        tx.execute(
            "DELETE FROM series_genres WHERE server_id = ?1 AND series_id = ?2",
            params![server_id, item.id],
        )?;
        for genre in &genres {
            tx.execute(
                "INSERT OR IGNORE INTO series_genres (server_id, series_id, genre) VALUES (?1, ?2, ?3)",
                params![server_id, item.id, genre],
            )?;
        }
        tx.execute(
            "DELETE FROM series_authors WHERE server_id = ?1 AND series_id = ?2",
            params![server_id, item.id],
        )?;
        for author in &authors {
            tx.execute(
                "INSERT OR IGNORE INTO series_authors (server_id, series_id, name, role)
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    server_id,
                    item.id,
                    author.name,
                    author.role.clone().unwrap_or_default(),
                ],
            )?;
        }

        // Incremental FTS row (series_fts) — derived from the same DTO.
        let fts_rowid: Option<i64> = tx.query_row(
            "SELECT fts_rowid FROM series WHERE server_id = ?1 AND remote_id = ?2",
            params![server_id, item.id],
            |row| row.get(0),
        )?;
        fts::upsert_series_fts(
            &tx,
            server_id,
            &item.id,
            fts_rowid,
            &item.name,
            &sort_name,
            &authors_text(&authors),
            &md.and_then(|m| m.publisher.clone()).unwrap_or_default(),
            &join_names(&tags),
            &md.and_then(|m| m.summary.clone()).unwrap_or_default(),
        )?;

        written += 1;
    }
    tx.commit()?;
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

/// One series row (the facade detail endpoint).
pub fn get_series(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<Option<SeriesRow>> {
    let mut stmt = conn.prepare("SELECT * FROM series WHERE server_id = ?1 AND remote_id = ?2")?;
    let mut rows = stmt.query_map(params![server_id, series_id], row_to_series)?;
    rows.next().transpose()
}

// MARK: - Filter options (本地筛选：选项来自 SQLite 的归一化表)

/// Distinct series tags for one server (filter chips).
pub fn list_series_tags(conn: &Connection, server_id: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT DISTINCT tag FROM series_tags WHERE server_id = ?1 ORDER BY tag COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id], |row| row.get(0))?;
    rows.collect()
}

/// Distinct series genres for one server (filter chips).
pub fn list_series_genres(conn: &Connection, server_id: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT DISTINCT genre FROM series_genres WHERE server_id = ?1 ORDER BY genre COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id], |row| row.get(0))?;
    rows.collect()
}

/// Distinct series statuses for one server (filter chips).
pub fn list_series_statuses(conn: &Connection, server_id: &str) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT DISTINCT status FROM series WHERE server_id = ?1 AND status IS NOT NULL AND status != ''
         ORDER BY status COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id], |row| row.get(0))?;
    rows.collect()
}

/// genres / tags / authors of one series (detail screen).
pub fn series_tags(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT tag FROM series_tags WHERE server_id = ?1 AND series_id = ?2 ORDER BY tag COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id, series_id], |row| row.get(0))?;
    rows.collect()
}

pub fn series_genres(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT genre FROM series_genres WHERE server_id = ?1 AND series_id = ?2 ORDER BY genre COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id, series_id], |row| row.get(0))?;
    rows.collect()
}

pub fn series_authors(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<Vec<crate::store::AuthorRow>> {
    let mut stmt = conn.prepare(
        "SELECT name, role FROM series_authors WHERE server_id = ?1 AND series_id = ?2 ORDER BY name COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id, series_id], crate::store::author_row)?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::author::Author;
    use crate::store::open_in_memory;

    fn sample_series(id: &str, name: &str) -> Series {
        Series {
            id: id.into(),
            library_id: "lib-1".into(),
            name: name.into(),
            created: Some("2025-01-01T00:00:00Z".into()),
            last_modified: Some("2025-01-02T00:00:00Z".into()),
            books_count: Some(3),
            books_read_count: Some(1),
            books_unread_count: Some(2),
            books_in_progress_count: Some(1),
            books_metadata: None,
            metadata: Some(SeriesMetadata {
                title: name.into(),
                status: Some("ONGOING".into()),
                summary: Some("A story.".into()),
                publisher: Some("Shueisha".into()),
                genres: vec!["Adventure".into()],
                tags: vec!["Manga".into()],
                authors: vec![Author {
                    name: "Author One".into(),
                    role: Some("STORY_ART".into()),
                }],
                reading_direction: Some("LEFT_TO_RIGHT".into()),
                language: Some("ja".into()),
                age_rating: Some("MATURE".into()),
                title_sort: Some(name.into()),
                total_book_count: Some(3),
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
        assert_eq!(rows[0].books_count, Some(3));

        // Normalized metadata landed.
        assert_eq!(
            series_genres(&conn, "server-1", "s1").unwrap(),
            vec!["Adventure"]
        );
        assert_eq!(series_tags(&conn, "server-1", "s1").unwrap(), vec!["Manga"]);
        let authors = series_authors(&conn, "server-1", "s1").unwrap();
        assert_eq!(authors[0].name, "Author One");
        assert_eq!(authors[0].role, "STORY_ART");

        // Filter options are server-scoped and sorted.
        assert_eq!(list_series_tags(&conn, "server-1").unwrap(), vec!["Manga"]);
        assert_eq!(
            list_series_genres(&conn, "server-1").unwrap(),
            vec!["Adventure"]
        );
        assert_eq!(
            list_series_statuses(&conn, "server-1").unwrap(),
            vec!["ONGOING"]
        );
    }

    #[test]
    fn upsert_is_idempotent_and_refreshes_children() {
        let conn = open_in_memory().unwrap();
        let mut s = sample_series("s1", "One Piece");
        save_series_batch(&conn, "server-1", &[s.clone()]).unwrap();
        s.name = "One Piece (Revised)".into();
        s.metadata.as_mut().unwrap().tags = vec!["Manga".into(), "Pirate".into()];
        s.metadata.as_mut().unwrap().status = Some("ENDED".into());
        save_series_batch(&conn, "server-1", &[s]).unwrap();
        assert_eq!(count_series(&conn, "server-1").unwrap(), 1);
        let rows = list_series(&conn, "server-1", 10, 0).unwrap();
        assert_eq!(rows[0].name, "One Piece (Revised)");
        assert_eq!(rows[0].status.as_deref(), Some("ENDED"));
        // Children replaced, not appended.
        assert_eq!(
            series_tags(&conn, "server-1", "s1").unwrap(),
            vec!["Manga", "Pirate"]
        );
        // FTS row updated in place (same fts_rowid).
        let rowid: Option<i64> = conn
            .query_row(
                "SELECT fts_rowid FROM series WHERE server_id = ?1 AND remote_id = ?2",
                params!["server-1", "s1"],
                |row| row.get(0),
            )
            .unwrap();
        assert!(rowid.is_some());
        // Search finds the new name.
        let hits: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM series_fts WHERE series_fts MATCH ?1 AND server_id = ?2",
                params![fts::fts_match_query("revised"), "server-1"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(hits, 1);
    }

    #[test]
    fn multi_server_isolation() {
        let conn = open_in_memory().unwrap();
        save_series_batch(&conn, "server-1", &[sample_series("s1", "One Piece")]).unwrap();
        save_series_batch(&conn, "server-2", &[sample_series("s1", "One Piece")]).unwrap();
        assert_eq!(count_series(&conn, "server-1").unwrap(), 1);
        assert_eq!(count_series(&conn, "server-2").unwrap(), 1);
        assert_eq!(list_series_tags(&conn, "server-1").unwrap().len(), 1);
        assert_eq!(list_series_tags(&conn, "server-2").unwrap().len(), 1);
    }
}
