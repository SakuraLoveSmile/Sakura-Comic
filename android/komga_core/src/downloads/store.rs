//! Every SQL the offline download queue speaks.
//!
//! Two shapes in here are the whole design, so they are stated once and pointed at
//! from elsewhere rather than being rediscovered per query:
//!
//!   * a state change is an **optimistic** `UPDATE ... WHERE state = <expected>`,
//!     and it reports whether it moved anything. That is how a user's pause, which
//!     can land at any millisecond of a pass that is mid-book, wins without a
//!     signal, a lock or a cancellation flag: the pass's next write simply changes
//!     zero rows and it stops.
//!   * `pages_done` / `bytes_done` are **derived**. Nothing in this module adds one
//!     to a counter; every write path recomputes both from `download_pages`. A
//!     bookkeeping row lost to a half-applied commit would otherwise leave a book
//!     permanently one page short of finishing.

use rusqlite::{params, Connection, OptionalExtension};

use super::queue::{self, book_state, page_state, Actor, SettleMode};

#[derive(Debug, thiserror::Error)]
pub enum QueueError {
    #[error("sqlite: {0}")]
    Sql(#[from] rusqlite::Error),
    /// Refused by the contract table rather than by a constraint. Reported as an
    /// error and never silently dropped, because the only ways to reach one are a
    /// code change that ignored the table or a database somebody edited by hand.
    #[error("illegal download transition {from} -> {to} by {actor}")]
    IllegalTransition {
        from: String,
        to: String,
        actor: String,
    },
    #[error("no download for {server_id}/{book_id}")]
    NotFound { server_id: String, book_id: String },
    /// The derived `manifest.json` could not be written or read. Reported rather
    /// than swallowed: the third-party view of a download is the only thing about it
    /// that survives somebody deleting the database.
    #[error("manifest: {0}")]
    Manifest(#[from] super::manifest::ManifestError),
}

/// One `downloads` row. `pages_total`/`pages_done` are nullable in the schema
/// because SQLite cannot change a live column's nullability, so every read of
/// them coalesces: a NULL is a zero, never a mystery.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadRow {
    pub server_id: String,
    pub book_id: String,
    pub manifest_path: Option<String>,
    pub state: String,
    pub position: i64,
    pub pages_total: i64,
    pub pages_done: i64,
    pub bytes_total: i64,
    pub bytes_done: i64,
    pub created_at: String,
    pub updated_at: Option<String>,
    pub last_error: Option<String>,
    pub next_retry_at: Option<String>,
    pub remote_last_modified: Option<String>,
    pub book_title: Option<String>,
    pub series_title: Option<String>,
    pub allow_cellular: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadPageRow {
    pub server_id: String,
    pub book_id: String,
    pub number: u32,
    pub file_path: Option<String>,
    pub state: String,
    pub size_bytes: i64,
    pub media_type: String,
    pub attempts: i64,
    pub last_error: Option<String>,
    pub updated_at: Option<String>,
}

const DOWNLOAD_COLUMNS: &str = "server_id, book_id, manifest_path, state, position, \
     COALESCE(pages_total, 0), COALESCE(pages_done, 0), bytes_total, bytes_done, created_at, \
     updated_at, last_error, next_retry_at, remote_last_modified, book_title, series_title, \
     allow_cellular";

const PAGE_COLUMNS: &str = "server_id, book_id, page_number, file_path, state, size_bytes, \
     media_type, attempts, last_error, updated_at";

fn download_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DownloadRow> {
    Ok(DownloadRow {
        server_id: row.get(0)?,
        book_id: row.get(1)?,
        manifest_path: row.get(2)?,
        state: row.get(3)?,
        position: row.get(4)?,
        pages_total: row.get(5)?,
        pages_done: row.get(6)?,
        bytes_total: row.get(7)?,
        bytes_done: row.get(8)?,
        created_at: row.get(9)?,
        updated_at: row.get(10)?,
        last_error: row.get(11)?,
        next_retry_at: row.get(12)?,
        remote_last_modified: row.get(13)?,
        book_title: row.get(14)?,
        series_title: row.get(15)?,
        allow_cellular: row.get::<_, i64>(16)? != 0,
    })
}

fn page_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DownloadPageRow> {
    Ok(DownloadPageRow {
        server_id: row.get(0)?,
        book_id: row.get(1)?,
        number: row.get::<_, i64>(2)? as u32,
        file_path: row.get(3)?,
        state: row.get(4)?,
        size_bytes: row.get(5)?,
        media_type: row.get(6)?,
        attempts: row.get(7)?,
        last_error: row.get(8)?,
        updated_at: row.get(9)?,
    })
}

/// What the caller knows when it asks for a job to be created.
#[derive(Debug, Clone)]
pub struct NewDownload {
    pub server_id: String,
    pub book_id: String,
    pub pages_total: u32,
    pub bytes_total: i64,
    pub manifest_path: String,
    pub remote_last_modified: Option<String>,
    pub book_title: Option<String>,
    pub series_title: Option<String>,
}

/// Create or re-open the queue entry for one book, and lay out its page rows.
///
/// Re-enqueuing a completed book is a fresh job: its page rows are rebuilt, which
/// is what keeps the `completed -> waiting` transition legal under the contract
/// (a user gesture clears the rows first, so the pump never decides to redo work).
pub fn enqueue(
    conn: &Connection,
    job: &NewDownload,
    numbers: &[u32],
    now: &str,
) -> Result<DownloadRow, QueueError> {
    if !queue::enqueue_allowed() {
        return Err(QueueError::IllegalTransition {
            from: "(none)".to_string(),
            to: book_state::WAITING.to_string(),
            actor: Actor::User.as_str().to_string(),
        });
    }
    // Re-tapping 下载 while a pass holds the book would rebuild the page rows
    // underneath it, so it is refused rather than merely discouraged. The same
    // gesture is also how a completed book starts over, and that one is legal —
    // see the `illegal` list in downloads/states.json.
    let existing = get(conn, &job.server_id, &job.book_id)?;
    if let Some(existing) = &existing {
        if !queue::transition_allowed(&existing.state, book_state::WAITING, Actor::User) {
            return Err(QueueError::IllegalTransition {
                from: existing.state.clone(),
                to: book_state::WAITING.to_string(),
                actor: Actor::User.as_str().to_string(),
            });
        }
    }
    // A re-tap on a book still in the queue keeps its place: moving it to the back
    // for pressing the button twice is the kind of thing a user never forgives.
    let keep_position = existing
        .as_ref()
        .map(|row| row.state == book_state::WAITING)
        .unwrap_or(false);
    let tx = conn.unchecked_transaction()?;
    let position: i64 = if keep_position {
        existing.as_ref().map(|row| row.position).unwrap_or(1)
    } else {
        tx.query_row(
            "SELECT COALESCE(MAX(position), 0) + 1 FROM downloads WHERE server_id = ?1",
            params![job.server_id],
            |row| row.get(0),
        )?
    };
    tx.execute(
        "INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done,
                                state, created_at, updated_at, position, bytes_total, bytes_done,
                                remote_last_modified, book_title, series_title)
         VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6, ?6, ?7, ?8, 0, ?9, ?10, ?11)
         ON CONFLICT(server_id, book_id) DO UPDATE SET
           manifest_path = excluded.manifest_path,
           pages_total = excluded.pages_total,
           bytes_total = excluded.bytes_total,
           state = excluded.state,
           updated_at = excluded.updated_at,
           last_error = NULL,
           next_retry_at = NULL,
           remote_last_modified = excluded.remote_last_modified,
           book_title = excluded.book_title,
           series_title = excluded.series_title",
        params![
            job.server_id,
            job.book_id,
            job.manifest_path,
            job.pages_total as i64,
            book_state::WAITING,
            now,
            position,
            job.bytes_total,
            job.remote_last_modified,
            job.book_title,
            job.series_title,
        ],
    )?;
    tx.execute(
        "DELETE FROM download_pages WHERE server_id = ?1 AND book_id = ?2",
        params![job.server_id, job.book_id],
    )?;
    for number in numbers {
        tx.execute(
            "INSERT INTO download_pages (server_id, book_id, page_number, state, size_bytes,
                                         media_type, attempts, updated_at)
             VALUES (?1, ?2, ?3, ?4, 0, '', 0, ?5)",
            params![
                job.server_id,
                job.book_id,
                *number as i64,
                page_state::PENDING,
                now
            ],
        )?;
    }
    let created = get(&tx, &job.server_id, &job.book_id)?.ok_or_else(|| QueueError::NotFound {
        server_id: job.server_id.clone(),
        book_id: job.book_id.clone(),
    })?;
    tx.commit()?;
    Ok(created)
}

pub fn get(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> Result<Option<DownloadRow>, QueueError> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {DOWNLOAD_COLUMNS} FROM downloads WHERE server_id = ?1 AND book_id = ?2"
    ))?;
    Ok(stmt
        .query_row(params![server_id, book_id], download_from_row)
        .optional()?)
}

/// The queue, in the order the user built it.
pub fn list(conn: &Connection, server_id: Option<&str>) -> Result<Vec<DownloadRow>, QueueError> {
    let sql = format!(
        "SELECT {DOWNLOAD_COLUMNS} FROM downloads {} ORDER BY position, server_id, book_id",
        match server_id {
            Some(_) => "WHERE server_id = ?1",
            None => "",
        }
    );
    let mut stmt = conn.prepare(&sql)?;
    let rows = match server_id {
        Some(server) => stmt.query_map(params![server], download_from_row)?,
        None => stmt.query_map([], download_from_row)?,
    };
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(QueueError::from)
}

/// The current state, or `None` when there is no such download.
pub fn state_of(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> Result<Option<String>, QueueError> {
    Ok(conn
        .query_row(
            "SELECT state FROM downloads WHERE server_id = ?1 AND book_id = ?2",
            params![server_id, book_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

// Eight arguments, and every one of them is a decision the contract table needs:
// the book, the states it may come from, the state it goes to, who is asking, when,
// and why. Precedent for the allow is `PageCache::store_tier`.
#[allow(clippy::too_many_arguments)]
/// Move a book's state, through the contract table and with optimistic locking.
///
/// `Ok(true)` means this write is the one that changed the row. `Ok(false)` means it
/// changed nothing: the row was no longer in any of the `from` states, because
/// somebody else — in practice the user, pausing it — got there first. The caller
/// must then stop, not retry with a different expectation. Whether the book exists at
/// all is a separate question with a separate function ([`get`]), and conflating the
/// two is a bug that looks like a race being handled.
pub fn set_state(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    from: &[&str],
    to: &str,
    actor: Actor,
    now: &str,
    last_error: Option<&str>,
) -> Result<bool, QueueError> {
    for previous in from {
        if !queue::transition_allowed(previous, to, actor) {
            return Err(QueueError::IllegalTransition {
                from: (*previous).to_string(),
                to: to.to_string(),
                actor: actor.as_str().to_string(),
            });
        }
    }
    let placeholders = from.iter().map(|_| "?").collect::<Vec<_>>().join(", ");
    let sql = format!(
        "UPDATE downloads SET state = ?1, updated_at = ?2, last_error = ?3
         WHERE server_id = ?4 AND book_id = ?5 AND state IN ({placeholders})"
    );
    let moved = {
        let mut stmt = conn.prepare(&sql)?;
        let mut args: Vec<&dyn rusqlite::ToSql> =
            vec![&to, &now, &last_error, &server_id, &book_id];
        for previous in from {
            args.push(previous);
        }
        stmt.execute(rusqlite::params_from_iter(args.iter()))?
    };
    Ok(moved > 0)
}

pub fn set_allow_cellular(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    allow: bool,
    now: &str,
) -> Result<(), QueueError> {
    conn.execute(
        "UPDATE downloads SET allow_cellular = ?3, updated_at = ?4
         WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id, allow as i64, now],
    )?;
    Ok(())
}

/// Park every book of one server until `until`. A rejected credential is a
/// server-wide fact, and discovering the 401 once per book is three hundred
/// requests that all mean the same thing.
pub fn park_server(
    conn: &Connection,
    server_id: &str,
    until: &str,
    reason: &str,
    now: &str,
) -> Result<usize, QueueError> {
    Ok(conn.execute(
        "UPDATE downloads SET next_retry_at = ?2, last_error = ?3, updated_at = ?4
         WHERE server_id = ?1 AND state IN (?5, ?6)",
        params![
            server_id,
            until,
            reason,
            now,
            book_state::WAITING,
            book_state::DOWNLOADING
        ],
    )?)
}

pub fn clear_park(conn: &Connection, server_id: &str, now: &str) -> Result<usize, QueueError> {
    Ok(conn.execute(
        "UPDATE downloads SET next_retry_at = NULL, updated_at = ?2 WHERE server_id = ?1",
        params![server_id, now],
    )?)
}

// -------------------------------------------------------------- page rows

pub fn pages(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> Result<Vec<DownloadPageRow>, QueueError> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {PAGE_COLUMNS} FROM download_pages
         WHERE server_id = ?1 AND book_id = ?2 ORDER BY page_number"
    ))?;
    let rows = stmt.query_map(params![server_id, book_id], page_from_row)?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(QueueError::from)
}

pub fn page(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    number: u32,
) -> Result<Option<DownloadPageRow>, QueueError> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {PAGE_COLUMNS} FROM download_pages
         WHERE server_id = ?1 AND book_id = ?2 AND page_number = ?3"
    ))?;
    Ok(stmt
        .query_row(params![server_id, book_id, number as i64], page_from_row)
        .optional()?)
}

/// The pages a book has that the reader may paint without a network. Used both by
/// the reader's own tier check and by the prefetch planner, which must not queue
/// what is already on the device.
pub fn complete_pages(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> Result<Vec<u32>, QueueError> {
    let mut stmt = conn.prepare(
        "SELECT page_number FROM download_pages
         WHERE server_id = ?1 AND book_id = ?2 AND state = ?3 ORDER BY page_number",
    )?;
    let rows = stmt.query_map(params![server_id, book_id, page_state::COMPLETE], |row| {
        Ok(row.get::<_, i64>(0)? as u32)
    })?;
    Ok(rows.collect::<Result<Vec<_>, _>>()?)
}

// See `set_state` for why the allow is here rather than a struct nobody reuses.
#[allow(clippy::too_many_arguments)]
/// A landed page. `path` is the final name, not the staging one: the caller has
/// already renamed.
pub fn mark_page_complete(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    number: u32,
    path: &str,
    size_bytes: i64,
    media_type: &str,
    now: &str,
) -> Result<(), QueueError> {
    conn.execute(
        "INSERT INTO download_pages (server_id, book_id, page_number, file_path, state,
                                     size_bytes, media_type, attempts, last_error, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, NULL, ?8)
         ON CONFLICT(server_id, book_id, page_number) DO UPDATE SET
           file_path = excluded.file_path,
           state = excluded.state,
           size_bytes = excluded.size_bytes,
           media_type = excluded.media_type,
           last_error = NULL,
           updated_at = excluded.updated_at",
        params![
            server_id,
            book_id,
            number as i64,
            path,
            page_state::COMPLETE,
            size_bytes,
            media_type,
            now
        ],
    )?;
    Ok(())
}

/// A page attempt that was about this page. Burns one attempt, and at the limit
/// the page becomes `failed` so the queue can move on past it.
pub fn record_page_attempt(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    number: u32,
    error: &str,
    now: &str,
) -> Result<bool, QueueError> {
    conn.execute(
        "UPDATE download_pages SET attempts = attempts + 1, last_error = ?4, updated_at = ?5
         WHERE server_id = ?1 AND book_id = ?2 AND page_number = ?3",
        params![server_id, book_id, number as i64, error, now],
    )?;
    let exhausted: bool = conn.query_row(
        "SELECT attempts >= ?4 FROM download_pages
         WHERE server_id = ?1 AND book_id = ?2 AND page_number = ?3",
        params![
            server_id,
            book_id,
            number as i64,
            queue::max_page_attempts()
        ],
        |row| row.get::<_, i64>(0),
    )? != 0;
    if exhausted {
        conn.execute(
            "UPDATE download_pages SET state = ?4, updated_at = ?5
             WHERE server_id = ?1 AND book_id = ?2 AND page_number = ?3",
            params![server_id, book_id, number as i64, page_state::FAILED, now],
        )?;
    }
    Ok(exhausted)
}

/// Clear the failed pages of a book, and only those. `complete` rows are untouched:
/// the value of single-page retry is that three bad pages in a four-hundred page
/// book costs three requests, and the acceptance harness asserts exactly that.
pub fn retry_failed_pages(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    now: &str,
) -> Result<i64, QueueError> {
    Ok(conn.execute(
        "UPDATE download_pages SET state = ?4, attempts = 0, last_error = NULL, updated_at = ?5
         WHERE server_id = ?1 AND book_id = ?2 AND state = ?3",
        params![
            server_id,
            book_id,
            page_state::FAILED,
            page_state::PENDING,
            now
        ],
    )? as i64)
}

/// The `heal` direction: the filesystem disproved a row.
pub fn heal_page(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    number: u32,
    now: &str,
) -> Result<(), QueueError> {
    let previous = page(conn, server_id, book_id, number)?;
    let from = previous
        .as_ref()
        .map(|row| row.state.clone())
        .unwrap_or_else(|| page_state::PENDING.to_string());
    if !queue::transition_allowed(&from, page_state::PENDING, Actor::Heal)
        && from != page_state::PENDING
    {
        return Err(QueueError::IllegalTransition {
            from,
            to: page_state::PENDING.to_string(),
            actor: Actor::Heal.as_str().to_string(),
        });
    }
    match previous {
        Some(_) => {
            conn.execute(
                "UPDATE download_pages SET state = ?4, file_path = NULL, size_bytes = 0,
                        attempts = 0, last_error = NULL, media_type = '', updated_at = ?5
                 WHERE server_id = ?1 AND book_id = ?2 AND page_number = ?3",
                params![server_id, book_id, number as i64, page_state::PENDING, now],
            )?;
        }
        None => {
            conn.execute(
                "INSERT INTO download_pages (server_id, book_id, page_number, state, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![server_id, book_id, number as i64, page_state::PENDING, now],
            )?;
        }
    }
    Ok(())
}

/// The other `heal` direction, and the one that looks backwards at first: a usable
/// file with no row is ADOPTED rather than deleted. "Row commit lost, file landed"
/// is a real event on a device under write contention, and the alternative is
/// throwing away bytes the user paid for on a metered link.
#[allow(clippy::too_many_arguments)]
pub fn adopt_page(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    number: u32,
    path: &str,
    size_bytes: i64,
    media_type: &str,
    now: &str,
) -> Result<(), QueueError> {
    mark_page_complete(
        conn, server_id, book_id, number, path, size_bytes, media_type, now,
    )
}

pub fn delete_page(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    number: u32,
) -> Result<(), QueueError> {
    conn.execute(
        "DELETE FROM download_pages WHERE server_id = ?1 AND book_id = ?2 AND page_number = ?3",
        params![server_id, book_id, number as i64],
    )?;
    Ok(())
}

// ------------------------------------------------------------- accounting

/// Recompute both book counters from the page rows. Returns `(pages_done,
/// bytes_done)` so the caller can settle state from the same pair it just wrote.
pub fn recompute_counters(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    now: &str,
) -> Result<(i64, i64), QueueError> {
    let (done, bytes): (i64, i64) = conn.query_row(
        "SELECT COUNT(*), COALESCE(SUM(size_bytes), 0) FROM download_pages
         WHERE server_id = ?1 AND book_id = ?2 AND state = ?3",
        params![server_id, book_id, page_state::COMPLETE],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    conn.execute(
        "UPDATE downloads SET pages_done = ?3, bytes_done = ?4, updated_at = ?5
         WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id, done, bytes, now],
    )?;
    Ok((done, bytes))
}

/// Derive a book's state from its rows, and write it if it moved.
///
/// `paused` survives untouched here whatever the rows say: the pump may settle a book
/// it holds, and it may never launder a pause into progress. `completed` is just as
/// sticky against a pass — and not against the sweep, which has looked at the disk.
/// See `healReopens` in `downloads/states.json`.
pub fn settle_book(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    now: &str,
    mode: SettleMode,
) -> Result<String, QueueError> {
    let row = get(conn, server_id, book_id)?.ok_or_else(|| QueueError::NotFound {
        server_id: server_id.to_string(),
        book_id: book_id.to_string(),
    })?;
    let (complete, failed): (i64, i64) = conn.query_row(
        "SELECT COALESCE(SUM(state = ?3), 0), COALESCE(SUM(state = ?4), 0)
         FROM download_pages WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id, page_state::COMPLETE, page_state::FAILED],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let derived = queue::settle_state(
        &row.state,
        row.pages_total.max(0) as u32,
        complete.max(0) as u32,
        failed.max(0) as u32,
        mode,
    );
    recompute_counters(conn, server_id, book_id, now)?;
    if derived == row.state {
        return Ok(derived);
    }
    set_state(
        conn,
        server_id,
        book_id,
        &[row.state.as_str()],
        &derived,
        // The transition is always recorded as `settle`: `mode` decides what may be
        // derived, and the table says who may write. See `healReopens`.
        Actor::Settle,
        now,
        row.last_error.as_deref(),
    )?;
    Ok(get(conn, server_id, book_id)?
        .map(|fresh| fresh.state)
        .unwrap_or(derived))
}

/// Force a state for the user's own actions (pause, resume, retry), refusing what
/// the contract table refuses.
pub fn user_set(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    to: &str,
    now: &str,
    last_error: Option<&str>,
) -> Result<DownloadRow, QueueError> {
    let row = get(conn, server_id, book_id)?.ok_or_else(|| QueueError::NotFound {
        server_id: server_id.to_string(),
        book_id: book_id.to_string(),
    })?;
    set_state(
        conn,
        server_id,
        book_id,
        &[row.state.as_str()],
        to,
        Actor::User,
        now,
        last_error,
    )?;
    get(conn, server_id, book_id)?.ok_or(QueueError::NotFound {
        server_id: server_id.to_string(),
        book_id: book_id.to_string(),
    })
}

/// Delete a book's rows. Returns the page paths the caller must then remove; the
/// order matters — rows first would leave the files unownable if the process died
/// between the two, and the sweep preserves what it cannot attribute.
pub fn delete_rows(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> Result<Vec<String>, QueueError> {
    let mut stmt = conn.prepare(
        "SELECT file_path FROM download_pages
         WHERE server_id = ?1 AND book_id = ?2 AND file_path IS NOT NULL",
    )?;
    let paths = stmt
        .query_map(params![server_id, book_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    conn.execute(
        "DELETE FROM download_pages WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
    )?;
    conn.execute(
        "DELETE FROM downloads WHERE server_id = ?1 AND book_id = ?2",
        params![server_id, book_id],
    )?;
    Ok(paths)
}

/// The queue as the planner needs it: every claimable book with its page rows and
/// the best size estimate available for each page.
///
/// The estimate matters because the byte budget is the only bound that keeps a pass
/// from holding a runtime worker through 96 MB of 4K pages, and a pending page has
/// no measured size yet. So it falls back through the mirror's declared size to the
/// book's own average, and a book with neither gets zero — which the planner reads
/// as "unbounded", the same conservative-but-not-frozen answer every unknown
/// device fact gets elsewhere in the core.
pub fn plan_books(
    conn: &Connection,
    server_id: Option<&str>,
) -> Result<Vec<super::queue::BookPlan>, QueueError> {
    let sql = "SELECT d.server_id, d.book_id, d.state, d.position, d.allow_cellular,
                COALESCE(d.pages_total, 0), d.next_retry_at,
                p.page_number, p.state, p.attempts,
                COALESCE(NULLIF(p.size_bytes, 0), bp.size_bytes,
                         CASE WHEN d.pages_total > 0
                              THEN d.bytes_total / d.pages_total ELSE 0 END, 0)
         FROM downloads d
         LEFT JOIN download_pages p
                ON p.server_id = d.server_id AND p.book_id = d.book_id
         LEFT JOIN book_pages bp
                ON bp.server_id = d.server_id AND bp.book_id = d.book_id
               AND bp.number = p.page_number
         WHERE (?1 IS NULL OR d.server_id = ?1) AND d.state IN (?2, ?3)
         ORDER BY d.position, d.server_id, d.book_id, p.page_number";
    let mut stmt = conn.prepare(sql)?;
    // Read one flat tuple per row. Building the two structs inside the row closure
    // means calling `row.get` from a nested closure, and `?` there has nowhere to
    // return to — so the shape is decided here and assembled below.
    type RawRow = (
        String,
        String,
        String,
        i64,
        i64,
        i64,
        Option<String>,
        Option<i64>,
        Option<String>,
        Option<i64>,
        Option<i64>,
    );
    let rows = stmt.query_map(
        params![server_id, book_state::WAITING, book_state::DOWNLOADING],
        |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
                row.get(8)?,
                row.get(9)?,
                row.get(10)?,
            ))
        },
    )?;
    let raw = rows.collect::<Result<Vec<RawRow>, _>>()?;

    let mut books: Vec<super::queue::BookPlan> = Vec::new();
    for (
        server_id,
        book_id,
        state,
        position,
        allow,
        pages_total,
        next_retry_at,
        number,
        page_state,
        attempts,
        declared,
    ) in raw
    {
        let page = number.map(|number| super::queue::PagePlan {
            number: number as u32,
            state: page_state.unwrap_or_default(),
            attempts: attempts.unwrap_or(0),
            declared_bytes: declared.unwrap_or(0),
        });
        match books.last_mut() {
            Some(last) if last.server_id == server_id && last.book_id == book_id => {
                if let Some(page) = page {
                    last.pages.push(page);
                }
                continue;
            }
            _ => {}
        }
        let mut plan = super::queue::BookPlan {
            server_id,
            book_id,
            position,
            state,
            allow_cellular: allow != 0,
            pages_total: pages_total.max(0) as u32,
            next_retry_at,
            pages: Vec::new(),
        };
        if let Some(page) = page {
            plan.pages.push(page);
        }
        books.push(plan);
    }
    Ok(books)
}

// ----------------------------------------------------------------- totals

/// Bytes the user's downloads hold, across every server.
pub fn bytes_done_all(conn: &Connection) -> Result<i64, QueueError> {
    Ok(conn.query_row(
        "SELECT COALESCE(SUM(size_bytes), 0) FROM download_pages WHERE state = ?1",
        params![page_state::COMPLETE],
        |row| row.get(0),
    )?)
}

pub fn bytes_done_for(conn: &Connection, server_id: &str) -> Result<i64, QueueError> {
    Ok(conn.query_row(
        "SELECT COALESCE(SUM(p.size_bytes), 0) FROM download_pages p
         JOIN downloads d ON d.server_id = p.server_id AND d.book_id = p.book_id
         WHERE p.state = ?2 AND p.server_id = ?1",
        params![server_id, page_state::COMPLETE],
        |row| row.get(0),
    )?)
}

pub fn page_count_all(conn: &Connection) -> Result<i64, QueueError> {
    Ok(conn.query_row(
        "SELECT COUNT(*) FROM download_pages WHERE state = ?1",
        params![page_state::COMPLETE],
        |row| row.get(0),
    )?)
}

/// Per-book storage rows, newest download first. Ordered in SQL rather than in
/// Dart so both platforms' screens agree without either restating the rule.
pub fn storage_rows(conn: &Connection) -> Result<Vec<DownloadRow>, QueueError> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {DOWNLOAD_COLUMNS} FROM downloads
         ORDER BY bytes_done DESC, created_at, server_id, book_id"
    ))?;
    let rows = stmt.query_map([], download_from_row)?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(QueueError::from)
}

#[cfg(test)]
mod tests {
    use super::super::harness::{enqueue_book, stamp, Tree};
    use super::queue::{book_state, page_state};
    use super::*;

    fn mark(tree: &Tree, book: &str, number: u32) {
        let path = tree
            .root
            .page_path("s1", book, number, "png")
            .to_string_lossy()
            .into_owned();
        mark_page_complete(
            &tree.conn,
            "s1",
            book,
            number,
            &path,
            1_000 + i64::from(number),
            "image/png",
            &stamp(0),
        )
        .unwrap();
    }

    #[test]
    fn counters_are_derived_from_rows_and_a_corrupted_one_is_recomputed() {
        let tree = Tree::new("counters");
        enqueue_book(&tree, "s1", "b1", 6);
        for number in 1..=3 {
            mark(&tree, "b1", number);
        }
        // A page write does not touch the book's counters: the engine recomputes
        // them inside the same transaction it lands the page in, which is the only
        // order that cannot leave a book claiming a page the disk does not have.
        recompute_counters(&tree.conn, "s1", "b1", &stamp(1)).unwrap();
        let row = get(&tree.conn, "s1", "b1").unwrap().unwrap();
        assert_eq!(row.pages_done, 3);
        assert_eq!(row.bytes_done, 1_001 + 1_002 + 1_003);

        // Corrupt the counter the way a half-applied commit would, and prove the
        // recompute fixes it. Without this half the test only measures arithmetic.
        tree.conn
            .execute(
                "UPDATE downloads SET pages_done = 999, bytes_done = 1 WHERE book_id = 'b1'",
                [],
            )
            .unwrap();
        let (done, bytes) = recompute_counters(&tree.conn, "s1", "b1", &stamp(1)).unwrap();
        assert_eq!((done, bytes), (3, 3_006));
        let row = get(&tree.conn, "s1", "b1").unwrap().unwrap();
        assert_eq!((row.pages_done, row.bytes_done), (3, 3_006));
    }

    #[test]
    fn a_pause_that_lands_mid_pass_wins_the_write() {
        let tree = Tree::new("pause_race");
        enqueue_book(&tree, "s1", "b1", 4);
        set_state(
            &tree.conn,
            "s1",
            "b1",
            &[book_state::WAITING],
            book_state::DOWNLOADING,
            Actor::Pump,
            &stamp(0),
            None,
        )
        .unwrap();
        // The user's gesture arrives while a page is in flight.
        user_set(&tree.conn, "s1", "b1", book_state::PAUSED, &stamp(1), None).unwrap();
        // The pass now tries to settle the book it believes it holds. It must not
        // move at all — and it must not report an error, because nothing went wrong.
        let moved = set_state(
            &tree.conn,
            "s1",
            "b1",
            &[book_state::DOWNLOADING],
            book_state::COMPLETED,
            Actor::Settle,
            &stamp(2),
            None,
        )
        .unwrap();
        assert!(!moved, "a settle overwrote the user's pause");
        mark(&tree, "b1", 1);
        settle_book(&tree.conn, "s1", "b1", &stamp(3), SettleMode::Pass).unwrap();
        let row = get(&tree.conn, "s1", "b1").unwrap().unwrap();
        assert_eq!(row.state, book_state::PAUSED, "settle laundered the pause");
        assert_eq!(row.pages_done, 1, "the counters still track the rows");
    }

    #[test]
    fn retry_clears_failed_pages_and_leaves_complete_ones_alone() {
        let tree = Tree::new("retry");
        enqueue_book(&tree, "s1", "b1", 4);
        mark(&tree, "b1", 1);
        mark(&tree, "b1", 2);
        for number in 3..=4 {
            record_page_attempt(
                &tree.conn,
                "s1",
                "b1",
                number,
                "页面没有完整到达",
                &stamp(1),
            )
            .unwrap();
            record_page_attempt(
                &tree.conn,
                "s1",
                "b1",
                number,
                "页面没有完整到达",
                &stamp(2),
            )
            .unwrap();
            let exhausted =
                record_page_attempt(&tree.conn, "s1", "b1", number, "still bad", &stamp(3))
                    .unwrap();
            assert!(exhausted, "the third attempt is the limit");
        }
        let settled = settle_book(&tree.conn, "s1", "b1", &stamp(4), SettleMode::Pass).unwrap();
        assert_eq!(
            settled,
            book_state::FAILED,
            "2 of 4 done, 2 failed = no options left"
        );

        let reset = retry_failed_pages(&tree.conn, "s1", "b1", &stamp(5)).unwrap();
        assert_eq!(reset, 2, "only the failed pages are re-queued");
        let kept: Vec<(u32, String, i64)> = pages(&tree.conn, "s1", "b1")
            .unwrap()
            .into_iter()
            .filter(|row| row.state == page_state::COMPLETE)
            .map(|row| {
                (
                    row.number,
                    row.file_path.unwrap_or_default(),
                    row.size_bytes,
                )
            })
            .collect();
        assert_eq!(kept.len(), 2);
        assert!(
            kept.iter()
                .all(|(_, path, size)| !path.is_empty() && *size > 0),
            "a retry must not clear a page the disk already has"
        );
        // The book is fetchable again, so it is no longer failed.
        user_set(&tree.conn, "s1", "b1", book_state::WAITING, &stamp(6), None).unwrap();
        assert_eq!(
            state_of(&tree.conn, "s1", "b1").unwrap().as_deref(),
            Some(book_state::WAITING)
        );
    }

    #[test]
    fn an_illegal_state_write_is_refused_rather_than_ignored() {
        let tree = Tree::new("illegal");
        enqueue_book(&tree, "s1", "b1", 2);
        set_state(
            &tree.conn,
            "s1",
            "b1",
            &[book_state::WAITING],
            book_state::DOWNLOADING,
            Actor::Pump,
            &stamp(0),
            None,
        )
        .unwrap();
        let error = set_state(
            &tree.conn,
            "s1",
            "b1",
            &[book_state::DOWNLOADING],
            book_state::DOWNLOADING,
            Actor::Pump,
            &stamp(1),
            None,
        )
        .err();
        // `downloading -> downloading` is not in the table at all, so the refusal is
        // the contract's, not a special case in this module.
        assert!(
            matches!(error, Some(QueueError::IllegalTransition { .. })),
            "{error:?}"
        );
    }

    #[test]
    fn re_enqueueing_while_a_pass_holds_the_book_is_refused() {
        let tree = Tree::new("reenqueue");
        enqueue_book(&tree, "s1", "b1", 3);
        set_state(
            &tree.conn,
            "s1",
            "b1",
            &[book_state::WAITING],
            book_state::DOWNLOADING,
            Actor::Pump,
            &stamp(0),
            None,
        )
        .unwrap();
        let again = super::enqueue(
            &tree.conn,
            &NewDownload {
                server_id: "s1".to_string(),
                book_id: "b1".to_string(),
                pages_total: 3,
                bytes_total: 3_000,
                manifest_path: "/tmp/manifest.json".to_string(),
                remote_last_modified: None,
                book_title: None,
                series_title: None,
            },
            &[1, 2, 3],
            &stamp(1),
        );
        assert!(matches!(
            again.err(),
            Some(QueueError::IllegalTransition { .. })
        ));
        // The rows the in-flight pass is working from are still there.
        assert_eq!(pages(&tree.conn, "s1", "b1").unwrap().len(), 3);
        // A completed book, by contrast, restarts: same gesture, different state.
        mark(&tree, "b1", 1);
        mark(&tree, "b1", 2);
        mark(&tree, "b1", 3);
        settle_book(&tree.conn, "s1", "b1", &stamp(2), SettleMode::Pass).unwrap();
        assert_eq!(
            state_of(&tree.conn, "s1", "b1").unwrap().as_deref(),
            Some(book_state::COMPLETED)
        );
        super::enqueue(
            &tree.conn,
            &NewDownload {
                server_id: "s1".to_string(),
                book_id: "b1".to_string(),
                pages_total: 2,
                bytes_total: 2_000,
                manifest_path: "/tmp/manifest.json".to_string(),
                remote_last_modified: None,
                book_title: None,
                series_title: None,
            },
            &[1, 2],
            &stamp(3),
        )
        .expect("a finished book may be re-downloaded by its owner");
        assert_eq!(pages(&tree.conn, "s1", "b1").unwrap().len(), 2);
    }

    #[test]
    fn a_parked_server_leaves_paused_and_finished_books_alone() {
        let tree = Tree::new("park");
        for book in ["b1", "b2", "b3"] {
            enqueue_book(&tree, "s1", book, 2);
        }
        user_set(&tree.conn, "s1", "b2", book_state::PAUSED, &stamp(1), None).unwrap();
        mark(&tree, "b3", 1);
        mark(&tree, "b3", 2);
        settle_book(&tree.conn, "s1", "b3", &stamp(1), SettleMode::Pass).unwrap();
        let parked =
            park_server(&tree.conn, "s1", &stamp(60), "服务器拒绝了凭据", &stamp(2)).unwrap();
        assert_eq!(
            parked, 1,
            "a parked appointment is only worth giving to a book that would run"
        );
        for book in ["b1", "b2", "b3"] {
            let row = get(&tree.conn, "s1", book).unwrap().unwrap();
            assert_eq!(
                row.next_retry_at.is_some(),
                book == "b1",
                "{book} carries a park appointment it should not have"
            );
        }
    }

    #[test]
    fn plan_books_sizes_pages_from_the_mirror_then_the_book_average() {
        let tree = Tree::new("plandims");
        enqueue_book(&tree, "s1", "b1", 4);
        let plans = plan_books(&tree.conn, Some("s1")).unwrap();
        assert_eq!(plans.len(), 1);
        let first = &plans[0];
        assert_eq!(first.pages.len(), 4, "every page of the book is planned");
        assert!(
            first.pages.iter().all(|page| page.declared_bytes > 0),
            "the mirror's declared sizes are what the byte budget works from"
        );
        let mirrored = first.pages[0].declared_bytes;

        // Take the mirror away: the book's own average still bounds the pass.
        tree.conn.execute("DELETE FROM book_pages", []).unwrap();
        let plans = plan_books(&tree.conn, Some("s1")).unwrap();
        let average = plans[0].pages[0].declared_bytes;
        assert!(average > 0, "bytes_total / pages_total is the fallback");
        assert!(
            (average - mirrored).abs() < mirrored,
            "the average is the same order as the real sizes: {average} vs {mirrored}"
        );

        // And with neither, zero means "unbounded", which the planner reads as
        // page-count-bound rather than as a frozen queue.
        tree.conn
            .execute("UPDATE downloads SET bytes_total = 0", [])
            .unwrap();
        let plans = plan_books(&tree.conn, Some("s1")).unwrap();
        assert_eq!(plans[0].pages[0].declared_bytes, 0);
        assert_eq!(plan_books(&tree.conn, Some("other")).unwrap().len(), 0);
    }

    #[test]
    fn complete_pages_is_the_list_the_reader_and_the_prefetcher_share() {
        let tree = Tree::new("complete");
        enqueue_book(&tree, "s1", "b1", 5);
        mark(&tree, "b1", 1);
        mark(&tree, "b1", 3);
        assert_eq!(complete_pages(&tree.conn, "s1", "b1").unwrap(), vec![1, 3]);
        assert_eq!(page_count_all(&tree.conn).unwrap(), 2);
        assert!(bytes_done_all(&tree.conn).unwrap() > 0);
        assert_eq!(bytes_done_for(&tree.conn, "nope").unwrap(), 0);
    }

    #[test]
    fn a_settled_book_does_not_un_settle_when_a_row_goes_missing() {
        let tree = Tree::new("sticky");
        enqueue_book(&tree, "s1", "b1", 2);
        mark(&tree, "b1", 1);
        mark(&tree, "b1", 2);
        assert_eq!(
            settle_book(&tree.conn, "s1", "b1", &stamp(1), SettleMode::Pass).unwrap(),
            book_state::COMPLETED
        );
        heal_page(&tree.conn, "s1", "b1", 2, &stamp(2)).unwrap();
        let settled = settle_book(&tree.conn, "s1", "b1", &stamp(3), SettleMode::Pass).unwrap();
        assert_eq!(
            settled,
            book_state::COMPLETED,
            "a completion is the disk's, and settle does not take it back"
        );
        // The missing page is still queued for the sweep to re-fetch.
        assert_eq!(
            page(&tree.conn, "s1", "b1", 2).unwrap().unwrap().state,
            page_state::PENDING
        );
    }

    #[test]
    fn delete_rows_hands_back_the_paths_it_stopped_tracking() {
        let tree = Tree::new("delete");
        enqueue_book(&tree, "s1", "b1", 3);
        mark(&tree, "b1", 1);
        let paths = delete_rows(&tree.conn, "s1", "b1").unwrap();
        assert_eq!(paths.len(), 1);
        assert!(get(&tree.conn, "s1", "b1").unwrap().is_none());
        assert!(pages(&tree.conn, "s1", "b1").unwrap().is_empty());
        assert_eq!(bytes_done_all(&tree.conn).unwrap(), 0);
    }

    #[test]
    fn the_queue_reads_back_in_the_order_the_user_tapped_it() {
        let tree = Tree::new("order");
        // Deliberately reverse-alphabetical ids, so an order that fell back to the
        // rowid or the id would show up.
        for book in ["c", "a", "b"] {
            enqueue_book(&tree, "s1", book, 1);
        }
        let order: Vec<String> = list(&tree.conn, Some("s1"))
            .unwrap()
            .into_iter()
            .map(|row| row.book_id)
            .collect();
        assert_eq!(order, vec!["c", "a", "b"]);
        assert_eq!(list(&tree.conn, None).unwrap().len(), 3);
    }
}
