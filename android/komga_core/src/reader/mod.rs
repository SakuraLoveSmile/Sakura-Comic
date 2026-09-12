//! Reader pipeline: prepare pages, lay them out, keep the position durable.
//!
//! Stage 7 shape, in the order the code follows:
//!
//! ```text
//! Reader (UI)
//!   -> reader::loader   PageRequest -> PageRef
//!   -> reader::manifest canonical 1-based pages (from the mirrored manifest)
//!   -> reader::memory   byte-budget LRU tier (Stage 8)
//!   -> reader::cache    page cache lookup  (SQLite `cache_entries` -> file)
//!   -> reader::integrity verdict on every byte that lands or is handed back
//!   -> local file       decode + render (platform side; the core never decodes)
//! ```
//!
//! Stage 8 adds the performance half: a bounded memory tier in front of the disk
//! cache, a `prefetch/` directory that keeps not-yet-seen bytes separate from
//! pages the reader actually looked at, a window computed per session from the
//! device rather than hardcoded, and integrity checks that make a truncated or
//! non-image response self-healing instead of permanent.
//!
//! Two layering rules keep this honest:
//!
//! 1. `reader` never issues HTTP. Fetching is injected through
//!    [`loader::PageFetcher`], which `api::page` implements. The UI therefore
//!    cannot grow a network call by accident.
//! 2. `reader` never invents a wire format. Progress bodies come from
//!    `store::outbox::request_for`, so Stage 6's conflict rules cannot be
//!    redefined by the reader.
//!
//! Contracts: `specs/contracts/fixtures/reader/*.json` — every module in here
//! mirrors a Swift implementation reading the same files.

pub mod cache;
pub mod integrity;
pub mod loader;
pub mod manifest;
pub mod memory;
pub mod paging;
pub mod prefetch;
pub mod series_override;
pub mod session;
pub mod settings;
pub mod throttle;
pub mod window;

pub use cache::{PageCache, PageLocation, ReconcileReport, StoreError, Tier};
pub use integrity::{inspect, quick_check_file, Corruption, Format, ImageInfo, Verdict};
pub use loader::{
    LoaderError, ManifestSource, PageRef, PageSource, PrefetchReport, ReaderLoader, Source,
};
pub use manifest::{extension_for_content_type, PageDescriptor, PageManifest, RawPage};
pub use memory::{MemoryCache, Stats as MemoryStats};
pub use paging::{layout, pair, Axis, Direction, Layout, Nav, ReadMode, Zone};
pub use prefetch::{plan, Plan, Superseded, Window};
pub use series_override::{resolve_for_series, SeriesOverride};
pub use session::{Clock, ReaderSession, Upload, UPLOAD_INTERVAL_MS};
pub use settings::{resolve_direction, Background, ReaderSettings};
pub use throttle::{Event, EventKind, PendingIntent, ProgressThrottle, WireCall};
pub use window::{
    constants, decode_slots, memory_budget, plan as plan_window, Constants, Network,
    Profile as WindowProfile,
};
