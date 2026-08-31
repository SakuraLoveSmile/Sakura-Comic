//! Diagnostics — what the core can say about itself when asked.
//!
//! Release hardening needs an answer to "what is the client actually doing
//! right now" that is not "read the source". Two things live here:
//!
//! * [`log`] — an in-process ring buffer that owns the `log` backend, so the
//!   lines the core already writes are readable by the UI and by the
//!   acceptance gates instead of being dropped on the floor.
//! * [`snapshot`] — the store's own account of itself: pragmas, integrity
//!   verdict and per-table row counts. The aggregate the UI asks for —
//!   `diagnostics_snapshot`, which folds these primitives together with the
//!   sync state, the outbox, the three cache tiers, the download queue, the
//!   contract verdict and the log ring — is assembled by the application
//!   facade, because only the facade can reach all of those areas, and it
//!   follows the field names pinned in
//!   `specs/contracts/fixtures/diagnostics/snapshot.json` so the Swift side
//!   answers with the same shape.
//!
//! The rule for everything in here: it *reports*, never *repairs*. A
//! diagnostic that also mutated state would make the acceptance gates
//! disagree with themselves about what a run did.

pub mod log;
pub mod snapshot;

pub use log::{LogRecord, LogStats};
pub use snapshot::{DbHealth, TableRows};
