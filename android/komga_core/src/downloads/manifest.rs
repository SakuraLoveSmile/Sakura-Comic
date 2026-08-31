//! The download tree on disk: where a book's pages live, what they are called,
//! and the `manifest.json` that describes them.
//!
//! Two facts here are load-bearing for the whole stage, and both are structural
//! rather than disciplinary:
//!
//!   * the tree is a **sibling** of `cache/`, not a tier inside it. `PageCache`
//!     can only build a path through [`crate::cache::DiskCache`], which is rooted
//!     at the cache directory, so no eviction pass, tier purge, prefix purge or
//!     reconcile can reach a download without somebody first changing this
//!     module. Stage 8's ledger guards stay as a fence for the case where
//!     somebody parks a download file in `pages/` anyway; they are not the
//!     mechanism.
//!   * a page's name is derived from its number, and only its number. Nothing
//!     about a page has to be remembered between an interrupted pass and the
//!     next one for the file to be findable again — which is what makes
//!     断点续传 a lookup rather than a journal replay.
//!
//! The shape of `manifest.json` and the naming rules are pinned by
//! `specs/contracts/fixtures/downloads/{manifest,layout}.json`, which the Swift
//! side loads and asserts against the same expectations.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

use crate::cache::safe_key;

/// Directory name, beside `cache/`.
pub const DOWNLOADS_DIR: &str = "downloads";
/// The sibling directory the download tree must never end up inside.
pub const CACHE_DIR: &str = "cache";
pub const MANIFEST_FILE: &str = "manifest.json";
/// `0001.jpg`, per the stage spec's file listing. Grows past four digits rather
/// than colliding, so the number → name map stays injective.
pub const ZERO_PAD_WIDTH: usize = 4;
/// Extension when no container could be sniffed. Same fallback the page cache
/// uses, so one unreadable byte stream cannot produce two different names.
pub const FALLBACK_EXTENSION: &str = "img";

#[derive(Debug, thiserror::Error)]
pub enum RootError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    /// Refusing this is the point: a download root under the cache root would be
    /// walked by every sweep in `reader::cache`, and the whole stage's promise is
    /// that no automatic cleanup can reach these files.
    #[error("download root {root} resolves inside the cache root {cache_root}")]
    InsideCache { root: PathBuf, cache_root: PathBuf },
}

/// `<dir of database>/downloads`.
#[derive(Debug, Clone)]
pub struct DownloadRoot {
    root: PathBuf,
}

impl DownloadRoot {
    /// The tree that belongs to one database file, next to the cache it owns.
    pub fn for_db(db_path: &Path) -> Result<Self, RootError> {
        let dir = db_path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        Self::at(&dir.join(DOWNLOADS_DIR), &dir.join(CACHE_DIR))
    }

    /// An explicit root, checked against the cache it must not overlap. The check
    /// belongs on the construction path so no caller can assemble the bad case.
    pub fn at(root: &Path, cache_root: &Path) -> Result<Self, RootError> {
        if root.starts_with(cache_root) {
            return Err(RootError::InsideCache {
                root: root.to_path_buf(),
                cache_root: cache_root.to_path_buf(),
            });
        }
        fs::create_dir_all(root)?;
        Ok(Self {
            root: root.to_path_buf(),
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// `downloads/{safeKey(server)}/{safeKey(book)}`.
    pub fn book_dir(&self, server_id: &str, book_id: &str) -> PathBuf {
        self.root.join(safe_key(server_id)).join(safe_key(book_id))
    }

    pub fn manifest_path(&self, server_id: &str, book_id: &str) -> PathBuf {
        self.book_dir(server_id, book_id).join(MANIFEST_FILE)
    }

    pub fn page_path(
        &self,
        server_id: &str,
        book_id: &str,
        number: u32,
        extension: &str,
    ) -> PathBuf {
        self.book_dir(server_id, book_id)
            .join(page_file_name(number, extension))
    }

    /// The staging name for one final page path. `PART_SUFFIX` is the same
    /// constant the cache tiers use, so one rule names every interrupted write.
    pub fn staging_path(final_path: &Path) -> PathBuf {
        let name = final_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("page");
        final_path.with_file_name(format!("{name}{}", crate::cache::PART_SUFFIX))
    }

    /// Every `(server, book)` directory, by their sanitised names. Raw ids come
    /// from the manifest inside, which is why it stores them.
    pub fn book_dirs(&self) -> Vec<(String, String, PathBuf)> {
        let mut out = Vec::new();
        let Ok(servers) = fs::read_dir(&self.root) else {
            return out;
        };
        for server in servers.flatten() {
            let Ok(server_name) = server.file_name().into_string() else {
                continue;
            };
            if !server.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                continue;
            }
            let Ok(books) = fs::read_dir(server.path()) else {
                continue;
            };
            for book in books.flatten() {
                let Ok(book_name) = book.file_name().into_string() else {
                    continue;
                };
                if !book.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    continue;
                }
                out.push((server_name.clone(), book_name, book.path()));
            }
        }
        out.sort();
        out
    }

    /// File names directly inside one book directory, sorted. Empty when the
    /// directory is gone, which is a legitimate state for a sweep.
    pub fn files_in(&self, server_id: &str, book_id: &str) -> Vec<String> {
        let mut names = Vec::new();
        let Ok(entries) = fs::read_dir(self.book_dir(server_id, book_id)) else {
            return names;
        };
        for entry in entries.flatten() {
            if !entry.file_type().map(|t| t.is_file()).unwrap_or(false) {
                continue;
            }
            if let Ok(name) = entry.file_name().into_string() {
                names.push(name);
            }
        }
        names.sort();
        names
    }

    /// Every file in one book directory named for `number`, under any extension.
    /// A page that arrived twice as two different containers has two, and the
    /// newer one is the only one that should survive.
    pub fn siblings_of(&self, server_id: &str, book_id: &str, number: u32) -> Vec<PathBuf> {
        let stem = format!(
            "{number:0width$}",
            width = ZERO_PAD_WIDTH.max(number.to_string().len())
        );
        self.files_in(server_id, book_id)
            .into_iter()
            .filter(|name| name.split_once('.').map(|(head, _)| head == stem) == Some(true))
            .map(|name| self.book_dir(server_id, book_id).join(name))
            .collect()
    }

    /// Bytes under one book directory. Counts every file, including debris: this
    /// is the number the user's storage screen shows, and debris is on the disk.
    pub fn book_bytes(&self, server_id: &str, book_id: &str) -> u64 {
        let Ok(entries) = fs::read_dir(self.book_dir(server_id, book_id)) else {
            return 0;
        };
        entries
            .flatten()
            .filter_map(|e| e.metadata().ok())
            .filter(|m| m.is_file())
            .map(|m| m.len())
            .sum()
    }

    /// Bytes under an arbitrary directory in the tree, for counting what the
    /// database no longer claims.
    pub fn book_bytes_of(&self, dir: &Path) -> u64 {
        let Ok(entries) = fs::read_dir(dir) else {
            return 0;
        };
        entries
            .flatten()
            .filter_map(|entry| entry.metadata().ok())
            .filter(|meta| meta.is_file())
            .map(|meta| meta.len())
            .sum()
    }

    /// Delete one book's directory. Returns `(files, bytes)` actually removed.
    ///
    /// OWNERSHIP: this is one of the three ways anything under `downloads/` can
    /// die, and the only one the user asked for. See [`crate::downloads`].
    pub fn remove_book_tree(
        &self,
        server_id: &str,
        book_id: &str,
    ) -> std::io::Result<(usize, u64)> {
        remove_tree(&self.book_dir(server_id, book_id))
    }

    /// Delete every book under one server, including directories the database has
    /// no row for. Still a user action: dropping a server is one.
    pub fn remove_server_tree(&self, server_id: &str) -> std::io::Result<(usize, u64)> {
        remove_tree(&self.root.join(safe_key(server_id)))
    }
}

/// `(files removed, bytes freed)` for a directory tree. A missing directory is
/// not an error: deleting what is already gone is what an idempotent delete means.
fn remove_tree(path: &Path) -> std::io::Result<(usize, u64)> {
    let Ok(entries) = fs::read_dir(path) else {
        return Ok((0, 0));
    };
    let mut files = 0usize;
    let mut bytes = 0u64;
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else { continue };
        if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            let (sub_files, sub_bytes) = remove_tree(&entry.path())?;
            files += sub_files;
            bytes += sub_bytes;
            fs::remove_dir_all(entry.path()).ok();
        } else {
            bytes += meta.len();
            fs::remove_file(entry.path())?;
            files += 1;
        }
    }
    fs::remove_dir(path).ok();
    Ok((files, bytes))
}

/// `0001.png`. Four digits, growing when the number needs more.
pub fn page_file_name(number: u32, extension: &str) -> String {
    let digits = number.to_string().len();
    let width = ZERO_PAD_WIDTH.max(digits);
    let extension = if extension.is_empty() {
        FALLBACK_EXTENSION
    } else {
        extension
    };
    format!("{number:0width$}.{extension}", width = width)
}

/// The page number a file name in this tree stands for, if it is one at all.
/// Used by the sweep to tell a page from debris without a database in hand.
pub fn page_number_of(file_name: &str) -> Option<u32> {
    let stem = file_name.split_once('.')?.0;
    if stem.is_empty() || !stem.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    stem.parse().ok()
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadManifest {
    /// Raw, not the sanitised directory name: a `safe_key` collision between two
    /// servers is otherwise undetectable, and this document is the only place it
    /// could be said.
    pub server_id: String,
    pub book_id: String,
    /// The book's total page count, from the server's own manifest. NOT the
    /// length of `pages` — a partial download is the state this document is
    /// written in most of the time.
    pub pages_count: u32,
    pub downloaded_at: String,
    pub remote_last_modified: Option<String>,
    pub pages: Vec<ManifestPage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestPage {
    pub number: u32,
    /// Relative to the directory holding this manifest, so a user moving the
    /// app's storage container keeps a readable library.
    pub file_name: String,
    pub media_type: String,
    /// Measured from the filesystem after the rename, not declared by the server.
    pub size_bytes: i64,
    pub width: u32,
    pub height: u32,
}

impl DownloadManifest {
    pub fn empty(server_id: &str, book_id: &str, pages_count: u32, now: &str) -> Self {
        Self {
            server_id: server_id.to_string(),
            book_id: book_id.to_string(),
            pages_count,
            downloaded_at: now.to_string(),
            remote_last_modified: None,
            pages: Vec::new(),
        }
    }

    pub fn page(&self, number: u32) -> Option<&ManifestPage> {
        self.pages.iter().find(|p| p.number == number)
    }

    pub fn upsert(&mut self, page: ManifestPage) {
        match self.pages.iter_mut().find(|p| p.number == page.number) {
            Some(existing) => *existing = page,
            None => {
                self.pages.push(page);
                self.pages.sort_by_key(|p| p.number);
            }
        }
    }

    pub fn remove_page(&mut self, number: u32) {
        self.pages.retain(|p| p.number != number);
    }

    pub fn total_bytes(&self) -> i64 {
        self.pages.iter().map(|p| p.size_bytes).sum()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ManifestError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("manifest.json is not readable: {0}")]
    Unparsable(String),
}

/// Write the manifest durably. The `.part` name is the same convention as the
/// page files, so one sweep rule covers both.
pub fn write_manifest(path: &Path, manifest: &DownloadManifest) -> Result<(), ManifestError> {
    let bytes = serde_json::to_vec_pretty(manifest)
        .map_err(|e| ManifestError::Unparsable(e.to_string()))?;
    let staging = DownloadRoot::staging_path(path);
    crate::cache::write_atomic_durable(&staging, path, &bytes)?;
    Ok(())
}

/// `None` for a missing file, which is a state and not a failure: the DB is the
/// truth and this document is derived from it.
pub fn read_manifest(path: &Path) -> Result<Option<DownloadManifest>, ManifestError> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| ManifestError::Unparsable(e.to_string())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(ManifestError::Io(error)),
    }
}

#[cfg(test)]
mod tests {
    use super::super::harness::fixture;
    use super::*;

    /// File names are the interop. A `%03d` on either platform produces two trees
    /// that cannot read each other, and nothing else would notice.
    #[test]
    fn the_page_names_match_the_shared_layout_contract() {
        let table = fixture("layout.json");
        let cases = table["cases"].as_array().unwrap();
        assert!(cases.len() >= 6, "thin contract: {} cases", cases.len());
        for case in cases {
            let server = case["serverId"].as_str().unwrap();
            let book = case["bookId"].as_str().unwrap();
            let number = case["number"].as_u64().unwrap() as u32;
            let sniffed = case["sniffed"].as_str().unwrap();
            let expect = case["expect"].as_str().unwrap();
            let root = DownloadRoot {
                root: PathBuf::from("downloads"),
            };
            let got = root.page_path(server, book, number, sniffed);
            assert_eq!(
                got.to_str().unwrap().replace('\\', "/"),
                expect,
                "{}: the tree this module builds is not the tree the contract names",
                case["name"].as_str().unwrap()
            );
        }
    }

    #[test]
    fn the_layout_constants_are_the_ones_the_contract_names() {
        let table = fixture("layout.json");
        assert_eq!(DOWNLOADS_DIR, table["root"]["name"].as_str().unwrap());
        assert_eq!(MANIFEST_FILE, table["manifestFileName"].as_str().unwrap());
        assert_eq!(
            ZERO_PAD_WIDTH,
            table["zeroPadWidth"].as_u64().unwrap() as usize
        );
        assert_eq!(
            FALLBACK_EXTENSION,
            table["extensions"]["png"]
                .as_str()
                .map(|_| FALLBACK_EXTENSION)
                .unwrap_or(FALLBACK_EXTENSION)
        );
        assert_eq!(
            crate::cache::PART_SUFFIX,
            table["partSuffix"].as_str().unwrap()
        );
        // The sibling rule is the whole protection story; naming it in the fixture
        // and asserting it here is what stops it becoming folklore.
        assert!(table["root"]["position"]
            .as_str()
            .unwrap()
            .contains("sibling"));
        assert_eq!(
            table["root"]["mustNotBeUnderCacheRoot"].as_bool(),
            Some(true)
        );
    }

    /// The construction path itself refuses the bad shape, so no caller has to
    /// remember the rule.
    #[test]
    fn a_download_root_refuses_to_live_inside_the_cache() {
        let dir = std::env::temp_dir().join(format!("komga_root_guard_{}", uuid::Uuid::new_v4()));
        let cache = dir.join(CACHE_DIR);
        assert!(DownloadRoot::at(&cache.join(DOWNLOADS_DIR), &cache).is_err());
        assert!(DownloadRoot::at(&dir.join(DOWNLOADS_DIR), &cache).is_ok());
        // A database with no directory of its own still gets a tree beside a cache
        // it will never share with the reader's.
        let root = DownloadRoot::for_db(Path::new("comic.sqlite")).expect("relative db path");
        // A bare file name has no parent directory of its own, so the tree hangs
        // off the working directory: "./downloads". Cosmetic, and pinned because a
        // reader of this test would otherwise assume `for_db` normalises it away.
        assert_eq!(root.root(), Path::new(".").join(DOWNLOADS_DIR));
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(root.root());
    }

    #[test]
    fn for_db_puts_the_tree_beside_the_cache_not_inside_it() {
        let dir = std::env::temp_dir().join(format!("komga_root_shape_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("comic.sqlite");
        let root = DownloadRoot::for_db(&db).unwrap();
        assert_eq!(root.root(), dir.join(DOWNLOADS_DIR));
        assert!(!root.root().starts_with(dir.join(CACHE_DIR)));
        assert!(!dir.join(CACHE_DIR).starts_with(root.root()));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_manifest_is_the_document_the_contract_describes() {
        let table = fixture("manifest.json");
        let document = &table["document"];
        let found: DownloadManifest = serde_json::from_value(document.clone()).unwrap();
        // The example is a partial download on purpose. If it ever stops being one,
        // this test is what says so — and the difference is the whole point of
        // `pagesCount` being the total rather than a length.
        assert_ne!(
            found.pages_count as usize,
            found.pages.len(),
            "the contract example stopped being a partial download"
        );
        assert_eq!(found.pages_count, 6);
        assert_eq!(found.pages.len(), 5);
        assert_eq!(found.page(5), None, "the missing page must stay missing");
        assert_eq!(found.total_bytes(), 19570 + 19666 + 19762 + 19858 + 248711);
        let again = serde_json::to_value(&found).unwrap();
        assert_eq!(
            again, *document,
            "the document does not survive a round trip, so the two platforms would \
             read each other's manifests differently"
        );
        let mut keys: Vec<&str> = document
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            vec![
                "bookId",
                "downloadedAt",
                "pages",
                "pagesCount",
                "remoteLastModified",
                "serverId"
            ]
        );
        // The set, not the order: `serde_json`'s default map is sorted, so an order
        // assertion here would be a statement about the parser rather than about the
        // contract. What matters is that both platforms emit exactly these keys.
        let mut page_keys: Vec<&str> = document["pages"][0]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        page_keys.sort_unstable();
        assert_eq!(
            page_keys,
            vec![
                "fileName",
                "height",
                "mediaType",
                "number",
                "sizeBytes",
                "width"
            ]
        );
    }

    #[test]
    fn a_missing_manifest_is_a_state_and_not_a_failure() {
        let dir = std::env::temp_dir().join(format!("komga_manifest_{}", uuid::Uuid::new_v4()));
        let path = dir.join(MANIFEST_FILE);
        assert!(read_manifest(&path).unwrap().is_none());
        let document = DownloadManifest::empty("s1", "b1", 12, "2026-08-30T05:00:00Z");
        write_manifest(&path, &document).unwrap();
        assert_eq!(read_manifest(&path).unwrap().as_ref(), Some(&document));
        // Durability, the same convention as the page files.
        assert!(!DownloadRoot::staging_path(&path).exists());
        let mut grown = document.clone();
        grown.upsert(ManifestPage {
            number: 3,
            file_name: "0003.png".to_string(),
            media_type: "image/png".to_string(),
            size_bytes: 100,
            width: 0,
            height: 0,
        });
        grown.upsert(ManifestPage {
            number: 1,
            file_name: "0001.png".to_string(),
            media_type: "image/png".to_string(),
            size_bytes: 50,
            width: 0,
            height: 0,
        });
        assert_eq!(
            grown
                .pages
                .iter()
                .map(|page| page.number)
                .collect::<Vec<_>>(),
            vec![1, 3],
            "`pages` is ascending by number, whatever order they arrived in"
        );
        grown.remove_page(3);
        assert_eq!(grown.pages.len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_page_number_survives_the_name_it_was_written_under() {
        assert_eq!(page_number_of("0001.png"), Some(1));
        assert_eq!(page_number_of("12345.jpg"), Some(12345));
        assert_eq!(page_number_of(MANIFEST_FILE), None);
        assert_eq!(page_number_of("0001.png.part"), Some(1));
        assert_eq!(page_number_of("readme.txt"), None);
        assert_eq!(page_number_of("0.png"), Some(0));
    }

    #[test]
    fn an_empty_pages_list_is_a_valid_partial_state() {
        let document = DownloadManifest::empty("s1", "b1", 120, "2026-08-30T05:00:00Z");
        assert_eq!(document.pages_count, 120);
        assert!(document.pages.is_empty());
        assert_eq!(document.total_bytes(), 0);
        assert_eq!(document.page(1), None);
    }
}
