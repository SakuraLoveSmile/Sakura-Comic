import SwiftUI
import KomgaStore
import KomgaSync
import KomgaReader
import KomgaAPI

/// macOS entry point for the Phase 0 vertical slice.
///
/// Shares the exact same local-first screen as iOS (see `Shared/LibraryView`):
/// server config → auth → BootstrapSync → local store → cover wall.
@main
struct ComicApp_macOSApp: App {
    @StateObject private var model = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(model)
        }
    }
}
