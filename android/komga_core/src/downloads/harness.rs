//! Shared test fixtures for the download module: a real temp tree, a real SQLite
//! store, and a transport that can be told exactly what each page will do.
//!
//! The fake answers per page number rather than per call, so a test can say "page 3
//! is broken" and have the queue's behaviour around one bad page be the thing under
//! test. `requests` is the record of what the transport was actually asked for: every
//! claim in this stage about duplicate or missing fetches is checked against it, and
//! not against a self-reported counter elsewhere.
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;

use chrono::{TimeZone, Utc};
use rusqlite::Connection;

use crate::api::error::ApiError;
use crate::api::page::{PageDto, PageStreaming};
use crate::cache::demo_png;
use crate::downloads::{manifest::DownloadRoot, store};
use crate::store as core_store;

/// A fixed clock. Every timestamp in a test is derived from it, so a run is
/// replayable and a `next_retry_at` comparison cannot pass by accident because the
/// wall clock happened to move.
pub fn now() -> chrono::DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 8, 30, 5, 0, 0).unwrap()
}

/// A stamp `seconds` after [`now`], in the format the store writes.
pub fn stamp(seconds: i64) -> String {
    (now() + chrono::Duration::seconds(seconds)).to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

/// A database, a download tree beside it, and the directory holding both.
pub struct Tree {
    pub dir: PathBuf,
    pub db_path: PathBuf,
    pub root: DownloadRoot,
    pub conn: Connection,
}

impl Tree {
    pub fn new(tag: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("komga_downloads_{tag}_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).expect("temp dir");
        let db_path = dir.join("comic.sqlite");
        let conn = core_store::open(&db_path).expect("store opens");
        // The real derivation, not a hand-built path: asserting that the tree lands
        // beside `cache/` is only meaningful if it was produced the way production
        // produces it.
        let root = DownloadRoot::for_db(&db_path).expect("download root");
        // The real derivation must land beside the cache, not inside it: every
        // protection in this stage rests on that, and this is where it is proved.
        assert_eq!(root.root(), dir.join("downloads"));
        assert!(!root.root().starts_with(dir.join("cache")));
        Self {
            dir,
            db_path,
            root,
            conn,
        }
    }

    /// The cache root the reader uses, for the tests that prove the two trees are
    /// disjoint.
    pub fn cache_root(&self) -> PathBuf {
        self.dir.join("cache")
    }

    /// Every file under one book's directory, sorted, with the manifest excluded
    /// where a test only cares about pages.
    pub fn page_files(&self, server: &str, book: &str) -> Vec<String> {
        self.root
            .files_in(server, book)
            .into_iter()
            .filter(|name| name != "manifest.json")
            .collect()
    }

    pub fn bytes_on_disk(&self, server: &str, book: &str) -> u64 {
        self.root.book_bytes(server, book)
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// What the transport should do with one page.
#[derive(Debug, Clone)]
pub enum Fates {
    /// Real PNG bytes for that page number.
    Good,
    /// Bytes that arrived, but fewer than the manifest declared for the page.
    Short,
    /// A whole response that is not an image at all.
    Garbage,
    /// Nothing arrived: the route failed.
    Unreachable,
    /// The server rejected the credential.
    Rejected,
    /// The page is not on the server any more.
    Missing,
    /// Too slow to be worth a request, and too small to be a page.
    Empty,
}

/// The mid-pass hook's shape, named because a `RefCell<Option<Box<dyn Fn(usize)>>>`
/// inline is the sort of type that makes a reader give up on the line.
pub type RequestHook = Box<dyn Fn(usize)>;

/// A transport that answers from a per-page table and remembers every ask.
pub struct FakePages {
    fates: RefCell<HashMap<u32, Fates>>,
    default: RefCell<Fates>,
    pub requests: RefCell<Vec<u32>>,
    /// Called after each request with the count so far. This is how a test delivers
    /// a user gesture *during* a pass rather than only before or after it.
    pub after_request: RefCell<Option<RequestHook>>,
}

impl FakePages {
    pub fn new() -> Self {
        Self {
            fates: RefCell::new(HashMap::new()),
            default: RefCell::new(Fates::Good),
            requests: RefCell::new(Vec::new()),
            after_request: RefCell::new(None),
        }
    }

    pub fn with_pages(count: u32) -> Self {
        let fake = Self::new();
        for number in 1..=count {
            fake.set(number, Fates::Good);
        }
        fake
    }

    pub fn set(&self, number: u32, fate: Fates) {
        self.fates.borrow_mut().insert(number, fate);
    }

    pub fn set_default(&self, fate: Fates) {
        *self.default.borrow_mut() = fate;
    }

    pub fn asked(&self) -> Vec<u32> {
        self.requests.borrow().clone()
    }

    pub fn asked_count(&self) -> usize {
        self.requests.borrow().len()
    }

    pub fn distinct(&self) -> usize {
        let mut asked = self.asked();
        asked.sort_unstable();
        asked.dedup();
        asked.len()
    }
}

impl Default for FakePages {
    fn default() -> Self {
        Self::new()
    }
}

#[allow(async_fn_in_trait)]
impl PageStreaming for FakePages {
    async fn pages(&self, _book_id: &str) -> Result<Vec<PageDto>, ApiError> {
        Ok(Vec::new())
    }

    async fn page_bytes(&self, _book_id: &str, number: u32) -> Result<(Vec<u8>, String), ApiError> {
        let count = {
            self.requests.borrow_mut().push(number);
            self.requests.borrow().len()
        };
        let fate = self
            .fates
            .borrow()
            .get(&number)
            .cloned()
            .unwrap_or_else(|| self.default.borrow().clone());
        if let Some(hook) = self.after_request.borrow().as_ref() {
            hook(count);
        }
        match fate {
            Fates::Good => Ok((demo_png::demo_page_bytes(number), "image/png".to_string())),
            // Whole, decodable, and smaller than the manifest said. The one shape a
            // container walk cannot tell from a genuinely small page, which is why
            // the declared size is the only witness that has ever been able to.
            Fates::Short => {
                let mut bytes = demo_png::demo_page_bytes(number);
                bytes.truncate(bytes.len() / 2);
                Ok((bytes, "image/png".to_string()))
            }
            Fates::Garbage => Ok((
                b"<html><body>500 Internal Server Error</body></html>".to_vec(),
                "text/html".to_string(),
            )),
            Fates::Empty => Ok((Vec::new(), "image/png".to_string())),
            Fates::Unreachable => Err(ApiError::Network),
            Fates::Rejected => Err(ApiError::Authentication),
            Fates::Missing => Err(ApiError::Server { status_code: 404 }),
        }
    }
}

/// Enqueue a book the way the facade does: mirror the manifest, lay out the page
/// rows, then create the directory and its self-describing empty `manifest.json`.
/// All four here is what lets a test write a page file without thinking about `mkdir`,
/// and it keeps the harness on the same path production takes.
pub fn enqueue_book(tree: &Tree, server: &str, book: &str, pages: u32) -> store::DownloadRow {
    let numbers: Vec<u32> = (1..=pages).collect();
    let bytes_total: i64 = numbers
        .iter()
        .map(|number| demo_png::demo_page_bytes(*number).len() as i64)
        .sum();
    mirror_manifest(tree, server, book, &numbers);
    let created = store::enqueue(
        &tree.conn,
        &store::NewDownload {
            server_id: server.to_string(),
            book_id: book.to_string(),
            pages_total: pages,
            bytes_total,
            manifest_path: tree
                .root
                .manifest_path(server, book)
                .to_string_lossy()
                .into_owned(),
            remote_last_modified: Some("2024-05-11T18:07:33Z".to_string()),
            book_title: Some(format!("Book {book}")),
            series_title: Some("Series One".to_string()),
        },
        &numbers,
        &stamp(0),
    )
    .expect("enqueue");
    create_tree_for(tree, server, book, pages);
    created
}

/// The directory and empty-manifest half of an enqueue, shared with the facade's own
/// implementation: the directory exists and is self-describing before a single page
/// byte has arrived, which is what makes a half-finished download legible to a sweep,
/// to a user reading the folder, and to a restore after a crash.
pub fn create_tree_for(tree: &Tree, server: &str, book: &str, pages: u32) {
    use crate::downloads::manifest::{self, DownloadManifest};
    std::fs::create_dir_all(tree.root.book_dir(server, book)).expect("book dir");
    manifest::write_manifest(
        &tree.root.manifest_path(server, book),
        &DownloadManifest::empty(server, book, pages, &stamp(0)),
    )
    .expect("initial manifest");
}

/// Fill `book_pages` the way `App::reader_open` would, because the declared sizes the
/// byte budget works from come from there and nowhere else.
pub fn mirror_manifest(tree: &Tree, server: &str, book: &str, numbers: &[u32]) {
    for number in numbers {
        let (width, height) = demo_png::page_dimensions(*number);
        let size = demo_png::demo_page_bytes(*number).len() as i64;
        tree.conn
            .execute(
                "INSERT OR REPLACE INTO book_pages
                 (server_id, book_id, number, file_name, media_type, width, height, size_bytes, fetched_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                rusqlite::params![
                    server,
                    book,
                    *number as i64,
                    format!("{number:04}.png"),
                    "image/png",
                    width as i64,
                    height as i64,
                    size,
                    stamp(0)
                ],
            )
            .expect("mirror page");
    }
}

/// The fixture directory, shared with the Swift tests by path.
pub fn fixture(name: &str) -> serde_json::Value {
    let path = format!(
        "{}/../../specs/contracts/fixtures/downloads/{name}",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {path}: {error}"));
    serde_json::from_str(&text).unwrap_or_else(|error| panic!("cannot decode {path}: {error}"))
}
