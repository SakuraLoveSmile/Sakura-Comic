//! Sync engine: bootstrap / full mirror / reconciliation / event-driven /
//! mutation upload (upload lands with the outbox consumer, later phase).

pub mod bootstrap;
pub mod full;
pub mod reconcile;
pub mod scenario;

pub use bootstrap::{
    bootstrap_page_to_store, bootstrap_series, fetch_bootstrap_page, BootstrapSummary,
    SeriesFetcher,
};
pub use full::{
    bootstrap_sync, clear_progress, full_sync, full_sync_from, FullSyncSummary, LibraryFetcher,
    PageRequest, StartAt, PAGE_SIZE,
};
pub use reconcile::{reconcile, ReconcileSummary, ReconcileTrigger, MIN_RECONCILE_INTERVAL_SECS};
