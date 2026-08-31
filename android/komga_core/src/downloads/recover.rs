//! The download tree's own reconciliation, and the reader's view of it.
//!
//! Where the cache's sweep (`reader::cache::PageCache::reconcile`) may delete
//! anything it cannot account for, this one may not: these files belong to the user
//! and were chosen deliberately, so the job here is to make the bookkeeping match the
//! disk, not to win space back. Two directions follow from that and are worth reading
//! twice:
//!
//!   * a usable file with no row is **adopted**. "Row commit lost, file landed" is a
//!     real event under write contention, and the alternative is deleting a page the
//!     user may have paid for on a metered link.
//!   * a book directory with no `downloads` row is **counted and left alone**. It
//!     stays deletable, because its path is derived from `(serverId, bookId)` and an
//!     explicit user action can still name it — see
//!     [`crate::downloads::manifest::DownloadRoot::remove_server_tree`].
//!
//! `freed_bytes` follows the cache sweep's accounting idiom for the same reason it
//! uses it: a ghost row's bytes were already gone, so counting them as freed would
//! double-count the disk.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use rusqlite::Connection;

use crate::cache::PART_SUFFIX;
use crate::reader::integrity;
use crate::store;

use super::manifest::{self, DownloadManifest, DownloadRoot, ManifestPage, MANIFEST_FILE};
use super::queue::{page_state, SettleMode};
use super::store::{self as downloads, QueueError};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SweepReport {
    /// Books whose rows were walked.
    pub books: usize,
    pub stale_parts: usize,
    /// `complete` rows whose file is gone.
    pub ghost_rows: usize,
    /// Files that failed the container walk, deleted.
    pub corrupt: usize,
    /// Files whose size no longer matches their row, deleted.
    pub size_mismatch: usize,
    /// Files adopted because they are usable and the database forgot them.
    pub adopted_files: usize,
    /// Books whose derived counters had to be recomputed.
    pub counters_repaired: usize,
    /// Manifests rewritten because they were missing, unparsable or disagreed.
    pub manifests_rewritten: usize,
    /// Page rows past the book's own page count, deleted with their files.
    pub pages_removed: usize,
    /// Directories with no `downloads` row. Counted, never touched.
    pub unowned_books: usize,
    pub unowned_bytes: i64,
    /// Bytes this sweep actually removed.
    pub freed_bytes: i64,
}

impl SweepReport {
    /// How much the sweep had to repair. Zero means the database and the disk already
    /// agreed — the ordinary case, and the one that must stay cheap.
    pub fn repairs(&self) -> usize {
        self.stale_parts
            + self.ghost_rows
            + self.corrupt
            + self.size_mismatch
            + self.adopted_files
            + self.counters_repaired
            + self.manifests_rewritten
            + self.pages_removed
    }
}

fn remove_file(path: &Path, report: &mut SweepReport) {
    if let Ok(meta) = std::fs::metadata(path) {
        report.freed_bytes += meta.len() as i64;
    }
    std::fs::remove_file(path).ok();
}

/// The reader's highest-priority tier: is this page's downloaded copy usable?
///
/// Row says `complete`, the file is there, and the container's head and trailer agree
/// with the size the row recorded — the same three-part hit contract the page cache
/// uses. Any disagreement is healed in the direction the disk proves: the row goes
/// back to `pending`, the bad file goes with it, the reader falls through to the cache
/// and network, and the next pass puts it right.
///
/// OWNERSHIP: apart from [`crate::downloads::store::delete_rows`] on a user delete,
/// this is the only place a download file is removed by something other than the user,
/// and it removes only a file it has just proved is not the page it claims to be.
pub fn usable_page(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    number: u32,
    now: &str,
) -> Result<Option<PathBuf>, QueueError> {
    let Some(row) = downloads::page(conn, server_id, book_id, number)? else {
        return Ok(None);
    };
    if row.state != page_state::COMPLETE {
        return Ok(None);
    }
    let Some(path) = row.file_path.as_deref().map(PathBuf::from) else {
        downloads::heal_page(conn, server_id, book_id, number, now)?;
        return Ok(None);
    };
    if !path.is_file() {
        downloads::heal_page(conn, server_id, book_id, number, now)?;
        return Ok(None);
    }
    let declared = (row.size_bytes > 0).then_some(row.size_bytes);
    if integrity::quick_check_file(&path, declared).is_usable() {
        return Ok(Some(path));
    }
    downloads::heal_page(conn, server_id, book_id, number, now)?;
    std::fs::remove_file(&path).ok();
    Ok(None)
}

/// Rebuild one book's `manifest.json` from its rows, joined to the mirror for the
/// dimensions the server once told us.
pub fn rebuild_manifest(
    conn: &Connection,
    root: &DownloadRoot,
    server_id: &str,
    book_id: &str,
    now: &str,
) -> Result<(), QueueError> {
    let Some(row) = downloads::get(conn, server_id, book_id)? else {
        return Ok(());
    };
    let mut stmt = conn.prepare(
        "SELECT p.page_number, p.file_path, p.media_type, p.size_bytes,
                COALESCE(bp.width, 0), COALESCE(bp.height, 0)
         FROM download_pages p
         LEFT JOIN book_pages bp
                ON bp.server_id = p.server_id AND bp.book_id = p.book_id
               AND bp.number = p.page_number
         WHERE p.server_id = ?1 AND p.book_id = ?2 AND p.state = ?3
         ORDER BY p.page_number",
    )?;
    let pages = stmt
        .query_map(
            rusqlite::params![server_id, book_id, page_state::COMPLETE],
            |row| {
                let path = row.get::<_, Option<String>>(1)?.unwrap_or_default();
                Ok(ManifestPage {
                    number: row.get::<_, i64>(0)? as u32,
                    file_name: Path::new(&path)
                        .file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or_default()
                        .to_string(),
                    media_type: row.get::<_, String>(2)?,
                    size_bytes: row.get(3)?,
                    width: row.get::<_, i64>(4)?.max(0) as u32,
                    height: row.get::<_, i64>(5)?.max(0) as u32,
                })
            },
        )?
        .collect::<Result<Vec<_>, _>>()?;
    let document = DownloadManifest {
        server_id: server_id.to_string(),
        book_id: book_id.to_string(),
        pages_count: row.pages_total.max(0) as u32,
        // Creation time is a fact about the job, not about this write: a 292-page
        // download has exactly one, and 292 different ones would make the field
        // useless for the freshness comparison.
        downloaded_at: if row.created_at.is_empty() {
            now.to_string()
        } else {
            row.created_at.clone()
        },
        remote_last_modified: row.remote_last_modified.clone(),
        pages,
    };
    manifest::write_manifest(&root.manifest_path(server_id, book_id), &document)?;
    Ok(())
}

/// Does this book's manifest already say what the rows say?
fn manifest_is_current(
    conn: &Connection,
    root: &DownloadRoot,
    server_id: &str,
    book_id: &str,
    pages_total: i64,
) -> Result<bool, QueueError> {
    let path = root.manifest_path(server_id, book_id);
    let Some(found) = manifest::read_manifest(&path)? else {
        return Ok(false);
    };
    if i64::from(found.pages_count) != pages_total.max(0) {
        return Ok(false);
    }
    let complete = downloads::complete_pages(conn, server_id, book_id)?;
    if found.pages.len() != complete.len() {
        return Ok(false);
    }
    Ok(found
        .pages
        .iter()
        .zip(complete.iter())
        .all(|(page, number)| page.number == *number))
}

/// Walk every download the database knows about and make the bookkeeping match the
/// disk.
pub fn sweep(conn: &Connection, root: &DownloadRoot, now: &str) -> Result<SweepReport, QueueError> {
    let mut report = SweepReport::default();
    let mut owned: Vec<PathBuf> = Vec::new();

    for book in downloads::list(conn, None)? {
        let dir = root.book_dir(&book.server_id, &book.book_id);
        owned.push(dir.clone());
        let rows = downloads::pages(conn, &book.server_id, &book.book_id)?;
        let past_end = book.pages_total.max(0) as u32;

        // Rows first: only a row can say what a file was supposed to be.
        for row in &rows {
            if past_end > 0 && row.number > past_end {
                // Not part of this book any more: the mirror said how many pages it
                // has, so this one is from an earlier, longer version of it.
                if let Some(path) = row.file_path.as_deref() {
                    remove_file(Path::new(path), &mut report);
                }
                downloads::delete_page(conn, &book.server_id, &book.book_id, row.number)?;
                report.pages_removed += 1;
                continue;
            }
            let Some(path) = row.file_path.as_deref().map(PathBuf::from) else {
                if row.state == page_state::COMPLETE {
                    downloads::heal_page(conn, &book.server_id, &book.book_id, row.number, now)?;
                    report.ghost_rows += 1;
                }
                continue;
            };
            let exists = path.is_file();
            if row.state != page_state::COMPLETE {
                // A pending or failed row should hold no file. One that does is
                // debris from an interrupted attempt, and the directory walk below
                // would otherwise adopt it back.
                if exists {
                    remove_file(&path, &mut report);
                    report.corrupt += 1;
                }
                continue;
            }
            let Ok(meta) = std::fs::metadata(&path) else {
                downloads::heal_page(conn, &book.server_id, &book.book_id, row.number, now)?;
                report.ghost_rows += 1;
                continue;
            };
            let size = meta.len() as i64;
            if row.size_bytes > 0 && size != row.size_bytes {
                downloads::heal_page(conn, &book.server_id, &book.book_id, row.number, now)?;
                remove_file(&path, &mut report);
                report.size_mismatch += 1;
                continue;
            }
            if !integrity::quick_check_file(&path, (size > 0).then_some(size)).is_usable() {
                downloads::heal_page(conn, &book.server_id, &book.book_id, row.number, now)?;
                remove_file(&path, &mut report);
                report.corrupt += 1;
            }
        }

        // Then the directory, for what no row mentions.
        let walkable = dir.is_dir();
        for name in root.files_in(&book.server_id, &book.book_id) {
            if !walkable {
                break;
            }
            let path = dir.join(&name);
            if name == MANIFEST_FILE {
                continue;
            }
            if name.ends_with(PART_SUFFIX) {
                remove_file(&path, &mut report);
                report.stale_parts += 1;
                continue;
            }
            let Some(number) = manifest::page_number_of(&name) else {
                continue;
            };
            if row_matches(&rows, number, &path) {
                continue; // already judged above
            }
            if past_end > 0 && number > past_end {
                remove_file(&path, &mut report);
                report.pages_removed += 1;
                continue;
            }
            let size = std::fs::metadata(&path)
                .map(|meta| meta.len() as i64)
                .unwrap_or(0);
            if !integrity::quick_check_file(&path, (size > 0).then_some(size)).is_usable() {
                remove_file(&path, &mut report);
                report.corrupt += 1;
                continue;
            }
            downloads::adopt_page(
                conn,
                &book.server_id,
                &book.book_id,
                number,
                &path.to_string_lossy(),
                size,
                &sniffed_media_type(&path),
                now,
            )?;
            report.adopted_files += 1;
        }

        let (done, bytes) =
            downloads::recompute_counters(conn, &book.server_id, &book.book_id, now)?;
        if done != book.pages_done || bytes != book.bytes_done {
            report.counters_repaired += 1;
        }
        downloads::settle_book(conn, &book.server_id, &book.book_id, now, SettleMode::Sweep)?;
        if !manifest_is_current(conn, root, &book.server_id, &book.book_id, book.pages_total)? {
            rebuild_manifest(conn, root, &book.server_id, &book.book_id, now)?;
            report.manifests_rewritten += 1;
        }
        report.books += 1;
    }

    for (_server_name, _book_name, path) in root.book_dirs() {
        if owned.contains(&path) {
            continue;
        }
        let files = listing(&path);
        if files.is_empty() {
            std::fs::remove_dir(&path).ok();
            continue;
        }
        report.unowned_books += 1;
        report.unowned_bytes += files
            .iter()
            .filter_map(|name| std::fs::metadata(path.join(name)).ok())
            .map(|meta| meta.len() as i64)
            .sum::<i64>();
    }
    Ok(report)
}

/// Was this file already judged as some row's page?
fn row_matches(rows: &[downloads::DownloadPageRow], number: u32, path: &Path) -> bool {
    rows.iter().any(|row| {
        row.number == number
            && row
                .file_path
                .as_deref()
                .map(|existing| Path::new(existing) == path)
                == Some(true)
    })
}

/// The container a file actually is, from its leading bytes.
fn sniffed_media_type(path: &Path) -> String {
    let Ok(mut handle) = std::fs::File::open(path) else {
        return String::new();
    };
    let mut head = [0u8; 16];
    let read = std::io::Read::read(&mut handle, &mut head).unwrap_or(0);
    integrity::Format::from_magic(&head[..read])
        .content_type()
        .to_string()
}

fn listing(dir: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect()
}

/// Run [`sweep`] once per database per process.
///
/// Once is enough: this walks every downloaded file, which is the same cost the
/// reader's cache sweep pays at open time. The first pump or `download_list` of a
/// session pays it, and a process that was killed and restarted pays it again — which
/// is exactly when the tree needs reconciling, and the reason the kill-and-resume
/// acceptance has to be two processes rather than one.
pub fn sweep_once(
    db_path: &Path,
    root: &DownloadRoot,
    now: &str,
) -> Result<Option<SweepReport>, QueueError> {
    let key = db_path.to_string_lossy().into_owned();
    // A poisoned lock means another pass died while holding it. Skipping the sweep
    // is right twice over: the sweep is not the victim of that death, and re-walking
    // every downloaded file on a phone is the cost this guard exists to avoid.
    let Ok(mut guard) = swept().lock() else {
        return Ok(None);
    };
    let already = guard.contains(&key);
    if !already {
        guard.push(key);
    }
    drop(guard);
    if already {
        return Ok(None);
    }
    let conn = store::open(db_path)?;
    Ok(Some(sweep(&conn, root, now)?))
}

fn swept() -> &'static Mutex<Vec<String>> {
    static SWEPT: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
    SWEPT.get_or_init(|| Mutex::new(Vec::new()))
}

/// Forget which databases have been swept. Without this, a second sweep in the same
/// process is unobservable — and "the sweep ran twice" is the only way to tell a
/// sweep that is idempotent from one that merely looks quiet the second time.
pub fn forget_swept() {
    if let Ok(mut guard) = swept().lock() {
        guard.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::super::harness::{enqueue_book, stamp, Tree};
    use super::*;
    use crate::cache::demo_png;
    use crate::downloads::queue::page_state;
    use crate::downloads::store as downloads;

    /// A real PNG on disk at the page's contract name, and the row that claims it.
    fn plant(tree: &Tree, book: &str, number: u32) -> PathBuf {
        let path = tree.root.page_path("s1", book, number, "png");
        std::fs::write(&path, demo_png::demo_page_bytes(number)).unwrap();
        let size = std::fs::metadata(&path).unwrap().len() as i64;
        downloads::mark_page_complete(
            &tree.conn,
            "s1",
            book,
            number,
            &path.to_string_lossy(),
            size,
            "image/png",
            &stamp(0),
        )
        .unwrap();
        path
    }

    #[test]
    fn a_file_the_database_forgot_is_adopted_not_deleted() {
        let tree = Tree::new("adopt");
        enqueue_book(&tree, "s1", "b1", 3);
        // Bytes landed, the row commit did not. This is the direction that looks
        // backwards and is the one that saves a metered download.
        let path = tree.root.page_path("s1", "b1", 2, "png");
        std::fs::write(&path, demo_png::demo_page_bytes(2)).unwrap();
        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(report.adopted_files, 1, "the file should have been adopted");
        assert!(path.is_file(), "adopting must not delete");
        assert_eq!(
            downloads::complete_pages(&tree.conn, "s1", "b1").unwrap(),
            vec![2]
        );
        let row = downloads::page(&tree.conn, "s1", "b1", 2).unwrap().unwrap();
        assert_eq!(
            row.size_bytes,
            std::fs::metadata(&path).unwrap().len() as i64
        );
        assert_eq!(
            row.media_type, "image/png",
            "the container is sniffed, and named the way the server names it"
        );
    }

    #[test]
    fn a_ghost_row_is_healed_and_its_absent_bytes_are_not_reported_freed() {
        let tree = Tree::new("ghost");
        enqueue_book(&tree, "s1", "b1", 3);
        let path = plant(&tree, "b1", 1);
        std::fs::remove_file(&path).unwrap();
        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(report.ghost_rows, 1);
        // The accounting idiom the cache sweep uses for the same reason: these bytes
        // were already gone, so counting them as freed would double-count the disk.
        assert_eq!(report.freed_bytes, 0, "a ghost row freed nothing");
        assert_eq!(
            downloads::page(&tree.conn, "s1", "b1", 1)
                .unwrap()
                .unwrap()
                .state,
            page_state::PENDING
        );
        assert_eq!(downloads::bytes_done_all(&tree.conn).unwrap(), 0);
    }

    #[test]
    fn a_corrupt_file_is_removed_and_its_row_goes_back_to_pending() {
        let tree = Tree::new("corrupt");
        enqueue_book(&tree, "s1", "b1", 2);
        let path = tree.root.page_path("s1", "b1", 1, "png");
        let garbage = b"not an image at all, but the row says complete".to_vec();
        let len = garbage.len() as i64;
        std::fs::write(&path, &garbage).unwrap();
        downloads::mark_page_complete(
            &tree.conn,
            "s1",
            "b1",
            1,
            &path.to_string_lossy(),
            len,
            "image/png",
            &stamp(0),
        )
        .unwrap();
        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(report.corrupt, 1);
        assert_eq!(report.freed_bytes, len, "these bytes really were on disk");
        assert!(!path.exists());
        assert_eq!(
            downloads::page(&tree.conn, "s1", "b1", 1)
                .unwrap()
                .unwrap()
                .state,
            page_state::PENDING
        );
    }

    /// The size check and the container check are different witnesses, and this is
    /// the case that tells them apart: a valid PNG of the wrong length walks
    /// perfectly and must still be refused.
    #[test]
    fn a_size_drift_is_caught_even_though_the_file_still_walks() {
        let tree = Tree::new("drift");
        enqueue_book(&tree, "s1", "b1", 3);
        let claimed = demo_png::demo_page_bytes(1).len() as i64;
        let path = tree.root.page_path("s1", "b1", 1, "png");
        std::fs::write(&path, demo_png::demo_page_bytes(2)).unwrap();
        downloads::mark_page_complete(
            &tree.conn,
            "s1",
            "b1",
            1,
            &path.to_string_lossy(),
            claimed,
            "image/png",
            &stamp(0),
        )
        .unwrap();
        assert!(
            integrity::quick_check_file(&path, None).is_usable(),
            "the file is a well-formed image"
        );
        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(
            report.size_mismatch, 1,
            "only the recorded size says it is wrong"
        );
        assert!(!path.exists());
        assert_eq!(
            report.corrupt, 0,
            "this is the size arm, not the integrity arm"
        );
    }

    #[test]
    fn a_directory_the_database_forgot_is_counted_and_kept() {
        let tree = Tree::new("unowned");
        enqueue_book(&tree, "s1", "b1", 1);
        plant(&tree, "b1", 1);
        let ghost = tree.root.book_dir("s1", "deleted-long-ago");
        std::fs::create_dir_all(&ghost).unwrap();
        let leftover = ghost.join("0001.png");
        std::fs::write(&leftover, demo_png::demo_page_bytes(1)).unwrap();
        let kept = std::fs::metadata(&leftover).unwrap().len() as i64;

        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(report.unowned_books, 1);
        assert_eq!(report.unowned_bytes, kept);
        assert!(
            leftover.exists(),
            "the sweep may not guess at a user's data"
        );
        // And it is still deletable by the only thing allowed to delete it.
        tree.root.remove_server_tree("s1").unwrap();
        assert!(!ghost.exists());
    }

    #[test]
    fn the_sweep_is_idempotent_and_says_so_the_second_time() {
        let tree = Tree::new("idempotent");
        enqueue_book(&tree, "s1", "b1", 3);
        let good = tree.root.page_path("s1", "b1", 2, "png");
        std::fs::write(&good, demo_png::demo_page_bytes(2)).unwrap();
        std::fs::write(
            tree.root
                .page_path("s1", "b1", 3, "png")
                .with_extension("png.part"),
            b"debris",
        )
        .unwrap();
        std::fs::write(tree.root.page_path("s1", "b1", 1, "png"), b"broken").unwrap();
        downloads::mark_page_complete(
            &tree.conn,
            "s1",
            "b1",
            1,
            &tree.root.page_path("s1", "b1", 1, "png").to_string_lossy(),
            6,
            "image/png",
            &stamp(0),
        )
        .unwrap();

        let first = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert!(
            first.repairs() >= 3,
            "the setup stopped being interesting: {first:?}"
        );
        let after_first = tree.page_files("s1", "b1");
        let second = sweep(&tree.conn, &tree.root, &stamp(2)).unwrap();
        assert_eq!(second.repairs(), 0, "a second sweep found work: {second:?}");
        assert_eq!(tree.page_files("s1", "b1"), after_first);
        assert_eq!(second.adopted_files, 0);
    }

    #[test]
    fn stale_staging_files_are_reaped() {
        let tree = Tree::new("parts");
        enqueue_book(&tree, "s1", "b1", 2);
        plant(&tree, "b1", 1);
        let part = DownloadRoot::staging_path(&tree.root.page_path("s1", "b1", 2, "png"));
        std::fs::write(&part, b"half a page").unwrap();
        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(report.stale_parts, 1);
        assert!(!part.exists());
        assert_eq!(report.ghost_rows, 0, "debris is not a missing page");
    }

    #[test]
    fn a_page_past_the_books_end_is_removed_with_its_row() {
        let tree = Tree::new("past_end");
        enqueue_book(&tree, "s1", "b1", 2);
        // The server shrunk the book after the download: page 3 is no longer part of
        // it, and the mirror's own count is the only thing that can say so.
        let path = plant(&tree, "b1", 3);
        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(report.pages_removed, 1);
        assert!(!path.exists());
        assert!(downloads::page(&tree.conn, "s1", "b1", 3)
            .unwrap()
            .is_none());
    }

    #[test]
    fn the_manifest_matches_the_tree_after_a_sweep() {
        let tree = Tree::new("manifest");
        enqueue_book(&tree, "s1", "b1", 3);
        for number in 1..=3 {
            plant(&tree, "b1", number);
        }
        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(
            report.manifests_rewritten, 1,
            "the manifest disagreed with the rows"
        );
        let document = manifest::read_manifest(&tree.root.manifest_path("s1", "b1"))
            .unwrap()
            .expect("a sweep leaves a manifest");
        assert_eq!(document.server_id, "s1");
        assert_eq!(document.book_id, "b1");
        assert_eq!(document.pages_count, 3);
        assert_eq!(document.pages.len(), 3);
        assert_eq!(
            document.remote_last_modified.as_deref(),
            Some("2024-05-11T18:07:33Z")
        );
        for page in &document.pages {
            let path = tree.root.book_dir("s1", "b1").join(&page.file_name);
            assert!(
                path.is_file(),
                "{} is in the manifest but not on disk",
                page.file_name
            );
            assert_eq!(
                page.size_bytes,
                std::fs::metadata(&path).unwrap().len() as i64,
                "the manifest records the measured size, not a claim"
            );
            let (width, height) = demo_png::page_dimensions(page.number);
            assert_eq!(
                (page.width, page.height),
                (width, height),
                "dimensions come from the mirrored manifest, which is the only place \
                 the server ever stated them"
            );
        }
        // A second sweep must not rewrite what already agrees.
        let again = sweep(&tree.conn, &tree.root, &stamp(2)).unwrap();
        assert_eq!(again.manifests_rewritten, 0);
    }

    /// A file under its final name that walks as a complete image cannot be a torn
    /// write — a torn write is still called `.part` — so it is adopted. This is the
    /// same rule as a missing row, arriving through the other door: an interrupted
    /// attempt that had already renamed, with the commit lost underneath it.
    #[test]
    fn a_whole_file_under_a_pending_row_is_adopted() {
        let tree = Tree::new("pending_good_file");
        enqueue_book(&tree, "s1", "b1", 2);
        let path = tree.root.page_path("s1", "b1", 1, "png");
        std::fs::write(&path, demo_png::demo_page_bytes(1)).unwrap();
        // Before the sweep the reader will not paint it: the row is the promise, and
        // there is no promise yet.
        assert!(usable_page(&tree.conn, "s1", "b1", 1, &stamp(0))
            .unwrap()
            .is_none());
        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(report.adopted_files, 1);
        assert_eq!(report.corrupt, 0, "a whole image is not debris");
        assert!(path.exists());
        assert_eq!(
            usable_page(&tree.conn, "s1", "b1", 1, &stamp(2)).unwrap(),
            Some(path.clone())
        );
    }

    /// A file that is not a whole image, under a row that never completed, is debris
    /// from an interrupted attempt and is reaped.
    #[test]
    fn a_broken_file_under_a_pending_row_is_reaped() {
        let tree = Tree::new("pending_bad_file");
        enqueue_book(&tree, "s1", "b1", 2);
        let path = tree.root.page_path("s1", "b1", 1, "png");
        std::fs::write(&path, b"half an image, at best").unwrap();
        let report = sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert_eq!(report.corrupt, 1);
        assert!(!path.exists());
        assert_eq!(report.adopted_files, 0);
        // The row stays pending, so the next pass fetches it. That is the difference
        // between this and a completed book: nothing here needed healing, only
        // clearing away.
        assert_eq!(
            downloads::page(&tree.conn, "s1", "b1", 1)
                .unwrap()
                .unwrap()
                .state,
            page_state::PENDING
        );
    }

    #[test]
    fn usable_page_refuses_a_file_that_is_not_the_page_it_claims() {
        let tree = Tree::new("usable");
        enqueue_book(&tree, "s1", "b1", 2);
        let path = plant(&tree, "b1", 1);
        assert_eq!(
            usable_page(&tree.conn, "s1", "b1", 1, &stamp(0)).unwrap(),
            Some(path.clone())
        );
        // Now break the file underneath the row.
        std::fs::write(&path, b"truncated").unwrap();
        assert!(usable_page(&tree.conn, "s1", "b1", 1, &stamp(1))
            .unwrap()
            .is_none());
        assert_eq!(
            downloads::page(&tree.conn, "s1", "b1", 1)
                .unwrap()
                .unwrap()
                .state,
            page_state::PENDING,
            "the read healed the row as it went"
        );
        assert!(
            !path.exists(),
            "a file proved not to be the page does not stay"
        );
        // A missing file is the same story from the other end.
        let path = plant(&tree, "b1", 2);
        std::fs::remove_file(&path).unwrap();
        assert!(usable_page(&tree.conn, "s1", "b1", 2, &stamp(2))
            .unwrap()
            .is_none());
    }

    #[test]
    fn sweep_once_runs_once_per_database_until_asked_again() {
        let tree = Tree::new("once");
        enqueue_book(&tree, "s1", "b1", 1);
        forget_swept();
        let first = sweep_once(&tree.db_path, &tree.root, &stamp(1)).unwrap();
        assert!(first.is_some(), "the first pass per process must sweep");
        assert!(
            sweep_once(&tree.db_path, &tree.root, &stamp(2))
                .unwrap()
                .is_none(),
            "the second must not"
        );
        // A second database is a second download tree, and gets its own sweep.
        let other = Tree::new("once_b");
        assert!(sweep_once(&other.db_path, &other.root, &stamp(3))
            .unwrap()
            .is_some());
        forget_swept();
        assert!(sweep_once(&tree.db_path, &tree.root, &stamp(4))
            .unwrap()
            .is_some());
    }

    /// The disjointness that the whole stage rests on, proved from both sides at
    /// once: the cache's own walk cannot see this tree, and this tree is not in the
    /// LRU ledger the cache evicts from.
    #[test]
    fn the_cache_never_sees_this_tree_and_vice_versa() {
        let tree = Tree::new("disjoint");
        enqueue_book(&tree, "s1", "b1", 3);
        for number in 1..=3 {
            plant(&tree, "b1", number);
        }
        let disk = crate::cache::DiskCache::new(tree.cache_root()).unwrap();
        assert_eq!(
            disk.bytes_used().unwrap(),
            0,
            "a download wrote into the cache tiers"
        );
        let ledger: i64 = tree
            .conn
            .query_row("SELECT COUNT(*) FROM cache_entries", [], |row| row.get(0))
            .unwrap();
        assert_eq!(ledger, 0, "a download put a row in the LRU ledger");
        // And the sweep leaves the cache directory alone, including its tiers.
        sweep(&tree.conn, &tree.root, &stamp(1)).unwrap();
        assert!(tree.cache_root().join("pages").is_dir());
        assert_eq!(disk.bytes_used().unwrap(), 0);
    }
}
