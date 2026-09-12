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
        Window("媒体库", id: "library") {
            LibraryView()
                .environmentObject(model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        WindowGroup("阅读器", id: "reader", for: String.self) { $compositeID in
            MacReaderWindowView(compositeID: compositeID, model: model)
        }
        .defaultSize(width: 960, height: 1100)
    }
}

private struct MacReaderWindowView: View {
    let compositeID: String?
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        let (serverID, bookID) = parseID(compositeID)
        if let bookID, let readerModel = model.readerModel(serverID: serverID, bookID: bookID) {
            NavigationStack {
                ReaderScreen(model: readerModel)
                    .environmentObject(model)
            }
        } else {
            ContentUnavailableView("无法加载书籍", systemImage: "book.closed", description: Text("未找到指定书籍或服务器未连接"))
        }
    }

    private func parseID(_ raw: String?) -> (String?, String?) {
        guard let raw, !raw.isEmpty else { return (nil, nil) }
        if let colonIndex = raw.firstIndex(of: ":") {
            let server = String(raw[..<colonIndex])
            let book = String(raw[raw.index(after: colonIndex)...])
            return (server.isEmpty ? nil : server, book)
        }
        return (nil, raw)
    }
}
