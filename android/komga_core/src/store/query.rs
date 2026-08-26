//! Local query layer — 搜索、筛选、排序、分页全部基于 SQLite。
//!
//! Every page in the media library reads through this module; the network
//! is only involved in explicit sync actions. Search uses the FTS5
//! indexes (`series_fts` / `book_fts`), filters use the normalized child
//! tables, and the results come back with their total for pagination.

use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection, Row};

use crate::store::books::{row_to_book, BookRow, BOOK_SELECT};
use crate::store::fts::fts_match_query;
use crate::store::series::{row_to_series, SeriesRow};

/// SQL parameters as `Value`s — cheap to clone, trivially `ToSql`, and the
/// count/data queries share the same binding vector.
type Params = Vec<Value>;

// MARK: - Series queries

/// Sort keys exposed by the UI; strings ride the FFI surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SeriesSort {
    #[default]
    Name,
    SortName,
    DateAdded,
    DateUpdated,
    BooksCount,
}

impl std::str::FromStr for SeriesSort {
    type Err = crate::api::error::ApiError;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        Ok(match s {
            "name" => Self::Name,
            "sortName" => Self::SortName,
            "dateAdded" => Self::DateAdded,
            "dateUpdated" => Self::DateUpdated,
            "booksCount" => Self::BooksCount,
            _ => {
                return Err(crate::api::error::ApiError::InvalidInput {
                    message: format!("unknown series sort: {s}"),
                })
            }
        })
    }
}

impl SeriesSort {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Name => "name",
            Self::SortName => "sortName",
            Self::DateAdded => "dateAdded",
            Self::DateUpdated => "dateUpdated",
            Self::BooksCount => "booksCount",
        }
    }

    fn order_expr(&self, ascending: bool) -> String {
        let dir = if ascending { "ASC" } else { "DESC" };
        match self {
            Self::Name => format!("s.name COLLATE NOCASE {dir}"),
            Self::SortName => format!("COALESCE(s.sort_name, s.name) COLLATE NOCASE {dir}"),
            Self::DateAdded => format!("s.created_at {dir}"),
            Self::DateUpdated => format!("s.last_modified {dir}"),
            Self::BooksCount => format!("s.books_count {dir}"),
        }
    }
}

/// Filter + sort + pagination params for the series wall.
#[derive(Debug, Clone, PartialEq)]
pub struct SeriesQuery {
    pub search: Option<String>,
    pub library_id: Option<String>,
    pub status: Option<String>,
    pub tag: Option<String>,
    pub genre: Option<String>,
    pub sort: SeriesSort,
    pub ascending: bool,
}

impl Default for SeriesQuery {
    fn default() -> Self {
        Self {
            search: None,
            library_id: None,
            status: None,
            tag: None,
            genre: None,
            sort: SeriesSort::Name,
            ascending: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SeriesPageResult {
    pub items: Vec<SeriesRow>,
    pub total: i64,
}

/// Build `(sql_fragment, params)` for the series WHERE clause (server_id
/// is always `?1`).
fn series_where(query: &SeriesQuery, server_id: &str) -> (String, Params) {
    let mut params: Params = vec![Value::Text(server_id.to_string())];
    let mut sql = "s.server_id = ?1".to_string();
    if let Some(library) = &query.library_id {
        params.push(Value::Text(library.clone()));
        sql.push_str(&format!(" AND s.library_id = ?{}", params.len()));
    }
    if let Some(status) = &query.status {
        params.push(Value::Text(status.clone()));
        sql.push_str(&format!(" AND s.status = ?{}", params.len()));
    }
    if let Some(tag) = &query.tag {
        params.push(Value::Text(tag.clone()));
        sql.push_str(&format!(
            " AND EXISTS (SELECT 1 FROM series_tags st WHERE st.server_id = s.server_id AND st.series_id = s.remote_id AND st.tag = ?{})",
            params.len()
        ));
    }
    if let Some(genre) = &query.genre {
        params.push(Value::Text(genre.clone()));
        sql.push_str(&format!(
            " AND EXISTS (SELECT 1 FROM series_genres sg WHERE sg.server_id = s.server_id AND sg.series_id = s.remote_id AND sg.genre = ?{})",
            params.len()
        ));
    }
    if let Some(search) = &query.search {
        let match_expr = fts_match_query(search);
        if !match_expr.is_empty() {
            params.push(Value::Text(match_expr));
            sql.push_str(&format!(
                " AND s.fts_rowid IN (SELECT rowid FROM series_fts WHERE series_fts MATCH ?{} AND server_id = ?1)",
                params.len()
            ));
        }
    }
    (sql, params)
}

/// Paged series list honoring search / filters / sort (本地查询).
pub fn query_series(
    conn: &Connection,
    server_id: &str,
    query: &SeriesQuery,
    limit: i64,
    offset: i64,
) -> rusqlite::Result<SeriesPageResult> {
    let (where_sql, mut params) = series_where(query, server_id);

    let total: i64 = conn.query_row(
        &format!("SELECT COUNT(*) FROM series s WHERE {where_sql}"),
        params_from_iter(params.clone()),
        |row| row.get(0),
    )?;

    params.push(Value::Integer(limit));
    params.push(Value::Integer(offset));
    let sql = format!(
        "SELECT * FROM series s WHERE {where_sql} ORDER BY {} LIMIT ?{} OFFSET ?{}",
        query.sort.order_expr(query.ascending),
        params.len() - 1,
        params.len()
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(params), row_to_series)?;
    let items: Vec<SeriesRow> = rows.collect::<rusqlite::Result<_>>()?;
    Ok(SeriesPageResult { items, total })
}

// MARK: - Book queries

/// Sort keys for a series' book list.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BookSort {
    #[default]
    Number,
    Title,
    DateAdded,
}

impl std::str::FromStr for BookSort {
    type Err = crate::api::error::ApiError;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        Ok(match s {
            "number" => Self::Number,
            "title" => Self::Title,
            "dateAdded" => Self::DateAdded,
            _ => {
                return Err(crate::api::error::ApiError::InvalidInput {
                    message: format!("unknown book sort: {s}"),
                })
            }
        })
    }
}

impl BookSort {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Number => "number",
            Self::Title => "title",
            Self::DateAdded => "dateAdded",
        }
    }

    fn order_expr(&self, ascending: bool) -> String {
        let dir = if ascending { "ASC" } else { "DESC" };
        match self {
            // NULL number_sort always sorts last (unnumbered extras).
            Self::Number => format!("b.number_sort IS NULL, b.number_sort {dir}"),
            Self::Title => format!("b.title COLLATE NOCASE {dir}"),
            Self::DateAdded => format!("b.created_at {dir}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadStatus {
    Unread,
    InProgress,
    Read,
}

impl std::str::FromStr for ReadStatus {
    type Err = crate::api::error::ApiError;

    fn from_str(s: &str) -> std::result::Result<Self, Self::Err> {
        Ok(match s {
            "unread" => Self::Unread,
            "in_progress" => Self::InProgress,
            "read" => Self::Read,
            _ => {
                return Err(crate::api::error::ApiError::InvalidInput {
                    message: format!("unknown read status: {s}"),
                })
            }
        })
    }
}

/// Filter + sort + pagination params for a series' book list.
#[derive(Debug, Clone, PartialEq)]
pub struct BookQuery {
    pub search: Option<String>,
    pub read_status: Option<ReadStatus>,
    pub tag: Option<String>,
    pub sort: BookSort,
    pub ascending: bool,
}

impl Default for BookQuery {
    fn default() -> Self {
        Self {
            search: None,
            read_status: None,
            tag: None,
            sort: BookSort::Number,
            ascending: true,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct BookPageResult {
    pub items: Vec<BookRow>,
    pub total: i64,
}

fn book_where(query: &BookQuery, server_id: &str, series_id: &str) -> (String, Params) {
    let mut params: Params = vec![
        Value::Text(server_id.to_string()),
        Value::Text(series_id.to_string()),
    ];
    let mut sql = "b.server_id = ?1 AND b.series_id = ?2".to_string();
    if let Some(read_status) = query.read_status {
        match read_status {
            ReadStatus::Read => sql.push_str(" AND rp.completed = 1"),
            ReadStatus::InProgress => {
                sql.push_str(" AND rp.completed = 0 AND rp.page IS NOT NULL AND rp.page > 0")
            }
            ReadStatus::Unread => {
                sql.push_str(
                    " AND (rp.book_id IS NULL OR (rp.completed = 0 AND (rp.page IS NULL OR rp.page = 0)))",
                )
            }
        }
    }
    if let Some(tag) = &query.tag {
        params.push(Value::Text(tag.clone()));
        sql.push_str(&format!(
            " AND EXISTS (SELECT 1 FROM book_tags bt WHERE bt.server_id = b.server_id AND bt.book_id = b.remote_id AND bt.tag = ?{})",
            params.len()
        ));
    }
    if let Some(search) = &query.search {
        let match_expr = fts_match_query(search);
        if !match_expr.is_empty() {
            params.push(Value::Text(match_expr));
            sql.push_str(&format!(
                " AND b.fts_rowid IN (SELECT rowid FROM book_fts WHERE book_fts MATCH ?{} AND server_id = ?1)",
                params.len()
            ));
        }
    }
    (sql, params)
}

/// Paged book list honoring read-status / tag filters / sort (本地查询).
pub fn query_books(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
    query: &BookQuery,
    limit: i64,
    offset: i64,
) -> rusqlite::Result<BookPageResult> {
    let (where_sql, mut params) = book_where(query, server_id, series_id);

    let total: i64 = conn.query_row(
        &format!(
            "SELECT COUNT(*) FROM books b LEFT JOIN read_progress rp
               ON rp.server_id = b.server_id AND rp.book_id = b.remote_id
             WHERE {where_sql}"
        ),
        params_from_iter(params.clone()),
        |row| row.get(0),
    )?;

    params.push(Value::Integer(limit));
    params.push(Value::Integer(offset));
    let sql = format!(
        "{BOOK_SELECT} WHERE {where_sql} ORDER BY {} LIMIT ?{} OFFSET ?{}",
        query.sort.order_expr(query.ascending),
        params.len() - 1,
        params.len()
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(params), row_to_book)?;
    let items: Vec<BookRow> = rows.collect::<rusqlite::Result<_>>()?;
    Ok(BookPageResult { items, total })
}

// MARK: - Query on row-list helpers (collections / readlists members)

/// Series rows for one collection (name-sorted, paged).
pub fn collection_series_page(
    conn: &Connection,
    server_id: &str,
    collection_id: &str,
    limit: i64,
    offset: i64,
) -> rusqlite::Result<SeriesPageResult> {
    let where_sql = "s.server_id = ?1 AND s.remote_id IN (SELECT series_id FROM collection_series WHERE server_id = ?1 AND collection_id = ?2)";
    let total: i64 = conn.query_row(
        &format!("SELECT COUNT(*) FROM series s WHERE {where_sql}"),
        params![server_id, collection_id],
        |row| row.get(0),
    )?;
    let mut stmt = conn.prepare(&format!(
        "SELECT * FROM series s WHERE {where_sql} ORDER BY s.name COLLATE NOCASE LIMIT ?3 OFFSET ?4"
    ))?;
    let rows = stmt.query_map(
        params![server_id, collection_id, limit, offset],
        row_to_series,
    )?;
    let items: Vec<SeriesRow> = rows.collect::<rusqlite::Result<_>>()?;
    Ok(SeriesPageResult { items, total })
}

/// Book rows for one readlist, in list order (paged).
pub fn readlist_books_page(
    conn: &Connection,
    server_id: &str,
    readlist_id: &str,
    limit: i64,
    offset: i64,
) -> rusqlite::Result<BookPageResult> {
    let total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM readlist_books WHERE server_id = ?1 AND readlist_id = ?2",
        params![server_id, readlist_id],
        |row| row.get(0),
    )?;
    let mut stmt = conn.prepare(&format!(
        "{BOOK_SELECT} JOIN readlist_books rb ON rb.server_id = b.server_id AND rb.book_id = b.remote_id
         WHERE b.server_id = ?1 AND rb.readlist_id = ?2
         ORDER BY rb.position LIMIT ?3 OFFSET ?4"
    ))?;
    let rows = stmt.query_map(params![server_id, readlist_id, limit, offset], row_to_book)?;
    let items: Vec<BookRow> = rows.collect::<rusqlite::Result<_>>()?;
    Ok(BookPageResult { items, total })
}

// MARK: - Library counts

/// One library row with its local series count (Library 列表/详情).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryCountRow {
    pub remote_id: String,
    pub name: String,
    pub series_count: i64,
}

pub fn library_counts(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<Vec<LibraryCountRow>> {
    let mut stmt = conn.prepare(
        "SELECT l.remote_id, l.name, COUNT(s.remote_id) AS series_count
           FROM libraries l
           LEFT JOIN series s ON s.server_id = l.server_id AND s.library_id = l.remote_id
          WHERE l.server_id = ?1
          GROUP BY l.remote_id, l.name
          ORDER BY l.name COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id], |row: &Row| {
        Ok(LibraryCountRow {
            remote_id: row.get("remote_id")?,
            name: row.get("name")?,
            series_count: row.get("series_count")?,
        })
    })?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::author::Author;
    use crate::model::series::{Series, SeriesMetadata};
    use crate::store::open_in_memory;

    fn series(
        id: &str,
        name: &str,
        lib: &str,
        status: &str,
        created: &str,
        tags: Vec<&str>,
        genres: Vec<&str>,
    ) -> Series {
        Series {
            id: id.into(),
            library_id: lib.into(),
            name: name.into(),
            created: Some(created.into()),
            last_modified: Some(created.into()),
            books_count: Some(0),
            books_read_count: Some(0),
            books_unread_count: Some(0),
            books_in_progress_count: Some(0),
            books_metadata: None,
            metadata: Some(SeriesMetadata {
                title: name.into(),
                status: Some(status.into()),
                summary: Some(format!("Summary of {name}")),
                publisher: Some("Shueisha".into()),
                genres: genres.into_iter().map(String::from).collect(),
                tags: tags.into_iter().map(String::from).collect(),
                authors: vec![Author {
                    name: name.into(),
                    role: Some("STORY_ART".into()),
                }],
                reading_direction: None,
                language: None,
                age_rating: None,
                title_sort: Some(name.into()),
                total_book_count: None,
            }),
        }
    }

    fn seed(conn: &Connection) {
        crate::store::series::save_series_batch(
            conn,
            "server-1",
            &[
                series(
                    "s1",
                    "One Piece",
                    "lib-1",
                    "ENDED",
                    "2025-01-01T00:00:00Z",
                    vec!["Manga", "Pirate"],
                    vec!["Adventure"],
                ),
                series(
                    "s2",
                    "Berserk",
                    "lib-1",
                    "ONGOING",
                    "2025-01-03T00:00:00Z",
                    vec!["Manga", "Seinen"],
                    vec!["Dark Fantasy", "Action"],
                ),
                series(
                    "s3",
                    "Solo Leveling",
                    "lib-2",
                    "COMPLETED",
                    "2025-01-05T00:00:00Z",
                    vec!["Manhwa"],
                    vec!["Fantasy", "Action"],
                ),
            ],
        )
        .unwrap();
    }

    #[test]
    fn query_series_default_sorts_by_name() {
        let conn = open_in_memory().unwrap();
        seed(&conn);
        let q = SeriesQuery::default();
        let page = query_series(&conn, "server-1", &q, 10, 0).unwrap();
        assert_eq!(page.total, 3);
        assert_eq!(page.items[0].name, "Berserk");
        assert_eq!(page.items[2].name, "Solo Leveling");
    }

    #[test]
    fn query_series_search_is_fts_and_offline() {
        let conn = open_in_memory().unwrap();
        seed(&conn);
        let q = SeriesQuery {
            search: Some("berserk".into()),
            ..Default::default()
        };
        let page = query_series(&conn, "server-1", &q, 10, 0).unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.items[0].name, "Berserk");

        // Prefix search "one" finds One Piece.
        let q = SeriesQuery {
            search: Some("one".into()),
            ..Default::default()
        };
        assert_eq!(
            query_series(&conn, "server-1", &q, 10, 0).unwrap().items[0].remote_id,
            "s1"
        );

        // Summary text is indexed too.
        let q = SeriesQuery {
            search: Some("leveling".into()),
            ..Default::default()
        };
        assert_eq!(query_series(&conn, "server-1", &q, 10, 0).unwrap().total, 1);
        // Malformed input degrades to no results, never an error.
        let q = SeriesQuery {
            search: Some("".into()),
            ..Default::default()
        };
        assert_eq!(query_series(&conn, "server-1", &q, 10, 0).unwrap().total, 3);
    }

    #[test]
    fn query_series_filters_combine() {
        let conn = open_in_memory().unwrap();
        seed(&conn);
        // Library filter.
        let q = SeriesQuery {
            library_id: Some("lib-2".into()),
            ..Default::default()
        };
        let page = query_series(&conn, "server-1", &q, 10, 0).unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.items[0].name, "Solo Leveling");
        // Tag filter.
        let q = SeriesQuery {
            tag: Some("Seinen".into()),
            ..Default::default()
        };
        let page = query_series(&conn, "server-1", &q, 10, 0).unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.items[0].name, "Berserk");
        // Genre filter matches two series.
        let q = SeriesQuery {
            genre: Some("Action".into()),
            ..Default::default()
        };
        assert_eq!(query_series(&conn, "server-1", &q, 10, 0).unwrap().total, 2);
        // Status filter.
        let q = SeriesQuery {
            status: Some("ENDED".into()),
            ..Default::default()
        };
        let page = query_series(&conn, "server-1", &q, 10, 0).unwrap();
        assert_eq!(page.total, 1);
        // Combined: genre + library.
        let q = SeriesQuery {
            genre: Some("Action".into()),
            library_id: Some("lib-1".into()),
            ..Default::default()
        };
        assert_eq!(query_series(&conn, "server-1", &q, 10, 0).unwrap().total, 1);
    }

    #[test]
    fn query_series_sorts_and_paginates() {
        let conn = open_in_memory().unwrap();
        seed(&conn);
        let q = SeriesQuery {
            sort: SeriesSort::DateAdded,
            ascending: false,
            ..Default::default()
        };
        let page = query_series(&conn, "server-1", &q, 10, 0).unwrap();
        assert_eq!(page.items[0].name, "Solo Leveling"); // newest first

        let q = SeriesQuery::default();
        let page1 = query_series(&conn, "server-1", &q, 2, 0).unwrap();
        assert_eq!(page1.items.len(), 2);
        assert_eq!(page1.total, 3);
        let page2 = query_series(&conn, "server-1", &q, 2, 2).unwrap();
        assert_eq!(page2.items.len(), 1);
        assert_eq!(page2.items[0].name, "Solo Leveling");
    }

    #[test]
    fn server_isolation_in_queries() {
        let conn = open_in_memory().unwrap();
        seed(&conn);
        crate::store::series::save_series_batch(
            &conn,
            "server-2",
            &[series(
                "s1",
                "One Piece",
                "lib-1",
                "ENDED",
                "2025-01-01T00:00:00Z",
                vec!["Manga"],
                vec!["Adventure"],
            )],
        )
        .unwrap();
        let q = SeriesQuery::default();
        assert_eq!(query_series(&conn, "server-2", &q, 10, 0).unwrap().total, 1);
        let qt = SeriesQuery {
            tag: Some("Seinen".into()),
            ..Default::default()
        };
        assert_eq!(
            query_series(&conn, "server-2", &qt, 10, 0).unwrap().total,
            0
        );
    }

    #[test]
    fn query_books_filters_by_read_status_and_tag() {
        use crate::model::book::{Book, BookMetadata, Media, ReadProgress};
        use crate::store::books::save_books_batch;

        let conn = open_in_memory().unwrap();
        seed(&conn);
        let book = |id: &str, number: i64, progress: Option<ReadProgress>, tags: Vec<&str>| Book {
            id: id.into(),
            series_id: "s1".into(),
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
                release_date: None,
                authors: vec![],
                tags: tags.into_iter().map(String::from).collect(),
            }),
            read_progress: progress,
            created: Some("2025-01-01T00:00:00Z".into()),
            last_modified: None,
            size_bytes: None,
        };
        save_books_batch(
            &conn,
            "server-1",
            &[
                book(
                    "b1",
                    1,
                    Some(ReadProgress {
                        page: Some(20),
                        completed: true,
                        last_modified: None,
                    }),
                    vec!["Manga"],
                ),
                book(
                    "b2",
                    2,
                    Some(ReadProgress {
                        page: Some(8),
                        completed: false,
                        last_modified: None,
                    }),
                    vec!["Manga"],
                ),
                book("b3", 3, None, vec!["Pirate"]),
            ],
        )
        .unwrap();

        // Default: number order.
        let q = BookQuery::default();
        let page = query_books(&conn, "server-1", "s1", &q, 10, 0).unwrap();
        assert_eq!(page.total, 3);
        assert_eq!(page.items[0].remote_id, "b1");

        // read_status filters (SQLite join on read_progress).
        let q = BookQuery {
            read_status: Some(ReadStatus::Read),
            ..Default::default()
        };
        let page = query_books(&conn, "server-1", "s1", &q, 10, 0).unwrap();
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].remote_id, "b1");

        let q = BookQuery {
            read_status: Some(ReadStatus::InProgress),
            ..Default::default()
        };
        let page = query_books(&conn, "server-1", "s1", &q, 10, 0).unwrap();
        assert_eq!(page.items[0].remote_id, "b2");

        let q = BookQuery {
            read_status: Some(ReadStatus::Unread),
            ..Default::default()
        };
        let page = query_books(&conn, "server-1", "s1", &q, 10, 0).unwrap();
        assert_eq!(page.items.len(), 1);
        assert_eq!(page.items[0].remote_id, "b3");

        // Tag filter + pagination total.
        let q = BookQuery {
            tag: Some("Pirate".into()),
            ..Default::default()
        };
        let page = query_books(&conn, "server-1", "s1", &q, 10, 0).unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.items[0].remote_id, "b3");

        // FTS search on book titles.
        let q = BookQuery {
            search: Some("book 2".into()),
            ..Default::default()
        };
        let page = query_books(&conn, "server-1", "s1", &q, 10, 0).unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.items[0].remote_id, "b2");
    }

    #[test]
    fn library_counts_left_join_all_libraries() {
        let conn = open_in_memory().unwrap();
        crate::store::libraries::save_libraries_batch(
            &conn,
            "server-1",
            &[
                crate::model::server::Library {
                    id: "lib-1".into(),
                    name: "Manga Main".into(),
                    root: "/manga".into(),
                    unavailable: None,
                },
                crate::model::server::Library {
                    id: "lib-2".into(),
                    name: "Webtoons".into(),
                    root: "/webtoons".into(),
                    unavailable: None,
                },
            ],
        )
        .unwrap();
        seed(&conn);
        let rows = library_counts(&conn, "server-1").unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].name, "Manga Main");
        assert_eq!(rows[0].series_count, 2);
        assert_eq!(rows[1].name, "Webtoons");
        assert_eq!(rows[1].series_count, 1);
    }
}
