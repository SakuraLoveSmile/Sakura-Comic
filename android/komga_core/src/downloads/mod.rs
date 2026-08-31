//! Offline downloads: the queue the user owns, and the tree of files that makes a
//! book readable with the network off.
//!
//! The separation from the cache is the point of this module, and it is structural
//! rather than a rule somebody has to remember:
//!
//! ```text
//! <dir of database>/
//!   ├── comic.sqlite
//!   ├── cache/       thumbnails · pages · prefetch   ← LRU may delete any of it
//!   └── downloads/   {serverId}/{bookId}/*           ← only the user may delete it
//! ```
//!
//! # OWNERSHIP
//!
//! Exactly three writers may remove anything under `downloads/`, and each carries an
//! `OWNERSHIP:` comment at the site:
//!
//!   1. a user delete — [`store::delete_rows`] and the `remove_*_tree` helpers on
//!      [`manifest::DownloadRoot`];
//!   2. a pass cleaning up after itself — [`engine::land_page`] removing its own
//!      staging file, or a page it has just proved is not the image it claims to be;
//!   3. [`recover::sweep`] removing a file that failed the container walk, drifted in
//!      size, or is numbered past the book's own page count.
//!
//! Everything else is excluded by construction rather than by care: LRU eviction, tier
//! cleanup, prefix purge, the reader's reconcile sweep, the mirror sweep and prune all
//! reach files through [`crate::cache::DiskCache`] or the `cache_entries` ledger, and
//! neither can name a path in this tree. That is what makes "no LRU or cache cleanup
//! may delete an offline download" true without a single `if` in the eviction path —
//! and it is why [`crate::store::cache::protected_paths`] keeps its
//! `kind = 'download'` arm as a fence rather than as the mechanism.
//!
//! # What each sub-module is allowed to know
//!
//! | module | knows | so that |
//! | --- | --- | --- |
//! | [`queue`] | the fixtures, nothing else | Swift can re-derive the same rules from the same two files |
//! | [`store`] | SQLite only | one place states that counters are derived and states are optimistic |
//! | [`manifest`] | the filesystem only | the tree's shape is decided once, and checked at construction |
//! | [`recover`] | both, plus the container walk | the disk is the witness, in both directions |
//! | [`engine`] | all of the above, plus the transport | the only code in here that may make a request |

pub mod engine;
pub mod manifest;
pub mod queue;
pub mod recover;
pub mod store;

pub use engine::{PassReport, PassRequest};
pub use manifest::{DownloadManifest, DownloadRoot, ManifestPage};
pub use queue::{Link, StopReason};
pub use recover::SweepReport;
pub use store::{DownloadPageRow, DownloadRow};

#[cfg(test)]
pub mod harness;
