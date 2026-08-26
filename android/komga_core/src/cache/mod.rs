//! Disk cache (thumbnails / pages) with LRU-friendly layout:
//!
//!   cache/
//!   ├── thumbnails/
//!   └── pages/
//!
//! Phase 0 ships filesystem primitives; LRU eviction and size limits land
//! with cache_entries bookkeeping (docs/offline-storage.md). LRU must never
//! evict offline downloads.

pub mod cover;

use std::fs;
use std::path::{Path, PathBuf};

const THUMBNAILS: &str = "thumbnails";
const PAGES: &str = "pages";

pub struct DiskCache {
    root: PathBuf,
}

impl DiskCache {
    /// root is the .../cache directory; thumbnails/ and pages/ are created below it.
    pub fn new(root: impl AsRef<Path>) -> std::io::Result<Self> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(root.join(THUMBNAILS))?;
        fs::create_dir_all(root.join(PAGES))?;
        Ok(Self { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn thumbnail_path(&self, key: &str) -> PathBuf {
        self.root.join(THUMBNAILS).join(safe_key(key))
    }

    pub fn page_path(&self, key: &str) -> PathBuf {
        self.root.join(PAGES).join(safe_key(key))
    }

    /// Write bytes under thumbnails/ and return the file path.
    pub fn store_thumbnail(&self, key: &str, bytes: &[u8]) -> std::io::Result<PathBuf> {
        let path = self.thumbnail_path(key);
        fs::write(&path, bytes)?;
        Ok(path)
    }

    pub fn load(&self, path: &Path) -> std::io::Result<Vec<u8>> {
        fs::read(path)
    }

    pub fn exists(&self, path: &Path) -> bool {
        path.exists()
    }

    /// Remove a cached file; missing files are treated as success.
    pub fn remove(&self, path: &Path) -> std::io::Result<()> {
        match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e),
        }
    }

    /// Total bytes currently stored in thumbnails/ and pages/.
    pub fn bytes_used(&self) -> std::io::Result<u64> {
        let mut total = 0u64;
        for dir in [THUMBNAILS, PAGES] {
            for entry in fs::read_dir(self.root.join(dir))? {
                let entry = entry?;
                if entry.file_type()?.is_file() {
                    total += entry.metadata()?.len();
                }
            }
        }
        Ok(total)
    }
}

/// Cache key for a series cover (multi-server safe).
pub fn cover_key(server_id: &str, series_id: &str) -> String {
    safe_key(&format!("{server_id}-{series_id}"))
}

/// Keys become filenames: keep only [A-Za-z0-9._-], everything else -> '_'.
pub fn safe_key(key: &str) -> String {
    key.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn temp_root() -> PathBuf {
        std::env::temp_dir().join(format!("komga_cache_test_{}", Uuid::new_v4()))
    }

    #[test]
    fn store_load_remove_and_accounting() {
        let root = temp_root();
        let cache = DiskCache::new(&root).unwrap();

        let path = cache
            .store_thumbnail("srv-1-series-1", b"cover-bytes")
            .unwrap();
        assert!(cache.exists(&path));
        assert_eq!(cache.load(&path).unwrap(), b"cover-bytes");

        let expected = cache.thumbnail_path("srv-1-series-1");
        assert_eq!(path, expected);

        let used = cache.bytes_used().unwrap();
        assert_eq!(used, b"cover-bytes".len() as u64);

        cache.remove(&path).unwrap();
        assert!(!cache.exists(&path));
        assert_eq!(cache.bytes_used().unwrap(), 0);

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn safe_key_sanitizes_path_characters() {
        assert_eq!(safe_key("srv-1/series-1"), "srv-1_series-1");
        assert_eq!(safe_key("abc.def-ghi_jkl"), "abc.def-ghi_jkl");
        assert_eq!(cover_key("server A", "series 1"), "server_A-series_1");
    }
}
