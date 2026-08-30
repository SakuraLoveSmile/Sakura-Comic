/// KomgaReader — reading pipeline: paged / double-page / webtoon modes,
/// image prefetch + cache, and read progress tracking with throttled upload.
///
/// Stage 7 shape, in the order the code follows (mirror of Rust `reader/mod.rs`):
///
/// ```text
/// Reader (UI)
///   -> PageLoader        page number -> local file URL
///   -> PageManifest      canonical 1-based pages (from the mirrored manifest)
///   -> ByteBudgetCache   byte-budget LRU tier in front of the disk cache (Stage 8)
///   -> PageCache         cache_entries row -> cache/pages/<key>.<ext>
///   -> local file        decode + render (the core never decodes)
///
/// UI gesture
///   -> ReaderSession     reader_position + read_progress + one coalesced outbox row
///   -> ProgressThrottle  whether a request leaves now
///   -> OutboxUpload      the wire call, with Stage 6's conflict rules
///
/// per session
///   -> WindowPlanner     how far to look, how many to run, how much RAM to hold
/// ```
///
/// Stage 8 adds the two rows above it: `MemoryCache.swift` is the bounded tier,
/// `Window.swift` is the plan that sizes it and sizes the prefetch window. Both
/// are driven by `reader/window.json`, the same fixture Rust replays.
///
/// Two layering rules keep this honest:
///
/// 1. This module never issues HTTP for pages. Fetching arrives through
///    `PageSource`, whose live implementation is `RemotePageSource`. The UI
///    therefore cannot grow a network call by accident.
/// 2. This module never invents a wire format. Progress bodies come from Stage
///    6's `requestFor(bookID:intent:)`, so the already-shipped conflict rules
///    cannot be redefined here.
///
/// Contracts: `specs/contracts/fixtures/reader/*.json` — every type in here
/// mirrors a Rust implementation reading the same files.
public enum KomgaReader {}
