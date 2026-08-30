import Foundation
import Combine
import KomgaStore
import KomgaAPI
import KomgaSync
import KomgaReader
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
    private let pathMonitor = NWPathMonitor()
    private var wasOffline = false

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

    // MARK: - Stage 5 sync engine (Bootstrap resume + Reconcile)

    /// Starts the connectivity watcher and the live stream. Call once, after the
    /// store is open and the scene is active.
    func startSyncTriggers() {
        if !syncTriggersStarted {
            syncTriggersStarted = true
            pathMonitor.pathUpdateHandler = { [weak self] path in
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
            pathMonitor.start(queue: DispatchQueue(label: "komga.reachability"))
        }
        startLiveSync()
    }

    /// Tears the watchers down (background / teardown). Disconnecting here never
    /// reconciles — the next foreground entry does that instead.
    func stopSyncTriggers() {
        pathMonitor.pathUpdateHandler = nil
        pathMonitor.cancel()
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
        guard server != nil else { return }
        await reconcile(trigger: .didBecomeActive)
        await refreshShelfAfterLiveUpdate()
    }

    /// Scene went away: drop the socket. No reconcile here — the next foreground
    /// entry is what converges, and a background task must not spend the server.
    func enterBackground() {
        stopSyncTriggers()
    }

    /// A live update may have moved anything the shelf reads.
    private func refreshShelfAfterLiveUpdate() async {
        guard server != nil else { return }
        try? loadSeries()
        try? syncMediaState()
        refreshSyncState()
    }

    /// The one place the Stage 6 loop lives: an Outbox ticker plus the event
    /// stream. Either one ending (cancelled, or credentials refused) stops the
    /// other, so there is exactly one owner of each while the scene is active.
    private func liveSyncLoop(serverID: String, baseURL: String, auth: AuthMethod) async {
        let transport = KomgaTransport(baseURL: baseURL, auth: auth)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.outboxTicker(serverID: serverID, transport: transport)
            }
            group.addTask {
                await self.streamLoop(serverID: serverID, baseURL: baseURL, transport: transport)
            }
        }
    }

    /// Stage 7: build the reader model for one book.
    ///
    /// Returns nil when there is no active server to read pages from; the book
    /// sheet turns that into a disabled 开始阅读 rather than a crash. The cache
    /// and the store are the ones this view model already owns, so the reader
    /// sees exactly the mirror the shelf shows.
    func readerModel(for book: BookRecord) -> ReaderModel? {
        guard let server else { return nil }
        let auth = (try? authMethod(for: server)) ?? .apiKey("")
        let transport = KomgaTransport(baseURL: server.baseURL, auth: auth)
        let store = self.store
        return ReaderModel(
            store: store,
            serverID: server.id,
            bookID: book.remoteID,
            title: book.title,
            bookMediaType: book.mediaType,
            baseURL: server.baseURL,
            auth: auth,
            disk: cache,
            flush: {
                // Draining the queue stays Stage 6's code path; the reader only
                // nudges it so an explicit mark leaves immediately.
                _ = try? await OutboxUpload.run(store: store, serverID: server.id, writer: transport)
            }
        )
    }

    /// Background Upload Sync: drain whatever the Outbox has made due. A pass
    /// with an empty queue costs one indexed query, so the tick can be short.
    private func outboxTicker(serverID: String, transport: KomgaTransport) async {
        while !Task.isCancelled {
            do {
                _ = try await OutboxUpload.run(store: store, serverID: serverID, writer: transport)
            } catch {
                // A queue we could not read is not a reason to stop trying: the
                // next tick looks at it again. Nothing is ever dropped here.
            }
            refreshOutboxBadge(serverID: serverID)
            try? await Task.sleep(nanoseconds: Self.outboxTickNanoseconds)
        }
    }

    /// Event Driven Sync: hold the stream, apply hints, and reconnect with the
    /// shared backoff. A reconnect always reconciles before its hints are trusted.
    private func streamLoop(serverID: String, baseURL: String, transport: KomgaTransport) async {
        var attempts = 0
        var hasEverConnected = false
        while !Task.isCancelled {
            if let reason = streamUnavailable {
                // Reconcile-only mode: the socket is not attempted again, and the
                // mirror keeps converging through every other trigger.
                liveSyncStatus = reason
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                continue
            }
            var hints = EventHints()
            var reconciledForThisConnection = !hasEverConnected
            do {
                let client = SSEClient(baseURL: baseURL, auth: transport.auth)
                for try await event in client.events(lastEventID: lastEventID) {
                    attempts = 0
                    hasEverConnected = true
                    liveSyncStatus = nil
                    if !reconciledForThisConnection {
                        // The gap this connection replaces is unknowable, so the
                        // sweep comes first — even if events are already in hand.
                        reconciledForThisConnection = true
                        await reconcile(trigger: .sseReconnected)
                    }
                    if let id = event.id { lastEventID = id }
                    if let retry = event.retryMS { retryFloorSeconds = TimeInterval(retry / 1000) }
                    hints.merge(EventClassifying.classify(event))
                    let batch = hints
                    hints = EventHints()
                    if batch.isEmpty { continue }
                    let needsSweep = try await EventApplication.apply(
                        hints: batch, store: store, serverID: serverID, reader: transport
                    )
                    if needsSweep != nil {
                        await reconcile(trigger: .manualRefresh)
                    } else {
                        await refreshShelfAfterLiveUpdate()
                    }
                }
                // The server closed the stream cleanly: that is a reconnect too.
                hasEverConnected = true
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
            if Task.isCancelled { return }
            attempts += 1
            let delay = max(Double(outboxBackoffSeconds(Int64(attempts))), retryFloorSeconds)
            liveSyncStatus = "事件流断开，\(Int(delay)) 秒后重连"
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// 5 s: long enough to coalesce a burst of reader page-turns into one write,
    /// short enough that a queued action is on the wire while the app is open.
    private static let outboxTickNanoseconds: UInt64 = 5_000_000_000

    /// The queued-mutation badge (SQLite only).
    private func refreshOutboxBadge(serverID: String) {
        let counts = try? store.outboxCounts(serverID: serverID, now: outboxSecondText(Date()))
        outboxPending = Int(counts?.total ?? 0)
    }

    /// Reads `sync_state` into the published fields (SQLite only).
    func refreshSyncState() {
        guard let server else {
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
    func bootstrapLibrary(fresh: Bool = false) async {
        guard let transport, let server else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let summary = try await FullSync.run(
                fetcher: transport,
                store: store,
                serverID: server.id,
                start: fresh ? .fresh : .resume
            )
            try loadSeries()
            await refreshAllCovers()
            try syncMediaState()
            refreshSyncState()
            var message = "已镜像 \(summary.series) Series / \(summary.books) Books"
            if !summary.resumedSteps.isEmpty {
                message += "（续跑 \(summary.resumedSteps.joined(separator: "、"))）"
            }
            banner = message
        } catch {
            refreshSyncState()
            banner = "同步失败（本地库仍可用）：\(error.localizedDescription)"
        }
    }

    /// Reconcile Sync for one trigger. Every trigger runs the same full id
    /// sweep, so the mirror converges even when no SSE event ever arrived.
    func reconcile(trigger: ReconcileTrigger) async {
        guard let transport, let server, !isRefreshing else { return }
        do {
            guard try ReconcileSync.shouldRun(store: store, serverID: server.id, trigger: trigger)
            else { return } // background trigger inside the throttle window
        } catch {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let summary = try await ReconcileSync.run(
                fetcher: transport, store: store, serverID: server.id, trigger: trigger
            )
            // Delete propagation reaches the disk too: pruned covers are gone.
            for path in summary.orphanedCovers {
                try? cache.remove(URL(fileURLWithPath: path))
            }
            let changed = summary.totalMutations() > 0
            if changed {
                try loadSeries()
                await refreshAllCovers()
                try syncMediaState()
            }
            refreshSyncState()
            if trigger == .manualRefresh {
                let added = summary.seriesAdded + summary.booksAdded
                let edited = summary.seriesChanged + summary.booksChanged
                let removed = summary.seriesRemoved + summary.booksRemoved
                banner = changed
                    ? "同步完成：新增 \(added) · 更新 \(edited) · 删除 \(removed)"
                    : "本地库已与服务器一致"
            }
        } catch {
            // An unreachable server never takes the shelf down.
            refreshSyncState()
            if trigger == .manualRefresh {
                banner = "同步失败（本地库仍可用）：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Sync (write-through to SQLite)

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

    // MARK: - Stage 4 media library (全部本地查询)

    /// Full demo: seeds the whole media library from the shared fixtures
    /// (libraries / series / books / collections / readlists / progress).
    func loadFullDemo() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let profile = ServerProfile(id: "demo", displayName: "Demo", baseURL: "https://demo.local", authType: .apiKey)
            try store.upsertServer(profile)
            try store.setActiveServer(id: profile.id)
            self.server = profile
            self.servers = try store.fetchServers()
            reloadCoverLoader()
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
        guard let server else { return }
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
        guard let server else { return nil }
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
        guard let server else { return PagedSeries(items: [], total: 0) }
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
        guard let server else { return }
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
        guard let server else { return }
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
        guard let server else { return }
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
        guard let server else { return nil }
        return try store.bookDetail(serverID: server.id, bookID: book.remoteID)
    }

    func loadBooks(seriesID: String, reset: Bool = true) {
        guard let server else { return }
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
        guard let server else { return nil }
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
        bookCovers[book.remoteID] = await bookCoverData(for: book)
    }

    /// Local read-status mutations (本地优先 + Outbox), then reload.
    func markRead(_ book: BookRecord) {
        guard let server else { return }
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
        guard let server else { return }
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
}