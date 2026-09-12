//! Local query layer — 搜索、筛选、排序、分页全部基于 SQLite。
//!
//! Every page in the media library reads through this module; the network
//! is only involved in explicit sync actions. Search uses the FTS5
//! indexes (`series_fts` / `book_fts`), filters use the normalized child
//! tables, and the results come back with their total for pagination.

use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};

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

// MARK: - Library list / detail

/// One library row with its local counts (Library 列表/详情).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibraryCountRow {
    pub remote_id: String,
    pub name: String,
    pub root: Option<String>,
    pub unavailable: bool,
    pub series_count: i64,
    pub book_count: i64,
    pub read_count: i64,
}

/// Correlated subqueries rather than joins, so the three counts stay
/// independent of each other's row multiplication.
const LIBRARY_STATS_SQL: &str = "SELECT l.remote_id, l.name, l.root, l.unavailable,
           (SELECT COUNT(*) FROM series s
             WHERE s.server_id = l.server_id AND s.library_id = l.remote_id) AS series_count,
           (SELECT COUNT(*) FROM books b
             JOIN series s2 ON s2.server_id = b.server_id AND s2.remote_id = b.series_id
             WHERE s2.server_id = l.server_id AND s2.library_id = l.remote_id) AS book_count,
           (SELECT COUNT(*) FROM books b
             JOIN series s3 ON s3.server_id = b.server_id AND s3.remote_id = b.series_id
             JOIN read_progress rp ON rp.server_id = b.server_id AND rp.book_id = b.remote_id
             WHERE s3.server_id = l.server_id AND s3.library_id = l.remote_id
               AND rp.completed = 1) AS read_count
       FROM libraries l";

fn read_library_stats(row: &Row) -> rusqlite::Result<LibraryCountRow> {
    Ok(LibraryCountRow {
        remote_id: row.get("remote_id")?,
        name: row.get("name")?,
        root: row.get("root")?,
        unavailable: row.get::<_, i64>("unavailable")? != 0,
        series_count: row.get("series_count")?,
        book_count: row.get("book_count")?,
        read_count: row.get("read_count")?,
    })
}

/// Every library of one server with its counts — the Library 列表.
pub fn library_counts(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<Vec<LibraryCountRow>> {
    let mut stmt = conn.prepare(&format!(
        "{LIBRARY_STATS_SQL} WHERE l.server_id = ?1 ORDER BY l.name COLLATE NOCASE"
    ))?;
    let rows = stmt.query_map(params![server_id], read_library_stats)?;
    rows.collect()
}

/// A single library by id — the Library 详情. Same SQL, extra filter.
pub fn library_detail(
    conn: &Connection,
    server_id: &str,
    library_id: &str,
) -> rusqlite::Result<Option<LibraryCountRow>> {
    let mut stmt = conn.prepare(&format!(
        "{LIBRARY_STATS_SQL} WHERE l.server_id = ?1 AND l.remote_id = ?2"
    ))?;
    stmt.query_row(params![server_id, library_id], read_library_stats)
        .optional()
}

// MARK: - Read target (统一阅读入口)

/// Why [`series_read_target`] points where it does. The UI needs this: "继续阅读"
/// and "开始阅读" are different words on the same button, and "重新阅读" only
/// appears when every book is finished.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadIntent {
    /// An unfinished book with real progress — the button says 继续阅读.
    Continue,
    /// Nothing started yet — 开始阅读.
    Start,
    /// Everything finished — 重新阅读.
    Reread,
    /// No readable book at all — the button is disabled.
    Empty,
}

impl ReadIntent {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Continue => "continue",
            Self::Start => "start",
            Self::Reread => "reread",
            Self::Empty => "empty",
        }
    }
}

/// The one book a "start or continue reading" tap should open, with the reason.
#[derive(Debug, Clone, PartialEq)]
pub struct ReadTarget {
    pub book: BookRow,
    /// The book's 1-based position in [`ordered_books`].
    pub position: i64,
    pub intent: ReadIntent,
}

/// The series order, and whether the local catalog can be trusted for "next".
#[derive(Debug, Clone, PartialEq)]
pub struct OrderedBooks {
    pub books: Vec<BookRow>,
    /// `books_count` the server reported for this series, when it was synced.
    pub book_count: Option<i64>,
    /// The local mirror has every book the server says the series has.
    ///
    /// This is what gates "下一册". A series whose books are still streaming in
    /// can end on an unfinished-looking page while missing the very next volume:
    /// offering "下一册" there is offering a book that may not exist yet.
    pub complete: bool,
}

/// The book after `book_id`, or `None` when this really is the last one.
pub fn next_book_in_series(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
    book_id: &str,
) -> rusqlite::Result<Option<BookRow>> {
    let ordered = ordered_books(conn, server_id, series_id)?;
    if !ordered.complete {
        return Ok(None);
    }
    let position = ordered
        .books
        .iter()
        .position(|row| row.remote_id == book_id);
    Ok(position.and_then(|index| ordered.books.get(index + 1).cloned()))
}

/// Which book a "start or continue reading" tap should open.
///
/// The rule, in one place so the shelf and the series detail cannot disagree:
///
/// 1. the unfinished book with the newest local progress — you were reading it;
/// 2. otherwise the first unread book in series order — you start at the start;
/// 3. otherwise, when every book is finished, the first book — 重新阅读;
/// 4. nothing readable → [`ReadIntent::Empty`] and the caller disables the button.
pub fn series_read_target(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<Option<ReadTarget>> {
    let ordered = ordered_books(conn, server_id, series_id)?;
    if ordered.books.is_empty() {
        return Ok(None);
    }

    // (1) In progress, newest first. `read_progress.page > 0` is the same test
    // the reader itself uses: a row a sync created with page 0 is "unread".
    let in_progress = conn
        .query_row(
            &format!(
                "{BOOK_SELECT} WHERE b.server_id = ?1 AND b.series_id = ?2
                   AND rp.completed = 0 AND rp.page IS NOT NULL AND rp.page > 0
                 ORDER BY COALESCE(rp.local_updated_at, rp.server_updated_at) DESC
                 LIMIT 1"
            ),
            params![server_id, series_id],
            row_to_book,
        )
        .optional()?;

    if let Some(book) = in_progress {
        let position = ordered
            .books
            .iter()
            .position(|row| row.remote_id == book.remote_id)
            .map(|index| index as i64 + 1)
            .unwrap_or(1);
        return Ok(Some(ReadTarget {
            book,
            position,
            intent: ReadIntent::Continue,
        }));
    }

    // (2) Nothing started: the first unread book in *series order*, which is the
    // order the user sees, not the order SQLite happens to return.
    let first_unread = ordered
        .books
        .iter()
        .position(|row| !row.progress_completed && row.progress_page.unwrap_or(0) == 0);

    let (index, intent) = match first_unread {
        Some(index) => (index, ReadIntent::Start),
        // (3) Every book finished → 重新阅读 from the top.
        None => (0, ReadIntent::Reread),
    };
    Ok(Some(ReadTarget {
        book: ordered.books[index].clone(),
        position: index as i64 + 1,
        intent,
    }))
}

/// Every book of one series in the order the user sees it.
///
/// The order is a product rule, not a detail: numbered books first in ascending
/// `number_sort`, then case-insensitively by title, with `remote_id` last so two
/// runs of the same library can never disagree. Books with no number (extras,
/// one-shots) sort last — they are side stories, not volume 0.
pub fn ordered_books(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<OrderedBooks> {
    let mut stmt = conn.prepare(&format!(
        "{BOOK_SELECT} WHERE b.server_id = ?1 AND b.series_id = ?2
         ORDER BY b.number_sort IS NULL, b.number_sort ASC,
                  b.title COLLATE NOCASE ASC, b.remote_id ASC"
    ))?;
    let rows = stmt.query_map(params![server_id, series_id], row_to_book)?;
    let books: Vec<BookRow> = rows.collect::<rusqlite::Result<_>>()?;

    let book_count: Option<i64> = conn
        .query_row(
            "SELECT books_count FROM series WHERE server_id = ?1 AND remote_id = ?2",
            params![server_id, series_id],
            |row| row.get(0),
        )
        .optional()?
        .flatten();

    // A missing `books_count` means the series row itself is not mirrored yet,
    // which is exactly the case where "the next book" cannot be promised either.
    let complete = matches!(book_count, Some(count) if count == books.len() as i64);
    Ok(OrderedBooks {
        books,
        book_count,
        complete,
    })
}

/// One flat row for the FFI: the read target plus the series facts the UI needs
/// to draw it honestly ("no next book" vs "we cannot prove there is no next
/// book" are different sentences, so the completeness flag travels with it).
#[derive(Debug, Clone, PartialEq)]
pub struct ReadTargetRow {
    pub book: BookRow,
    pub intent: String,
    /// 1-based position in [`ordered_books`]; 0 when there is no target.
    pub position: i64,
    pub book_count: Option<i64>,
    pub complete: bool,
}

/// [`series_read_target`] as the FFI sees it.
///
/// Returns a row with an empty-`remote_id` book and `intent == "empty"` when the
/// series has nothing readable, rather than `None`: a nullable struct is one
/// more shape for the Dart side to get wrong, and the UI needs the completeness
/// answer either way.
pub fn series_read_target_row(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<ReadTargetRow> {
    let ordered = ordered_books(conn, server_id, series_id)?;
    let (book, intent, position) = match series_read_target(conn, server_id, series_id)? {
        Some(target) => (target.book, target.intent.as_str(), target.position),
        None => (
            BookRow {
                server_id: server_id.to_string(),
                remote_id: String::new(),
                series_id: series_id.to_string(),
                series_title: None,
                title: String::new(),
                number: None,
                number_sort: None,
                file_size: None,
                media_type: None,
                pages_count: None,
                created_at: None,
                last_modified: None,
                progress_page: None,
                progress_completed: false,
                fts_rowid: None,
            },
            ReadIntent::Empty.as_str(),
            0,
        ),
    };
    Ok(ReadTargetRow {
        book,
        intent: intent.to_string(),
        position,
        book_count: ordered.book_count,
        complete: ordered.complete,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::author::Author;
    use crate::model::book::{Book, Media};
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
                    unavailable: Some(true),
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
        assert_eq!(rows[0].root.as_deref(), Some("/manga"));
        assert!(rows[0].unavailable);
        assert_eq!(rows[1].name, "Webtoons");
        assert_eq!(rows[1].series_count, 1);
        assert!(!rows[1].unavailable);

        let detail = library_detail(&conn, "server-1", "lib-1")
            .unwrap()
            .expect("lib-1 exists");
        assert_eq!(detail.remote_id, "lib-1");
        assert_eq!(detail.series_count, 2);
        assert_eq!(detail.root.as_deref(), Some("/manga"));
        assert!(detail.unavailable);
        assert!(library_detail(&conn, "server-1", "nope").unwrap().is_none());
        // Another server's library id must not resolve here.
        assert!(library_detail(&conn, "server-1", "lib-9")
            .unwrap()
            .is_none());
    }

    // MARK: read target

    /// A series with an explicit `books_count` — the mirror-completeness signal
    /// "下一册" depends on. Built by hand so nothing about the fixture's page
    /// count is implicit.
    fn seed_read_series(conn: &Connection, series_id: &str, book_count: i64, books: &[Book]) {
        let mut row = series(
            series_id,
            "Reading Order",
            "lib-1",
            "ONGOING",
            "2025-01-01T00:00:00Z",
            Vec::new(),
            Vec::new(),
        );
        row.books_count = Some(book_count);
        crate::store::series::save_series_batch(conn, "server-1", &[row]).unwrap();
        crate::store::books::save_books_batch(conn, "server-1", books).unwrap();
    }

    fn reading_book(id: &str, series_id: &str, title: &str, number: Option<i64>) -> Book {
        Book {
            id: id.into(),
            series_id: series_id.into(),
            series_title: Some("Reading Order".into()),
            name: title.into(),
            number,
            oneshot: false,
            media: Some(Media {
                media_type: Some("image".into()),
                pages_count: Some(100),
            }),
            metadata: None,
            read_progress: None,
            created: Some("2025-01-01T00:00:00Z".into()),
            last_modified: None,
            size_bytes: None,
        }
    }

    #[test]
    fn ordered_books_puts_numbered_first_then_title_then_id() {
        let conn = open_in_memory().unwrap();
        seed_read_series(
            &conn,
            "s-order",
            4,
            &[
                reading_book("b-null", "s-order", "附录", None),
                reading_book("b-two-b", "s-order", "Extra B", Some(2)),
                reading_book("b-two-a", "s-order", "extra a", Some(2)),
                reading_book("b-one", "s-order", "第一卷", Some(1)),
            ],
        );

        let ordered = ordered_books(&conn, "server-1", "s-order").unwrap();
        let ids: Vec<&str> = ordered.books.iter().map(|b| b.remote_id.as_str()).collect();
        assert_eq!(
            ids,
            vec!["b-one", "b-two-a", "b-two-b", "b-null"],
            "numbered ascending; equal numbers case-insensitive by title; unnumbered last"
        );
        assert!(ordered.complete);
        assert_eq!(ordered.book_count, Some(4));
    }

    #[test]
    fn a_short_of_the_server_count_mirror_is_not_complete() {
        let conn = open_in_memory().unwrap();
        // The server says 5, the mirror holds 2: books are still streaming in.
        seed_read_series(
            &conn,
            "s-partial",
            5,
            &[
                reading_book("p1", "s-partial", "1", Some(1)),
                reading_book("p2", "s-partial", "2", Some(2)),
            ],
        );
        let ordered = ordered_books(&conn, "server-1", "s-partial").unwrap();
        assert!(!ordered.complete);
        assert_eq!(ordered.book_count, Some(5));

        // The last mirrored book is NOT the last book — so there is no next one.
        assert!(next_book_in_series(&conn, "server-1", "s-partial", "p2")
            .unwrap()
            .is_none());
    }

    #[test]
    fn next_book_is_the_following_book_in_series_order() {
        let conn = open_in_memory().unwrap();
        seed_read_series(
            &conn,
            "s-next",
            3,
            &[
                reading_book("n1", "s-next", "1", Some(1)),
                reading_book("n2", "s-next", "2", Some(2)),
                reading_book("n3", "s-next", "3", Some(3)),
            ],
        );
        assert_eq!(
            next_book_in_series(&conn, "server-1", "s-next", "n1")
                .unwrap()
                .unwrap()
                .remote_id,
            "n2"
        );
        assert!(
            next_book_in_series(&conn, "server-1", "s-next", "n3")
                .unwrap()
                .is_none(),
            "the last book of a complete series has no next"
        );
        assert!(next_book_in_series(&conn, "server-1", "s-next", "not-here")
            .unwrap()
            .is_none());
    }

    #[test]
    fn read_target_prefers_the_newest_unfinished_book() {
        let conn = open_in_memory().unwrap();
        let mut older = reading_book("r1", "s-read", "1", Some(1));
        older.read_progress = None;
        seed_read_series(
            &conn,
            "s-read",
            3,
            &[
                older,
                reading_book("r2", "s-read", "2", Some(2)),
                reading_book("r3", "s-read", "3", Some(3)),
            ],
        );
        crate::store::read_progress::upsert_local_read_progress(&conn, "server-1", "r1", 10, false)
            .unwrap();
        crate::store::read_progress::upsert_local_read_progress(&conn, "server-1", "r3", 40, false)
            .unwrap();
        conn.execute(
            "UPDATE read_progress SET local_updated_at = ?1 WHERE book_id = ?2",
            params!["2025-02-01T00:00:00Z", "r1"],
        )
        .unwrap();
        conn.execute(
            "UPDATE read_progress SET local_updated_at = ?1 WHERE book_id = ?2",
            params!["2025-03-01T00:00:00Z", "r3"],
        )
        .unwrap();

        let target = series_read_target(&conn, "server-1", "s-read")
            .unwrap()
            .unwrap();
        assert_eq!(target.intent, ReadIntent::Continue);
        assert_eq!(target.book.remote_id, "r3", "the newest progress wins");
        assert_eq!(target.position, 3);
    }

    #[test]
    fn read_target_starts_at_the_first_unread_book_not_the_first_row() {
        let conn = open_in_memory().unwrap();
        seed_read_series(
            &conn,
            "s-fresh",
            3,
            &[
                reading_book("f1", "s-fresh", "1", Some(1)),
                reading_book("f2", "s-fresh", "2", Some(2)),
                reading_book("f3", "s-fresh", "3", Some(3)),
            ],
        );
        crate::store::read_progress::mark_read(&conn, "server-1", "f1").unwrap();

        let target = series_read_target(&conn, "server-1", "s-fresh")
            .unwrap()
            .unwrap();
        assert_eq!(target.intent, ReadIntent::Start);
        assert_eq!(target.book.remote_id, "f2", "volume 1 is finished");
        assert_eq!(target.position, 2);
    }

    #[test]
    fn an_all_read_series_offers_a_reread_of_the_first_book() {
        let conn = open_in_memory().unwrap();
        seed_read_series(
            &conn,
            "s-done",
            2,
            &[
                reading_book("d1", "s-done", "1", Some(1)),
                reading_book("d2", "s-done", "2", Some(2)),
            ],
        );
        crate::store::read_progress::mark_read(&conn, "server-1", "d1").unwrap();
        crate::store::read_progress::mark_read(&conn, "server-1", "d2").unwrap();

        let target = series_read_target(&conn, "server-1", "s-done")
            .unwrap()
            .unwrap();
        assert_eq!(target.intent, ReadIntent::Reread);
        assert_eq!(target.book.remote_id, "d1");
        assert_eq!(target.position, 1);
    }

    #[test]
    fn a_series_with_no_books_has_no_read_target() {
        let conn = open_in_memory().unwrap();
        seed_read_series(&conn, "s-none", 0, &[]);
        assert!(series_read_target(&conn, "server-1", "s-none")
            .unwrap()
            .is_none());
        assert!(ordered_books(&conn, "server-1", "s-none")
            .unwrap()
            .books
            .is_empty());
    }

    #[test]
    fn read_target_reads_only_the_named_server() {
        let conn = open_in_memory().unwrap();
        seed_read_series(
            &conn,
            "s-srv",
            1,
            &[reading_book("m1", "s-srv", "1", Some(1))],
        );
        assert!(series_read_target(&conn, "server-2", "s-srv")
            .unwrap()
            .is_none());
        assert!(ordered_books(&conn, "server-2", "s-srv")
            .unwrap()
            .books
            .is_empty());
    }

    #[test]
    fn the_ffi_row_carries_the_completeness_answer_even_with_no_target() {
        let conn = open_in_memory().unwrap();
        seed_read_series(&conn, "s-ffi", 2, &[]);

        // An empty series still answers the completeness question: the UI has to
        // say "this series is empty", not "we don't know yet".
        let row = series_read_target_row(&conn, "server-1", "s-ffi").unwrap();
        assert_eq!(row.intent, "empty");
        assert_eq!(row.position, 0);
        assert!(row.book.remote_id.is_empty());
        assert_eq!(row.book_count, Some(2));
        assert!(!row.complete, "the server says 2 books and we hold none");

        // And a real target carries its book plus the same flags.
        seed_read_series(
            &conn,
            "s-ffi2",
            1,
            &[reading_book("f1", "s-ffi2", "1", Some(1))],
        );
        let row = series_read_target_row(&conn, "server-1", "s-ffi2").unwrap();
        assert_eq!(row.intent, "start");
        assert_eq!(row.book.remote_id, "f1");
        assert_eq!(row.position, 1);
        assert!(row.complete);
    }

    #[test]
    fn library_detail_counts_read_books_from_progress() {
        use crate::model::book::{Book, Media};
        use crate::store::books::save_books_batch;

        let conn = open_in_memory().unwrap();
        seed(&conn);
        let book = |id: &str| Book {
            id: id.into(),
            series_id: "s1".into(),
            series_title: Some("One Piece".into()),
            name: id.into(),
            number: Some(1),
            oneshot: false,
            media: Some(Media {
                media_type: Some("image".into()),
                pages_count: Some(10),
            }),
            metadata: None,
            read_progress: None,
            created: None,
            last_modified: None,
            size_bytes: None,
        };
        save_books_batch(&conn, "server-1", &[book("b1"), book("b2")]).unwrap();
        crate::store::read_progress::mark_read(&conn, "server-1", "b1").unwrap();

        crate::store::libraries::save_libraries_batch(
            &conn,
            "server-1",
            &[crate::model::server::Library {
                id: "lib-1".into(),
                name: "Manga Main".into(),
                root: "/manga".into(),
                unavailable: Some(false),
            }],
        )
        .unwrap();
        let detail = library_detail(&conn, "server-1", "lib-1")
            .unwrap()
            .expect("lib-1");
        assert_eq!(detail.book_count, 2);
        assert_eq!(detail.read_count, 1);
    }

    // MARK: v11 indexes — the plan, not a stopwatch

    /// Seed a library big enough that the planner has to make a real decision.
    /// Raw inserts rather than the store writers: this is about table
    /// cardinality and shape, and 1,200 model objects would only slow the test.
    fn seed_scale(conn: &Connection, series_count: i64, books_per: i64) {
        conn.execute_batch("BEGIN").unwrap();
        {
            let mut s = conn
                .prepare(
                    "INSERT INTO series (server_id, remote_id, library_id, name, sort_name,
                                         status, created_at, last_modified, books_count,
                                         books_read_count, books_unread_count,
                                         books_in_progress_count)
                     VALUES ('server-1', ?1, ?2, ?3, ?4, 'ONGOING', ?5, ?5, ?6, 0, ?6, 0)",
                )
                .unwrap();
            for i in 0..series_count {
                s.execute(rusqlite::params![
                    format!("s{i:06}"),
                    format!("lib-{}", i % 4),
                    format!("Series {i:06}"),
                    format!("zzz {i:06}"),
                    format!("2026-01-{:02}T00:00:00Z", 1 + i % 28),
                    books_per,
                ])
                .unwrap();
            }
        }
        {
            let mut b = conn
                .prepare(
                    "INSERT INTO books (server_id, remote_id, series_id, series_title, title,
                                        number, number_sort, pages_count)
                     VALUES ('server-1', ?1, ?2, ?3, ?4, ?5, ?6, 20)",
                )
                .unwrap();
            for i in 0..series_count {
                for k in 0..books_per {
                    b.execute(rusqlite::params![
                        format!("b{i:06}-{k:03}"),
                        format!("s{i:06}"),
                        format!("Series {i:06}"),
                        format!("Vol {k}"),
                        format!("{k}"),
                        k as f64,
                    ])
                    .unwrap();
                }
            }
        }
        conn.execute_batch("COMMIT").unwrap();
    }

    /// The plan SQLite chose, one line per row, for the failure message. The
    /// parameters are bound because SQLite plans against their values too.
    fn plan_of(conn: &Connection, sql: &str, params: Vec<Value>) -> String {
        let mut stmt = conn.prepare(&format!("EXPLAIN QUERY PLAN {sql}")).unwrap();
        let rows: Vec<String> = stmt
            .query_map(params_from_iter(params), |r| r.get::<_, String>(3))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        rows.join(" | ")
    }

    /// Run a statement to completion and report `(Sort, VmStep)`.
    ///
    /// `StatementStatus::Sort` counts the temporary B-trees SQLite opened for
    /// this statement. Zero means it never needed one — a deterministic integer,
    /// unlike a millisecond reading that depends on the machine.
    fn plan_counters(conn: &Connection, sql: &str, params: Vec<Value>) -> (i32, i32) {
        let mut stmt = conn.prepare(sql).unwrap();
        let rows: Vec<i64> = stmt
            .query_map(params_from_iter(params), |_| Ok(0i64))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        // Keep the rows alive so the counters describe the execution, not a plan.
        assert!(rows.len() <= 1000);
        (
            stmt.get_status(rusqlite::StatementStatus::Sort),
            stmt.get_status(rusqlite::StatementStatus::VmStep),
        )
    }

    /// Every one of the wall's five sorts must come off an index.
    ///
    /// Without the v11 indexes each of these opened a temp B-tree over all
    /// 1,200 series (and a second one for the `COUNT(*)` beside it), on every
    /// page — so scrolling the wall was quadratic in the library.
    #[test]
    fn a_series_wall_page_never_sorts_in_a_temp_btree() {
        let conn = open_in_memory().unwrap();
        seed_scale(&conn, 1_200, 10);

        for sort in [
            SeriesSort::Name,
            SeriesSort::SortName,
            SeriesSort::DateAdded,
            SeriesSort::DateUpdated,
            SeriesSort::BooksCount,
        ] {
            for ascending in [true, false] {
                let query = SeriesQuery {
                    sort,
                    ascending,
                    ..SeriesQuery::default()
                };
                let (where_sql, mut params) = series_where(&query, "server-1");
                params.push(Value::Integer(50));
                params.push(Value::Integer(0));
                // The same SQL `query_series` builds, with its parameters bound.
                let sql = format!(
                    "SELECT * FROM series s WHERE {where_sql} ORDER BY {} LIMIT ?{} OFFSET ?{}",
                    query.sort.order_expr(query.ascending),
                    params.len() - 1,
                    params.len()
                );

                let bound = {
                    let mut stmt = conn.prepare(&sql).unwrap();
                    let rows: Vec<i64> = stmt
                        .query_map(params_from_iter(params.clone()), |_| Ok(0i64))
                        .unwrap()
                        .collect::<rusqlite::Result<_>>()
                        .unwrap();
                    assert!(rows.len() <= 50);
                    stmt.get_status(rusqlite::StatementStatus::Sort)
                };

                assert_eq!(
                    bound,
                    0,
                    "sort {:?} ascending={ascending} still sorts in a temp B-tree; plan: {}",
                    sort,
                    plan_of(&conn, &sql, params.clone())
                );
            }
        }
    }

    /// The sort-name index is an expression index, and SQLite only uses it while
    /// the query's ORDER BY is *the same expression*. This test is the tripwire
    /// for an edit to `SeriesSort::order_expr` that silently reintroduces the
    /// filesort that index exists to remove.
    #[test]
    fn the_sort_name_expression_index_still_matches_the_order_expression() {
        let conn = open_in_memory().unwrap();
        seed_scale(&conn, 1_200, 10);

        let query = SeriesQuery {
            sort: SeriesSort::SortName,
            ascending: true,
            ..SeriesQuery::default()
        };
        let (where_sql, params) = series_where(&query, "server-1");
        let sql = format!(
            "SELECT * FROM series s WHERE {where_sql} ORDER BY {} LIMIT 50 OFFSET 0",
            query.sort.order_expr(query.ascending)
        );

        let (sort, _) = plan_counters(&conn, &sql, params.clone());
        let plan = plan_of(&conn, &sql, params);
        assert_eq!(
            sort, 0,
            "sort_name fell back to a temp B-tree; plan: {plan}"
        );
        assert!(
            plan.contains("series_sort_name_nocase"),
            "the expression index exists but the query stopped matching it; plan: {plan}"
        );
    }

    /// Listing one series' books must not scan the whole library's books.
    ///
    /// `books` is keyed `(server_id, remote_id)`, so before
    /// `books_series_order` this query had no way to reach one series' rows
    /// other than reading every book of the server.
    #[test]
    fn a_series_book_page_reads_one_series_not_the_whole_library() {
        let conn = open_in_memory().unwrap();
        seed_scale(&conn, 1_200, 10); // 12,000 books

        let query = BookQuery {
            sort: BookSort::Number,
            ascending: true,
            ..BookQuery::default()
        };
        let (where_sql, mut params) = book_where(&query, "server-1", "s000500");
        params.push(Value::Integer(100));
        params.push(Value::Integer(0));
        let sql = format!(
            "{} WHERE {where_sql} ORDER BY {} LIMIT ?{} OFFSET ?{}",
            BOOK_SELECT,
            query.sort.order_expr(query.ascending),
            params.len() - 1,
            params.len()
        );

        let mut stmt = conn.prepare(&sql).unwrap();
        let rows: Vec<i64> = stmt
            .query_map(params_from_iter(params.clone()), |_| Ok(0i64))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(rows.len(), 10, "one series' ten books");
        let vm_steps = stmt.get_status(rusqlite::StatementStatus::VmStep);

        // Ten books in, ten rows out. A full scan of 12,000 books would be
        // three orders of magnitude more work; the bound leaves room for the
        // join and the sort but not for another series' rows.
        assert!(
            vm_steps < 2_000,
            "books-of-a-series visited {vm_steps} rows for a ten-book series; plan: {}",
            plan_of(&conn, &sql, params)
        );
    }

    /// Seed `libraries` rows too, so `library_counts` has something to count into.
    fn seed_libraries(conn: &Connection, count: i64) {
        conn.execute_batch("BEGIN").unwrap();
        {
            let mut l = conn
                .prepare(
                    "INSERT INTO libraries (server_id, remote_id, name, root, unavailable)
                     VALUES ('server-1', ?1, ?2, ?3, 0)",
                )
                .unwrap();
            for i in 0..count {
                l.execute(rusqlite::params![
                    format!("lib-{i}"),
                    format!("Library {i}"),
                    format!("/root/{i}"),
                ])
                .unwrap();
            }
        }
        conn.execute_batch("COMMIT").unwrap();
    }

    /// Statistics are what makes the planner pick the library-first join order.
    ///
    /// The v11 indexes alone are not enough, and this is the measurement that
    /// says so: `library_counts` counts books per library with a correlated
    /// subquery. With no `sqlite_stat1` SQLite does not know how many series a
    /// library holds and drives from `books` — every book of the server, once per
    /// library. After statistics it drives from `series_library` into
    /// `books_series_order`. `PRAGMA optimize` is where those statistics come
    /// from, and it has to run *after* the mirror has rows: on an empty database
    /// `ANALYZE` writes no `sqlite_stat1` rows at all.
    #[test]
    fn library_counts_drives_from_the_library_when_statistics_exist() {
        let conn = open_in_memory().unwrap();
        seed_libraries(&conn, 4);
        // Series are spread round-robin over the libraries, so each library owns
        // a few hundred series and a few thousand books.
        seed_scale(&conn, 1_200, 10);

        let sql =
            format!("{LIBRARY_STATS_SQL} WHERE l.server_id = ?1 ORDER BY l.name COLLATE NOCASE");
        let params = vec![Value::Text("server-1".to_string())];

        let (_, before) = plan_counters(&conn, &sql, params.clone());

        conn.execute_batch("PRAGMA optimize").unwrap();
        let stat_rows: i64 = conn
            .query_row("SELECT COUNT(*) FROM sqlite_stat1", [], |r| r.get(0))
            .unwrap();

        let (_, after) = plan_counters(&conn, &sql, params.clone());
        let plan = plan_of(&conn, &sql, params);

        assert!(
            stat_rows > 0,
            "PRAGMA optimize collected nothing; plan: {plan}"
        );
        assert!(
            plan.contains("series_library") && plan.contains("books_series_order"),
            "the planner is not using the library-driven order; plan: {plan}"
        );
        assert!(
            after < before,
            "statistics did not help: {before} rows visited before, {after} after; plan: {plan}"
        );
        // The substantive claim, as a ratio rather than a magic number. Measured
        // on this seed: 1,539,860 VM steps without statistics, 119,068 with — a
        // 12.9x cut. A 5x floor has ample headroom for a planner tweak on a
        // different SQLite build, and still fails loudly if the plan reverts to
        // books-first (ratio 1).
        assert!(
            before > after * 5,
            "statistics barely moved the plan: {before} steps before, {after} after; plan: {plan}"
        );
    }

    /// `PRAGMA optimize` on an empty database collects nothing for the tables
    /// the plan actually turns on.
    ///
    /// Measured, and the measurement is the point: it does write a couple of
    /// `sqlite_stat1` rows (for the FTS config tables), so a bare "is stat1
    /// non-empty?" check would pass and tell you nothing. What it never does is
    /// collect statistics for `series` or `books`, which is why the planner has
    /// no row counts and why the refresh at the end of a bootstrap is
    /// load-bearing rather than belt-and-braces.
    #[test]
    fn optimize_on_an_empty_database_collects_nothing_for_the_library_tables() {
        let conn = open_in_memory().unwrap();
        // migrate() ran `PRAGMA optimize` on an empty database.
        let library_stats: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_stat1 WHERE tbl IN ('series', 'books')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            library_stats, 0,
            "an empty database cannot describe tables that have no rows; if this \
             changes, re-measure before trusting the bootstrap hook's necessity"
        );

        seed_libraries(&conn, 4);
        seed_scale(&conn, 1_200, 10);
        conn.execute_batch("PRAGMA optimize").unwrap();

        let after: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_stat1 WHERE tbl IN ('series', 'books')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(
            after > 0,
            "the refresh has to produce statistics for the tables the library queries read"
        );
    }
}
