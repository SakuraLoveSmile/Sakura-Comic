import SwiftUI
import KomgaStore
import KomgaSync
import KomgaReader
import KomgaAPI

/// iOS entry point for the Phase 0 vertical slice.
///
/// Local-first rule: the UI only reads `KomgaStore` (SQLite). The only
/// network touches are `BootstrapSync` (write-through to SQLite) and
/// `CoverLoader` (cache-first cover fetch). Everything the grid shows comes
/// from the local store.
@main
struct ComicApp_iOSApp: App {
    @StateObject private var model = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(model)
        }
    }
}
