//! The page pipeline: Page Manifest -> Cache -> Local File.
//!
//! ```text
//! Reader (UI)
//!   -> ReaderLoader::page(n)
//!        manifest mirror (SQLite)  or  fetched + mirrored manifest
//!        page cache (cache_entries -> cache/pages/<key>.<ext>)
//!        local file path            (the UI decodes and renders this)
//! ```
//!
//! The UI never issues a request and never builds a path: it asks for a page and
//! gets a file it can open. Network access arrives only through the injected
//! [`PageSource`], which `api::page::PageStreaming` implements at the facade.

use super::cache::{PageCache, StoreError, Tier};
use super::manifest::{PageDescriptor, PageManifest, RawPage};
use super::paging::{layout, Direction, Layout, ReadMode};
use super::prefetch::{plan, Window};
use crate::store::{pages as mirror, position};
use rusqlite::Connection;
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::path::PathBuf;

/// Anything the reader needs from the server. Implemented by an adapter over
/// `api::page::PageStreaming`; faked in every test in this module.
pub trait PageSource {
    fn fetch_pages(&mut self, book_id: &str) -> Result<Vec<RawPage>, LoaderError>;
    /// Bytes + the response content type.
    fn fetch_page(&mut self, book_id: &str, number: u32) -> Result<(Vec<u8>, String), LoaderError>;
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LoaderError {
    /// Server answered with no pages: there is nothing to read.
    Empty,
    /// Not an image-paged book (EPUB/PDF) — needs another viewer.
    NotPaged,
    /// Asked for a page the book does not have.
    OutOfRange {
        page: u32,
        page_count: u32,
    },
    /// The server could not be reached or refused. Cached pages are unaffected.
    Network(String),
    /// The server answered with bytes that are not a complete image of the page
    /// it claims. They were refused rather than cached, so the entry cannot go
    /// bad permanently; [`MAX_CORRUPT_ATTEMPTS`] consecutive failures for one
    /// page stop the retries, because a server that answers twice with garbage
    /// will answer a third time the same way.
    Corrupt {
        page: u32,
        reason: String,
    },
    Disk(String),
    Store(String),
}

impl fmt::Display for LoaderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LoaderError::Empty => write!(f, "book has no pages"),
            LoaderError::NotPaged => write!(f, "book is not image-paged"),
            LoaderError::OutOfRange { page, page_count } => {
                write!(f, "page {page} outside a {page_count}-page book")
            }
            LoaderError::Network(reason) => write!(f, "page unavailable: {reason}"),
            LoaderError::Corrupt { page, reason } => {
                write!(f, "page {page} arrived unusable: {reason}")
            }
            LoaderError::Disk(reason) => write!(f, "cache write failed: {reason}"),
            LoaderError::Store(reason) => write!(f, "store failed: {reason}"),
        }
    }
}

impl std::error::Error for LoaderError {}

impl From<rusqlite::Error> for LoaderError {
    fn from(error: rusqlite::Error) -> Self {
        LoaderError::Store(error.to_string())
    }
}

impl From<std::io::Error> for LoaderError {
    fn from(error: std::io::Error) -> Self {
        LoaderError::Disk(error.to_string())
    }
}

/// Where the manifest for this open came from — the difference between a
/// reading session that needs a network and one that does not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManifestSource {
    /// Read straight out of SQLite: no request was made.
    Mirror,
    /// Fetched now and mirrored for next time.
    Network,
}

/// A page resolved to something the UI can open.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageRef {
    pub number: u32,
    pub path: PathBuf,
    pub size: i64,
    pub source: Source,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Cache,
    Network,
}

/// A `PageSource` backed by bytes someone already fetched. The FFI facade uses
/// it because a `rusqlite::Connection` may not be held across an `await`: the
/// transport runs first, the pipeline stays synchronous.
#[derive(Clone, Debug, Default)]
pub struct FixedSource {
    pub manifest: Vec<RawPage>,
    pub pages: std::collections::BTreeMap<u32, (Vec<u8>, String)>,
}

impl PageSource for FixedSource {
    fn fetch_pages(&mut self, _book_id: &str) -> Result<Vec<RawPage>, LoaderError> {
        Ok(self.manifest.clone())
    }

    fn fetch_page(
        &mut self,
        _book_id: &str,
        number: u32,
    ) -> Result<(Vec<u8>, String), LoaderError> {
        self.pages
            .get(&number)
            .cloned()
            .ok_or_else(|| LoaderError::Network(format!("page {number} was not pre-fetched")))
    }
}

/// How many times one page may be fetched and refused before the loader stops
/// asking. Two is enough to cover a transient proxy hiccup and small enough that
/// a genuinely broken page cannot generate a request per attempt forever.
pub const MAX_CORRUPT_ATTEMPTS: u32 = 2;

/// Outcome of one prefetch pass. Failures are recorded, never propagated: a
/// neighbor that could not load must not break the page on screen.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PrefetchReport {
    pub requested: Vec<u32>,
    pub loaded: Vec<u32>,
    pub failed: Vec<u32>,
    /// A subset of `failed`: refused for integrity, not for connectivity.
    pub corrupt: Vec<u32>,
    /// Bytes that landed in the memory tier during this pass.
    pub resident_bytes: i64,
}

pub struct ReaderLoader<F: PageSource> {
    book_id: String,
    manifest: PageManifest,
    manifest_source: ManifestSource,
    fetcher: F,
    cache: PageCache,
    /// Per-page count of fetched-then-refused responses for this session.
    corrupt_attempts: HashMap<u32, u32>,
}

impl<F: PageSource> ReaderLoader<F> {
    /// Open a book. With a mirrored manifest present this touches no network at
    /// all — which is what lets a previously-opened book reopen offline.
    #[allow(clippy::too_many_arguments)]
    pub fn open(
        conn: &Connection,
        server_id: &str,
        book_id: &str,
        book_media_type: Option<&str>,
        mut fetcher: F,
        cache: PageCache,
        now: &str,
        refresh_manifest: bool,
    ) -> Result<Self, LoaderError> {
        let mirrored = mirror::list(conn, server_id, book_id)?;
        let (manifest, manifest_source) = if !refresh_manifest && !mirrored.is_empty() {
            (
                PageManifest::from_rows(server_id, book_id, book_media_type, &mirrored),
                ManifestSource::Mirror,
            )
        } else {
            let raw = fetcher.fetch_pages(book_id)?;
            let manifest = PageManifest::from_raw(server_id, book_id, book_media_type, &raw);
            if manifest.empty_error() {
                // Keep whatever mirror exists: an outage on the manifest endpoint
                // must not destroy a readable book.
                return Err(LoaderError::Empty);
            }
            let rows: Vec<mirror::PageRow> =
                manifest.pages.iter().map(PageDescriptor::to_row).collect();
            mirror::replace(conn, server_id, book_id, &rows, now)?;
            (manifest, ManifestSource::Network)
        };
        Ok(ReaderLoader {
            book_id: book_id.to_string(),
            manifest,
            manifest_source,
            fetcher,
            cache,
            corrupt_attempts: HashMap::new(),
        })
    }

    pub fn manifest(&self) -> &PageManifest {
        &self.manifest
    }

    pub fn manifest_source(&self) -> ManifestSource {
        self.manifest_source
    }

    pub fn page_count(&self) -> u32 {
        self.manifest.page_count()
    }

    pub fn cache(&self) -> &PageCache {
        &self.cache
    }

    /// The injected source, read-only. The acceptance harness counts requests
    /// through it; nothing in the reader core looks at it.
    pub fn source(&self) -> &F {
        &self.fetcher
    }

    pub fn layout_for(
        &self,
        mode: ReadMode,
        direction: Direction,
        first_page_single: bool,
    ) -> Layout {
        layout(
            self.manifest.page_count(),
            mode,
            direction,
            first_page_single,
            &self.manifest.unpairable(),
        )
    }

    /// Cache-only lookup: what the UI renders when there is no connection, and
    /// the input to the next prefetch plan.
    pub fn cached_page(
        &self,
        conn: &Connection,
        number: u32,
        now: &str,
    ) -> Result<Option<PageRef>, LoaderError> {
        let key = self.manifest.cache_key(number);
        Ok(self.cache.lookup(conn, &key, now)?.map(|location| PageRef {
            number,
            path: location.path,
            size: location.size,
            source: Source::Cache,
        }))
    }

    pub fn cached_pages(&self, conn: &Connection) -> HashSet<u32> {
        self.cache.cached_pages(conn, &self.manifest)
    }

    /// Resolve one page for display. Cache first, then the network; a network
    /// failure leaves the cached copy (if any) in place, so an outage cannot
    /// turn a readable page into an error.
    pub fn page(
        &mut self,
        conn: &Connection,
        number: u32,
        now: &str,
    ) -> Result<PageRef, LoaderError> {
        if !self.manifest.is_paged() {
            return Err(LoaderError::NotPaged);
        }
        if number == 0 || number > self.manifest.page_count() {
            return Err(LoaderError::OutOfRange {
                page: number,
                page_count: self.manifest.page_count(),
            });
        }
        if let Some(hit) = self.cached_page(conn, number, now)? {
            return Ok(hit);
        }
        if self.corrupt_attempts.get(&number).copied().unwrap_or(0) >= MAX_CORRUPT_ATTEMPTS {
            // Not a fetch: the point of the counter is that this page stops
            // generating requests once the server has proven itself twice.
            return Err(LoaderError::Corrupt {
                page: number,
                reason: format!("gave up after {MAX_CORRUPT_ATTEMPTS} unusable responses"),
            });
        }
        let (bytes, content_type) = self.fetcher.fetch_page(&self.book_id, number)?;
        let key = self.manifest.cache_key(number);
        let declared = self.declared_size(number);
        match self
            .cache
            .store_tier(conn, &key, &bytes, &content_type, now, Tier::Page, declared)
        {
            Ok(location) => {
                self.corrupt_attempts.remove(&number);
                Ok(PageRef {
                    number,
                    path: location.path,
                    size: location.size,
                    source: Source::Network,
                })
            }
            Err(error) => Err(self.note_corruption(number, error)),
        }
    }

    /// The size the server itself reported for this page, when it reported one.
    /// This is the only witness that can prove a response arrived short.
    fn declared_size(&self, number: u32) -> Option<i64> {
        self.manifest
            .pages
            .get(number.wrapping_sub(1) as usize)
            .map(|page| page.size_bytes)
            .filter(|size| *size > 0)
    }

    /// Record a refused response and turn it into the error the UI shows.
    fn note_corruption(&mut self, number: u32, error: StoreError) -> LoaderError {
        if !error.is_corrupt() {
            return LoaderError::Disk(error.to_string());
        }
        let reason = error.reason();
        let attempts = self.corrupt_attempts.entry(number).or_insert(0);
        *attempts += 1;
        log::warn!("page {number} refused, attempt {attempts}: {reason}");
        LoaderError::Corrupt {
            page: number,
            reason,
        }
    }

    /// Pages this session has already failed to cache, with their attempt count.
    pub fn corrupt_attempts(&self) -> Vec<(u32, u32)> {
        let mut entries: Vec<(u32, u32)> = self
            .corrupt_attempts
            .iter()
            .map(|(k, v)| (*k, *v))
            .collect();
        entries.sort_unstable();
        entries
    }

    /// Land bytes that a caller already fetched (the FFI facade fetches
    /// asynchronously outside the store, then hands the result here). Returns
    /// the same shape `page` returns, so the UI cannot tell the two paths apart.
    pub fn store_page(
        &self,
        conn: &Connection,
        number: u32,
        bytes: &[u8],
        content_type: &str,
        now: &str,
    ) -> Result<PageRef, LoaderError> {
        if number == 0 || number > self.manifest.page_count() {
            return Err(LoaderError::OutOfRange {
                page: number,
                page_count: self.manifest.page_count(),
            });
        }
        let key = self.manifest.cache_key(number);
        let declared = self.declared_size(number);
        let location = self
            .cache
            .store_tier(conn, &key, bytes, content_type, now, Tier::Page, declared)
            .map_err(|error| match error {
                StoreError::Corrupt { reason } => LoaderError::Corrupt {
                    page: number,
                    reason,
                },
                other => LoaderError::Disk(other.to_string()),
            })?;
        Ok(PageRef {
            number,
            path: location.path,
            size: location.size,
            source: Source::Network,
        })
    }

    /// Prefetch the window around `center` (a spread index). Everything already
    /// cached is skipped before any request is made.
    pub fn prefetch(
        &mut self,
        conn: &Connection,
        spreads: &[Vec<u32>],
        center: usize,
        window: Window,
        now: &str,
    ) -> Result<PrefetchReport, LoaderError> {
        let cached = self.cache.cached_pages(conn, &self.manifest);
        let plan = plan(spreads, center, window, &cached);
        let mut report = PrefetchReport {
            requested: plan.queue.clone(),
            ..Default::default()
        };
        for number in plan.queue {
            let key = self.manifest.cache_key(number);
            if self.cache.is_cached(conn, &key) {
                continue;
            }
            if self.corrupt_attempts.get(&number).copied().unwrap_or(0) >= MAX_CORRUPT_ATTEMPTS {
                report.failed.push(number);
                continue;
            }
            match self.fetcher.fetch_page(&self.book_id, number) {
                Ok((bytes, content_type)) => {
                    let declared = self.declared_size(number);
                    match self.cache.store_tier(
                        conn,
                        &key,
                        &bytes,
                        &content_type,
                        now,
                        Tier::Prefetch,
                        declared,
                    ) {
                        Ok(_) => {
                            report.loaded.push(number);
                            report.resident_bytes += bytes.len() as i64;
                        }
                        Err(error) => {
                            report.failed.push(number);
                            if error.is_corrupt() {
                                report.corrupt.push(number);
                                let attempts = self.corrupt_attempts.entry(number).or_insert(0);
                                *attempts += 1;
                            }
                            // Stop on the first failure: a page that will not
                            // load is a server-side signal, and hammering the
                            // rest of the window turns one outage into N requests.
                            let _ = error;
                            break;
                        }
                    }
                }
                Err(error) => {
                    report.failed.push(number);
                    let _ = error;
                    break;
                }
            }
        }
        Ok(report)
    }
}

/// Durable reading state for one book: the display page plus the layout it was
/// shown with. Kept next to the loader because both are "what the reader saw".
pub fn save_position(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
    page: u32,
    mode: ReadMode,
    direction: Direction,
    now: &str,
) -> Result<(), LoaderError> {
    position::save(
        conn,
        server_id,
        book_id,
        page,
        mode.as_str(),
        direction.as_str(),
        now,
    )?;
    Ok(())
}

pub fn load_position(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> Result<Option<position::Position>, LoaderError> {
    Ok(position::get(conn, server_id, book_id)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cache::demo_png;
    use crate::reader::manifest::PageManifest;
    use crate::store::open_in_memory;
    use std::cell::RefCell;
    use uuid::Uuid;

    /// Scripted server: counts every call so the tests can prove that a
    /// second open and a cached page make none.
    struct Fake {
        pages: usize,
        page_calls: RefCell<Vec<u32>>,
        manifest_calls: RefCell<usize>,
        offline: bool,
    }

    impl Fake {
        fn online(pages: usize) -> Self {
            Fake {
                pages,
                page_calls: RefCell::new(Vec::new()),
                manifest_calls: RefCell::new(0),
                offline: false,
            }
        }

        fn offline(pages: usize) -> Self {
            let mut fake = Self::online(pages);
            fake.offline = true;
            fake
        }
    }

    impl PageSource for Fake {
        fn fetch_pages(&mut self, _book_id: &str) -> Result<Vec<RawPage>, LoaderError> {
            *self.manifest_calls.borrow_mut() += 1;
            if self.offline {
                return Err(LoaderError::Network("offline".to_string()));
            }
            Ok((1..=self.pages as i64)
                .map(|number| RawPage {
                    file_name: format!("{number:03}.png"),
                    media_type: "image/png".to_string(),
                    number,
                    width: Some(100),
                    height: Some(150),
                    size_bytes: Some(demo_png::demo_page_bytes(number as u32).len() as i64),
                })
                .collect())
        }

        fn fetch_page(
            &mut self,
            _book_id: &str,
            number: u32,
        ) -> Result<(Vec<u8>, String), LoaderError> {
            self.page_calls.borrow_mut().push(number);
            if self.offline {
                return Err(LoaderError::Network("offline".to_string()));
            }
            Ok((demo_png::demo_page_bytes(number), "image/png".to_string()))
        }
    }

    struct Temp {
        dir: PathBuf,
    }

    impl Temp {
        fn new() -> Self {
            Temp {
                dir: std::env::temp_dir().join(format!("komga_loader_{}", Uuid::new_v4())),
            }
        }
    }

    impl Drop for Temp {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.dir).ok();
        }
    }

    fn open_loader(
        conn: &Connection,
        fetcher: Fake,
        temp: &Temp,
        offline: bool,
    ) -> Result<ReaderLoader<Fake>, LoaderError> {
        ReaderLoader::open(
            conn,
            "srv",
            "book",
            Some("image/jpeg"),
            fetcher,
            PageCache::new(&temp.dir).unwrap(),
            if offline { "t-offline" } else { "t0" },
            false,
        )
    }

    #[test]
    fn first_open_mirrors_the_manifest_and_a_second_open_asks_for_nothing() {
        let conn = open_in_memory().unwrap();
        let temp = Temp::new();

        let mut loader = open_loader(&conn, Fake::online(5), &temp, false).unwrap();
        assert_eq!(loader.manifest_source(), ManifestSource::Network);
        assert_eq!(loader.page_count(), 5);
        assert_eq!(*loader.fetcher.manifest_calls.borrow(), 1);

        loader.page(&conn, 1, "t1").unwrap();
        let calls_after_first_page = loader.fetcher.page_calls.borrow().clone();
        drop(loader);

        // Reopening must be a pure database read: no manifest request at all.
        let reopened = open_loader(&conn, Fake::online(5), &temp, true).unwrap();
        assert_eq!(
            reopened.manifest_source(),
            ManifestSource::Mirror,
            "a mirrored manifest means an offline reopen is possible"
        );
        assert_eq!(reopened.page_count(), 5);
        assert_eq!(calls_after_first_page, vec![1]);
    }

    #[test]
    fn cached_pages_survive_a_dead_server_and_uncached_ones_report_network() {
        let conn = open_in_memory().unwrap();
        let temp = Temp::new();
        {
            let mut loader = open_loader(&conn, Fake::online(4), &temp, false).unwrap();
            for number in 1..=3 {
                let page = loader.page(&conn, number, "t1").unwrap();
                assert_eq!(page.source, Source::Network);
                assert_eq!(
                    page.size,
                    demo_png::demo_page_bytes(number).len() as i64,
                    "the cache accounts for what really landed"
                );
            }
        }

        let mut offline = open_loader(&conn, Fake::offline(4), &temp, true).unwrap();
        assert_eq!(offline.manifest_source(), ManifestSource::Mirror);
        for number in 1..=3 {
            let page = offline.page(&conn, number, "t2").unwrap();
            assert_eq!(
                page.source,
                Source::Cache,
                "page {number} must come from disk"
            );
            assert_eq!(
                std::fs::read(&page.path).unwrap(),
                demo_png::demo_page_bytes(number)
            );
        }
        // Page 4 was never fetched: the outage is visible, but as a network
        // error on that page only — not as a broken book.
        let missing = offline.page(&conn, 4, "t2").err().unwrap();
        assert!(matches!(missing, LoaderError::Network(_)), "{missing:?}");
        assert_eq!(
            offline.cached_pages(&conn),
            [1, 2, 3].into_iter().collect::<HashSet<u32>>()
        );
    }

    #[test]
    fn out_of_range_and_empty_books_are_explicit_states() {
        let conn = open_in_memory().unwrap();
        let temp = Temp::new();
        let mut loader = open_loader(&conn, Fake::online(3), &temp, false).unwrap();
        assert_eq!(
            loader.page(&conn, 4, "t1").err(),
            Some(LoaderError::OutOfRange {
                page: 4,
                page_count: 3
            })
        );
        assert_eq!(
            loader.page(&conn, 0, "t1").err(),
            Some(LoaderError::OutOfRange {
                page: 0,
                page_count: 3
            }),
            "page 0 is not a page"
        );

        struct Empty;
        impl PageSource for Empty {
            fn fetch_pages(&mut self, _: &str) -> Result<Vec<RawPage>, LoaderError> {
                Ok(Vec::new())
            }
            fn fetch_page(&mut self, _: &str, _: u32) -> Result<(Vec<u8>, String), LoaderError> {
                Err(LoaderError::Empty)
            }
        }
        let error = ReaderLoader::open(
            &conn,
            "srv",
            "empty-book",
            None,
            Empty,
            PageCache::new(temp.dir.join("empty")).unwrap(),
            "t1",
            false,
        )
        .err()
        .expect("an empty manifest must be a stated error state");
        assert_eq!(error, LoaderError::Empty);
    }

    #[test]
    fn a_reflowable_book_is_not_paged() {
        let conn = open_in_memory().unwrap();
        let temp = Temp::new();
        struct Epub;
        impl PageSource for Epub {
            fn fetch_pages(&mut self, _: &str) -> Result<Vec<RawPage>, LoaderError> {
                Ok(vec![RawPage {
                    file_name: "c1.xhtml".to_string(),
                    media_type: "application/xhtml+xml".to_string(),
                    number: 1,
                    width: None,
                    height: None,
                    size_bytes: None,
                }])
            }
            fn fetch_page(&mut self, _: &str, _: u32) -> Result<(Vec<u8>, String), LoaderError> {
                unreachable!("the loader must not request a page it cannot render")
            }
        }
        let mut loader = ReaderLoader::open(
            &conn,
            "srv",
            "epub-book",
            Some("application/epub+zip"),
            Epub,
            PageCache::new(temp.dir.join("epub")).unwrap(),
            "t1",
            false,
        )
        .unwrap();
        assert!(loader.manifest().reflowable);
        assert!(!loader.manifest().writes_page_progress());
        assert_eq!(
            loader.page(&conn, 1, "t2").err(),
            Some(LoaderError::NotPaged)
        );
    }

    #[test]
    fn prefetch_fills_the_window_and_stops_at_the_first_failure() {
        let conn = open_in_memory().unwrap();
        let temp = Temp::new();
        let mut loader = open_loader(&conn, Fake::online(10), &temp, false).unwrap();
        let spreads = loader
            .layout_for(ReadMode::Single, Direction::Ltr, false)
            .spreads;
        let report = loader
            .prefetch(
                &conn,
                &spreads,
                4,
                Window {
                    forward: 2,
                    back: 1,
                    cap: 12,
                },
                "t1",
            )
            .unwrap();
        assert_eq!(report.requested, vec![5, 6, 7, 4]);
        assert_eq!(report.loaded, vec![5, 6, 7, 4]);
        assert!(report.failed.is_empty());
        assert_eq!(loader.fetcher.page_calls.borrow().len(), 4);

        // Second pass over the same window: everything is warm, nothing leaves.
        let again = loader
            .prefetch(&conn, &spreads, 4, Window::default(), "t2")
            .unwrap();
        assert_eq!(again.requested, Vec::<u32>::new());
        assert_eq!(
            loader.fetcher.page_calls.borrow().len(),
            4,
            "a warm window is free"
        );

        let mut broken = open_loader(&conn, Fake::offline(10), &temp, true).unwrap();
        let report = broken
            .prefetch(
                &conn,
                &spreads,
                0,
                Window {
                    forward: 3,
                    back: 0,
                    cap: 12,
                },
                "t3",
            )
            .unwrap();
        assert_eq!(report.requested, vec![1, 2, 3], "page 4 is already warm");
        assert_eq!(
            (report.loaded.as_slice(), report.failed.as_slice()),
            (&[] as &[u32], &[1u32][..]),
            "the pass stops at the first failure instead of hammering an outage"
        );
    }

    #[test]
    fn position_round_trips_and_layout_follows_it() {
        let conn = open_in_memory().unwrap();
        save_position(
            &conn,
            "srv",
            "book",
            7,
            ReadMode::Double,
            Direction::Rtl,
            "t1",
        )
        .unwrap();
        let position = load_position(&conn, "srv", "book").unwrap().unwrap();
        assert_eq!(position.page, 7);
        assert_eq!(position.mode, "double");
        assert_eq!(position.direction, "rtl");

        let manifest = PageManifest::from_raw(
            "srv",
            "book",
            None,
            &(1..=10i64)
                .map(|number| RawPage {
                    file_name: String::new(),
                    media_type: "image/jpeg".to_string(),
                    number,
                    width: Some(100),
                    height: Some(150),
                    size_bytes: Some(1),
                })
                .collect::<Vec<_>>(),
        );
        let layout = layout(
            manifest.page_count(),
            ReadMode::Double,
            Direction::Rtl,
            false,
            &manifest.unpairable(),
        );
        let spread = layout.index_for_page(position.page as u32).unwrap();
        assert_eq!(spread, 3, "page 7 sits in the 4th spread");
        assert_eq!(layout.visual(spread), Some(vec![8, 7]));
    }
}
