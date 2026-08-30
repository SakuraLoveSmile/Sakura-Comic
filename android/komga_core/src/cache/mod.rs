//! Disk cache with the three tiers the reader needs:
//!
//!   cache/
//!   ├── thumbnails/   covers, keyed per entity
//!   ├── pages/        bytes the reader actually displayed, plus offline downloads
//!   └── prefetch/     bytes pulled ahead of the reader and not yet looked at
//!
//! The split between `pages/` and `prefetch/` is what makes eviction honest:
//! unseen bytes are worth less than seen bytes, so they are always the first
//! victims (`store::cache::evict_to_budget`). LRU accounting lives in the
//! `cache_entries` ledger, not on the filesystem; these are the primitives.

pub mod cover;
pub mod demo_png;

use std::fs;
use std::path::{Path, PathBuf};

pub const THUMBNAILS_DIR: &str = "thumbnails";
pub const PAGES_DIR: &str = "pages";
pub const PREFETCH_DIR: &str = "prefetch";

/// Every tier, in the order a sweep should walk them.
pub const TIERS: [&str; 3] = [THUMBNAILS_DIR, PAGES_DIR, PREFETCH_DIR];

/// Suffix a partially written file carries. It is never a cache candidate, so
/// anything found with it during a sweep is debris from an interrupted write.
pub const PART_SUFFIX: &str = ".part";

pub struct DiskCache {
    root: PathBuf,
}

impl DiskCache {
    /// root is the .../cache directory; the three tier directories are created
    /// below it so a later path build never needs to mkdir.
    pub fn new(root: impl AsRef<Path>) -> std::io::Result<Self> {
        let root = root.as_ref().to_path_buf();
        for tier in TIERS {
            fs::create_dir_all(root.join(tier))?;
        }
        Ok(Self { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn thumbnail_path(&self, key: &str) -> PathBuf {
        self.root.join(THUMBNAILS_DIR).join(safe_key(key))
    }

    pub fn page_path(&self, key: &str) -> PathBuf {
        self.root.join(PAGES_DIR).join(safe_key(key))
    }

    pub fn prefetch_path(&self, key: &str) -> PathBuf {
        self.root.join(PREFETCH_DIR).join(safe_key(key))
    }

    /// Move a file from one tier's directory to another's, keeping its name.
    /// This is the prefetch-to-page promotion, and it must stay a rename:
    /// copying a 24 MB page to promote it would cost the reader a frame.
    pub fn relocate(&self, from: &Path, to_tier: &str) -> std::io::Result<PathBuf> {
        let name = from
            .file_name()
            .ok_or_else(|| std::io::Error::other("cache path has no file name"))?;
        let target = self.root.join(to_tier).join(name);
        match fs::rename(from, &target) {
            Ok(()) => Ok(target),
            // Same filesystem by construction, so this is the rare
            // cross-device/exfat case; a copy is slow but correct.
            Err(_) => {
                fs::copy(from, &target)?;
                fs::remove_file(from)?;
                Ok(target)
            }
        }
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

    /// File names present in one tier directory. Empty when the directory is
    /// gone, which is a legitimate state for a sweep (nothing to reconcile).
    pub fn files_in(&self, tier: &str) -> std::io::Result<Vec<String>> {
        let Ok(entries) = fs::read_dir(self.root.join(tier)) else {
            return Ok(Vec::new());
        };
        let mut names = Vec::new();
        for entry in entries {
            let entry = entry?;
            if entry.file_type()?.is_file() {
                if let Some(name) = entry.file_name().to_str() {
                    names.push(name.to_string());
                }
            }
        }
        names.sort();
        Ok(names)
    }

    /// Delete every `*.part` staging file. A download that was interrupted
    /// leaves one behind, and nothing ever reads it, so it is pure waste.
    /// Returns how many files were removed.
    pub fn remove_stale_parts(&self) -> std::io::Result<usize> {
        let mut removed = 0usize;
        for tier in TIERS {
            for name in self.files_in(tier)? {
                if name.ends_with(PART_SUFFIX) {
                    let path = self.root.join(tier).join(name);
                    fs::remove_file(&path)?;
                    removed += 1;
                }
            }
        }
        Ok(removed)
    }

    /// Total bytes currently stored in all three tiers.
    pub fn bytes_used(&self) -> std::io::Result<u64> {
        let mut total = 0u64;
        for dir in TIERS {
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
