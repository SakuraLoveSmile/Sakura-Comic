import Foundation
import Combine
import KomgaStore
import KomgaAPI
import KomgaSync
import KomgaReader

/// Drives the Library screen. Owns the local store, the cover cache, and the
/// two network facades (real `KomgaTransport` + a demo fetcher).
///
/// Phase 0 single-server scope: one configured server is remembered; the
/// secret lives in `UserDefaults` for convenience and moves to Keychain in
/// Phase 1 (`ServerProfile.credentialRef`).
@MainActor
final class LibraryViewModel: ObservableObject {
    let store: KomgaStore
    private let cache: DiskImageCache
    private var realCoverLoader: CoverLoader
    private let demoCoverLoader: CoverLoader

    @Published var server: ServerProfile?
    @Published var series: [SeriesRecord] = []
    @Published var covers: [String: Data] = [:]
    @Published var isRefreshing = false
    @Published var banner: String?

    /// API key for the active server (in-memory; see class note).
    private(set) var apiKey: String = ""

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dbURL = documents.appendingPathComponent("comic.sqlite")
        let cacheURL = documents.appendingPathComponent("cache")
        // Each `let` is assigned exactly once via a fallible-then-fallback helper.
        self.store = LibraryViewModel.makeStore(at: dbURL)
        self.cache = LibraryViewModel.makeCache(at: cacheURL)
        self.realCoverLoader = CoverLoader(cache: cache, fetcher: URLSessionCoverFetcher(auth: .apiKey("")))
        self.demoCoverLoader = CoverLoader(cache: cache, fetcher: DemoCoverFetcher())
        restoreServer()
    }

    /// Opens the on-disk store, falling back to an in-memory store if the
    /// path is unavailable so the app can still launch.
    private static func makeStore(at dbURL: URL) -> KomgaStore {
        (try? KomgaStore(path: dbURL.path)) ?? (try! KomgaStore())
    }

    /// Opens the on-disk cache, falling back to a temp cache if needed.
    private static func makeCache(at cacheURL: URL) -> DiskImageCache {
        (try? DiskImageCache(rootURL: cacheURL))
            ?? (try! DiskImageCache(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("comic-cache-\(UUID().uuidString)")
            ))
    }

    // MARK: - Server persistence

    private func restoreServer() {
        let d = UserDefaults.standard
        guard let id = d.string(forKey: "server.id"),
              let base = d.string(forKey: "server.baseURL"),
              let name = d.string(forKey: "server.displayName")
        else { return }
        self.server = ServerProfile(id: id, displayName: name, baseURL: base, authType: .apiKey)
        self.apiKey = d.string(forKey: "server.apiKey") ?? ""
        self.realCoverLoader = CoverLoader(cache: cache, fetcher: URLSessionCoverFetcher(auth: .apiKey(apiKey)))
    }

    private func persistServer(_ profile: ServerProfile, apiKey: String) {
        let d = UserDefaults.standard
        d.set(profile.id, forKey: "server.id")
        d.set(profile.baseURL, forKey: "server.baseURL")
        d.set(profile.displayName, forKey: "server.displayName")
        d.set(apiKey, forKey: "server.apiKey")
        self.server = profile
        self.apiKey = apiKey
        self.realCoverLoader = CoverLoader(cache: cache, fetcher: URLSessionCoverFetcher(auth: .apiKey(apiKey)))
    }

    private var transport: KomgaTransport? {
        guard let server else { return nil }
        return KomgaTransport(baseURL: server.baseURL, auth: .apiKey(apiKey))
    }

    // MARK: - Configure a real server

    /// Validate connectivity + auth by fetching the first page, persist the
    /// profile, then bootstrap the local mirror.
    func addServer(displayName: String, baseURL raw: String, apiKey: String) async {
        do {
            let base = try ServerURL.normalized(raw)
            let profile = ServerProfile(displayName: displayName, baseURL: base, authType: .apiKey)
            let probe = KomgaTransport(baseURL: base, auth: .apiKey(apiKey))
            let page = try await probe.fetchSeriesPage(PageRequest(page: 0, size: 10))
            try store.upsertServer(profile)
            persistServer(profile, apiKey: apiKey)
            try await bootstrap()
            banner = "已连接：\(page.totalElements) 个 Series"
        } catch {
            banner = "连接失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Sync (write-through to SQLite)

    /// Pull the first page of Series into SQLite, then reload the grid.
    func bootstrap() async {
        guard let transport else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let summary = try await BootstrapSync.run(fetcher: transport, store: store, serverID: server!.id)
            try loadSeries()
            await refreshAllCovers()
            banner = "已同步 \(summary.syncedSeries) 个 Series"
        } catch {
            banner = "同步失败：\(error.localizedDescription)"
        }
    }

    func loadSeries() throws {
        guard let server else { return }
        series = try store.fetchSeries(serverID: server.id, limit: 200, offset: 0)
    }

    // MARK: - Covers (cache-first)

    /// Returns cover bytes for a series, or nil if unavailable.
    func coverData(for record: SeriesRecord) async -> Data? {
        guard let server else { return nil }
        let loader: CoverLoader = server.id == "demo" ? demoCoverLoader : realCoverLoader
        do {
            let url = try KomgaTransport.seriesThumbnailURL(baseURL: server.baseURL, seriesID: record.remoteID)
            return try await loader.thumbnailData(serverID: server.id, seriesID: record.remoteID, coverURL: url)
        } catch {
            return nil
        }
    }

    /// Loads (or reloads) the cover for one series into `covers`.
    func refreshCover(_ record: SeriesRecord) async {
        covers[record.remoteID] = await coverData(for: record)
    }

    /// Reloads covers for every series currently in the grid.
    func refreshAllCovers() async {
        covers.removeAll()
        for s in series {
            await refreshCover(s)
        }
    }

    // MARK: - Demo (no server required)

    /// Injects the shared fixture into the local store and loads the grid, so
    /// the cover wall is demonstrable without a Komga server.
    func loadDemo() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let profile = ServerProfile(id: "demo", displayName: "Demo", baseURL: "https://demo.local", authType: .apiKey)
            try store.upsertServer(profile)
            self.server = profile
            self.apiKey = ""
            let summary = try await BootstrapSync.run(fetcher: DemoPageFetcher(), store: store, serverID: "demo")
            try loadSeries()
            await refreshAllCovers()
            banner = "演示数据：\(summary.syncedSeries) 个 Series"
        } catch {
            banner = "演示失败：\(error.localizedDescription)"
        }
    }
}
