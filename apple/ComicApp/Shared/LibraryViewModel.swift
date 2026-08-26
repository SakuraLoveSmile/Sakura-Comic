import Foundation
import Combine
import KomgaStore
import KomgaAPI
import KomgaSync
import KomgaReader

/// Errors surfaced by the server-management flow (banner messages).
enum ServerConfigError: LocalizedError, Equatable {
    case missingCredential
    case credentialFormat

    var errorDescription: String? {
        switch self {
        case .missingCredential: return "缺少认证凭据"
        case .credentialFormat: return "凭据格式错误"
        }
    }
}

/// Drives the Library screen. Owns the local store, the cover cache, and the
/// two network facades (real `KomgaTransport` + a demo fetcher).
///
/// Multi-server scope (Stage 2): profiles live in SQLite, secrets in
/// Keychain (only `credentialRef` is stored), the active server rides in
/// `app_state`. Every remote entity keys on `(serverId, remoteId)`.
@MainActor
final class LibraryViewModel: ObservableObject {
    let store: KomgaStore
    private let cache: DiskImageCache
    private let keychain = KeychainStore()
    private var realCoverLoader: CoverLoader
    private let demoCoverLoader: CoverLoader

    @Published var server: ServerProfile?
    @Published var servers: [ServerProfile] = []
    @Published var series: [SeriesRecord] = []
    @Published var covers: [String: Data] = [:]
    @Published var isRefreshing = false
    @Published var banner: String?

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dbURL = documents.appendingPathComponent("comic.sqlite")
        let cacheURL = documents.appendingPathComponent("cache")
        // Each `let` is assigned exactly once via a fallible-then-fallback helper.
        self.store = LibraryViewModel.makeStore(at: dbURL)
        self.cache = LibraryViewModel.makeCache(at: cacheURL)
        self.realCoverLoader = CoverLoader(cache: cache, fetcher: URLSessionCoverFetcher(auth: .apiKey("")))
        self.demoCoverLoader = CoverLoader(cache: cache, fetcher: DemoCoverFetcher())
        restoreState()
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

    // MARK: - Restore / auth

    private func restoreState() {
        do {
            servers = try store.fetchServers()
        } catch {
            banner = "读取服务器列表失败：\(error.localizedDescription)"
        }
        do {
            server = try store.activeServerProfile()
            if let server, server.id != "demo" {
                _ = try authMethod(for: server)
            }
        } catch {
            banner = banner ?? "读取当前服务器失败：\(error.localizedDescription)"
        }
        reloadCoverLoader()
    }

    /// Rebuild the real cover fetcher with the active server's auth method.
    private func reloadCoverLoader() {
        let auth: AuthMethod
        if let server, server.id == "demo" {
            auth = .apiKey("")
        } else if let server, let method = try? authMethod(for: server) {
            auth = method
        } else {
            auth = .apiKey("")
        }
        realCoverLoader = CoverLoader(cache: cache, fetcher: URLSessionCoverFetcher(auth: auth))
    }

    /// Reconstruct the HTTP auth method from a profile's stored secret.
    /// Demo profile carries no credential → empty API key.
    func authMethod(for profile: ServerProfile) throws -> AuthMethod {
        if profile.id == "demo" || profile.credentialRef == nil {
            return .apiKey("")
        }
        guard let secret = try keychain.read(ref: profile.credentialRef!) else {
            throw ServerConfigError.missingCredential
        }
        switch profile.authType {
        case .apiKey:
            return .apiKey(secret)
        case .basic:
            let parts = secret.split(separator: "\n", maxSplits: 1)
            guard parts.count == 2 else { throw ServerConfigError.credentialFormat }
            return .basic(username: String(parts[0]), password: String(parts[1]))
        }
    }

    private var transport: KomgaTransport? {
        guard let server else { return nil }
        guard let auth = try? authMethod(for: server) else { return nil }
        return KomgaTransport(baseURL: server.baseURL, auth: auth)
    }

    // MARK: - Connection flow (acceptance chain)

    /// 登录 + 验证 Komga + 获取服务器信息 + 远端实体探测 (version policy applied).
    func testConnection(baseURL raw: String, authType: AuthType, secret: String) async throws -> ConnectionResult {
        let base = try ServerURL.normalized(raw)
        let auth: AuthMethod = try makeAuth(authType: authType, secret: secret)
        let transport = KomgaTransport(baseURL: base, auth: auth)
        return try await ServerConnection.connect(fetching: transport)
    }

    /// 保存 Server Profile: secret → Keychain, profile → SQLite, libraries
    /// mirror, then activate + bootstrap. Called after a successful test.
    func addServer(
        displayName: String,
        baseURL raw: String,
        authType: AuthType,
        secret: String,
        result: ConnectionResult
    ) async {
        do {
            let base = try ServerURL.normalized(raw)
            let id = UUID().uuidString
            let ref = KeychainStore.credentialRef(serverID: id)
            try keychain.save(secret: secret, for: ref)
            let profile = ServerProfile(
                id: id,
                displayName: displayName,
                baseURL: base,
                authType: authType,
                credentialRef: ref,
                capabilities: result.capabilities,
                lastSuccessfulConnection: Date()
            )
            try store.upsertServer(profile)
            try store.upsertLibraries(serverID: id, libraries: result.libraries)
            try await activate(profile)
            banner = "已连接\(result.serverVersion.map { " Komga \($0)" } ?? "") · \(result.libraries.count) 个库"
        } catch {
            banner = "添加服务器失败：\(error.localizedDescription)"
        }
    }

    /// Edit: re-connect, overwrite the secret, refresh profile + libraries.
    func updateServer(
        _ existing: ServerProfile,
        displayName: String,
        baseURL raw: String,
        authType: AuthType,
        secret: String,
        result: ConnectionResult
    ) async {
        do {
            let base = try ServerURL.normalized(raw)
            let ref = existing.credentialRef ?? KeychainStore.credentialRef(serverID: existing.id)
            try keychain.save(secret: secret, for: ref)
            let profile = ServerProfile(
                id: existing.id,
                displayName: displayName,
                baseURL: base,
                authType: authType,
                credentialRef: ref,
                capabilities: result.capabilities,
                lastSuccessfulConnection: Date()
            )
            try store.upsertServer(profile)
            _ = try store.upsertLibraries(serverID: existing.id, libraries: result.libraries)
            if server?.id == existing.id {
                try await activate(profile)
            } else {
                servers = try store.fetchServers()
                banner = "已更新「\(displayName)」"
            }
        } catch {
            banner = "更新服务器失败：\(error.localizedDescription)"
        }
    }

    /// 切换服务器.
    func switchServer(to profile: ServerProfile) async {
        do {
            try store.setActiveServer(id: profile.id)
            try await activate(profile)
            banner = "已切换到「\(profile.displayName)」"
        } catch {
            banner = "切换失败：\(error.localizedDescription)"
        }
    }

    /// 删除服务器 (secret + profile + active state + cover records/files).
    func deleteServer(_ profile: ServerProfile) async {
        do {
            if let ref = profile.credentialRef {
                try keychain.delete(ref: ref)
            }
            // Cover files are removed together with their SQLite records.
            let coverFiles = (try? store.listThumbnails(serverID: profile.id)) ?? []
            _ = try store.deleteServer(id: profile.id)
            for record in coverFiles {
                try? cache.remove(URL(fileURLWithPath: record.localPath))
            }
            servers = try store.fetchServers()
            if server?.id == profile.id {
                self.server = nil
                series = []
                covers = [:]
                reloadCoverLoader()
            }
            banner = "已删除「\(profile.displayName)」"
        } catch {
            banner = "删除失败：\(error.localizedDescription)"
        }
    }

    /// Make the profile the active server, reload the auth-dependent pieces
    /// and pull the first series page.
    private func activate(_ profile: ServerProfile) async throws {
        try store.setActiveServer(id: profile.id)
        self.server = profile
        self.servers = try store.fetchServers()
        reloadCoverLoader()
        try loadSeries()
        await refreshAllCovers()
    }

    private func makeAuth(authType: AuthType, secret: String) throws -> AuthMethod {
        switch authType {
        case .apiKey:
            return .apiKey(secret)
        case .basic:
            let parts = secret.split(separator: "\n", maxSplits: 1)
            guard parts.count == 2 else { throw ServerConfigError.credentialFormat }
            return .basic(username: String(parts[0]), password: String(parts[1]))
        }
    }

    // MARK: - Sync (write-through to SQLite)

    /// Pull the first page of Series into SQLite, then reload the grid.
    func bootstrap() async {
        guard let transport else { return }
        guard let server else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let summary = try await BootstrapSync.run(fetcher: transport, store: store, serverID: server.id)
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

    // MARK: - Covers (cache-first; cover paths resolved from SQLite)

    /// Returns cover bytes for a series, or nil if unavailable.
    ///
    /// Local-first: the file path comes from the `thumbnails` table; a cache
    /// miss (no record or file gone) downloads, stores to disk and records
    /// the path so the next read never touches the network.
    func coverData(for record: SeriesRecord) async -> Data? {
        guard let server else { return nil }
        let loader: CoverLoader = server.id == "demo" ? demoCoverLoader : realCoverLoader
        do {
            let url = try KomgaTransport.seriesThumbnailURL(baseURL: server.baseURL, seriesID: record.remoteID)
            if let path = try store.coverPath(serverID: server.id, remoteID: record.remoteID) {
                let fileURL = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path), let cached = try? cache.load(fileURL) {
                    return cached
                }
            }
            let data = try await loader.thumbnailData(serverID: server.id, seriesID: record.remoteID, coverURL: url)
            let key = DiskImageCache.coverKey(serverID: server.id, seriesID: record.remoteID)
            let fileURL = cache.thumbnailURL(for: key)
            try store.upsertThumbnail(ThumbnailRecord(
                serverID: server.id,
                remoteID: record.remoteID,
                localPath: fileURL.path,
                sizeBytes: Int64(data.count)
            ))
            return data
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
            try store.setActiveServer(id: profile.id)
            self.server = profile
            self.servers = try store.fetchServers()
            reloadCoverLoader()
            let summary = try await BootstrapSync.run(fetcher: DemoPageFetcher(), store: store, serverID: "demo")
            try loadSeries()
            await refreshAllCovers()
            banner = "演示数据：\(summary.syncedSeries) 个 Series"
        } catch {
            banner = "演示失败：\(error.localizedDescription)"
        }
    }
}