//! `cache_entries` bookkeeping — the generic LRU ledger for page/prefetch
//! bytes (docs/offline-storage.md). The `thumbnails` table keeps its own
//! accounting because covers are keyed per entity; everything byte-sized that
//! the reader generates goes here.
//!
//! Hit rule, same as covers: a row AND a readable file. Either missing is a
//! miss, and a row whose file is gone is deleted on sight so the ledger cannot
//! drift from the disk.

use rusqlite::{params, Connection, OptionalExtension};

pub const KIND_PAGE: &str = "page";
pub const KIND_PREFETCH: &str = "prefetch";
/// A user-owned offline download. Eviction must never touch these.
pub const KIND_DOWNLOAD: &str = "download";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CacheEntry {
    pub key: String,
    pub kind: String,
    pub path: String,
    pub size: i64,
    pub last_access: String,
}

pub fn record(
    conn: &Connection,
    key: &str,
    kind: &str,
    path: &str,
    size: i64,
    now: &str,
) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO cache_entries (key, kind, path, size, last_access)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(key) DO UPDATE SET kind = excluded.kind, path = excluded.path,
                                        size = excluded.size, last_access = excluded.last_access",
        params![key, kind, path, size, now],
    )?;
    Ok(())
}

pub fn get(conn: &Connection, key: &str) -> rusqlite::Result<Option<CacheEntry>> {
    conn.query_row(
        "SELECT key, kind, path, size, last_access FROM cache_entries WHERE key = ?1",
        params![key],
        |row| {
            Ok(CacheEntry {
                key: row.get(0)?,
                kind: row.get(1)?,
                path: row.get(2)?,
                size: row.get(3)?,
                last_access: row.get(4)?,
            })
        },
    )
    .optional()
}

/// Stamp an entry as recently used without rewriting the row.
pub fn touch(conn: &Connection, key: &str, now: &str) -> rusqlite::Result<()> {
    conn.execute(
        "UPDATE cache_entries SET last_access = ?2 WHERE key = ?1",
        params![key, now],
    )?;
    Ok(())
}

/// Drop a row and hand back its path so the caller can delete the file.
pub fn remove(conn: &Connection, key: &str) -> rusqlite::Result<Option<String>> {
    let path: Option<String> = conn
        .query_row(
            "SELECT path FROM cache_entries WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()?;
    if path.is_some() {
        conn.execute("DELETE FROM cache_entries WHERE key = ?1", params![key])?;
    }
    Ok(path)
}

pub fn remove_many(conn: &Connection, keys: &[String]) -> rusqlite::Result<Vec<String>> {
    let mut paths = Vec::new();
    for key in keys {
        paths.extend(remove(conn, key)?);
    }
    Ok(paths)
}

/// Move a row to a new path and/or kind, stamping it as used.
///
/// This is the prefetch -> page promotion: the file has been renamed, and the
/// ledger must stop describing it as a candidate for eviction before it has
/// ever been looked at.
pub fn relocate(
    conn: &Connection,
    key: &str,
    path: &str,
    kind: &str,
    now: &str,
) -> rusqlite::Result<()> {
    let changed = conn.execute(
        "UPDATE cache_entries SET path = ?2, kind = ?3, last_access = ?4 WHERE key = ?1",
        params![key, path, kind, now],
    )?;
    if changed == 0 {
        return Err(rusqlite::Error::QueryReturnedNoRows);
    }
    Ok(())
}

/// Sum of accounted bytes with no filesystem walk.
///
/// The eviction decision runs on every store, so it may not stat every cached
/// file — over a 500-page book that is O(n) per page turn. [`total_bytes`] is
/// the reconciling variant and runs on open instead.
pub fn total_bytes_fast(conn: &Connection) -> rusqlite::Result<i64> {
    conn.query_row(
        "SELECT COALESCE(SUM(size), 0) FROM cache_entries",
        [],
        |row| row.get(0),
    )
}

/// Every row, for the reconciliation sweep. Ascending key so a sweep is
/// reproducible.
pub fn entries(conn: &Connection) -> rusqlite::Result<Vec<CacheEntry>> {
    let mut rows = conn
        .prepare("SELECT key, kind, path, size, last_access FROM cache_entries ORDER BY key ASC")?;
    let collected = rows.query_map([], |row| {
        Ok(CacheEntry {
            key: row.get(0)?,
            kind: row.get(1)?,
            path: row.get(2)?,
            size: row.get(3)?,
            last_access: row.get(4)?,
        })
    })?;
    Ok(collected.filter_map(Result::ok).collect())
}

/// Sweep every entry whose key starts with `prefix`, returning their paths.
///
/// Page keys are `{server}-{book}-p{number}`, so a book or server prune is a
/// prefix match. Wildcards in the prefix are escaped: an id containing `%` must
/// not evict somebody else's cache.
///
/// Entries whose file the user owns outright ([`protected_paths`]) are left in the
/// ledger and not returned, so the caller cannot delete them: pruning a book out
/// of the mirror must never take an offline copy with it.
pub fn delete_for_key_prefix(conn: &Connection, prefix: &str) -> rusqlite::Result<Vec<String>> {
    let escaped = escape_like(prefix);
    let protected = protected_paths(conn)?;
    let mut doomed: Vec<(String, String)> = Vec::new();
    {
        let mut statement = conn.prepare(
            "SELECT key, path FROM cache_entries WHERE key LIKE ?1 ESCAPE '\\' ORDER BY key ASC",
        )?;
        let rows = statement.query_map(params![format!("{escaped}%")], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (key, path) = row?;
            if !protected.contains(&path) {
                doomed.push((key, path));
            }
        }
    }
    let mut paths = Vec::with_capacity(doomed.len());
    for (key, path) in doomed {
        conn.execute("DELETE FROM cache_entries WHERE key = ?1", params![key])?;
        paths.push(path);
    }
    Ok(paths)
}

/// Drop every entry of one kind, returning their paths — except the ones the user
/// owns. A row recorded as `kind='download'` is protected by definition, and so is
/// any path the download tables name, whichever kind filed it.
pub fn delete_of_kind(conn: &Connection, kind: &str) -> rusqlite::Result<Vec<String>> {
    let protected = protected_paths(conn)?;
    let mut doomed: Vec<(String, String)> = Vec::new();
    {
        let mut statement =
            conn.prepare("SELECT key, path FROM cache_entries WHERE kind = ?1 ORDER BY key ASC")?;
        let rows = statement.query_map(params![kind], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        for row in rows {
            let (key, path) = row?;
            if !protected.contains(&path) {
                doomed.push((key, path));
            }
        }
    }
    let mut paths = Vec::with_capacity(doomed.len());
    for (key, path) in doomed {
        conn.execute("DELETE FROM cache_entries WHERE key = ?1", params![key])?;
        paths.push(path);
    }
    Ok(paths)
}

fn escape_like(prefix: &str) -> String {
    prefix
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

/// The keys under `prefix` that the ledger believes are cached — one query, no
/// filesystem walk.
///
/// Deliberately weaker than a hit test: a row whose file has since been deleted
/// is reported here. That is the right trade for the prefetch planner, which
/// asks this question for a whole 500-page book on every spread change and must
/// not stat 500 files to answer it. Anything stale is healed where it matters,
/// by [`crate::reader::cache::PageCache::lookup`], which validates before it
/// hands a path to the UI.
pub fn cached_keys(
    conn: &Connection,
    prefix: &str,
) -> rusqlite::Result<std::collections::HashSet<String>> {
    let escaped = prefix
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_");
    let mut rows = conn.prepare("SELECT key FROM cache_entries WHERE key LIKE ?1 ESCAPE '\\'")?;
    let collected = rows.query_map(params![format!("{escaped}%")], |row| {
        row.get::<_, String>(0)
    })?;
    Ok(collected.filter_map(Result::ok).collect())
}

/// Every path the user owns outright, whether or not the LRU ledger knows it.
///
/// Stage 8 needs this because the LRU's protection is a *convention* — write a
/// `kind='download'` row and you are safe — and conventions break the day the
/// offline-download feature (Phase 4, still a stub) writes page files without one.
/// `downloads.manifest_path` and `download_pages.file_path` are the schema truth
/// about what the user asked to keep, so cleanup asks them directly instead of
/// trusting that somebody remembered to also touch `cache_entries`.
pub fn protected_paths(conn: &Connection) -> rusqlite::Result<std::collections::HashSet<String>> {
    let mut kept = std::collections::HashSet::new();
    let mut statement = conn.prepare(
        "SELECT manifest_path FROM downloads WHERE manifest_path IS NOT NULL \
         UNION SELECT file_path FROM download_pages WHERE file_path IS NOT NULL \
         UNION SELECT path FROM cache_entries WHERE kind = ?1",
    )?;
    let rows = statement.query_map(params![KIND_DOWNLOAD], |row| row.get::<_, String>(0))?;
    for row in rows {
        let path = row?;
        if !path.is_empty() {
            kept.insert(path);
        }
    }
    Ok(kept)
}

/// Total bytes accounted. Rows whose file already vanished are excluded from
/// the total and pruned, so the LRU decision sees the real disk state.
pub fn total_bytes(conn: &Connection) -> rusqlite::Result<i64> {
    let stale: Vec<String> = conn
        .prepare("SELECT key, path FROM cache_entries")?
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .filter_map(Result::ok)
        .filter(|(_, path)| !std::path::Path::new(path).exists())
        .map(|(key, _)| key)
        .collect();
    remove_many(conn, &stale)?;
    let total: i64 = conn.query_row(
        "SELECT COALESCE(SUM(size), 0) FROM cache_entries",
        [],
        |row| row.get(0),
    )?;
    Ok(total)
}

pub fn bytes_of_kind(conn: &Connection, kind: &str) -> rusqlite::Result<i64> {
    conn.query_row(
        "SELECT COALESCE(SUM(size), 0) FROM cache_entries WHERE kind = ?1",
        params![kind],
        |row| row.get(0),
    )
}

/// Evictable entries, worst-value-first.
///
/// Kind outranks age: a prefetched page the reader never looked at is worth
/// less than a page it did, even if the reader saw that page an hour ago and the
/// prefetch landed a second ago. Age then breaks ties inside a kind, and `key`
/// breaks ties inside a timestamp, so two runs with the same contents evict the
/// same entries.
fn evictable_order(conn: &Connection) -> rusqlite::Result<Vec<(String, String, i64)>> {
    let mut rows = conn.prepare(
        "SELECT key, path, size FROM cache_entries
         WHERE kind <> ?1
         ORDER BY CASE kind WHEN ?2 THEN 0 ELSE 1 END ASC, last_access ASC, key ASC",
    )?;
    let collected = rows.query_map(params![KIND_DOWNLOAD, KIND_PREFETCH], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
        ))
    })?;
    Ok(collected.filter_map(Result::ok).collect())
}

/// Trim the cache to `budget` bytes, worst-value first.
///
/// Offline downloads are never victims (docs/offline-storage.md): the ledger is
/// trimmed by kind, not just by age. Returns the paths whose rows were dropped.
pub fn evict_to_budget(conn: &Connection, budget: i64) -> rusqlite::Result<Vec<String>> {
    evict_to_budget_except(conn, budget, None)
}

/// `evict_to_budget` with one entry held back.
///
/// The entry that was just written has to survive the trim that writing it
/// triggered, and age alone does not guarantee that: `last_access` has
/// millisecond resolution, so a prefetch and a display landing in the same
/// millisecond tie, and the tie is broken by key. Without this, a pool that fits
/// one and a half pages evicts the page it just cached and the reader
/// re-downloads it — a 2x request count for a book of 4K pages, measured rather
/// than imagined.
pub fn evict_to_budget_except(
    conn: &Connection,
    budget: i64,
    except_key: Option<&str>,
) -> rusqlite::Result<Vec<String>> {
    let mut removed = Vec::new();
    let mut used = total_bytes(conn)?;
    if used <= budget {
        return Ok(removed);
    }
    for (key, path, size) in evictable_order(conn)? {
        if used <= budget {
            break;
        }
        if except_key == Some(key.as_str()) {
            continue;
        }
        remove(conn, &key)?;
        removed.push(path);
        used -= size;
    }
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    /// The shape Phase 4 will write: files the user asked to keep, recorded only
    /// in the download tables. Cleanup must protect them without being told twice.
    #[test]
    fn a_download_recorded_only_in_the_download_tables_is_still_protected() {
        let conn = open_in_memory().unwrap();
        let manifest = std::env::temp_dir().join(format!("dl-manifest-{}", uuid::Uuid::new_v4()));
        let page = std::env::temp_dir().join(format!("dl-page-{}", uuid::Uuid::new_v4()));
        std::fs::write(&manifest, b"{\"pages\":3}").unwrap();
        std::fs::write(&page, b"page-bytes").unwrap();
        conn.execute(
            "INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done, state)
             VALUES ('A', 'book', ?1, 1, 1, 'complete')",
            params![manifest.to_string_lossy()],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO download_pages (server_id, book_id, page_number, file_path, state)
             VALUES ('A', 'book', 1, ?1, 'complete')",
            params![page.to_string_lossy()],
        )
        .unwrap();

        let protected = protected_paths(&conn).unwrap();
        assert!(protected.contains(&manifest.to_string_lossy().into_owned()));
        assert!(protected.contains(&page.to_string_lossy().into_owned()));
        // Nothing in the LRU ledger, and it still knows.
        assert_eq!(get(&conn, "whatever").unwrap(), None);
        for path in [manifest, page] {
            std::fs::remove_file(path).ok();
        }
    }

    #[test]
    fn protected_paths_includes_an_ledger_download_row_and_skips_empty_paths() {
        let conn = open_in_memory().unwrap();
        let file = temp_path();
        tracked(&file, b"x");
        record(&conn, "dl", KIND_DOWNLOAD, file.to_str().unwrap(), 1, "now").unwrap();
        conn.execute(
            "INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done, state)
             VALUES ('A', 'b', '', 1, 1, 'downloading')",
            [],
        )
        .unwrap();
        let protected = protected_paths(&conn).unwrap();
        assert!(protected.contains(&file.to_string_lossy().into_owned()));
        assert!(
            !protected.contains(""),
            "an empty path would protect the world"
        );
        std::fs::remove_file(file).ok();
    }
    use std::path::PathBuf;
    use uuid::Uuid;

    /// `total_bytes` counts what is really on disk, so the tests write real
    /// temp files rather than trusting the ledger.
    fn tracked(path: &PathBuf, bytes: &[u8]) {
        std::fs::write(path, bytes).unwrap();
    }

    fn temp_path() -> PathBuf {
        std::env::temp_dir().join(format!("komga_cache_entry_{}", Uuid::new_v4()))
    }

    #[test]
    fn record_get_touch_remove() {
        let conn = open_in_memory().unwrap();
        let path = temp_path();
        tracked(&path, b"0123456789");
        record(
            &conn,
            "k1",
            KIND_PAGE,
            path.to_str().unwrap(),
            10,
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        let entry = get(&conn, "k1").unwrap().unwrap();
        assert_eq!(entry.size, 10);
        assert_eq!(entry.kind, KIND_PAGE);
        assert_eq!(total_bytes(&conn).unwrap(), 10);

        touch(&conn, "k1", "2026-02-01T00:00:00.000Z").unwrap();
        assert_eq!(
            get(&conn, "k1").unwrap().unwrap().last_access,
            "2026-02-01T00:00:00.000Z"
        );

        // Re-recording the same key replaces rather than duplicates.
        record(
            &conn,
            "k1",
            KIND_PAGE,
            path.to_str().unwrap(),
            4,
            "2026-03-01T00:00:00.000Z",
        )
        .unwrap();
        assert_eq!(total_bytes(&conn).unwrap(), 4);

        assert_eq!(
            remove(&conn, "k1").unwrap().as_deref(),
            Some(path.to_str().unwrap())
        );
        assert_eq!(get(&conn, "k1").unwrap(), None);
        assert_eq!(
            remove(&conn, "k1").unwrap(),
            None,
            "removing twice is not an error"
        );
        std::fs::remove_file(path).ok();
    }

    #[test]
    fn a_row_whose_file_is_gone_is_a_miss_and_gets_pruned() {
        let conn = open_in_memory().unwrap();
        let path = temp_path();
        record(
            &conn,
            "ghost",
            KIND_PAGE,
            path.to_str().unwrap(),
            999,
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        assert!(get(&conn, "ghost").unwrap().is_some());
        assert_eq!(
            total_bytes(&conn).unwrap(),
            0,
            "phantom bytes must not steer eviction"
        );
        assert_eq!(get(&conn, "ghost").unwrap(), None, "total_bytes pruned it");
    }

    #[test]
    fn eviction_goes_prefetch_then_pages_oldest_first() {
        let conn = open_in_memory().unwrap();
        let mut paths = Vec::new();
        for (index, kind) in [KIND_PAGE, KIND_PREFETCH, KIND_PAGE, KIND_DOWNLOAD]
            .iter()
            .enumerate()
        {
            let path = temp_path();
            tracked(&path, &[0u8; 100]);
            record(
                &conn,
                &format!("k{index}"),
                kind,
                path.to_str().unwrap(),
                100,
                &format!("2026-01-0{index}T00:00:00.000Z"),
            )
            .unwrap();
            paths.push(path);
        }
        assert_eq!(total_bytes(&conn).unwrap(), 400);
        assert_eq!(bytes_of_kind(&conn, KIND_DOWNLOAD).unwrap(), 100);

        let removed = evict_to_budget(&conn, 250).unwrap();
        assert_eq!(
            removed.len(),
            2,
            "400 -> 250 needs the prefetch row and then the oldest page"
        );
        assert_eq!(
            removed[0],
            paths[1].to_str().unwrap(),
            "the prefetch entry goes first even though k0 is older"
        );
        assert_eq!(removed[1], paths[0].to_str().unwrap());
        // k1/k0 gone, k2 evictable but no longer needed, k3 never eligible.
        assert!(get(&conn, "k3").unwrap().is_some());
        assert_eq!(total_bytes(&conn).unwrap(), 200);

        // Even an impossible budget cannot evict the download.
        let removed = evict_to_budget(&conn, 0).unwrap();
        assert_eq!(removed.len(), 1, "only the remaining page row is eligible");
        assert!(get(&conn, "k3").unwrap().is_some());
        assert_eq!(bytes_of_kind(&conn, KIND_DOWNLOAD).unwrap(), 100);
        for path in paths {
            std::fs::remove_file(path).ok();
        }
    }

    /// The promotion rule, stated the other way: an entry stops being the first
    /// victim as soon as the reader looks at it, and a much older displayed page
    /// is then the one that goes.
    #[test]
    fn promoting_a_prefetch_entry_puts_it_behind_older_pages() {
        let conn = open_in_memory().unwrap();
        let old_page = temp_path();
        let seen_page = temp_path();
        tracked(&old_page, &[0u8; 100]);
        tracked(&seen_page, &[0u8; 100]);
        record(
            &conn,
            "old",
            KIND_PAGE,
            old_page.to_str().unwrap(),
            100,
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        record(
            &conn,
            "warm",
            KIND_PREFETCH,
            seen_page.to_str().unwrap(),
            100,
            "2026-02-01T00:00:00.000Z",
        )
        .unwrap();

        // While it is prefetch bytes, it is the victim despite being newer.
        let removed = evict_to_budget(&conn, 100).unwrap();
        assert_eq!(removed, vec![seen_page.to_str().unwrap().to_string()]);
        assert!(get(&conn, "old").unwrap().is_some());

        // A second entry, promoted, flips the decision.
        let third = temp_path();
        tracked(&third, &[0u8; 100]);
        record(
            &conn,
            "third",
            KIND_PREFETCH,
            third.to_str().unwrap(),
            100,
            "2026-03-01T00:00:00.000Z",
        )
        .unwrap();
        relocate(
            &conn,
            "third",
            third.to_str().unwrap(),
            KIND_PAGE,
            "2026-03-01T00:00:00.000Z",
        )
        .unwrap();
        assert_eq!(
            get(&conn, "third").unwrap().unwrap().kind,
            KIND_PAGE,
            "promotion must be visible in the ledger"
        );
        let removed = evict_to_budget(&conn, 100).unwrap();
        assert_eq!(
            removed,
            vec![old_page.to_str().unwrap().to_string()],
            "no prefetch rows remain, so the oldest page is the victim again"
        );
        assert!(matches!(
            relocate(&conn, "ghost", "/tmp/x", KIND_PAGE, "now"),
            Err(rusqlite::Error::QueryReturnedNoRows)
        ));
        for path in [old_page, seen_page, third] {
            std::fs::remove_file(path).ok();
        }
    }

    #[test]
    fn fast_and_reconciling_totals_agree_and_disagree_honestly() {
        let conn = open_in_memory().unwrap();
        let path = temp_path();
        tracked(&path, &[0u8; 40]);
        record(
            &conn,
            "real",
            KIND_PAGE,
            path.to_str().unwrap(),
            40,
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        // A phantom row: the ledger believes 90 bytes that are not on disk.
        record(
            &conn,
            "phantom",
            KIND_PAGE,
            temp_path().to_str().unwrap(),
            50,
            "2026-01-01T00:00:00.000Z",
        )
        .unwrap();
        assert_eq!(
            total_bytes_fast(&conn).unwrap(),
            90,
            "the cheap path reports what the ledger says"
        );
        assert_eq!(
            total_bytes(&conn).unwrap(),
            40,
            "the walking path proves it"
        );
        assert_eq!(get(&conn, "phantom").unwrap(), None, "and prunes the lie");
        std::fs::remove_file(path).ok();
    }

    /// The rule that keeps a half-full pool from thrashing: the entry that
    /// triggered the trim is the one entry the trim may not take.
    #[test]
    fn the_entry_just_written_survives_the_trim_it_triggered() {
        let conn = open_in_memory().unwrap();
        let older = temp_path();
        let fresh = temp_path();
        tracked(&older, &[0u8; 100]);
        tracked(&fresh, &[0u8; 100]);
        // Same millisecond, and the fresh key sorts first: age and tie-break
        // would both pick it as the victim.
        for (key, path) in [("p2", &fresh), ("p9", &older)] {
            record(
                &conn,
                key,
                KIND_PAGE,
                path.to_str().unwrap(),
                100,
                "2026-01-01T00:00:00.000Z",
            )
            .unwrap();
        }
        let removed = evict_to_budget_except(&conn, 100, Some("p2")).unwrap();
        assert_eq!(
            removed,
            vec![older.to_str().unwrap().to_string()],
            "p2 was held back, so the other page went"
        );
        assert!(get(&conn, "p2").unwrap().is_some());
        assert!(fresh.exists());
        // Without the protection the tie-break by key takes the fresh one.
        let removed = evict_to_budget_except(&conn, 0, None).unwrap();
        assert_eq!(removed, vec![fresh.to_str().unwrap().to_string()]);
        std::fs::remove_file(older).ok();
        std::fs::remove_file(fresh).ok();
    }

    #[test]
    fn eviction_ties_are_deterministic() {
        let conn = open_in_memory().unwrap();
        let now = "2026-01-01T00:00:00.000Z";
        for key in ["b", "a", "c"] {
            let path = temp_path();
            tracked(&path, &[0u8; 50]);
            record(&conn, key, KIND_PAGE, path.to_str().unwrap(), 50, now).unwrap();
        }
        let removed = evict_to_budget(&conn, 50).unwrap();
        assert_eq!(removed.len(), 2);
        let mut keys: Vec<String> = ["a", "b", "c"]
            .iter()
            .filter(|key| get(&conn, key).unwrap().is_some())
            .map(|key| (*key).to_string())
            .collect();
        keys.sort();
        assert_eq!(
            keys,
            vec!["c".to_string()],
            "same timestamp -> key order wins"
        );
    }
}
