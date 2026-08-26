//! Sync engine: bootstrap / full mirror / reconciliation / event-driven /
//! mutation upload (upload lands with the outbox consumer, later phase).

pub mod bootstrap;
pub mod full;

pub use bootstrap::{
    bootstrap_page_to_store, bootstrap_series, fetch_bootstrap_page, BootstrapSummary,
    SeriesFetcher,
};
pub use full::{full_sync, FullSyncSummary, LibraryFetcher, PageRequest, PAGE_SIZE};
