//! Delete propagation — remote deletion → local cascade + tombstone.
//!
//! Komga has no "deleted ids" endpoint, so deletions are discovered by
//! Reconcile: sweep the remote id set for an entity type, then remove every
//! local row that the server no longer reports. The mirrored row is hard
//! deleted (children cascade), and a tombstone is left behind so a late SSE
//! event or a stale Outbox mutation can be recognised as pointing at
//! something that is gone.
//!
//! Cascade rules mirror `specs/contracts/delete-propagation/README.md`:
//! covers / cache records for the deleted entity go with it (the facade
//! removes the files from disk). Queued Outbox entries deliberately
//! *survive*: a remote deletion is inferred from "this id was not in the
//! sweep", and offset pagination can skip an id when rows shift under a
//! concurrent change. Getting that wrong would silently discard a user
//! action that can never be re-derived, while every mirrored row we do
//! delete is refetchable — so the upload phase owns the "the server says
//! this book is gone" verdict.

use std::collections::{HashMap, HashSet};

use rusqlite::{params, Connection};

use crate::store::sync_state;
use crate::store::thumbnails;

/// Cause vocabulary for `deleted_entities.cause`.
pub const CAUSE_RECONCILE: &str = "reconcile";
pub const CAUSE_CASCADE: &str = "cascade";
pub const CAUSE_EVENT: &str = "event";

/// One tombstone row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tombstone {
    pub server_id: String,
    pub entity_type: String,
    pub remote_id: String,
    pub deleted_at: String,
    pub cause: String,
}

fn now_rfc3339() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

/// Local remote-ids for one entity type (the diff input for prune).
pub fn local_ids(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
) -> rusqlite::Result<Vec<String>> {
    // Entity types without a mirror table have nothing to diff and nothing
    // to prune — an empty set can only ever delete zero rows.
    let Some(table) = entity_table(entity_type) else {
        return Ok(vec![]);
    };
    let mut stmt = conn.prepare(&format!(
        "SELECT remote_id FROM {table} WHERE server_id = ?1 ORDER BY remote_id"
    ))?;
    let rows = stmt.query_map(params![server_id], |row| row.get::<_, String>(0))?;
    rows.collect()
}

/// Local book ids scoped to one series (books are swept per series).
pub fn local_book_ids_for_series(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT remote_id FROM books WHERE server_id = ?1 AND series_id = ?2 ORDER BY remote_id",
    )?;
    let rows = stmt.query_map(params![server_id, series_id], |row| row.get::<_, String>(0))?;
    rows.collect()
}

fn entity_table(entity_type: &str) -> Option<&'static str> {
    match entity_type {
        sync_state::ENTITY_LIBRARIES => Some("libraries"),
        sync_state::ENTITY_SERIES => Some("series"),
        sync_state::ENTITY_BOOKS => Some("books"),
        sync_state::ENTITY_COLLECTIONS => Some("collections"),
        sync_state::ENTITY_READLISTS => Some("readlists"),
        _ => None,
    }
}

/// Record that an entity is gone. Idempotent (re-deleting refreshes the stamp).
pub fn record_tombstone(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
    remote_id: &str,
    cause: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO deleted_entities (server_id, entity_type, remote_id, deleted_at, cause)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(server_id, entity_type, remote_id) DO UPDATE SET
           deleted_at = excluded.deleted_at,
           cause = excluded.cause",
        params![server_id, entity_type, remote_id, now_rfc3339(), cause],
    )?;
    Ok(())
}

/// True when one server/entity type has any tombstone at all. A steady-state
/// sweep has none, and checking once beats issuing `ids.len()` deletes.
pub fn has_tombstones(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
) -> rusqlite::Result<bool> {
    let found: i64 = conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM deleted_entities WHERE server_id = ?1 AND entity_type = ?2)",
        params![server_id, entity_type],
        |row| row.get(0),
    )?;
    Ok(found == 1)
}

/// Clear the tombstones of the ids a sweep saw. Cheap by design: a
/// steady-state sweep has no tombstones at all, and that is answered with one
/// `EXISTS` query instead of `ids.len()` deletes.
pub fn clear_tombstones(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
    ids: &[String],
) -> rusqlite::Result<()> {
    if ids.is_empty() || !has_tombstones(conn, server_id, entity_type)? {
        return Ok(());
    }
    for id in ids {
        clear_tombstone(conn, server_id, entity_type, id)?;
    }
    Ok(())
}

/// A re-added entity (same id back on the server) clears its tombstone.
pub fn clear_tombstone(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
    remote_id: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM deleted_entities WHERE server_id = ?1 AND entity_type = ?2 AND remote_id = ?3",
        params![server_id, entity_type, remote_id],
    )?;
    Ok(())
}

pub fn list_tombstones(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
) -> rusqlite::Result<Vec<Tombstone>> {
    let mut stmt = conn.prepare(
        "SELECT * FROM deleted_entities WHERE server_id = ?1 AND entity_type = ?2 ORDER BY deleted_at, remote_id",
    )?;
    let rows = stmt.query_map(params![server_id, entity_type], |row| {
        Ok(Tombstone {
            server_id: row.get("server_id")?,
            entity_type: row.get("entity_type")?,
            remote_id: row.get("remote_id")?,
            deleted_at: row.get("deleted_at")?,
            cause: row.get("cause")?,
        })
    })?;
    rows.collect()
}

pub fn count_tombstones(conn: &Connection, server_id: &str) -> rusqlite::Result<i64> {
    conn.query_row(
        "SELECT COUNT(*) FROM deleted_entities WHERE server_id = ?1",
        params![server_id],
        |row| row.get(0),
    )
}

/// Delete a book's mirror rows (children + search index + cover records +
/// Outbox entries). Returns the cover file paths that became orphaned.
///
/// It does NOT touch `downloads` / `download_pages`. The mirror infers a remote
/// deletion from absence in one sweep, and Stage 5's own rule is that absence is
/// weak evidence — offset pagination can produce it for a book that is fine. A
/// queued mutation is the least recoverable thing in the database for that reason;
/// so is a file the user chose to keep, and unlike a mutation it cannot be re-derived
/// from the server, because in this case the server is the thing that lost it.
/// `delete_server_mirror` still clears them: dropping a server is a user action.
pub fn delete_book(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let covers = take_cover_paths(conn, server_id, book_id, "book")?;
    drop_fts_row(conn, "book_fts", "books", server_id, book_id)?;
    for sql in [
        "DELETE FROM book_metadata WHERE server_id = ?1 AND book_id = ?2",
        "DELETE FROM book_tags WHERE server_id = ?1 AND book_id = ?2",
        "DELETE FROM book_authors WHERE server_id = ?1 AND book_id = ?2",
        "DELETE FROM readlist_books WHERE server_id = ?1 AND book_id = ?2",
        "DELETE FROM read_progress WHERE server_id = ?1 AND book_id = ?2",
    ] {
        conn.execute(sql, params![server_id, book_id])?;
    }
    conn.execute(
        "DELETE FROM books WHERE server_id = ?1 AND remote_id = ?2",
        params![server_id, book_id],
    )?;
    thumbnails::delete_entity(conn, server_id, book_id, "book")?;
    Ok(covers)
}

/// Delete a series and everything hanging off it (its books cascade first).
pub fn delete_series(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut covers = Vec::new();
    for book_id in local_book_ids_for_series(conn, server_id, series_id)? {
        record_tombstone(
            conn,
            server_id,
            sync_state::ENTITY_BOOKS,
            &book_id,
            CAUSE_CASCADE,
        )?;
        covers.extend(delete_book(conn, server_id, &book_id)?);
    }
    covers.extend(take_cover_paths(conn, server_id, series_id, "series")?);
    drop_fts_row(conn, "series_fts", "series", server_id, series_id)?;
    for sql in [
        "DELETE FROM series_metadata WHERE server_id = ?1 AND series_id = ?2",
        "DELETE FROM series_tags WHERE server_id = ?1 AND series_id = ?2",
        "DELETE FROM series_genres WHERE server_id = ?1 AND series_id = ?2",
        "DELETE FROM series_authors WHERE server_id = ?1 AND series_id = ?2",
        "DELETE FROM collection_series WHERE server_id = ?1 AND series_id = ?2",
    ] {
        conn.execute(sql, params![server_id, series_id])?;
    }
    conn.execute(
        "DELETE FROM series WHERE server_id = ?1 AND remote_id = ?2",
        params![server_id, series_id],
    )?;
    thumbnails::delete_entity(conn, server_id, series_id, "series")?;
    Ok(covers)
}

/// Delete a collection (membership rows go with it).
pub fn delete_collection(conn: &Connection, server_id: &str, id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM collection_series WHERE server_id = ?1 AND collection_id = ?2",
        params![server_id, id],
    )?;
    conn.execute(
        "DELETE FROM collections WHERE server_id = ?1 AND remote_id = ?2",
        params![server_id, id],
    )?;
    Ok(())
}

/// Delete a readlist (ordered book links go with it).
pub fn delete_readlist(conn: &Connection, server_id: &str, id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM readlist_books WHERE server_id = ?1 AND readlist_id = ?2",
        params![server_id, id],
    )?;
    conn.execute(
        "DELETE FROM readlists WHERE server_id = ?1 AND remote_id = ?2",
        params![server_id, id],
    )?;
    Ok(())
}

/// Delete a library row. Its series/books are removed by the series sweep
/// (they disappear from the server together with the library).
pub fn delete_library(conn: &Connection, server_id: &str, id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM libraries WHERE server_id = ?1 AND remote_id = ?2",
        params![server_id, id],
    )?;
    Ok(())
}

/// Delete one entity of a known type, leaving a tombstone.
pub fn delete_entity(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
    remote_id: &str,
    cause: &str,
) -> rusqlite::Result<Vec<String>> {
    record_tombstone(conn, server_id, entity_type, remote_id, cause)?;
    match entity_type {
        sync_state::ENTITY_SERIES => delete_series(conn, server_id, remote_id),
        sync_state::ENTITY_BOOKS => delete_book(conn, server_id, remote_id),
        sync_state::ENTITY_COLLECTIONS => {
            delete_collection(conn, server_id, remote_id)?;
            Ok(vec![])
        }
        sync_state::ENTITY_READLISTS => {
            delete_readlist(conn, server_id, remote_id)?;
            Ok(vec![])
        }
        sync_state::ENTITY_LIBRARIES => {
            delete_library(conn, server_id, remote_id)?;
            Ok(vec![])
        }
        _ => Ok(vec![]),
    }
}

/// What a prune pass removed: the mirrored rows plus the cover files that
/// became orphans (the facade deletes those from disk).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Pruned {
    pub ids: Vec<String>,
    pub cover_paths: Vec<String>,
}

impl Pruned {
    pub fn len(&self) -> usize {
        self.ids.len()
    }

    pub fn is_empty(&self) -> bool {
        self.ids.is_empty()
    }
}

/// Remove local rows the server no longer reports.
pub fn prune(
    conn: &Connection,
    server_id: &str,
    entity_type: &str,
    remote_ids: &HashSet<String>,
    cause: &str,
) -> rusqlite::Result<Pruned> {
    let missing: Vec<String> = local_ids(conn, server_id, entity_type)?
        .into_iter()
        .filter(|id| !remote_ids.contains(id))
        .collect();
    let mut pruned = Pruned {
        ids: missing.clone(),
        cover_paths: Vec::new(),
    };
    for id in &missing {
        pruned
            .cover_paths
            .extend(delete_entity(conn, server_id, entity_type, id, cause)?);
    }
    Ok(pruned)
}

/// Book prune scoped to the series actually swept in this pass: local books
/// under a series we did not visit stay untouched (they are not evidence of
/// a remote deletion yet).
pub fn prune_books_for_swept_series(
    conn: &Connection,
    server_id: &str,
    swept: &HashMap<String, HashSet<String>>,
    cause: &str,
) -> rusqlite::Result<Pruned> {
    let mut pruned = Pruned::default();
    let mut series_ids: Vec<&String> = swept.keys().collect();
    series_ids.sort();
    for series_id in series_ids {
        for book_id in local_book_ids_for_series(conn, server_id, series_id)? {
            if !swept[series_id].contains(&book_id) {
                pruned.cover_paths.extend(delete_entity(
                    conn,
                    server_id,
                    sync_state::ENTITY_BOOKS,
                    &book_id,
                    cause,
                )?);
                pruned.ids.push(book_id);
            }
        }
    }
    Ok(pruned)
}

/// Cover file paths recorded for an entity (before the row is deleted).
fn take_cover_paths(
    conn: &Connection,
    server_id: &str,
    remote_id: &str,
    variant: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT local_path FROM thumbnails WHERE server_id = ?1 AND remote_id = ?2 AND variant = ?3",
    )?;
    let rows = stmt.query_map(params![server_id, remote_id, variant], |row| {
        row.get::<_, String>(0)
    })?;
    rows.collect()
}

fn drop_fts_row(
    conn: &Connection,
    fts_table: &str,
    source_table: &str,
    server_id: &str,
    remote_id: &str,
) -> rusqlite::Result<()> {
    let rowid: Option<i64> = conn
        .query_row(
            &format!(
                "SELECT fts_rowid FROM {source_table} WHERE server_id = ?1 AND remote_id = ?2"
            ),
            params![server_id, remote_id],
            |row| row.get(0),
        )
        .unwrap_or(None);
    if let Some(rowid) = rowid {
        conn.execute(
            &format!("DELETE FROM {fts_table} WHERE rowid = ?1"),
            params![rowid],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::book::BookPage;
    use crate::model::collection::CollectionPage;
    use crate::model::series::SeriesPage;
    use crate::store;
    use crate::store::open_in_memory;

    fn series_page() -> SeriesPage {
        let json = include_str!("../../../../specs/contracts/fixtures/library/series-page.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    fn books_by_series() -> HashMap<String, BookPage> {
        let json =
            include_str!("../../../../specs/contracts/fixtures/library/books-by-series.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    fn collections_page() -> CollectionPage {
        let json =
            include_str!("../../../../specs/contracts/fixtures/library/collections-page.json");
        serde_json::from_str(json).expect("shared fixture must decode")
    }

    /// Series + books + one collection holding the series.
    fn seeded(conn: &Connection) {
        store::series::save_series_batch(conn, "srv", &series_page().content).unwrap();
        for page in books_by_series().values() {
            store::books::save_books_batch(conn, "srv", &page.content).unwrap();
        }
        store::collections::save_collections_batch(conn, "srv", &collections_page().content)
            .unwrap();
    }

    fn count(conn: &Connection, sql: &str) -> i64 {
        conn.query_row(sql, params!["srv"], |row| row.get(0))
            .unwrap()
    }

    #[test]
    fn series_delete_cascades_to_books_and_children() {
        let conn = open_in_memory().unwrap();
        seeded(&conn);
        // A cover record + a pending mutation for one book of series-1.
        thumbnails::record_thumbnail(&conn, "srv", "book-1-1", "book", "/tmp/b.png", 10).unwrap();
        conn.execute(
            "INSERT INTO pending_mutations (id, server_id, entity_id, mutation_type, payload, created_at)
             VALUES ('m1', 'srv', 'book-1-1', 'READ_PROGRESS', '{}', 'now')",
            [],
        )
        .unwrap();
        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM books WHERE server_id = ?1"),
            7
        );

        let covers = delete_entity(
            &conn,
            "srv",
            sync_state::ENTITY_SERIES,
            "series-1",
            CAUSE_RECONCILE,
        )
        .unwrap();

        // series-1 owned 3 books; the other series keep theirs.
        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM books WHERE server_id = ?1"),
            4
        );
        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM series WHERE server_id = ?1"),
            2
        );
        assert_eq!(
            count(
                &conn,
                "SELECT COUNT(*) FROM series_metadata WHERE server_id = ?1"
            ),
            2
        );
        assert_eq!(
            count(
                &conn,
                "SELECT COUNT(*) FROM read_progress WHERE server_id = ?1"
            ),
            1
        );
        assert_eq!(
            count(
                &conn,
                "SELECT COUNT(*) FROM collection_series WHERE server_id = ?1"
            ),
            2
        );
        // The queued upload survives on purpose: a deletion inferred from a
        // sweep can be a pagination artefact, and a lost user action cannot be
        // re-derived. Discarding it is the upload phase's call to make.
        let queued: String = conn
            .query_row(
                "SELECT mutation_type FROM pending_mutations WHERE server_id = ?1",
                params!["srv"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(queued, "READ_PROGRESS");
        assert_eq!(
            count(
                &conn,
                "SELECT COUNT(*) FROM thumbnails WHERE server_id = ?1"
            ),
            0
        );
        assert_eq!(covers, vec!["/tmp/b.png".to_string()]);
        // Tombstones: the series plus its 3 cascaded books.
        assert_eq!(count_tombstones(&conn, "srv").unwrap(), 4);
        let book_tombstones = list_tombstones(&conn, "srv", sync_state::ENTITY_BOOKS).unwrap();
        assert_eq!(book_tombstones.len(), 3);
        assert_eq!(book_tombstones[0].cause, CAUSE_CASCADE);
    }

    #[test]
    fn book_delete_clears_membership_and_search() {
        let conn = open_in_memory().unwrap();
        seeded(&conn);
        let before = count(&conn, "SELECT COUNT(*) FROM book_fts WHERE server_id = ?1");
        delete_book(&conn, "srv", "book-1-1").unwrap();
        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM books WHERE server_id = ?1"),
            6
        );
        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM book_fts WHERE server_id = ?1"),
            before - 1,
            "the deleted book must leave the search index"
        );
        assert_eq!(
            conn.query_row::<i64, _, _>(
                "SELECT COUNT(*) FROM series_fts WHERE server_id = ?1",
                params!["srv"],
                |r| r.get(0)
            )
            .unwrap(),
            3,
            "the parent series index is untouched"
        );
    }

    #[test]
    fn prune_only_removes_ids_the_server_no_longer_reports() {
        let conn = open_in_memory().unwrap();
        seeded(&conn);
        let keep: HashSet<String> = ["series-1".to_string(), "series-2".to_string()]
            .into_iter()
            .collect();
        let deleted = prune(
            &conn,
            "srv",
            sync_state::ENTITY_SERIES,
            &keep,
            CAUSE_RECONCILE,
        )
        .unwrap();
        assert_eq!(deleted.ids, vec!["series-3".to_string()]);
        // No cover files were recorded for this server, so nothing orphaned.
        assert!(deleted.cover_paths.is_empty());
        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM series WHERE server_id = ?1"),
            2
        );
        assert_eq!(
            list_tombstones(&conn, "srv", sync_state::ENTITY_SERIES).unwrap()[0].cause,
            CAUSE_RECONCILE
        );
        // A re-added series clears its own tombstone; the cascaded books keep
        // theirs until the server reports them again.
        clear_tombstone(&conn, "srv", sync_state::ENTITY_SERIES, "series-3").unwrap();
        assert_eq!(count_tombstones(&conn, "srv").unwrap(), 2);
    }

    #[test]
    fn book_prune_is_scoped_to_swept_series() {
        let conn = open_in_memory().unwrap();
        seeded(&conn);
        let mut swept: HashMap<String, HashSet<String>> = HashMap::new();
        // series-1 was swept and reports 2 of its 3 books; series-2 was not swept.
        swept.insert(
            "series-1".to_string(),
            ["book-1-1".to_string(), "book-1-2".to_string()]
                .into_iter()
                .collect(),
        );
        let pruned = prune_books_for_swept_series(&conn, "srv", &swept, CAUSE_RECONCILE).unwrap();
        assert_eq!(pruned.ids, vec!["book-1-3".to_string()]);
        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM books WHERE server_id = ?1"),
            6
        );
        // series-2's books survived: its sweep never ran.
        assert_eq!(
            conn.query_row::<i64, _, _>(
                "SELECT COUNT(*) FROM books WHERE server_id = ?1 AND series_id = 'series-2'",
                params!["srv"],
                |r| r.get(0)
            )
            .unwrap(),
            2
        );
    }
}
