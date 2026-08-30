import Foundation
import KomgaStore
// The reader reuses Stage 6's wire vocabulary (`Intent`, `WireRequest`,
// `requestFor(bookID:intent:)`) rather than restating it: two implementations of
// "what a progress write looks like on the wire" is exactly how the throttled
// reader stream would drift from the conflict rules Stage 6 shipped and pinned
// in `specs/contracts/fixtures/outbox/conflict.json`.
//
// This is a real dependency, declared in Package.swift: `KomgaSync` itself only
// reaches Foundation / KomgaAPI / KomgaStore, so the graph stays a DAG and the
// Xcode dependency scanner (unlike a cached `swift build`) accepts it.
@_exported import KomgaSync
