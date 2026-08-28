//! Sync engine: bootstrap / full mirror / reconciliation / event driven (SSE)
//! / mutation upload (the Outbox consumer).
//!
//! The last two depend on neither each other nor on the sync path for
//! correctness: events only say "go look", and an upload is replayed from SQLite
//! until the server confirms it.

pub mod bootstrap;
pub mod full;
pub mod reconcile;
pub mod scenario;
pub mod sse;
pub mod upload;

pub use bootstrap::{
    bootstrap_page_to_store, bootstrap_series, fetch_bootstrap_page, BootstrapSummary,
    SeriesFetcher,
};
pub use full::{
    bootstrap_sync, clear_progress, full_sync, full_sync_from, FullSyncSummary, LibraryFetcher,
    PageRequest, StartAt, PAGE_SIZE,
};
pub use reconcile::{reconcile, ReconcileSummary, ReconcileTrigger, MIN_RECONCILE_INTERVAL_SECS};
pub use upload::{outbox_counts, upload_outbox, RunStatus, UploadSummary};
