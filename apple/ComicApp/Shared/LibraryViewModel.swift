import Foundation
import Combine
import SwiftUI
import KomgaStore
import KomgaAPI
import KomgaSync
import KomgaReader
import KomgaDownloads
import Network

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
    @Published var startupError: Error?
    private(set) var store: KomgaStore?
    private let dbURL: URL
    private let cacheURL: URL
    private let cache: DiskImageCache
    private let keychain = KeychainStore()
    private var realCoverLoader: CoverLoader
    private let demoCoverLoader: CoverLoader

    @Published private(set) var activeSessionID: UUID = UUID()

    @Published var server: ServerProfile?
    @Published var servers: [ServerProfile] = []
    @Published var series: [SeriesRecord] = []
    @Published var covers: [String: Data] = [:]
    @Published var isRefreshing = false
    @Published var banner: String?

    // MARK: Stage 5 — sync engine state (`sync_state`)

    /// Last successful sync of the active server, for the "最近同步" surface.
    @Published var lastSyncAt: String?
    /// Entity types an interrupted run left a resume cursor on.
    @Published var resumableEntities: [String] = []
    /// Last sync error recorded by the core (the shelf keeps working without it).
    @Published var syncError: String?

    /// Stage 6 — what the live event stream last proved. `nil` while the stream
    /// is the reason we are up to date; otherwise the mirror converges on
    /// Reconcile alone, which costs freshness and never correctness.
    @Published var liveSyncStatus: String?

    /// The event stream + Outbox uploader loop. Cancelled on background, restarted
    /// on foreground and on connectivity recovery.
    private var liveSyncTask: Task<Void, Never>?
    /// `Last-Event-ID` resume token. Carrying it is a optimisation only: a
    /// reconnect still reconciles, because the gap is unknowable.
    private var lastEventID: String?
    /// A server-sent `retry:` raises the reconnect backoff floor.
    private var retryFloorSeconds: TimeInterval = 0
    /// Set once the handshake proved there is no usable stream: stop attempting,
    /// keep uploading and reconciling (contract: `on_failure.mode`).
    private var streamUnavailable: String?
    /// Queued client writes still waiting for the server (Outbox badge).
    @Published var outboxPending = 0
    @Published var outboxCounts = OutboxCounts()

    // MARK: Stage 9 — offline downloads
    private(set) var downloadEngine: DownloadEngine?
    @Published var downloads: [DownloadRow] = []
    @Published var downloadStorageBytes: Int64 = 0
    @Published var downloadPageCount: Int64 = 0
    /// The reachability watcher is started once per foreground session.
    private var syncTriggersStarted = false

    /// One-line summary of `sync_state` for the shelf header.
    var syncStatusLabel: String {
        if let error = syncError { return "同步中断：" + error }
        if !resumableEntities.isEmpty {
            return "同步未完成，将从 " + resumableEntities.joined(separator: "、") + " 续跑"
        }
        if let last = lastSyncAt { return "最近同步 " + last }
        return "尚未同步"
    }

    /// Connectivity watcher: coming back online is a Reconcile trigger.
    private var pathMonitor: NWPathMonitor?
    private var wasOffline = false

    /// Sync mutual exclusion & coalescing
    private var currentSyncTask: Task<Bool, Never>?
    private var nextSyncTask: Task<Bool, Never>?
    private var nextSyncTrigger: ReconcileTrigger?

    // MARK: Stage 4 — media library browsing state (全部来自 SQLite)

    @Published var libraries: [LibraryCountRecord] = []
    @Published var filterOptions = FilterOptions(tags: [], genres: [], statuses: [])
    @Published var continueReading: [ContinueReadingRecord] = []
    @Published var collections: [CollectionRecord] = []
    @Published var collectionsTotal = 0
    @Published var readlists: [ReadlistRecord] = []
    @Published var readlistsTotal = 0

    /// Series shelf query state (all local).
    @Published var searchText = ""
    @Published var selectedLibraryID: String?
    @Published var selectedStatus: String?
    @Published var selectedTag: String?
    @Published var selectedGenre: String?
    @Published var seriesSort = "name"
    @Published var seriesAscending = true
    @Published var seriesTotal = 0
    @Published var isLoadingSeries = false

    /// Series/Book drill-down state (one detail at a time).
    @Published var seriesDetail: SeriesDetailRecord?
    @Published var books: [BookRecord] = []
    @Published var booksTotal = 0
    @Published var bookReadFilter: String? // "read" | "in_progress" | "unread" | nil
    @Published var bookSort = "number"
    @Published var bookCovers: [String: Data] = [:]
    @Published var appSettings = AppSettings()

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dbURL = documents.appendingPathComponent("comic.sqlite")
        let cacheURL = documents.appendingPathComponent("cache")
        self.dbURL = dbURL
        self.cacheURL = cacheURL
        self.cache = LibraryViewModel.makeCache(at: cacheURL)
        self.realCoverLoader = CoverLoader(cache: cache, fetcher: URLSessionCoverFetcher(auth: .apiKey("")))
        self.demoCoverLoader = CoverLoader(cache: cache, fetcher: DemoCoverFetcher())

        do {
            let store = try KomgaStore(path: dbURL.path)
            self.store = store
            restoreState()
        } catch {
            self.store = nil
            self.startupError = error
        }
    }

    /// Retries opening the on-disk database after a startup failure.
    func retryStartup() {
        startupError = nil
        do {
            let store = try KomgaStore(path: dbURL.path)
            self.store = store
            restoreState()
        } catch {
            self.store = nil
            self.startupError = error
        }
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
        guard let store else { return }
        if let raw = try? store.appStateValue(key: AppSettings.stateKey) {
            appSettings = AppSettings.decode(from: raw)
        }
        do {
            servers = try store.fetchServers()
            retryPendingCredentialCleanups()
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
        if let server {
            downloadEngine = makeDownloadEngine(for: server)
            Task { await refreshDownloads() }
        }
    }

    func updateAppSettings(_ newSettings: AppSettings) {
        guard let store else { return }
        appSettings = newSettings
        try? store.putAppStateValue(key: AppSettings.stateKey, value: newSettings.encode())
        if !newSettings.autoSyncMetadata {
            stopLiveSync()
        }
    }

    var colorScheme: ColorScheme? {
        switch appSettings.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var gridItemMinimumWidth: CGFloat {
        switch appSettings.gridDensity {
        case "compact": return 95
        case "spacious": return 160
        default: return 120
        }
    }

    var gridSpacing: CGFloat {
        switch appSettings.gridDensity {
        case "compact": return 8
        case "spacious": return 16
        default: return 12
        }
    }

    var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: gridItemMinimumWidth), spacing: gridSpacing)]
    }

    func diskCacheSizeBytes() -> Int64 {
        (try? cache.bytesUsed()) ?? 0
    }

    func clearDiskCache() {
        for tier in [DiskImageCache.prefetchTier, DiskImageCache.pagesTier] {
            if let fileNames = try? cache.files(inTier: tier) {
                for name in fileNames {
                    try? cache.remove(cache.url(inTier: tier, named: name))
                }
            }
        }
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
    @discardableResult
    func addServer(
        displayName: String,
        baseURL raw: String,
        authType: AuthType,
        secret: String,
        result: ConnectionResult
    ) async -> Bool {
        do {
            let base = try ServerURL.normalized(raw)
            guard let store else { return false }
            let id = UUID().uuidString
            let ref = "keychain:\(id)-\(UUID().uuidString)"
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
            do {
                try store.upsertServerWithLibraries(profile: profile, libraries: result.libraries)
            } catch {
                try? keychain.delete(ref: ref)
                throw error
            }
            do {
                try await transitionServer(to: profile)
                banner = "已连接\(result.serverVersion.map { " Komga \($0)" } ?? "") · \(result.libraries.count) 个库"
            } catch {
                banner = "已添加「\(displayName)」，但连接激活失败：\(error.localizedDescription)"
            }
            return true
        } catch {
            banner = "添加服务器失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Edit: re-connect, overwrite the secret, refresh profile + libraries atomically.
    @discardableResult
    func updateServer(
        _ existing: ServerProfile,
        displayName: String,
        baseURL raw: String,
        authType: AuthType,
        secret: String,
        result: ConnectionResult
    ) async -> Bool {
        do {
            let base = try ServerURL.normalized(raw)
            guard let store else { return false }
            let oldRef = existing.credentialRef
            let newRef = "keychain:\(existing.id)-\(UUID().uuidString)"
            try keychain.save(secret: secret, for: newRef)
            let profile = ServerProfile(
                id: existing.id,
                displayName: displayName,
                baseURL: base,
                authType: authType,
                credentialRef: newRef,
                capabilities: result.capabilities,
                lastSuccessfulConnection: Date()
            )
            do {
                try store.upsertServerWithLibraries(profile: profile, libraries: result.libraries)
            } catch {
                try? keychain.delete(ref: newRef)
                throw error
            }

            if let old = oldRef, old != newRef {
                scheduleCredentialCleanup(ref: old)
            }

            if server?.id == existing.id {
                do {
                    try await transitionServer(to: profile)
                } catch {
                    banner = "已更新「\(displayName)」，但重连失败：\(error.localizedDescription)"
                    return true
                }
            } else {
                servers = (try? store.fetchServers()) ?? []
                banner = "已更新「\(displayName)」"
            }
            return true
        } catch {
            banner = "更新服务器失败：\(error.localizedDescription)"
            return false
        }
    }

    private func scheduleCredentialCleanup(ref: String) {
        guard let store else {
            try? keychain.delete(ref: ref)
            return
        }
        var pending = (try? store.pendingCredentialCleanups()) ?? []
        if !pending.contains(ref) {
            pending.append(ref)
            try? store.setPendingCredentialCleanups(pending)
        }
        if (try? keychain.delete(ref: ref)) != nil {
            pending.removeAll(where: { $0 == ref })
            try? store.setPendingCredentialCleanups(pending)
        }
    }

    func retryPendingCredentialCleanups() {
        guard let store else { return }
        let pending = (try? store.pendingCredentialCleanups()) ?? []
        var remaining: [String] = []
        for ref in pending {
            do {
                try keychain.delete(ref: ref)
            } catch {
                remaining.append(ref)
            }
        }
        if remaining != pending {
            try? store.setPendingCredentialCleanups(remaining)
        }
    }

    /// 切换服务器.
    func switchServer(to profile: ServerProfile) async {
        do {
            try await transitionServer(to: profile)
            banner = "已切换到「\(profile.displayName)」"
        } catch {
            banner = "切换失败：\(error.localizedDescription)"
        }
    }

    /// 删除服务器 (secret + profile + active state + cover records/files).
    func deleteServer(_ profile: ServerProfile) async {
        do {
            guard let store else { return }
            // Cover files are removed together with their SQLite records.
            let coverFiles = (try? store.listThumbnails(serverID: profile.id)) ?? []
            let deleted = try store.deleteServer(id: profile.id)
            if deleted, let ref = profile.credentialRef {
                scheduleCredentialCleanup(ref: ref)
            }
            for record in coverFiles {
                try? cache.remove(URL(fileURLWithPath: record.localPath))
            }
            servers = try store.fetchServers()
            if server?.id == profile.id {
                try await transitionServer(to: nil)
            }
            banner = "已删除「\(profile.displayName)」"
        } catch {
            banner = "删除失败：\(error.localizedDescription)"
        }
    }

    /// Centralized server transition: cancels in-flight tasks, generates a new session ID,
    /// cleans up or activates the profile, and starts new data loads under the active generation.
    func transitionServer(to profile: ServerProfile?) async throws {
        let runningLiveSync = liveSyncTask
        stopLiveSync()
        _ = await runningLiveSync?.value

        if let engine = downloadEngine {
            await engine.stop()
            downloadEngine = nil
        }
        let runningSync = currentSyncTask
        currentSyncTask?.cancel()
        nextSyncTask?.cancel()
        currentSyncTask = nil
        nextSyncTask = nil
        _ = await runningSync?.value

        activeSessionID = UUID()
        let sessionID = activeSessionID

        guard let store else { return }

        if let profile {
            try store.setActiveServer(id: profile.id)
            guard activeSessionID == sessionID else { return }
            self.server = profile
            self.servers = (try? store.fetchServers()) ?? []
            self.series = []
            self.covers = [:]
            self.libraries = []
            self.continueReading = []
            self.collections = []
            self.readlists = []
            self.seriesDetail = nil
            self.books = []
            self.bookCovers = [:]
            reloadCoverLoader()
            downloadEngine = makeDownloadEngine(for: profile)
            Task { await refreshDownloads() }
            try loadSeries()
            guard activeSessionID == sessionID && self.server?.id == profile.id else { return }
            await refreshAllCovers()
            guard activeSessionID == sessionID && self.server?.id == profile.id else { return }
            try syncMediaState()
            refreshSyncState()
            startLiveSync()
        } else {
            self.server = nil
            self.series = []
            self.covers = [:]
            self.libraries = []
            self.continueReading = []
            self.collections = []
            self.readlists = []
            self.seriesDetail = nil
            self.books = []
            self.bookCovers = [:]
            self.downloads = []
            self.downloadStorageBytes = 0
            self.downloadPageCount = 0
            reloadCoverLoader()
            refreshSyncState()
        }
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

    // MARK: - Stage 5 sync engine (Bootstrap resume + Reconcile)

    /// Starts the connectivity watcher and the live stream. Call once, after the
    /// store is open and the scene is active.
    func startSyncTriggers() {
        if !syncTriggersStarted {
            syncTriggersStarted = true
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                // The handler runs off the main actor: only the derived Bool crosses.
                let offline = path.status != .satisfied
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.wasOffline && !offline {
                        // Coming back: sweep, then replace whatever half-dead
                        // socket the monitor was still holding.
                        await self.reconcile(trigger: .networkRecovered)
                        self.startLiveSync()
                    }
                    self.wasOffline = offline
                }
            }
            monitor.start(queue: DispatchQueue(label: "komga.reachability"))
            self.pathMonitor = monitor
        }
        startLiveSync()
    }

    /// Tears the watchers down (background / teardown). Disconnecting here never
    /// reconciles — the next foreground entry does that instead.
    func stopSyncTriggers() {
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        syncTriggersStarted = false
        stopLiveSync()
    }

    /// Stage 6: stream + Outbox uploader while the scene is active.
    func startLiveSync() {
        guard liveSyncTask == nil, let server, server.id != "demo" else { return }
        guard let auth = try? authMethod(for: server) else { return }
        streamUnavailable = nil
        // A new session never resumes another server's (or another day's) token.
        lastEventID = nil
        retryFloorSeconds = 0
        liveSyncTask = Task { [weak self] in
            await self?.liveSyncLoop(serverID: server.id, baseURL: server.baseURL, auth: auth)
        }
    }

    func stopLiveSync() {
        liveSyncTask?.cancel()
        liveSyncTask = nil
    }

    /// Scene came back: reconnect now, and make up for the window we were away.
    func enterForeground() async {
        startSyncTriggers()
        if let engine = downloadEngine {
            await engine.resume()
            await refreshDownloads()
        }
        guard server != nil else { return }
        await reconcile(trigger: .didBecomeActive)
        await refreshShelfAfterLiveUpdate()
    }

    /// Scene went away: drop the socket. No reconcile here — the next foreground
    /// entry is what converges, and a background task must not spend the server.
    func enterBackground() {
        stopSyncTriggers()
        Task {
            await downloadEngine?.stop()
        }
    }

    /// A live update may have moved anything the shelf reads.
    private func refreshShelfAfterLiveUpdate() async {
        let sessionID = activeSessionID
        let serverID = server?.id
        guard let server, server.id == serverID else { return }
        try? loadSeries()
        try? syncMediaState()
        guard activeSessionID == sessionID && self.server?.id == serverID else { return }
        refreshSyncState()
    }

    /// The one place the Stage 6 loop lives: an Outbox ticker plus the event
    /// stream. Either one ending (cancelled, or credentials refused) stops the
    /// other, so there is exactly one owner of each while the scene is active.
    private func liveSyncLoop(serverID: String, baseURL: String, auth: AuthMethod) async {
        let transport = KomgaTransport(baseURL: baseURL, auth: auth)
        let sessionID = activeSessionID
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.outboxTicker(serverID: serverID, transport: transport, sessionID: sessionID)
            }
            group.addTask {
                await self.streamLoop(serverID: serverID, baseURL: baseURL, transport: transport, sessionID: sessionID)
            }
        }
    }

    /// Stage 7: build the reader model for one book.
    ///
    /// Active reader sessions cached by composite key "\(serverID):\(bookID)".
    private var activeReaders: [String: ReaderModel] = [:]

    /// Returns an existing or new ReaderModel for the given (serverID, bookID).
    /// Reuses active sessions if not closed, satisfying desktop window session reuse.
    func readerModel(serverID: String? = nil, bookID: String, title: String? = nil, mediaType: String? = nil) -> ReaderModel? {
        guard let store else { return nil }
        let targetServerID = serverID ?? server?.id ?? ""
        guard !targetServerID.isEmpty else { return nil }
        let key = "\(targetServerID):\(bookID)"
        if let existing = activeReaders[key], !existing.isClosed {
            return existing
        }

        let targetServer = (server?.id == targetServerID) ? server : servers.first(where: { $0.id == targetServerID })
        let auth = targetServer.flatMap { try? authMethod(for: $0) } ?? .apiKey("")
        let baseURL = targetServer?.baseURL ?? "http://localhost"
        let transport = KomgaTransport(baseURL: baseURL, auth: auth)

        let resolvedTitle: String
        let resolvedMediaType: String?
        if let title, !title.isEmpty {
            resolvedTitle = title
            resolvedMediaType = mediaType
        } else if let book = books.first(where: { $0.remoteID == bookID }) {
            resolvedTitle = book.title
            resolvedMediaType = book.mediaType
        } else if let row = continueReading.first(where: { $0.bookID == bookID }) {
            resolvedTitle = row.bookTitle
            resolvedMediaType = (try? store.bookDetail(serverID: targetServerID, bookID: bookID))?.mediaType
        } else if let detail = try? store.bookDetail(serverID: targetServerID, bookID: bookID) {
            resolvedTitle = detail.title
            resolvedMediaType = detail.mediaType
        } else {
            resolvedTitle = bookID
            resolvedMediaType = mediaType
        }

        let reader = ReaderModel(
            store: store,
            serverID: targetServerID,
            bookID: bookID,
            title: resolvedTitle,
            bookMediaType: resolvedMediaType,
            baseURL: baseURL,
            auth: auth,
            disk: cache,
            cacheBudgetBytes: Int64(appSettings.cacheLimitMiB) * 1024 * 1024,
            flush: {
                _ = try? await OutboxUpload.run(store: store, serverID: targetServerID, writer: transport)
            }
        )
        activeReaders[key] = reader
        return reader
    }

    func readerModel(bookID: String, title: String, mediaType: String?) -> ReaderModel? {
        readerModel(serverID: server?.id, bookID: bookID, title: title, mediaType: mediaType)
    }

    func readerModel(for book: BookRecord) -> ReaderModel? {
        readerModel(serverID: server?.id, bookID: book.remoteID, title: book.title, mediaType: book.mediaType)
    }

    func readerModel(forBookID bookID: String) -> ReaderModel? {
        readerModel(serverID: server?.id, bookID: bookID)
    }

    func releaseReader(serverID: String, bookID: String) {
        let key = "\(serverID):\(bookID)"
        activeReaders.removeValue(forKey: key)
    }

    /// Background Upload Sync: drain whatever the Outbox has made due. A pass
    /// with an empty queue costs one indexed query, so the tick can be short.
    private func outboxTicker(serverID: String, transport: KomgaTransport, sessionID: UUID) async {
        while !Task.isCancelled {
            guard activeSessionID == sessionID && server?.id == serverID, let store else { return }
            do {
                _ = try await OutboxUpload.run(store: store, serverID: serverID, writer: transport)
            } catch {
                // A queue we could not read is not a reason to stop trying: the
                // next tick looks at it again. Nothing is ever dropped here.
            }
            guard activeSessionID == sessionID && server?.id == serverID else { return }
            refreshOutboxBadge(serverID: serverID)
            try? await Task.sleep(nanoseconds: Self.outboxTickNanoseconds)
        }
    }

    private enum LiveSyncError: Error {
        case reconcileFailed
    }

    /// Event Driven Sync: hold the stream, apply hints, and reconnect with the
    /// shared backoff. A reconnect always reconciles before its hints are trusted.
    private func streamLoop(serverID: String, baseURL: String, transport: KomgaTransport, sessionID: UUID) async {
        var attempts = 0
        var hasEverConnected = false
        var hints = EventHints()
        while !Task.isCancelled {
            guard activeSessionID == sessionID && server?.id == serverID, let store else { return }
            if let reason = streamUnavailable {
                // Reconcile-only mode: the socket is not attempted again, and the
                // mirror keeps converging through every other trigger.
                liveSyncStatus = reason
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                continue
            }
            var reconciledForThisConnection = !hasEverConnected
            do {
                let client = SSEClient(baseURL: baseURL, auth: transport.auth)
                for try await event in client.events(lastEventID: lastEventID) {
                    guard activeSessionID == sessionID && server?.id == serverID else { return }
                    attempts = 0
                    hasEverConnected = true
                    liveSyncStatus = nil
                    if !reconciledForThisConnection {
                        // The gap this connection replaces is unknowable, so the
                        // sweep comes first — even if events are already in hand.
                        let ok = await reconcile(trigger: .sseReconnected)
                        if !ok {
                            hints.merge(EventClassifying.classify(event))
                            throw LiveSyncError.reconcileFailed
                        }
                        reconciledForThisConnection = true
                    }
                    if let id = event.id { lastEventID = id }
                    if let retry = event.retryMS { retryFloorSeconds = TimeInterval(retry / 1000) }
                    hints.merge(EventClassifying.classify(event))
                    let batch = hints
                    hints = EventHints()
                    if batch.isEmpty { continue }
                    do {
                        let needsSweep = try await EventApplication.apply(
                            hints: batch, store: store, serverID: serverID, reader: transport
                        )
                        guard activeSessionID == sessionID && server?.id == serverID else { return }
                        if needsSweep != nil {
                            let ok = await reconcile(trigger: .manualRefresh)
                            if !ok {
                                hints.merge(batch)
                            }
                        } else {
                            await refreshShelfAfterLiveUpdate()
                        }
                    } catch {
                        hints.merge(batch)
                    }
                }
                // The server closed the stream cleanly: that is a reconnect too.
                hasEverConnected = true
            } catch LiveSyncError.reconcileFailed {
                // Reconcile failed: back off and retry bounded without dropping hints or advancing cursor
            } catch let error as KomgaAPIError {
                switch error {
                case .apiCompatibility(let message):
                    streamUnavailable = "事件流不可用，仅靠同步收敛：" + message
                case .authentication:
                    // A credential problem is global: stop the retry storm and say so.
                    liveSyncStatus = "凭据被拒，已暂停实时同步"
                    return
                default:
                    break
                }
            } catch {
                // Anything else is a broken socket: back off and try again.
            }
            if Task.isCancelled || activeSessionID != sessionID || server?.id != serverID { return }
            attempts += 1
            let delay = min(max(Double(outboxBackoffSeconds(Int64(attempts))), retryFloorSeconds), 60.0)
            liveSyncStatus = "事件流重连中（第 \(attempts) 次尝试，\(Int(delay)) 秒后重试）"
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// 5 s: long enough to coalesce a burst of reader page-turns into one write,
    /// short enough that a queued action is on the wire while the app is open.
    private static let outboxTickNanoseconds: UInt64 = 5_000_000_000

    /// The queued-mutation badge (SQLite only).
    func refreshOutboxBadge(serverID: String) {
        guard let store else { return }
        let counts = (try? store.outboxCounts(serverID: serverID, now: outboxSecondText(Date()))) ?? OutboxCounts()
        outboxCounts = counts
        outboxPending = Int(counts.total)
    }

    func fetchOutboxEntries() -> [OutboxEntry] {
        guard let store, let server else { return [] }
        return (try? store.allOutboxEntries(serverID: server.id)) ?? []
    }

    @discardableResult
    func retryFailedOutbox() async -> Int {
        guard let store, let server else { return 0 }
        do {
            let reset = try store.retryAllFailed(serverID: server.id)
            refreshOutboxBadge(serverID: server.id)
            if reset > 0, let transport {
                _ = try? await OutboxUpload.run(
                    store: store,
                    serverID: server.id,
                    writer: transport
                )
                refreshOutboxBadge(serverID: server.id)
            }
            return reset
        } catch {
            return 0
        }
    }

    /// Reads `sync_state` into the published fields (SQLite only).
    func refreshSyncState() {
        guard let store, let server else {
            lastSyncAt = nil
            resumableEntities = []
            syncError = nil
            return
        }
        let states = (try? store.listEntityStates(serverID: server.id)) ?? []
        let rollup = states.first { $0.entityType == SyncEntity.full }
        lastSyncAt = rollup?.lastSyncAt
        syncError = rollup?.lastError
        resumableEntities = states
            .filter { $0.entityType != SyncEntity.full && $0.syncCursor != nil }
            .map { $0.entityType }
    }

    /// Cold start entry point: mirror the library the first time (resuming an
    /// interrupted run), reconcile it on every later launch.
    func syncLibrary(trigger: ReconcileTrigger = .appLaunch) async {
        guard server != nil else { return }
        if lastSyncAt == nil {
            await bootstrapLibrary()
        } else {
            await reconcile(trigger: trigger)
        }
    }

    /// Bootstrap Sync: Libraries → Series → Books → Collections → Readlists →
    /// Progress, resuming from the cursors a previous run left behind.
    @discardableResult
    func bootstrapLibrary(fresh: Bool = false) async -> Bool {
        guard let server else { return false }
        let sessionID = activeSessionID
        let serverID = server.id

        if let current = currentSyncTask {
            _ = await current.value
        }
        guard activeSessionID == sessionID && self.server?.id == serverID else { return false }

        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }
            guard let transport = self.transport, let store = self.store else { return false }
            self.isRefreshing = true
            defer { self.isRefreshing = false }
            do {
                let summary = try await FullSync.run(
                    fetcher: transport,
                    store: store,
                    serverID: serverID,
                    start: fresh ? .fresh : .resume
                )
                guard self.activeSessionID == sessionID && self.server?.id == serverID else { return false }
                try self.loadSeries()
                await self.refreshAllCovers()
                try self.syncMediaState()
                self.refreshSyncState()
                var message = "已镜像 \(summary.series) Series / \(summary.books) Books"
                if !summary.resumedSteps.isEmpty {
                    message += "（续跑 \(summary.resumedSteps.joined(separator: "、"))）"
                }
                self.banner = message
                return true
            } catch {
                guard self.activeSessionID == sessionID && self.server?.id == serverID else { return false }
                self.refreshSyncState()
                self.banner = "同步失败（本地库仍可用）：\(error.localizedDescription)"
                return false
            }
        }
        currentSyncTask = task
        let result = await task.value
        if currentSyncTask == task {
            currentSyncTask = nil
        }
        return result
    }

    /// Reconcile Sync for one trigger. Every trigger runs the same full id
    /// sweep, so the mirror converges even when no SSE event ever arrived.
    @discardableResult
    func reconcile(trigger: ReconcileTrigger) async -> Bool {
        guard let server else { return false }
        let sessionID = activeSessionID
        let serverID = server.id

        if let current = currentSyncTask {
            if nextSyncTrigger == nil || !trigger.isBackground {
                nextSyncTrigger = trigger
            }
            if let next = nextSyncTask {
                return await next.value
            }
            let next = Task<Bool, Never> { @MainActor [weak self] in
                _ = await current.value
                guard let self, self.activeSessionID == sessionID, self.server?.id == serverID else {
                    return false
                }
                let t = self.nextSyncTrigger ?? trigger
                self.nextSyncTrigger = nil
                self.nextSyncTask = nil
                return await self.performReconcile(trigger: t, sessionID: sessionID, serverID: serverID)
            }
            nextSyncTask = next
            return await next.value
        }

        return await performReconcile(trigger: trigger, sessionID: sessionID, serverID: serverID)
    }

    private func performReconcile(trigger: ReconcileTrigger, sessionID: UUID, serverID: String) async -> Bool {
        guard let transport = self.transport, let store = self.store else { return false }
        do {
            guard try ReconcileSync.shouldRun(store: store, serverID: serverID, trigger: trigger)
            else { return false }
        } catch {
            return false
        }

        let task = Task<Bool, Never> { @MainActor [weak self] in
            guard let self else { return false }
            self.isRefreshing = true
            defer { self.isRefreshing = false }
            do {
                let summary = try await ReconcileSync.run(
                    fetcher: transport, store: store, serverID: serverID, trigger: trigger
                )
                guard self.activeSessionID == sessionID && self.server?.id == serverID else { return false }
                for path in summary.orphanedCovers {
                    try? self.cache.remove(URL(fileURLWithPath: path))
                }
                let changed = summary.totalMutations() > 0
                if changed {
                    try self.loadSeries()
                    await self.refreshAllCovers()
                    try self.syncMediaState()
                }
                self.refreshSyncState()
                if trigger == .manualRefresh {
                    let added = summary.seriesAdded + summary.booksAdded
                    let edited = summary.seriesChanged + summary.booksChanged
                    let removed = summary.seriesRemoved + summary.booksRemoved
                    self.banner = changed
                        ? "同步完成：新增 \(added) · 更新 \(edited) · 删除 \(removed)"
                        : "本地库已与服务器一致"
                }
                return true
            } catch {
                guard self.activeSessionID == sessionID && self.server?.id == serverID else { return false }
                self.refreshSyncState()
                if trigger == .manualRefresh {
                    self.banner = "同步失败（本地库仍可用）：\(error.localizedDescription)"
                }
                return false
            }
        }
        currentSyncTask = task
        let result = await task.value
        if currentSyncTask == task {
            currentSyncTask = nil
        }
        return result
    }

    // MARK: - Sync (write-through to SQLite)

    func loadSeries() throws {
        guard let store, let server else { return }
        series = try store.fetchSeries(serverID: server.id, limit: 200, offset: 0)
    }

    // MARK: - Covers (cache-first; cover paths resolved from SQLite)

    /// Returns cover bytes for a series, or nil if unavailable.
    ///
    /// Local-first: the file path comes from the `thumbnails` table; a cache
    /// miss (no record or file gone) downloads, stores to disk and records
    /// the path so the next read never touches the network.
    func coverData(for record: SeriesRecord) async -> Data? {
        guard let store, let server, record.serverID == server.id else { return nil }
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
        let sessionID = activeSessionID
        let serverID = record.serverID
        let data = await coverData(for: record)
        guard activeSessionID == sessionID, server?.id == serverID else { return }
        covers[record.remoteID] = data
    }

    /// Reloads covers for every series currently in the grid.
    func refreshAllCovers() async {
        covers.removeAll()
        let sessionID = activeSessionID
        for s in series {
            guard activeSessionID == sessionID else { return }
            await refreshCover(s)
        }
    }

    // MARK: - Demo (no server required)

    /// Injects the shared fixture into the local store and loads the grid, so
    /// the cover wall is demonstrable without a Komga server.
    func loadDemo() async {
        guard let store else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let profile = ServerProfile(id: "demo", displayName: "Demo", baseURL: "https://demo.local", authType: .apiKey)
            try store.upsertServer(profile)
            try store.setActiveServer(id: profile.id)
            try await transitionServer(to: profile)
            let summary = try await BootstrapSync.run(fetcher: DemoPageFetcher(), store: store, serverID: "demo")
            try loadSeries()
            await refreshAllCovers()
            banner = "演示数据：\(summary.syncedSeries) 个 Series"
        } catch {
            banner = "演示失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Stage 4 media library (全部本地查询)

    /// Full demo: seeds the whole media library from the shared fixtures
    /// (libraries / series / books / collections / readlists / progress).
    func loadFullDemo() async {
        guard let store else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let profile = ServerProfile(id: "demo", displayName: "Demo", baseURL: "https://demo.local", authType: .apiKey)
            try store.upsertServer(profile)
            try store.setActiveServer(id: profile.id)
            try await transitionServer(to: profile)
            let fetcher = DemoLibraryFetcher()
            let libraries = try await fetcher.fetchLibraries()
            _ = try store.upsertLibraries(serverID: "demo", libraries: libraries)
            let summary = try await FullSync.run(fetcher: fetcher, store: store, serverID: "demo")
            try loadSeries()
            await refreshAllCovers()
            try syncMediaState()
            banner = "演示数据：\(summary.series) Series / \(summary.books) Books"
        } catch {
            banner = "演示失败：\(error.localizedDescription)"
        }
    }

    /// Shelf entry points: libraries, filter options, continue reading,
    /// collections, readlists — all SQLite (断网可用).
    func syncMediaState() throws {
        guard let store, let server else { return }
        libraries = try store.libraryCounts(serverID: server.id)
        filterOptions = try store.filterOptions(serverID: server.id)
        continueReading = try store.continueReading(serverID: server.id, limit: 10)
        let collectionsPage = try store.listCollections(serverID: server.id, limit: 200, offset: 0)
        collections = collectionsPage.items
        collectionsTotal = collectionsPage.total
        let readlistsPage = try store.listReadlists(serverID: server.id, limit: 200, offset: 0)
        readlists = readlistsPage.items
        readlistsTotal = readlistsPage.total
    }

    /// Library 详情 row + its own paged series wall — SQLite only (断网可用).
    func libraryDetail(id: String) throws -> LibraryCountRecord? {
        guard let store, let server else { return nil }
        return try store.libraryDetail(serverID: server.id, libraryID: id)
    }

    /// A library's series page. Deliberately independent of `selectedLibraryID`
    /// so opening a library doesn't silently rewrite the shelf filters.
    func librarySeries(
        id: String,
        search: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> PagedSeries {
        guard let store, let server else { return PagedSeries(items: [], total: 0) }
        return try store.querySeries(
            serverID: server.id,
            search: search,
            libraryID: id,
            status: nil,
            tag: nil,
            genre: nil,
            sort: .name,
            ascending: true,
            limit: Int64(limit),
            offset: Int64(offset)
        )
    }

    /// 切换：把书架筛选范围设为某个 Library（nil = 全部）。
    func selectLibrary(id: String?) {
        selectedLibraryID = id
        loadSeriesWall(reset: true)
    }

    /// (Re)load the series wall honoring search/filters/sort (SQLite FTS).
    func loadSeriesWall(reset: Bool = true) {
        guard let store, let server else { return }
        let pageSize = 50
        let offset = reset ? 0 : series.count
        do {
            let result = try store.querySeries(
                serverID: server.id,
                search: searchText.isEmpty ? nil : searchText,
                libraryID: selectedLibraryID,
                status: selectedStatus,
                tag: selectedTag,
                genre: selectedGenre,
                sort: storeSeriesSort(),
                ascending: seriesAscending,
                limit: Int64(pageSize),
                offset: Int64(offset)
            )
            series = reset ? result.items : series + result.items
            seriesTotal = result.total
        } catch {
            banner = "查询失败：\(error.localizedDescription)"
        }
    }

    /// Load the next wall page (infinite scroll).
    func loadMoreSeries() {
        isLoadingSeries = true
        loadSeriesWall(reset: false)
        isLoadingSeries = false
    }

    private func storeSeriesSort() -> KomgaStore.SeriesSort {
        switch seriesSort {
        case "sortName": return .sortName
        case "dateAdded": return .dateAdded
        case "dateUpdated": return .dateUpdated
        case "booksCount": return .booksCount
        default: return .name
        }
    }

    /// Open a series detail: metadata + first book page + book-cover backfill.
    func openSeries(_ record: SeriesRecord) {
        guard let store, let server else { return }
        do {
            seriesDetail = try store.seriesDetail(serverID: server.id, seriesID: record.remoteID)
            loadBooks(seriesID: record.remoteID, reset: true)
            if covers[record.remoteID] == nil {
                Task { await refreshCover(record) }
            }
        } catch {
            banner = "读取详情失败：\(error.localizedDescription)"
        }
    }

    /// Open a series detail from a shelf entry (no wall record in memory).
    func openSeries(seriesID: String) {
        guard let store, let server else { return }
        do {
            guard let detail = try store.seriesDetail(serverID: server.id, seriesID: seriesID) else { return }
            seriesDetail = detail
            loadBooks(seriesID: seriesID, reset: true)
            let record = SeriesRecord(
                serverID: server.id, remoteID: detail.remoteID, libraryID: detail.libraryID,
                name: detail.name, sortName: detail.sortName, status: detail.status,
                createdAt: detail.createdAt, lastModified: detail.lastModified,
                booksCount: detail.booksCount, booksReadCount: detail.booksReadCount,
                booksUnreadCount: detail.booksUnreadCount, booksInProgressCount: detail.booksInProgressCount
            )
            if covers[detail.remoteID] == nil {
                Task { await refreshCover(record) }
            }
        } catch {
            banner = "读取详情失败：\(error.localizedDescription)"
        }
    }

    /// Book detail metadata (SQLite only).
    func bookDetail(for book: BookRecord) throws -> BookDetailRecord? {
        guard let store, let server else { return nil }
        return try store.bookDetail(serverID: server.id, bookID: book.remoteID)
    }

    func loadBooks(seriesID: String, reset: Bool = true) {
        guard let store, let server else { return }
        let pageSize = 100
        let offset = reset ? 0 : books.count
        do {
            let result = try store.queryBooks(
                serverID: server.id,
                seriesID: seriesID,
                readStatus: bookReadFilter.flatMap(KomgaStore.ReadStatus.init(rawValue:)),
                sort: bookSort == "title" ? .title : .number,
                ascending: true,
                limit: Int64(pageSize),
                offset: Int64(offset)
            )
            books = reset ? result.items : books + result.items
            booksTotal = result.total
        } catch {
            banner = "读取书籍失败：\(error.localizedDescription)"
        }
    }

    /// Book cover bytes (variant "book"), resolved SQLite-first — same
    /// cache discipline as series covers.
    func bookCoverData(for book: BookRecord) async -> Data? {
        guard let store, let server, book.serverID == server.id else { return nil }
        let loader: CoverLoader = server.id == "demo" ? demoCoverLoader : realCoverLoader
        do {
            // Resolve the cover path from SQLite (`variant = 'book'`).
            if let record = try store.thumbnail(serverID: server.id, remoteID: book.remoteID, variant: "book") {
                let path = record.localPath
                let fileURL = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path), let cached = try? cache.load(fileURL) {
                    bookCovers[book.remoteID] = cached
                    return cached
                }
            }
            let url = try KomgaTransport.bookThumbnailURL(baseURL: server.baseURL, bookID: book.remoteID)
            let data = try await loader.thumbnailData(serverID: server.id, seriesID: book.remoteID, coverURL: url)
            let key = DiskImageCache.coverKey(serverID: server.id, seriesID: book.remoteID)
            let fileURL = cache.thumbnailURL(for: key)
            try store.upsertThumbnail(ThumbnailRecord(
                serverID: server.id, remoteID: book.remoteID, variant: "book",
                localPath: fileURL.path, sizeBytes: Int64(data.count)
            ))
            bookCovers[book.remoteID] = data
            return data
        } catch {
            return nil
        }
    }

    func refreshBookCover(_ book: BookRecord) async {
        let sessionID = activeSessionID
        let serverID = book.serverID
        let data = await bookCoverData(for: book)
        guard activeSessionID == sessionID, server?.id == serverID else { return }
        bookCovers[book.remoteID] = data
    }

    /// Local read-status mutations (本地优先 + Outbox), then reload.
    func markRead(_ book: BookRecord) {
        guard let store, let server else { return }
        do {
            try store.markRead(serverID: server.id, bookID: book.remoteID)
            if let seriesDetail {
                loadBooks(seriesID: seriesDetail.remoteID, reset: true)
            }
            try syncMediaState()
            loadSeriesWall(reset: true)
        } catch {
            banner = "标记已读失败：\(error.localizedDescription)"
        }
    }

    func markUnread(_ book: BookRecord) {
        guard let store, let server else { return }
        do {
            try store.markUnread(serverID: server.id, bookID: book.remoteID)
            if let seriesDetail {
                loadBooks(seriesID: seriesDetail.remoteID, reset: true)
            }
            try syncMediaState()
            loadSeriesWall(reset: true)
        } catch {
            banner = "标记未读失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Offline downloads

    private func makeDownloadEngine(for server: ServerProfile) -> DownloadEngine? {
        guard let store, let auth = try? authMethod(for: server) else { return nil }
        guard let root = try? DownloadRoot.forDatabase(dbURL) else { return nil }
        let pageSource = RemotePageSource(baseURL: server.baseURL, auth: auth)
        let transport = ClosureDownloadTransport { bookID, pageNumber in
            let (data, contentType) = try await pageSource.fetchPage(bookID: bookID, number: UInt32(pageNumber))
            return (data, contentType)
        }
        return DownloadEngine(
            store: store,
            root: root,
            transport: transport,
            serverID: server.id
        )
    }

    func refreshDownloads() async {
        guard let engine = downloadEngine else {
            downloads = []
            downloadStorageBytes = 0
            downloadPageCount = 0
            return
        }
        downloads = (try? await engine.list()) ?? []
        if let store {
            downloadStorageBytes = (try? DownloadStore.bytesDoneAll(store: store)) ?? 0
            downloadPageCount = (try? DownloadStore.pageCountAll(store: store)) ?? 0
        }
    }

    func enqueueDownload(book: BookRecord) async {
        guard let server, let engine = downloadEngine else { return }
        do {
            let auth = try authMethod(for: server)
            let pageSource = RemotePageSource(baseURL: server.baseURL, auth: auth)
            let pages = try await pageSource.fetchPages(bookID: book.remoteID)
            let pageTuples: [(number: Int, fileName: String, mediaType: String, sizeBytes: Int64)] = pages.map { p in
                (number: Int(p.number), fileName: p.fileName, mediaType: p.mediaType, sizeBytes: p.sizeBytes ?? 0)
            }
            try await engine.enqueue(
                bookID: book.remoteID,
                bookTitle: book.title,
                seriesTitle: book.seriesTitle,
                pages: pageTuples
            )
            await engine.start()
            await refreshDownloads()
        } catch {
            banner = "加入下载失败：\(error.localizedDescription)"
        }
    }

    func pauseDownload(bookID: String) async {
        guard let engine = downloadEngine else { return }
        do {
            try await engine.pause(bookID: bookID)
            await refreshDownloads()
        } catch {
            banner = "暂停下载失败：\(error.localizedDescription)"
        }
    }

    func resumeDownload(bookID: String) async {
        guard let engine = downloadEngine else { return }
        do {
            try await engine.resumeBook(bookID: bookID)
            await engine.start()
            await refreshDownloads()
        } catch {
            banner = "继续下载失败：\(error.localizedDescription)"
        }
    }

    func retryDownload(bookID: String) async {
        guard let engine = downloadEngine else { return }
        do {
            try await engine.retryBook(bookID: bookID)
            await engine.start()
            await refreshDownloads()
        } catch {
            banner = "重试下载失败：\(error.localizedDescription)"
        }
    }

    func deleteDownload(bookID: String) async {
        guard let engine = downloadEngine else { return }
        do {
            try await engine.delete(bookID: bookID)
            await refreshDownloads()
        } catch {
            banner = "删除下载失败：\(error.localizedDescription)"
        }
    }

    func sweepDownloads() async -> RecoveryReport? {
        guard let engine = downloadEngine else { return nil }
        do {
            let report = try await engine.sweep()
            await refreshDownloads()
            return report
        } catch {
            banner = "检查修复失败：\(error.localizedDescription)"
            return nil
        }
    }

    func downloadStatus(bookID: String) -> DownloadRow? {
        downloads.first { $0.bookId == bookID }
    }
}