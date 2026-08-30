//! Page cache: bytes on disk under `cache/pages/` and `cache/prefetch/`, with
//! `cache_entries` as the ledger and a byte-budget memory tier in front.
//! LRU is budget-driven and never evicts an offline download.
//!
//! Four invariants worth naming:
//!
//! * A hit means the row exists AND the file exists AND the file is complete and
//!   decodable-looking. Completion is structural: bytes are written to a `.part`
//!   file and renamed, so a crash mid-download leaves no candidate for a hit.
//!   Integrity is additionally *proved* on every read ([`crate::reader::integrity`]),
//!   because a cache entry that goes bad once stays bad forever otherwise.
//! * The recorded path is the only thing a caller may open. Callers never
//!   rebuild a filename from a key, because the extension follows the response
//!   content type and can legitimately change between two fetches of one page.
//! * Bytes the reader actually looked at outrank bytes it did not. That is what
//!   the two directories are for: prefetch entries are promoted to pages on
//!   display, and eviction takes the prefetch tier first regardless of age.
//! * The memory tier is bounded, always. It holds at most the budget it was
//!   given, and refuses any single item larger than that whole budget.
//!
//! ```text
//! display a page          prefetch a page
//!      |                       |
//!      v                       v
//!  memory tier  --hit-->  promote from RAM
//!      | miss                    |
//!      v                         v
//!  ledger + file (validate)    store under prefetch/ + hold bytes in RAM
//!      | hit                        |
//!      v                            v
//!  promote prefetch -> pages, return path
//! ```

use super::integrity::{self, Verdict};
use super::manifest::{extension_for_content_type, PageManifest};
use super::memory::MemoryCache;
use crate::cache::{DiskCache, PAGES_DIR, PREFETCH_DIR};
use crate::store::cache as ledger;
use rusqlite::Connection;
use std::collections::HashSet;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

/// Refuse to cache a zero-byte page: it would look like a hit forever.
pub const MIN_PAGE_BYTES: u64 = 1;

/// Default ceiling for the whole cache pool (covers + pages + prefetch).
pub const DEFAULT_BUDGET_BYTES: i64 = 512 * 1024 * 1024;

/// Bytes the memory tier starts with before a device profile is known.
pub const DEFAULT_MEMORY_BYTES: i64 = super::window::MEMORY_DEFAULT_BYTES;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    /// The reader displayed this page at least once.
    Page,
    /// Fetched ahead of the reader and not yet looked at.
    Prefetch,
}

impl Tier {
    pub fn kind(self) -> &'static str {
        match self {
            Tier::Page => ledger::KIND_PAGE,
            Tier::Prefetch => ledger::KIND_PREFETCH,
        }
    }

    pub fn dir(self) -> &'static str {
        match self {
            Tier::Page => PAGES_DIR,
            Tier::Prefetch => PREFETCH_DIR,
        }
    }

    fn from_kind(kind: &str) -> Tier {
        if kind == ledger::KIND_PREFETCH {
            Tier::Prefetch
        } else {
            Tier::Page
        }
    }
}

/// Why a store attempt did not land. The distinction matters: a corrupt payload
/// is a server-side signal the reader should retry and report, while an I/O
/// failure is the device running out of room and must not be retried per page.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StoreError {
    /// Bytes failed the integrity verdict and were refused, not written.
    Corrupt { reason: String },
    /// Zero-length payload.
    Empty,
    /// The filesystem or the ledger failed.
    Io(String),
}

impl StoreError {
    pub fn is_corrupt(&self) -> bool {
        matches!(self, StoreError::Corrupt { .. })
    }

    pub fn reason(&self) -> String {
        match self {
            StoreError::Corrupt { reason } => reason.clone(),
            StoreError::Empty => "empty response".to_string(),
            StoreError::Io(detail) => detail.clone(),
        }
    }
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StoreError::Corrupt { reason } => write!(f, "refused corrupt bytes: {reason}"),
            StoreError::Empty => write!(f, "refusing to cache an empty page"),
            StoreError::Io(detail) => write!(f, "cache write failed: {detail}"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<StoreError> for io::Error {
    fn from(error: StoreError) -> Self {
        io::Error::other(error.to_string())
    }
}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        StoreError::Io(error.to_string())
    }
}

impl From<io::Error> for StoreError {
    fn from(error: io::Error) -> Self {
        StoreError::Io(error.to_string())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageLocation {
    pub path: PathBuf,
    pub size: i64,
    pub tier: Tier,
}

/// What one cleanup sweep found and fixed. Every field is a bug that used to be
/// permanent: a row pointing at a file that is gone, a file no row describes, a
/// half-written `.part`, an entry whose bytes are not a whole image.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReconcileReport {
    pub ghost_rows: usize,
    pub orphan_files: usize,
    pub stale_parts: usize,
    pub corrupt: usize,
    pub kind_repaired: usize,
    /// Files the sweep recognised as the user's own and left alone **without** an
    /// LRU row. Non-zero means the offline-download protection is doing real work.
    pub protected_kept: usize,
    pub evicted: usize,
    pub freed_bytes: i64,
}

pub struct PageCache {
    disk: DiskCache,
    memory: Arc<Mutex<MemoryCache>>,
    budget: i64,
}

impl PageCache {
    pub fn new(root: impl AsRef<Path>) -> io::Result<Self> {
        Ok(Self::with_memory(
            DiskCache::new(root)?,
            Arc::new(Mutex::new(MemoryCache::new(DEFAULT_MEMORY_BYTES))),
        ))
    }

    pub fn with_disk(disk: DiskCache) -> Self {
        Self::with_memory(
            disk,
            Arc::new(Mutex::new(MemoryCache::new(DEFAULT_MEMORY_BYTES))),
        )
    }

    /// The shape the FFI facade uses: one memory tier shared by every call,
    /// because `App` is rebuilt per request and a per-cache tier would die
    /// between two page turns and warm nothing.
    pub fn shared(root: impl AsRef<Path>) -> io::Result<Self> {
        Ok(Self::with_memory(DiskCache::new(root)?, shared_memory()))
    }

    fn with_memory(disk: DiskCache, memory: Arc<Mutex<MemoryCache>>) -> Self {
        PageCache {
            disk,
            memory,
            budget: DEFAULT_BUDGET_BYTES,
        }
    }

    /// Pool ceiling applied by [`PageCache::enforce_budget`]. `0` disables
    /// automatic trimming, which is what the ledger-level tests use.
    pub fn set_budget(&mut self, budget: i64) {
        self.budget = budget.max(0);
    }

    pub fn budget(&self) -> i64 {
        self.budget
    }

    pub fn disk(&self) -> &DiskCache {
        &self.disk
    }

    pub fn memory(&self) -> &Arc<Mutex<MemoryCache>> {
        &self.memory
    }

    fn memory_locked(&self) -> io::Result<MutexGuard<'_, MemoryCache>> {
        self.memory
            .lock()
            .map_err(|_| io::Error::other("page memory tier is poisoned"))
    }

    /// Resize the memory tier, e.g. after a device profile arrives. Shrinking
    /// evicts the tail rather than failing.
    pub fn set_memory_budget(&self, bytes: i64) -> io::Result<()> {
        self.memory_locked()?.set_budget(bytes);
        Ok(())
    }

    pub fn memory_stats(&self) -> io::Result<super::memory::Stats> {
        Ok(self.memory_locked()?.stats())
    }

    // ---------------------------------------------------------------- lookup

    /// Resolve a page for display, stamping it as recently used.
    ///
    /// This is the healing path: a row whose file has disappeared is deleted
    /// here rather than reported, and so is one whose bytes are not a complete
    /// image. Both answers are `None`, which sends the caller to the network
    /// again instead of serving a broken picture forever. A prefetch hit is
    /// promoted on the way out, because the reader is looking at it now.
    pub fn lookup(
        &self,
        conn: &Connection,
        key: &str,
        now: &str,
    ) -> io::Result<Option<PageLocation>> {
        let Some(entry) = ledger::get(conn, key).map_err(io::Error::other)? else {
            // No row. The bytes can still be resident: eviction drops the file
            // and the ledger together, and without this branch the RAM copy of an
            // evicted page would be dead weight while the reader re-downloaded
            // the very bytes it already holds.
            let resident = self.memory_locked()?.get(key);
            return match resident {
                None => Ok(None),
                Some(bytes) => {
                    let content_type = content_type_for_resident(key);
                    let landed =
                        self.store_tier(conn, key, &bytes, &content_type, now, Tier::Page, None)?;
                    self.memory_locked()?.remove(key);
                    Ok(Some(landed))
                }
            };
        };
        let path = PathBuf::from(&entry.path);
        let tier = Tier::from_kind(&entry.kind);

        if !self.disk.exists(&path) {
            // The file is gone. If the bytes are still resident — prefetched
            // seconds ago, then swept by an eviction this call cannot see —
            // land them again instead of paying for a network round trip.
            let resident = self.memory_locked()?.get(key);
            match resident {
                Some(bytes) => {
                    let content_type = content_type_for_path(&path);
                    let landed =
                        self.store_tier(conn, key, &bytes, &content_type, now, Tier::Page, None)?;
                    // The bytes are on disk in the displayed tier now; holding
                    // them in RAM too would double the cost of a warm page.
                    self.memory_locked()?.remove(key);
                    return Ok(Some(landed));
                }
                None => {
                    ledger::remove(conn, key).map_err(io::Error::other)?;
                    return Ok(None);
                }
            }
        }

        let verdict = integrity::quick_check_file(&path, Some(entry.size));
        if let Verdict::Corrupt(reason) = verdict {
            log::warn!("dropping corrupt cache entry {key}: {}", reason.describe());
            self.memory_locked()?.remove(key);
            self.disk.remove(&path)?;
            ledger::remove(conn, key).map_err(io::Error::other)?;
            return Ok(None);
        }

        if tier == Tier::Prefetch {
            return self.promote(conn, key, &entry.path, now).map(Some);
        }

        ledger::touch(conn, key, now).map_err(io::Error::other)?;
        Ok(Some(PageLocation {
            path,
            size: entry.size,
            tier,
        }))
    }

    /// Cheap existence check for the prefetch planner: one ledger read per book,
    /// no stat, no validation. See [`ledger::cached_keys`] for why that is safe.
    pub fn is_cached(&self, conn: &Connection, key: &str) -> bool {
        ledger::get(conn, key)
            .map(|entry| entry.is_some())
            .unwrap_or(false)
    }

    /// Which of a manifest's pages the ledger believes are on disk.
    pub fn cached_pages(&self, conn: &Connection, manifest: &PageManifest) -> HashSet<u32> {
        let prefix =
            crate::cache::safe_key(&format!("{}-{}-p", manifest.server_id, manifest.book_id));
        let warm = ledger::cached_keys(conn, &prefix).unwrap_or_default();
        manifest
            .pages
            .iter()
            .filter(|page| warm.contains(&manifest.cache_key(page.number)))
            .map(|page| page.number)
            .collect()
    }

    /// Is this page's bytes currently resident? The eviction path deletes a row
    /// and its file together, so without a question like this there is no way to
    /// tell "not cached" from "cached in RAM, waiting to be relanded".
    pub fn is_resident(&self, key: &str) -> io::Result<bool> {
        Ok(self.memory_locked()?.contains(key))
    }

    /// Which pages are in the memory tier right now — the number that says
    /// whether prefetch is actually arriving early enough to matter.
    pub fn resident_pages(&self, manifest: &PageManifest) -> io::Result<HashSet<u32>> {
        let memory = self.memory_locked()?;
        Ok(manifest
            .pages
            .iter()
            .filter(|page| memory.contains(&manifest.cache_key(page.number)))
            .map(|page| page.number)
            .collect())
    }

    // ----------------------------------------------------------------- write

    /// Commit fetched bytes the reader asked for, into the `pages/` tier.
    pub fn store(
        &self,
        conn: &Connection,
        key: &str,
        bytes: &[u8],
        content_type: &str,
        now: &str,
    ) -> io::Result<PageLocation> {
        self.store_tier(conn, key, bytes, content_type, now, Tier::Page, None)
            .map_err(io::Error::from)
    }

    /// The full form. `declared_size` is the page's size as the server's own
    /// manifest reported it, which is the only witness able to prove a response
    /// arrived short — nothing on disk can tell a complete small image from a
    /// truncated large one.
    #[allow(clippy::too_many_arguments)]
    pub fn store_tier(
        &self,
        conn: &Connection,
        key: &str,
        bytes: &[u8],
        content_type: &str,
        now: &str,
        tier: Tier,
        declared_size: Option<i64>,
    ) -> Result<PageLocation, StoreError> {
        if (bytes.len() as u64) < MIN_PAGE_BYTES {
            return Err(StoreError::Empty);
        }
        // The deep check runs here, once, while the bytes are already in hand.
        // Later reads only need the head-and-tail proof.
        if let Verdict::Corrupt(reason) = integrity::inspect(bytes, content_type, declared_size) {
            return Err(StoreError::Corrupt {
                reason: reason.describe(),
            });
        }
        let extension = self.extension_for(bytes, content_type);

        // The extension follows the bytes, so an earlier attempt under a
        // different one must not leave an orphan behind.
        if let Ok(Some(previous)) = ledger::get(conn, key) {
            let previous_path = PathBuf::from(&previous.path);
            if previous_path.extension().and_then(|e| e.to_str()) != Some(extension) {
                self.disk.remove(&previous_path)?;
                self.memory_locked()?.remove(key);
            }
        }

        let stem = format!("{key}.{extension}");
        let path = match tier {
            Tier::Page => self.disk.page_path(&stem),
            Tier::Prefetch => self.disk.prefetch_path(&stem),
        };
        let staging = path.with_file_name(format!(
            "{}.part",
            path.file_name().and_then(|n| n.to_str()).unwrap_or("page")
        ));
        write_then_rename(&staging, &path, bytes)?;

        let size = std::fs::metadata(&path)?.len() as i64;
        ledger::record(conn, key, tier.kind(), &path.to_string_lossy(), size, now)?;
        self.enforce_budget_except(conn, key)?;
        if tier == Tier::Prefetch {
            // Prefetch bytes are held in RAM as well as on disk. The first
            // display of a prefetched page then costs no file read, and if the
            // pool is tight enough that its file is trimmed before the reader
            // arrives, the resident copy relands it instead of a second
            // download.
            self.memory_locked()?.insert(key, bytes);
        }
        Ok(PageLocation { path, size, tier })
    }

    /// Commit prefetched bytes into `prefetch/` and hold them in the memory tier
    /// as well, so the first display of this page costs neither a download nor a
    /// file read. A page too large for the tier is still cached on disk — the
    /// memory tier is an optimisation, never a requirement.
    pub fn store_prefetch(
        &self,
        conn: &Connection,
        key: &str,
        bytes: &[u8],
        content_type: &str,
        now: &str,
    ) -> io::Result<PageLocation> {
        let location =
            self.store_tier(conn, key, bytes, content_type, now, Tier::Prefetch, None)?;
        // RAM first, disk as the durable copy: the memory tier is an optimisation,
        // so a page too large for it is still cached and still correct.
        self.memory_locked()?.insert(key, bytes);
        Ok(location)
    }

    /// Prefer the container the bytes actually are; fall back to the declared
    /// content type when this module cannot walk it.
    fn extension_for(&self, bytes: &[u8], content_type: &str) -> &'static str {
        match integrity::inspect(bytes, content_type, None) {
            Verdict::Valid(info) | Verdict::Reclassified { info, .. } => {
                info.format.extension().unwrap_or("img")
            }
            _ => extension_for_content_type(content_type).trim_start_matches('.'),
        }
    }

    // ------------------------------------------------------------- promote

    /// Move a prefetched page into the displayed tier: a rename, then the ledger
    /// follows. After this the entry is no longer the first victim of eviction,
    /// which is the whole point of having two tiers.
    pub fn promote(
        &self,
        conn: &Connection,
        key: &str,
        current_path: &str,
        now: &str,
    ) -> io::Result<PageLocation> {
        let source = PathBuf::from(current_path);
        let target = self.disk.relocate(&source, PAGES_DIR)?;
        // The leaf is unchanged, so the ledger's new path is derived, not guessed.
        ledger::relocate(conn, key, &target.to_string_lossy(), ledger::KIND_PAGE, now)
            .map_err(io::Error::other)?;
        self.memory_locked()?.remove(key);
        let size = std::fs::metadata(&target)?.len() as i64;
        Ok(PageLocation {
            path: target,
            size,
            tier: Tier::Page,
        })
    }

    // -------------------------------------------------------------- eviction

    /// Trim the pool to `budget`, prefetch tier first, never touching an offline
    /// download. Returns how many entries were dropped.
    pub fn evict_to_budget(&self, conn: &Connection, budget: i64) -> io::Result<usize> {
        let removed = ledger::evict_to_budget(conn, budget).map_err(io::Error::other)?;
        for path in &removed {
            self.disk.remove(&PathBuf::from(path))?;
        }
        Ok(removed.len())
    }

    /// Trim to this cache's configured pool. Runs after every store, on the cheap
    /// ledger total: walking the filesystem per page turn would make a 500-page
    /// book O(n^2) to read.
    pub fn enforce_budget(&self, conn: &Connection) -> io::Result<usize> {
        self.enforce_budget_except(conn, "")
    }

    /// `enforce_budget` with one key held back — see
    /// [`ledger::evict_to_budget_except`].
    pub fn enforce_budget_except(&self, conn: &Connection, keep: &str) -> io::Result<usize> {
        if self.budget <= 0 {
            return Ok(0);
        }
        let used = ledger::total_bytes_fast(conn).map_err(io::Error::other)?;
        if used <= self.budget {
            return Ok(0);
        }
        let keep = if keep.is_empty() { None } else { Some(keep) };
        let removed =
            ledger::evict_to_budget_except(conn, self.budget, keep).map_err(io::Error::other)?;
        for path in &removed {
            self.disk.remove(&PathBuf::from(path))?;
        }
        Ok(removed.len())
    }

    pub fn bytes_used(&self, conn: &Connection) -> io::Result<i64> {
        ledger::total_bytes(conn).map_err(io::Error::other)
    }

    pub fn bytes_of_tier(&self, conn: &Connection, tier: Tier) -> io::Result<i64> {
        ledger::bytes_of_kind(conn, tier.kind()).map_err(io::Error::other)
    }

    // -------------------------------------------------------------- cleanup

    /// Reconcile the ledger with the filesystem, then trim. Runs on open, not on
    /// the hot path, and makes every permanent-looking inconsistency transient.
    ///
    /// Where the two disagree the filesystem wins, because it is the witness:
    /// a row whose file is gone is deleted, a file no row describes is deleted,
    /// and a row that names the wrong tier is repaired to name the one its file
    /// actually sits in.
    pub fn reconcile(&self, conn: &Connection, now: &str) -> io::Result<ReconcileReport> {
        let mut report = ReconcileReport {
            stale_parts: self.disk.remove_stale_parts()?,
            ..Default::default()
        };
        let protected_pre = ledger::protected_paths(conn).map_err(io::Error::other)?;

        let mut live_paths: HashSet<String> = HashSet::new();
        for entry in ledger::entries(conn).map_err(io::Error::other)? {
            let path = PathBuf::from(&entry.path);
            let on_disk = self.disk.exists(&path);
            if !on_disk {
                // Nothing was freed: the bytes were already gone. Counting the
                // row's claimed size here would inflate what the sweep reports.
                ledger::remove(conn, &entry.key).map_err(io::Error::other)?;
                report.ghost_rows += 1;
                continue;
            }
            let actual_size = std::fs::metadata(&path)?.len() as i64;
            if actual_size != entry.size && protected_pre.contains(&entry.path) {
                // A download whose recorded size drifted is not a cache entry to
                // recycle; leave it and let the download feature reconcile it.
                live_paths.insert(entry.path.clone());
                continue;
            }
            if actual_size != entry.size {
                // The ledger's number drives eviction, so a lie here is worse
                // than a missing file: it hides real bytes.
                self.disk.remove(&path)?;
                ledger::remove(conn, &entry.key).map_err(io::Error::other)?;
                report.corrupt += 1;
                report.freed_bytes += actual_size.max(0);
                continue;
            }
            if let Verdict::Corrupt(reason) = integrity::quick_check_file(&path, Some(entry.size)) {
                log::warn!(
                    "sweep removed corrupt cache entry {}: {}",
                    entry.key,
                    reason.describe()
                );
                self.disk.remove(&path)?;
                ledger::remove(conn, &entry.key).map_err(io::Error::other)?;
                report.corrupt += 1;
                report.freed_bytes += actual_size;
                continue;
            }
            // The tier is a fact about the path, not about the row.
            let kind_on_disk = if path.starts_with(self.disk.root().join(PREFETCH_DIR)) {
                ledger::KIND_PREFETCH
            } else {
                ledger::KIND_PAGE
            };
            if kind_on_disk != entry.kind && entry.kind != ledger::KIND_DOWNLOAD {
                ledger::relocate(conn, &entry.key, &entry.path, kind_on_disk, now)
                    .map_err(io::Error::other)?;
                report.kind_repaired += 1;
            }
            live_paths.insert(entry.path);
        }

        // Files the user owns outright are never orphans, even with no
        // `cache_entries` row: `downloads` / `download_pages` are the schema's own
        // statement of what may not be swept, and the sweep consults it here so a
        // future offline-download feature cannot erase a user's book by forgetting
        // to also file an LRU row.
        let protected = ledger::protected_paths(conn).map_err(io::Error::other)?;
        for dir in [PAGES_DIR, PREFETCH_DIR] {
            for name in self.disk.files_in(dir)? {
                let path = self.disk.root().join(dir).join(&name);
                let as_text = path.to_string_lossy().into_owned();
                if protected.contains(&as_text) {
                    if !live_paths.contains(&as_text) {
                        report.protected_kept += 1;
                    }
                    continue;
                }
                if !live_paths.contains(&as_text) {
                    let size = std::fs::metadata(&path)
                        .map(|meta| meta.len() as i64)
                        .unwrap_or(0);
                    self.disk.remove(&path)?;
                    report.orphan_files += 1;
                    report.freed_bytes += size;
                }
            }
        }

        report.evicted = self.enforce_budget(conn)?;
        Ok(report)
    }

    /// Drop a whole tier. This is the user-facing "clear the reader cache":
    /// dropping `Prefetch` frees the bytes the reader guessed at while leaving
    /// every page it actually displayed, and dropping `Page` still never touches
    /// an offline download, because those are recorded under their own kind.
    pub fn clear_tier(&self, conn: &Connection, tier: Tier) -> io::Result<usize> {
        // Prefetched bytes are held twice on purpose — RAM and `prefetch/` — so a
        // request to drop the tier has to drop both, or the mirror would outlive
        // bytes the user just asked gone. This is the *user-facing* clear; the
        // memory-pressure response is `release_prefetch_memory`, which keeps the
        // files.
        let keys: Vec<String> = ledger::entries(conn)
            .map_err(io::Error::other)?
            .into_iter()
            .filter(|entry| entry.kind == tier.kind())
            .map(|entry| entry.key)
            .collect();
        let paths = ledger::delete_of_kind(conn, tier.kind()).map_err(io::Error::other)?;
        for path in &paths {
            self.disk.remove(&PathBuf::from(path))?;
        }
        let mut memory = self.memory_locked()?;
        for key in &keys {
            memory.remove(key);
        }
        Ok(paths.len())
    }

    /// Hand back the RAM the prefetch tier mirrors and leave the tier on disk.
    /// This is the memory-pressure response. Deleting the files here would be a
    /// category error — memory pressure is a shortage of RAM, and a stored file
    /// costs none — and because Android fires `onTrimMemory` on every
    /// backgrounding rather than only under real pressure, that deletion is what
    /// made each trip through HOME re-download the whole prefetch window on
    /// resume: measured on a device as 20 page requests for 4 distinct pages over
    /// 5 cycles.
    pub fn release_prefetch_memory(&self, conn: &Connection) -> io::Result<i64> {
        let mut released = 0i64;
        let mut memory = self.memory_locked()?;
        for entry in ledger::entries(conn).map_err(io::Error::other)? {
            if entry.kind == ledger::KIND_PREFETCH && memory.remove(&entry.key).is_some() {
                released += entry.size.max(0);
            }
        }
        Ok(released)
    }

    /// Drop every cached page of one book (used when a book is pruned).
    pub fn clear_book(
        &self,
        conn: &Connection,
        server_id: &str,
        book_id: &str,
    ) -> io::Result<usize> {
        let prefix = crate::cache::safe_key(&format!("{server_id}-{book_id}-p"));
        // The key set has to be read before the rows are deleted: afterwards
        // there is nothing left to tell the memory tier which bytes are dead.
        let keys = ledger::cached_keys(conn, &prefix).map_err(io::Error::other)?;
        let paths = ledger::delete_for_key_prefix(conn, &prefix).map_err(io::Error::other)?;
        for path in &paths {
            self.disk.remove(&PathBuf::from(path))?;
        }
        let mut memory = self.memory_locked()?;
        for key in keys {
            memory.remove(&key);
        }
        Ok(paths.len())
    }
}

/// A resident entry has no path to read an extension from, so the bytes are
/// their own witness: [`PageCache::store_tier`] sniffs the container anyway and
/// names the file after what it finds.
fn content_type_for_resident(_key: &str) -> String {
    "application/octet-stream".to_string()
}

/// The content type implied by a cached file's extension — the only witness left
/// once the response headers are gone.
fn content_type_for_path(path: &Path) -> String {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        _ => "application/octet-stream",
    }
    .to_string()
}

/// Write-then-rename: a reader can only ever observe the whole file or nothing.
fn write_then_rename(
    staging: &std::path::Path,
    path: &std::path::Path,
    bytes: &[u8],
) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let result = std::fs::write(staging, bytes).and_then(|()| std::fs::rename(staging, path));
    match result {
        Ok(()) => Ok(()),
        Err(error) => {
            std::fs::remove_file(staging).ok();
            Err(error)
        }
    }
}

fn shared_memory() -> Arc<Mutex<MemoryCache>> {
    static MEMORY: OnceLock<Arc<Mutex<MemoryCache>>> = OnceLock::new();
    MEMORY
        .get_or_init(|| Arc::new(Mutex::new(MemoryCache::new(DEFAULT_MEMORY_BYTES))))
        .clone()
}

/// The process-wide memory tier, for the FFI facade's own accounting and for
/// resetting it between acceptance phases.
pub fn process_memory() -> Arc<Mutex<MemoryCache>> {
    shared_memory()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cache::demo_png;
    use crate::reader::manifest::{PageManifest, RawPage};
    use crate::store::open_in_memory;
    use uuid::Uuid;

    struct Harness {
        dir: PathBuf,
        cache: PageCache,
    }

    impl Harness {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("komga_page_cache_{}", Uuid::new_v4()));
            let mut cache = PageCache::new(&dir).unwrap();
            cache.set_budget(0);
            Harness { dir, cache }
        }

        /// A tier with a memory budget small enough that page N does not fit,
        /// for the refusal tests.
        fn with_memory(&mut self, bytes: i64) -> &mut Self {
            self.cache.set_memory_budget(bytes).unwrap();
            self
        }

        fn cleanup(&self) {
            std::fs::remove_dir_all(&self.dir).ok();
        }

        fn tiers(&self) -> (Vec<String>, Vec<String>) {
            (
                self.cache.disk.files_in(PAGES_DIR).unwrap(),
                self.cache.disk.files_in(PREFETCH_DIR).unwrap(),
            )
        }
    }

    fn manifest(pages: usize) -> PageManifest {
        let raw: Vec<RawPage> = (1..=pages as i64)
            .map(|number| RawPage {
                file_name: format!("{number:03}.png"),
                media_type: "image/png".to_string(),
                number,
                width: Some(100),
                height: Some(150),
                size_bytes: Some(demo_png::demo_page_bytes(number as u32).len() as i64),
            })
            .collect();
        PageManifest::from_raw("srv", "book", None, &raw)
    }

    fn page(number: u32) -> Vec<u8> {
        demo_png::demo_page_bytes(number)
    }

    #[test]
    fn store_then_lookup_round_trips_with_accounting() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let pages = manifest(1);
        let key = pages.cache_key(1);
        let bytes = page(1);

        assert_eq!(harness.cache.lookup(&conn, &key, "t2").unwrap(), None);
        let location = harness
            .cache
            .store(&conn, &key, &bytes, "image/png", "t1")
            .unwrap();
        assert!(location.path.exists());
        assert!(location.path.to_string_lossy().ends_with(".png"));
        assert_eq!(location.size, bytes.len() as i64);
        assert_eq!(location.tier, Tier::Page);
        assert_eq!(harness.cache.bytes_used(&conn).unwrap(), bytes.len() as i64);

        let hit = harness.cache.lookup(&conn, &key, "t2").unwrap().unwrap();
        assert_eq!(hit.path, location.path);
        assert_eq!(
            ledger::get(&conn, &key).unwrap().unwrap().last_access,
            "t2",
            "a hit must stamp the entry or LRU will evict what is on screen"
        );
        assert_eq!(std::fs::read(&hit.path).unwrap(), bytes);
        harness.cleanup();
    }

    #[test]
    fn an_empty_or_non_image_payload_is_never_cached() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        assert!(harness
            .cache
            .store(&conn, "srv-book-p1", b"", "image/png", "t1")
            .is_err());
        let html = b"<html><body>502 Bad Gateway</body></html>".to_vec();
        let error = harness
            .cache
            .store(&conn, "srv-book-p1", &html, "image/jpeg", "t1")
            .unwrap_err();
        assert!(
            error.to_string().contains("not an image"),
            "the refusal must say why: {error}"
        );
        assert_eq!(harness.cache.bytes_used(&conn).unwrap(), 0);
        assert_eq!(
            harness.cache.lookup(&conn, "srv-book-p1", "t2").unwrap(),
            None
        );
        harness.cleanup();
    }

    #[test]
    fn a_deleted_file_is_a_miss_and_the_ledger_converges() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let key = manifest(1).cache_key(1);
        let location = harness
            .cache
            .store(&conn, &key, &page(1), "image/png", "t1")
            .unwrap();
        let stored = location.size;
        assert!(stored > 0);

        std::fs::remove_file(&location.path).unwrap();
        // The cheap check is a ledger query by design: it is what the prefetch
        // planner calls once per spread for every page of the book, and it may
        // not stat 500 files to answer.
        assert!(harness.cache.is_cached(&conn, &key));
        assert_eq!(harness.cache.lookup(&conn, &key, "t2").unwrap(), None);
        assert_eq!(
            ledger::get(&conn, &key).unwrap(),
            None,
            "lookup prunes the row it could not honour"
        );
        assert_eq!(harness.cache.bytes_used(&conn).unwrap(), 0);
        harness.cleanup();
    }

    /// The corruption-recovery rule, on the read path rather than the write path:
    /// an entry that was whole when it landed and is not whole now must be dropped
    /// and reported as a miss, never served.
    #[test]
    fn a_truncated_file_on_disk_is_dropped_and_reported_as_a_miss() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let key = manifest(1).cache_key(1);
        let location = harness
            .cache
            .store(&conn, &key, &page(1), "image/png", "t1")
            .unwrap();
        assert!(harness.cache.lookup(&conn, &key, "t2").unwrap().is_some());

        // Cut the tail off: the file still exists, and its size now disagrees
        // with the ledger too.
        let bytes = std::fs::read(&location.path).unwrap();
        std::fs::write(&location.path, &bytes[..bytes.len() - 8]).unwrap();
        assert!(
            harness.cache.lookup(&conn, &key, "t3").unwrap().is_none(),
            "a half file must not be a hit"
        );
        assert!(!location.path.exists(), "and the debris must be gone");
        assert_eq!(ledger::get(&conn, &key).unwrap(), None);
        // The next fetch can therefore succeed cleanly rather than loop.
        let refetched = harness
            .cache
            .store(&conn, &key, &page(1), "image/png", "t4")
            .unwrap();
        assert!(harness.cache.lookup(&conn, &key, "t5").unwrap().is_some());
        assert_eq!(refetched.size, bytes.len() as i64);
        harness.cleanup();
    }

    #[test]
    fn a_file_replaced_by_a_different_format_leaves_one_entry() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let key = manifest(1).cache_key(1);
        let png = page(1);
        let first = harness
            .cache
            .store(&conn, &key, &png, "image/png", "t1")
            .unwrap();
        // Same key, and the container really is PNG even though the header now
        // claims JPEG: the bytes name the file, not the response.
        let second = harness
            .cache
            .store(&conn, &key, &png, "image/jpeg", "t2")
            .unwrap();
        assert_eq!(first.path, second.path, "the magic wins over the header");
        assert_eq!(
            harness.cache.disk.files_in(PAGES_DIR).unwrap().len(),
            1,
            "no orphan from the superseded attempt"
        );
        assert!(harness.cache.lookup(&conn, &key, "t3").unwrap().is_some());
        harness.cleanup();
    }

    #[test]
    fn prefetch_lands_in_its_own_tier_and_is_held_in_ram() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(2);
        let bytes = page(2);
        let location = harness
            .cache
            .store_prefetch(&conn, &manifest.cache_key(2), &bytes, "image/png", "t1")
            .unwrap();

        assert_eq!(location.tier, Tier::Prefetch);
        assert!(location.path.starts_with(harness.dir.join(PREFETCH_DIR)));
        let (pages, prefetch) = harness.tiers();
        assert!(pages.is_empty(), "prefetch must not touch pages/");
        assert_eq!(prefetch.len(), 1);
        assert_eq!(
            harness.cache.memory_stats().unwrap().bytes,
            bytes.len() as i64,
            "the bytes are resident so the first display skips the disk"
        );
        assert_eq!(
            harness.cache.bytes_of_tier(&conn, Tier::Prefetch).unwrap(),
            bytes.len() as i64
        );
        assert_eq!(harness.cache.bytes_of_tier(&conn, Tier::Page).unwrap(), 0);
        harness.cleanup();
    }

    /// The reason two tiers exist: displaying a prefetched page promotes it, and
    /// promotion is a rename rather than a re-download or a copy.
    #[test]
    fn displaying_a_prefetched_page_promotes_it_once() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(3);
        let key = manifest.cache_key(3);
        let bytes = page(3);
        let prefetch_path = harness
            .cache
            .store_prefetch(&conn, &key, &bytes, "image/png", "t1")
            .unwrap()
            .path;

        let shown = harness.cache.lookup(&conn, &key, "t2").unwrap().unwrap();
        assert_eq!(shown.tier, Tier::Page);
        assert_eq!(
            shown.path.parent(),
            Some(harness.dir.join(PAGES_DIR).as_path())
        );
        assert!(shown.path.exists(), "the promoted path is the live one");
        assert!(
            !prefetch_path.exists(),
            "promotion moved the file, not copied it"
        );
        let entry = ledger::get(&conn, &key).unwrap().unwrap();
        assert_eq!(entry.kind, ledger::KIND_PAGE, "the ledger knows too");
        assert_eq!(entry.path, shown.path.to_string_lossy());
        assert_eq!(
            harness.cache.memory_stats().unwrap().bytes,
            0,
            "promotion hands the bytes to disk and stops holding RAM for them"
        );
        let (pages, prefetch) = harness.tiers();
        assert_eq!(pages.len(), 1);
        assert!(prefetch.is_empty());
        // A second display is a plain page hit and changes nothing.
        let again = harness.cache.lookup(&conn, &key, "t3").unwrap().unwrap();
        assert_eq!(again.path, shown.path);
        assert_eq!(again.tier, Tier::Page);
        harness.cleanup();
    }

    #[test]
    fn the_memory_tier_serves_a_page_whose_file_the_sweep_ate() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(1);
        let key = manifest.cache_key(1);
        let bytes = page(1);
        let path = harness
            .cache
            .store_prefetch(&conn, &key, &bytes, "image/png", "t1")
            .unwrap()
            .path;
        assert!(harness.cache.memory_stats().unwrap().bytes > 0);

        // Something outside the cache's control removed the file.
        std::fs::remove_file(&path).unwrap();
        let revived = harness
            .cache
            .lookup(&conn, &key, "t2")
            .unwrap()
            .expect("the resident copy should have been re-landed");
        assert_eq!(revived.tier, Tier::Page);
        assert_eq!(std::fs::read(&revived.path).unwrap(), bytes);
        assert_eq!(harness.cache.memory_stats().unwrap().bytes, 0);
        harness.cleanup();
    }

    #[test]
    fn a_page_too_large_for_the_tier_is_still_cached_on_disk() {
        let mut harness = Harness::new();
        harness.with_memory(1024);
        let conn = open_in_memory().unwrap();
        let manifest = manifest(1);
        let key = manifest.cache_key(1);
        let bytes = page(1);
        assert!(bytes.len() > 1024, "fixture must exceed the tiny tier");

        let location = harness
            .cache
            .store_prefetch(&conn, &key, &bytes, "image/png", "t1")
            .unwrap();
        assert!(location.path.exists());
        assert_eq!(
            harness.cache.memory_stats().unwrap().bytes,
            0,
            "refused for RAM, not for disk"
        );
        assert_eq!(harness.cache.bytes_used(&conn).unwrap(), bytes.len() as i64);
        assert!(harness.cache.lookup(&conn, &key, "t2").unwrap().is_some());
        harness.cleanup();
    }

    /// Eviction drops the row and the file together. A prefetched page still
    /// resident in RAM must therefore come back from RAM rather than the network
    /// — otherwise the memory tier holds bytes no reader can ever reach.
    #[test]
    fn an_evicted_page_still_resident_is_relanded_instead_of_refetched() {
        let mut harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(4);
        let first = page(1);
        let second = page(2);
        harness
            .cache
            .store(&conn, &manifest.cache_key(1), &first, "image/png", "t1")
            .unwrap();
        harness
            .cache
            .store_prefetch(&conn, &manifest.cache_key(2), &second, "image/png", "t2")
            .unwrap();
        assert!(harness.cache.memory_stats().unwrap().bytes > 0);

        // A pool small enough that showing page 3 has to evict page 1's row.
        let tight = first.len() as i64 + second.len() as i64;
        harness.cache.set_budget(tight);
        harness
            .cache
            .evict_to_budget(&conn, first.len() as i64)
            .unwrap();
        assert!(
            !harness.cache.is_cached(&conn, &manifest.cache_key(2)),
            "the prefetch row is gone"
        );
        assert!(
            harness.cache.is_resident(&manifest.cache_key(2)).unwrap(),
            "but its bytes were never dropped, which is the bug this test exists for"
        );

        let revived = harness
            .cache
            .lookup(&conn, &manifest.cache_key(2), "t3")
            .unwrap()
            .expect("a resident page must survive eviction of its row");
        assert_eq!(revived.tier, Tier::Page);
        assert_eq!(std::fs::read(&revived.path).unwrap(), second);
        harness.cleanup();
    }

    #[test]
    fn cached_pages_uses_the_ledger_and_names_every_warm_page() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let pages = manifest(4);
        for number in [1u32, 3] {
            let bytes = page(number);
            let content_type = "image/png";
            if number == 1 {
                harness
                    .cache
                    .store(&conn, &pages.cache_key(number), &bytes, content_type, "t1")
                    .unwrap();
            } else {
                harness
                    .cache
                    .store_prefetch(&conn, &pages.cache_key(number), &bytes, content_type, "t1")
                    .unwrap();
            }
        }
        assert_eq!(
            harness.cache.cached_pages(&conn, &pages),
            [1, 3].into_iter().collect::<HashSet<u32>>(),
            "both tiers count as warm for prefetch"
        );
        harness.cleanup();
    }

    /// The memory-pressure response must cost the next read nothing: the RAM
    /// mirror goes, the tier stays.
    #[test]
    fn releasing_prefetch_memory_frees_ram_and_keeps_every_prefetched_file() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let pages = manifest(3);
        for number in [1u32, 2] {
            harness
                .cache
                .store_prefetch(
                    &conn,
                    &pages.cache_key(number),
                    &page(number),
                    "image/png",
                    "t1",
                )
                .unwrap();
        }
        harness
            .cache
            .store(&conn, &pages.cache_key(3), &page(3), "image/png", "t1")
            .unwrap();
        let held = harness.cache.memory_stats().unwrap().bytes;
        assert!(held > 0, "stored pages are expected to be resident");

        let released = harness.cache.release_prefetch_memory(&conn).unwrap();
        assert_eq!(
            released, held,
            "only prefetched pages carry a RAM mirror — promote() drops the key from the
             tier — so the release should hand back exactly what was held"
        );
        for number in [1u32, 2] {
            assert!(
                !harness.cache.is_resident(&pages.cache_key(number)).unwrap(),
                "page {number} is still mirrored in RAM"
            );
        }
        // Page 3 was stored through the display path and promoted pages leave the
        // tier by design, so there is no mirror of it to lose — what has to survive
        // is the row, the file and its warmth, asserted below.
        assert_eq!(
            harness.cache.cached_pages(&conn, &pages),
            [1, 2, 3].into_iter().collect::<HashSet<u32>>(),
            "the tier has to stay warm, or the next resume pays for it"
        );
        for number in [1u32, 2] {
            let row = ledger::get(&conn, &pages.cache_key(number))
                .unwrap()
                .expect("the prefetch row must survive");
            assert!(
                std::path::PathBuf::from(&row.path).exists(),
                "the prefetch file must survive"
            );
        }
        assert_eq!(
            harness.cache.release_prefetch_memory(&conn).unwrap(),
            0,
            "a second release has nothing left to hand back"
        );
        harness.cleanup();
    }

    #[test]
    fn eviction_respects_the_budget_and_spares_downloads() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(3);
        let mut sizes = 0i64;
        for (index, number) in (1..=3u32).enumerate() {
            let bytes = page(number);
            sizes += bytes.len() as i64;
            harness
                .cache
                .store(
                    &conn,
                    &manifest.cache_key(number),
                    &bytes,
                    "image/png",
                    &format!("t{index}"),
                )
                .unwrap();
        }
        // A user-owned offline download lives in the same pool.
        let download = harness.dir.join("offline.bin");
        std::fs::write(&download, [0u8; 100]).unwrap();
        ledger::record(
            &conn,
            "dl",
            ledger::KIND_DOWNLOAD,
            &download.to_string_lossy(),
            100,
            "t0",
        )
        .unwrap();
        assert_eq!(harness.cache.bytes_used(&conn).unwrap(), sizes + 100);

        let dropped = harness.cache.evict_to_budget(&conn, 200).unwrap();
        assert!(dropped >= 1, "something had to give");
        assert!(harness.cache.bytes_used(&conn).unwrap() <= sizes + 100 - dropped as i64);
        assert_eq!(
            ledger::bytes_of_kind(&conn, ledger::KIND_DOWNLOAD).unwrap(),
            100
        );
        assert!(
            download.exists(),
            "LRU must never delete an offline download"
        );
        assert!(
            !harness.cache.is_cached(&conn, &manifest.cache_key(1)),
            "with equal kinds the oldest page goes first"
        );
        harness.cleanup();
    }

    /// Prefetch bytes are the first victims, so trimming the pool can never trade
    /// away what the reader is looking at while unseen pages sit in the cache.
    #[test]
    fn trimming_the_pool_loses_prefetch_before_any_displayed_page() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(3);
        let displayed = page(1);
        let unseen = page(2);
        let unseen_size = unseen.len() as i64;
        harness
            .cache
            .store(&conn, &manifest.cache_key(1), &displayed, "image/png", "t1")
            .unwrap();
        harness
            .cache
            .store_prefetch(&conn, &manifest.cache_key(2), &unseen, "image/png", "t2")
            .unwrap();
        let total = displayed.len() as i64 + unseen_size;
        let budget = total - unseen_size / 2;

        let dropped = harness.cache.evict_to_budget(&conn, budget).unwrap();
        assert_eq!(dropped, 1, "freeing the prefetch page is enough");
        assert!(!harness.cache.is_cached(&conn, &manifest.cache_key(2)));
        assert!(
            harness
                .cache
                .lookup(&conn, &manifest.cache_key(1), "t3")
                .unwrap()
                .is_some(),
            "the displayed page survives a trim that a newer prefetch entry does not"
        );
        harness.cleanup();
    }

    #[test]
    fn automatic_trimming_happens_on_store_and_never_eats_the_new_page() {
        let mut harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(4);
        let sizes: Vec<i64> = (1..=4u32).map(|n| page(n).len() as i64).collect();
        // Room for two pages, give or take.
        let budget = sizes[0] + sizes[1];
        harness.cache.set_budget(budget);
        let cache = &harness.cache;
        for number in 1..=4u32 {
            cache
                .store(
                    &conn,
                    &manifest.cache_key(number),
                    &page(number),
                    "image/png",
                    &format!("t{number}"),
                )
                .unwrap();
        }
        let used = cache.bytes_used(&conn).unwrap();
        assert!(
            used <= budget + sizes[3],
            "the pool stayed within about two pages, got {used} of {budget}"
        );
        assert!(
            cache
                .lookup(&conn, &manifest.cache_key(4), "t9")
                .unwrap()
                .is_some(),
            "the page just handed to the reader must never be the eviction victim"
        );
        assert!(
            !cache.is_cached(&conn, &manifest.cache_key(1)),
            "and the oldest displayed page is what paid for it"
        );
        harness.cleanup();
    }

    #[test]
    fn reconcile_fixes_ghosts_orphans_parts_and_wrong_tiers() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(4);
        for number in 1..=3u32 {
            harness
                .cache
                .store(
                    &conn,
                    &manifest.cache_key(number),
                    &page(number),
                    "image/png",
                    "t1",
                )
                .unwrap();
        }
        // Ghost row: the ledger names a file that is not there.
        std::fs::remove_file(
            ledger::get(&conn, &manifest.cache_key(3))
                .unwrap()
                .unwrap()
                .path,
        )
        .unwrap();
        // Orphan file: bytes on disk no row describes.
        std::fs::write(harness.dir.join(PAGES_DIR).join("orphan.png"), b"junk").unwrap();
        // Stale staging file from an interrupted write.
        std::fs::write(harness.dir.join(PAGES_DIR).join("half.png.part"), b"junk").unwrap();
        // Wrong tier: a page row pointing into prefetch/.
        let misplaced = harness
            .cache
            .store_prefetch(&conn, &manifest.cache_key(4), &page(4), "image/png", "t1")
            .unwrap();
        ledger::relocate(
            &conn,
            &manifest.cache_key(4),
            &misplaced.path.to_string_lossy(),
            ledger::KIND_PAGE,
            "t1",
        )
        .unwrap();

        let report = harness.cache.reconcile(&conn, "t2").unwrap();
        assert_eq!(report.ghost_rows, 1, "the row whose file was deleted");
        assert_eq!(report.orphan_files, 1, "orphan.png went");
        assert_eq!(report.stale_parts, 1, "the .part went");
        assert_eq!(
            report.kind_repaired, 1,
            "the page row is now a prefetch row"
        );
        assert_eq!(
            ledger::get(&conn, &manifest.cache_key(4))
                .unwrap()
                .unwrap()
                .kind,
            ledger::KIND_PREFETCH
        );
        assert!(harness
            .cache
            .lookup(&conn, &manifest.cache_key(4), "t3")
            .unwrap()
            .is_some());
        assert_eq!(report.evicted, 0, "nothing needed evicting");
        assert_eq!(
            report.freed_bytes, 4,
            "only the 4-byte orphan really freed bytes; a ghost row's file was already gone"
        );
        assert!(!harness.dir.join(PAGES_DIR).join("orphan.png").exists());
        assert!(harness.cache.is_cached(&conn, &manifest.cache_key(1)));
        harness.cleanup();
    }

    #[test]
    fn reconcile_counts_and_frees_real_bytes() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(2);
        let bytes = page(1);
        let size = bytes.len() as i64;
        harness
            .cache
            .store(&conn, &manifest.cache_key(1), &bytes, "image/png", "t1")
            .unwrap();
        // A corrupt file whose ledger size still matches: the trailer check has to
        // be what catches it, not the byte count.
        let path = PathBuf::from(
            ledger::get(&conn, &manifest.cache_key(1))
                .unwrap()
                .unwrap()
                .path,
        );
        let mut wounded = bytes.clone();
        wounded.truncate(wounded.len() - 4);
        let wounded_size = wounded.len() as i64;
        std::fs::write(&path, &wounded).unwrap();
        ledger::record(
            &conn,
            &manifest.cache_key(1),
            ledger::KIND_PAGE,
            &path.to_string_lossy(),
            wounded_size,
            "t1",
        )
        .unwrap();
        assert_eq!(wounded_size, size - 4);

        let report = harness.cache.reconcile(&conn, "t2").unwrap();
        assert_eq!(report.corrupt, 1);
        assert_eq!(report.freed_bytes, wounded_size);
        assert_eq!(harness.cache.bytes_used(&conn).unwrap(), 0);
        assert!(!path.exists());
        harness.cleanup();
    }

    #[test]
    fn clear_book_removes_files_rows_ram_and_nothing_else() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let target = manifest(2);
        let other = PageManifest::from_raw(
            "srv",
            "other",
            None,
            &[RawPage {
                file_name: "a.png".to_string(),
                media_type: "image/png".to_string(),
                number: 1,
                width: Some(1),
                height: Some(1),
                size_bytes: Some(page(1).len() as i64),
            }],
        );
        let paths = vec![
            harness
                .cache
                .store(&conn, &target.cache_key(1), &page(1), "image/png", "t1")
                .unwrap()
                .path,
            harness
                .cache
                .store_prefetch(&conn, &target.cache_key(2), &page(2), "image/png", "t1")
                .unwrap()
                .path,
        ];
        let kept = harness
            .cache
            .store(&conn, &other.cache_key(1), &page(1), "image/png", "t1")
            .unwrap();

        assert_eq!(
            harness.cache.clear_book(&conn, "srv", "other2").unwrap(),
            0,
            "no false matches"
        );
        assert_eq!(harness.cache.clear_book(&conn, "srv", "book").unwrap(), 2);
        for path in &paths {
            assert!(!path.exists(), "{path:?} survived");
        }
        assert!(harness.cache.is_cached(&conn, &other.cache_key(1)));
        assert_eq!(kept.size, page(1).len() as i64);
        assert_eq!(
            harness.cache.memory_stats().unwrap().bytes,
            0,
            "clearing a book must drop its resident bytes too"
        );
        harness.cleanup();
    }

    /// The acceptance line "Cache 清理不会影响用户主动下载内容", proven on the
    /// worst case: a download whose file lives inside the very tier being swept.
    /// The same guarantee without the cooperation of the LRU ledger — which is
    /// how Phase 4 will actually look, because the download feature is still a stub
    /// and nothing writes `kind='download'` yet. Protection that depends on that row
    /// being written is a convention; this is the version that is not.
    #[test]
    fn a_download_with_no_ledger_row_is_still_kept_by_every_cleanup() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        // A downloaded page filed exactly where the reader would also put one, and
        // recorded only in the download tables.
        let downloaded = harness.cache.disk().page_path("srv-book-p2.png");
        std::fs::write(&downloaded, page(2)).unwrap();
        conn.execute(
            "INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done, state)
             VALUES ('srv', 'book', NULL, 1, 1, 'complete')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO download_pages (server_id, book_id, page_number, file_path, state)
             VALUES ('srv', 'book', 2, ?1, 'complete')",
            [downloaded.to_string_lossy().as_ref()],
        )
        .unwrap();
        assert!(!ledger::get(&conn, "anything").unwrap().is_some());

        let report = harness.cache.reconcile(&conn, "t1").unwrap();
        assert_eq!(
            report.orphan_files, 0,
            "the user's downloaded page must not read as an orphan: {report:?}"
        );
        assert_eq!(report.protected_kept, 1);
        assert!(
            downloaded.exists(),
            "and it is still on disk after the sweep"
        );

        assert_eq!(harness.cache.clear_book(&conn, "srv", "book").unwrap(), 0);
        assert!(
            downloaded.exists(),
            "pruning the mirrored book keeps the download"
        );
        assert_eq!(harness.cache.clear_tier(&conn, Tier::Page).unwrap(), 0);
        assert!(
            downloaded.exists(),
            "clearing the displayed tier keeps a file the download tables claim"
        );
        harness.cleanup();
    }

    #[test]
    fn clearing_a_tier_and_sweeping_never_touches_an_offline_download() {
        let harness = Harness::new();
        let conn = open_in_memory().unwrap();
        let manifest = manifest(3);
        // A download deliberately parked in pages/, where a naive sweep would eat it.
        let download = harness.cache.disk().page_path("srv-book-p2.png");
        std::fs::write(&download, page(2)).unwrap();
        let download_size = std::fs::metadata(&download).unwrap().len() as i64;
        ledger::record(
            &conn,
            &manifest.cache_key(2),
            ledger::KIND_DOWNLOAD,
            &download.to_string_lossy(),
            download_size,
            "t1",
        )
        .unwrap();
        harness
            .cache
            .store(&conn, &manifest.cache_key(1), &page(1), "image/png", "t1")
            .unwrap();
        harness
            .cache
            .store_prefetch(&conn, &manifest.cache_key(3), &page(3), "image/png", "t1")
            .unwrap();
        let displayed = ledger::get(&conn, &manifest.cache_key(1))
            .unwrap()
            .unwrap()
            .path;

        let report = harness.cache.reconcile(&conn, "t2").unwrap();
        assert_eq!(
            (report.ghost_rows, report.orphan_files, report.corrupt),
            (0, 0, 0),
            "a download row must not read as an orphan: {report:?}"
        );
        assert!(download.exists(), "the sweep left the download file alone");

        assert_eq!(harness.cache.clear_tier(&conn, Tier::Prefetch).unwrap(), 1);
        assert!(
            download.exists(),
            "clearing prefetch left the download alone"
        );
        assert!(harness.cache.is_cached(&conn, &manifest.cache_key(1)));
        assert_eq!(
            harness.cache.bytes_of_tier(&conn, Tier::Page).unwrap(),
            std::fs::metadata(&displayed).unwrap().len() as i64
        );
        assert_eq!(harness.cache.clear_tier(&conn, Tier::Page).unwrap(), 1);
        assert!(
            download.exists(),
            "even clearing the displayed tier may not delete a user's download"
        );
        assert!(!PathBuf::from(&displayed).exists());
        assert_eq!(harness.cache.memory_stats().unwrap().bytes, 0);
        harness.cleanup();
    }

    #[test]
    fn the_tier_and_extension_rules_are_explicit() {
        assert_eq!(Tier::Page.kind(), ledger::KIND_PAGE);
        assert_eq!(Tier::Prefetch.kind(), ledger::KIND_PREFETCH);
        assert_eq!(Tier::Page.dir(), PAGES_DIR);
        assert_eq!(Tier::Prefetch.dir(), PREFETCH_DIR);
        assert_eq!(Tier::from_kind(ledger::KIND_PREFETCH), Tier::Prefetch);
        assert_eq!(Tier::from_kind(ledger::KIND_DOWNLOAD), Tier::Page);
        assert_eq!(content_type_for_path(Path::new("x/y.jpg")), "image/jpeg");
        assert_eq!(content_type_for_path(Path::new("x/y.png")), "image/png");
        assert_eq!(
            content_type_for_path(Path::new("x/y.bin")),
            "application/octet-stream"
        );
        let cache =
            PageCache::new(std::env::temp_dir().join(format!("tier_{}", Uuid::new_v4()))).unwrap();
        assert_eq!(
            cache.extension_for(&page(1), "image/jpeg"),
            "png",
            "a PNG body behind a JPEG header is named for its body"
        );
        assert_eq!(
            cache.extension_for(b"<html/>", "text/html"),
            extension_for_content_type("text/html").trim_start_matches('.'),
            "undecidable bytes keep the declared name"
        );
        assert_eq!(
            integrity::Format::from_magic(&page(1)),
            integrity::Format::Png
        );
    }

    #[test]
    fn a_shared_tier_survives_new_cache_handles() {
        let dir = std::env::temp_dir().join(format!("shared_{}", Uuid::new_v4()));
        let mut first = PageCache::shared(&dir).unwrap();
        first.set_budget(0);
        let conn = open_in_memory().unwrap();
        let manifest = manifest(1);
        let key = manifest.cache_key(1);
        let bytes = page(1);
        first
            .store_prefetch(&conn, &key, &bytes, "image/png", "t1")
            .unwrap();
        // A second handle — what every FFI call rebuilds — sees the same RAM.
        let mut second = PageCache::shared(&dir).unwrap();
        second.set_budget(0);
        assert_eq!(
            second.memory_stats().unwrap().bytes,
            bytes.len() as i64,
            "the tier must be process-wide or it warms nothing"
        );
        assert_eq!(Arc::as_ptr(first.memory()), Arc::as_ptr(second.memory()));
        second.set_memory_budget(0).unwrap();
        assert_eq!(second.memory_stats().unwrap().bytes, 0);
        // Leave the shared tier empty for later tests in the same process.
        first.set_memory_budget(DEFAULT_MEMORY_BYTES).unwrap();
        std::fs::remove_dir_all(&dir).ok();
    }
}
