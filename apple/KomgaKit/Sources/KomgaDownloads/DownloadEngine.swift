import Foundation
import Network
import GRDB
import KomgaAPI
import KomgaStore
import KomgaDiagnostics

/// Abstraction for network path monitoring for offline downloads.
public protocol NetworkPathProviding: Sendable {
    func currentLinkClass() -> LinkClass
}

/// Constant network path provider (ideal for tests and fixed configurations).
public struct ConstantNetworkPathProvider: NetworkPathProviding {
    public let link: LinkClass
    public init(link: LinkClass = .unmetered) { self.link = link }
    public func currentLinkClass() -> LinkClass { link }
}

/// Real system network path provider based on NWPathMonitor.
public final class SystemNetworkPathProvider: NetworkPathProviding, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "dev.sakurasep.comic.download.network", qos: .utility)
    private let lock = NSLock()
    private var currentPath: NWPath?

    public init() {
        self.monitor = NWPathMonitor()
        self.currentPath = monitor.currentPath
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.currentPath = path
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    public func currentLinkClass() -> LinkClass {
        lock.lock()
        defer { lock.unlock() }
        guard let path = currentPath, path.status == .satisfied else {
            return .unknown
        }
        if path.isExpensive || path.isConstrained || path.usesInterfaceType(.cellular) {
            return .metered
        }
        return .unmetered
    }
}

/// Abstraction for querying disk space for offline downloads.
public protocol DiskSpaceProviding: Sendable {
    func availableFreeBytes() -> Int64
}

/// Constant disk space provider (ideal for tests).
public struct ConstantDiskSpaceProvider: DiskSpaceProviding {
    public let freeBytes: Int64
    public init(freeBytes: Int64 = 10 * 1024 * 1024 * 1024) { self.freeBytes = freeBytes }
    public func availableFreeBytes() -> Int64 { freeBytes }
}

/// Real system disk space provider querying volume attributes.
public struct SystemDiskSpaceProvider: DiskSpaceProviding {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func availableFreeBytes() -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return important
            }
            if let available = values.volumeAvailableCapacity {
                return Int64(available)
            }
        } catch {}
        return 10 * 1024 * 1024 * 1024
    }
}

/// Abstraction for fetching page data over the network for offline downloads.
public protocol DownloadTransport: Sendable {
    func fetchPageData(bookID: String, pageNumber: Int) async throws -> (data: Data, contentType: String)
}

/// Convenience closure adapter for `DownloadTransport`.
public struct ClosureDownloadTransport: DownloadTransport {
    private let fetcher: @Sendable (String, Int) async throws -> (Data, String)

    public init(fetcher: @escaping @Sendable (String, Int) async throws -> (Data, String)) {
        self.fetcher = fetcher
    }

    public func fetchPageData(bookID: String, pageNumber: Int) async throws -> (data: Data, contentType: String) {
        try await fetcher(bookID, pageNumber)
    }
}

/// Summary report of one bounded download pass.
public struct DownloadPassReport: Sendable {
    public var served: Int = 0
    public var failedPages: Int = 0
    public var bytesWritten: Int64 = 0
    public var stop: StopReason = .none
    public var lastError: String?

    public init(
        served: Int = 0,
        failedPages: Int = 0,
        bytesWritten: Int64 = 0,
        stop: StopReason = .none,
        lastError: String? = nil
    ) {
        self.served = served
        self.failedPages = failedPages
        self.bytesWritten = bytesWritten
        self.stop = stop
        self.lastError = lastError
    }
}

/// Foreground offline download engine managing bounded download passes,
/// disk persistence, and reconciliation.
public actor DownloadEngine {
    private let dbQueue: DatabaseQueue
    private let root: DownloadRoot
    private let transport: any DownloadTransport
    public let serverID: String
    private let networkProvider: any NetworkPathProviding
    private let diskSpaceProvider: any DiskSpaceProviding

    public private(set) var isRunning = false
    private var isPumping = false
    private var pumpTask: Task<Void, Never>?

    public init(
        dbQueue: DatabaseQueue,
        root: DownloadRoot,
        transport: any DownloadTransport,
        serverID: String,
        networkProvider: (any NetworkPathProviding)? = nil,
        diskSpaceProvider: (any DiskSpaceProviding)? = nil
    ) {
        self.dbQueue = dbQueue
        self.root = root
        self.transport = transport
        self.serverID = serverID
        self.networkProvider = networkProvider ?? SystemNetworkPathProvider()
        self.diskSpaceProvider = diskSpaceProvider ?? SystemDiskSpaceProvider(url: root.url)
    }

    public init(
        store: KomgaStore,
        root: DownloadRoot,
        transport: any DownloadTransport,
        serverID: String,
        networkProvider: (any NetworkPathProviding)? = nil,
        diskSpaceProvider: (any DiskSpaceProviding)? = nil
    ) {
        self.init(
            dbQueue: store.database,
            root: root,
            transport: transport,
            serverID: serverID,
            networkProvider: networkProvider,
            diskSpaceProvider: diskSpaceProvider
        )
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        schedulePump()
    }

    public func stop() {
        isRunning = false
        pumpTask?.cancel()
        pumpTask = nil
    }

    public func resume() {
        start()
    }

    // MARK: - User gestures

    public func enqueue(
        bookID: String,
        bookTitle: String?,
        seriesTitle: String?,
        pages: [(number: Int, fileName: String, mediaType: String, sizeBytes: Int64)]
    ) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        let totalBytes = pages.reduce(Int64(0)) { $0 + max($1.sizeBytes, 0) }
        let manifestPath = root.bookDirectory(serverId: serverID, bookId: bookID)
            .appendingPathComponent(DownloadRoot.manifestFileName).path

        let job = NewDownload(
            serverId: serverID,
            bookId: bookID,
            pagesTotal: pages.count,
            bytesTotal: totalBytes,
            manifestPath: manifestPath,
            remoteLastModified: nil,
            bookTitle: bookTitle,
            seriesTitle: seriesTitle
        )

        try await dbQueue.writeWithoutTransaction { db in
            for p in pages {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO book_pages
                      (server_id, book_id, number, file_name, media_type, width, height, size_bytes, fetched_at)
                    VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?)
                    """,
                    arguments: [
                        self.serverID, bookID, Int64(p.number), p.fileName,
                        p.mediaType, p.sizeBytes, now
                    ]
                )
            }
            _ = try DownloadStore.enqueue(
                db: db,
                job: job,
                numbers: pages.map(\.number),
                now: now
            )
        }

        await persistManifest(bookID: bookID)

        if isRunning {
            schedulePump()
        }
    }

    public func pause(bookID: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await dbQueue.write { db in
            _ = try DownloadStore.userSet(
                db: db,
                serverId: self.serverID,
                bookId: bookID,
                to: BookState.paused.rawValue,
                now: now,
                lastError: nil
            )
        }
        await persistManifest(bookID: bookID)
    }

    public func resumeBook(bookID: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await dbQueue.write { db in
            _ = try DownloadStore.userSet(
                db: db,
                serverId: self.serverID,
                bookId: bookID,
                to: BookState.waiting.rawValue,
                now: now,
                lastError: nil
            )
        }
        if isRunning {
            schedulePump()
        }
    }

    public func retryBook(bookID: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await dbQueue.write { db in
            _ = try DownloadStore.retryFailedPages(db: db, serverId: self.serverID, bookId: bookID, now: now)
            _ = try DownloadStore.userSet(
                db: db,
                serverId: self.serverID,
                bookId: bookID,
                to: BookState.waiting.rawValue,
                now: now,
                lastError: nil
            )
        }
        if isRunning {
            schedulePump()
        }
    }

    public func delete(bookID: String) async throws {
        let pathsToDelete: [String] = try await dbQueue.write { db in
            try DownloadStore.deleteRows(db: db, serverId: self.serverID, bookId: bookID)
        }
        for path in pathsToDelete {
            try? FileManager.default.removeItem(atPath: path)
        }
        let bookDir = root.bookDirectory(serverId: serverID, bookId: bookID)
        try? FileManager.default.removeItem(at: bookDir)
    }

    public func sweep() async throws -> RecoveryReport {
        try await dbQueue.write { db in
            try DownloadRecovery.sweep(db: db, root: self.root, serverID: self.serverID)
        }
    }

    // MARK: - Queries

    public func list() async throws -> [DownloadRow] {
        try await dbQueue.read { db in
            try DownloadStore.list(db: db, serverId: self.serverID)
        }
    }

    public func storageRows() async throws -> [DownloadRow] {
        try await dbQueue.read { db in
            try DownloadStore.storageRows(db: db)
        }
    }

    public func pages(bookID: String) async throws -> [DownloadPageRow] {
        try await dbQueue.read { db in
            try DownloadStore.pages(db: db, serverId: self.serverID, bookId: bookID)
        }
    }

    public func status(bookID: String) async throws -> DownloadRow? {
        try await dbQueue.read { db in
            try DownloadStore.get(db: db, serverId: self.serverID, bookId: bookID)
        }
    }

    // MARK: - Pump loop

    private func schedulePump() {
        guard isRunning && pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            guard let self else { return }
            await self.runPumpLoop()
        }
    }

    private func runPumpLoop() async {
        defer { pumpTask = nil }
        while isRunning && !Task.isCancelled {
            let report = await pumpOnePass()
            if !isRunning || Task.isCancelled { break }

            if report.stop == .idle || report.stop == .none || (report.stop == .drained && report.served == 0) {
                break
            }

            if report.stop == .linkBlocked || report.stop == .lowSpace {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                break
            }

            if report.stop == .linkDown || report.stop == .badRun {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } else if report.stop == .throttled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            } else if report.stop == .blocked {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                break
            } else {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    public func pumpOnePass() async -> DownloadPassReport {
        guard !isPumping else {
            var report = DownloadPassReport()
            report.stop = .idle
            return report
        }
        isPumping = true
        defer { isPumping = false }

        var report = DownloadPassReport()
        let now = Date()
        let nowStr = ISO8601DateFormatter().string(from: now)

        let currentLink = networkProvider.currentLinkClass()
        let currentFreeBytes = diskSpaceProvider.availableFreeBytes()

        let planResult: (pass: PlannedPass, books: [BookPlan])? = try? await dbQueue.read { db in
            let books = try DownloadStore.planBooks(db: db, serverId: self.serverID)
            let input = PassInput(
                now: now,
                books: books,
                link: currentLink,
                freeBytes: currentFreeBytes,
                maxPages: DownloadQueue.defaultMaxPages,
                maxBytes: DownloadQueue.defaultMaxBytes,
                reader: nil
            )
            let pass = DownloadQueue.planPass(input)
            return (pass, books)
        }

        guard let (pass, _) = planResult else {
            report.stop = .idle
            return report
        }

        report.stop = pass.stop
        guard let bookRef = pass.book else {
            return report
        }

        let bookID = bookRef.bookId
        let serverID = bookRef.serverId

        if pass.claims {
            let claimed = (try? await dbQueue.write { db in
                try DownloadStore.setState(
                    db: db,
                    serverId: serverID,
                    bookId: bookID,
                    from: [BookState.waiting.rawValue],
                    to: BookState.downloading.rawValue,
                    actor: .pump,
                    now: nowStr,
                    lastError: nil
                )
            }) ?? false

            if !claimed {
                report.stop = .paused
                return report
            }
        }

        let startTime = Date()
        var consecutiveBad = 0

        for job in pass.jobs {
            if Task.isCancelled { break }

            let currentState = (try? await dbQueue.read { db in
                try DownloadStore.stateOf(db: db, serverId: serverID, bookId: bookID)
            }) ?? nil

            if currentState != BookState.downloading.rawValue {
                report.stop = .paused
                break
            }

            if report.served > 0 && Date().timeIntervalSince(startTime) > Double(DownloadQueue.maxElapsedMs) / 1000.0 {
                report.stop = .elapsed
                break
            }

            let fetchResult: Result<(Data, String), Error>
            do {
                let dataAndType = try await transport.fetchPageData(bookID: bookID, pageNumber: job.number)
                fetchResult = .success(dataAndType)
            } catch {
                fetchResult = .failure(error)
            }

            switch fetchResult {
            case .success(let (data, contentType)):
                guard !data.isEmpty else {
                    _ = try? await dbQueue.write { db in
                        _ = try DownloadStore.recordPageAttempt(
                            db: db,
                            serverId: serverID,
                            bookId: bookID,
                            number: job.number,
                            error: "页面为空",
                            now: nowStr
                        )
                    }
                    report.failedPages += 1
                    consecutiveBad += 1
                    break
                }

                let verdict = ImageIntegrity.inspect(
                    Array(data),
                    declaredContentType: contentType,
                    declaredSize: job.declaredBytes > 0 ? job.declaredBytes : nil
                )
                guard verdict.isUsable else {
                    let reason: String
                    if case .corrupt(let c) = verdict {
                        reason = c.reason
                    } else {
                        reason = "图片损坏"
                    }
                    let exhausted = (try? await dbQueue.write { db in
                        try DownloadStore.recordPageAttempt(
                            db: db,
                            serverId: serverID,
                            bookId: bookID,
                            number: job.number,
                            error: "容器校验失败: \(reason)",
                            now: nowStr
                        )
                    }) ?? false
                    if exhausted {
                        report.failedPages += 1
                    }
                    consecutiveBad += 1
                    report.lastError = "容器校验失败: \(reason)"
                    if consecutiveBad >= DownloadQueue.consecutiveBadPages {
                        report.stop = .badRun
                        break
                    }
                    continue
                }

                let ext = sniffExtension(data: data, contentType: contentType)
                let fileName = DownloadTree.pageFileName(number: job.number, fileExtension: ext)
                let bookDir = root.bookDirectory(serverId: serverID, bookId: bookID)
                let pageURL = bookDir.appendingPathComponent(fileName)
                let stagingURL = DownloadTree.stagingPath(for: pageURL)

                do {
                    try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
                    try data.write(to: stagingURL, options: .atomic)
                    if FileManager.default.fileExists(atPath: pageURL.path) {
                        try? FileManager.default.removeItem(at: pageURL)
                    }
                    try FileManager.default.moveItem(at: stagingURL, to: pageURL)

                    let writtenSize = Int64((try? FileManager.default.attributesOfItem(atPath: pageURL.path)[.size] as? UInt64) ?? 0)
                    guard writtenSize > 0 else {
                        try? FileManager.default.removeItem(at: pageURL)
                        throw QueueError.manifest("写入校验失败")
                    }

                    let saved = (try? await dbQueue.write { db -> Bool in
                        guard let s = try DownloadStore.stateOf(db: db, serverId: serverID, bookId: bookID),
                              s == BookState.downloading.rawValue else {
                            return false
                        }
                        try DownloadStore.markPageComplete(
                            db: db,
                            serverId: serverID,
                            bookId: bookID,
                            number: job.number,
                            path: pageURL.path,
                            sizeBytes: writtenSize,
                            mediaType: contentType.isEmpty ? "image/\(ext)" : contentType,
                            now: nowStr
                        )
                        _ = try DownloadStore.recomputeCounters(db: db, serverId: serverID, bookId: bookID, now: nowStr)
                        return true
                    }) ?? false

                    if saved {
                        report.served += 1
                        report.bytesWritten += writtenSize
                        consecutiveBad = 0
                    } else {
                        report.stop = .paused
                        break
                    }
                } catch {
                    report.lastError = error.localizedDescription
                    report.stop = .ioFailed
                    break
                }

            case .failure(let error):
                let classification = classifyFailure(error)
                report.lastError = error.localizedDescription
                if classification.isTransient {
                    // Do not consume page attempt counter on transient network / auth / rate limit
                    report.stop = classification.stopReason
                    break
                }

                consecutiveBad += 1
                let exhausted = (try? await dbQueue.write { db in
                    try DownloadStore.recordPageAttempt(
                        db: db,
                        serverId: serverID,
                        bookId: bookID,
                        number: job.number,
                        error: error.localizedDescription,
                        now: nowStr
                    )
                }) ?? false

                if exhausted {
                    report.failedPages += 1
                }

                if consecutiveBad >= DownloadQueue.consecutiveBadPages {
                    report.stop = .badRun
                    break
                }
            }
        }

        _ = try? await dbQueue.write { db in
            try DownloadStore.settleBook(db: db, serverId: serverID, bookId: bookID, now: nowStr, mode: .pass)
        }

        await persistManifest(bookID: bookID)

        return report
    }

    private func classifyFailure(_ error: Error) -> (isTransient: Bool, stopReason: StopReason) {
        if let apiError = error as? KomgaAPIError {
            switch apiError {
            case .authentication:
                return (true, .blocked)
            case .network:
                return (true, .linkDown)
            case let .server(statusCode):
                if statusCode == 401 || statusCode == 403 {
                    return (true, .blocked)
                } else if statusCode == 429 {
                    return (true, .throttled)
                }
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorDNSLookupFailed:
                return (true, .linkDown)
            default:
                break
            }
        }
        return (false, .badRun)
    }

    public func persistManifest(bookID: String) async {
        let manifestPath = root.bookDirectory(serverId: serverID, bookId: bookID)
            .appendingPathComponent(DownloadRoot.manifestFileName)
        do {
            let manifest = try await dbQueue.read { db -> DownloadManifest? in
                guard let row = try DownloadStore.get(db: db, serverId: self.serverID, bookId: bookID) else {
                    return nil
                }
                let pages = try DownloadStore.pages(db: db, serverId: self.serverID, bookId: bookID)
                let completedPages = pages.filter { $0.state == PageState.complete.rawValue && $0.filePath != nil }
                let manifestPages = completedPages.map { p in
                    ManifestPage(
                        number: p.number,
                        fileName: URL(fileURLWithPath: p.filePath!).lastPathComponent,
                        mediaType: p.mediaType,
                        sizeBytes: p.sizeBytes,
                        width: nil,
                        height: nil
                    )
                }
                return DownloadManifest(
                    serverId: self.serverID,
                    bookId: bookID,
                    pagesCount: Int(row.pagesTotal),
                    downloadedAt: row.createdAt,
                    remoteLastModified: row.remoteLastModified,
                    pages: manifestPages
                )
            }
            if let manifest {
                let dir = manifestPath.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try manifest.write(to: manifestPath)
            }
        } catch {}
    }

    private func sniffExtension(data: Data, contentType: String) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        } else if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        } else if data.starts(with: [0x47, 0x49, 0x46]) {
            return "gif"
        } else if data.count >= 12,
                  data.starts(with: [0x52, 0x49, 0x46, 0x46]),
                  data[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "webp"
        }
        let lower = contentType.lowercased()
        if lower.contains("png") { return "png" }
        if lower.contains("jpeg") || lower.contains("jpg") { return "jpg" }
        if lower.contains("webp") { return "webp" }
        if lower.contains("gif") { return "gif" }
        return DownloadRoot.fallbackExtension
    }
}
