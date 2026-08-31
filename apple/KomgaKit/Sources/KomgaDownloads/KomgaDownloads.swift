import Foundation

/// Stage 9's offline downloads, on the Apple side.
///
/// The layout follows the Rust module for one reason: the two implementations
/// are checked against the same fixtures
/// (`specs/contracts/fixtures/downloads/{states,errors,pump,manifest,layout}.json`),
/// and a reviewer comparing them should be able to walk down the same list of
/// files.
///
/// | file | knows | so that |
/// | --- | --- | --- |
/// | ``DownloadQueue`` | the rules, nothing else | one place says what a state change means |
/// | `DownloadStore.swift` | GRDB only | counters stay derived, states stay optimistic |
/// | `DownloadTree.swift` | the filesystem only | the tree's shape is decided once |
/// | `DownloadEngine.swift` | all of it, plus the transport | the only code here allowed to ask the network |
/// | `DownloadRecovery.swift` | both, plus the container walk | the disk is the witness, both ways |
///
/// The separation from the cache is the point of the feature and it is
/// structural, not a rule to remember: a download lives beside `cache/`, never
/// inside it, and never gets a `cache_entries` row — so no eviction, purge,
/// prefix delete or reconcile sweep can even name one of its paths.
