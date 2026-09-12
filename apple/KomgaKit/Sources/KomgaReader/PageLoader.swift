import Foundation
import KomgaDiagnostics
import KomgaAPI
import KomgaStore
import KomgaDownloads

// MARK: - The page pipeline: Page Manifest -> Cache -> Local File (mirror of
// `reader/loader.rs`)
//
// ```text
// Reader (UI)
//   -> PageLoader.page(n)
//        manifest mirror (SQLite book_pages)  or  fetched + mirrored manifest
//        page cache (cache_entries -> cache/pages/<key>.<ext>)
//        local file URL           (the UI decodes and renders this)
// ```
//
// The UI never issues a request and never builds a path: it asks for a page and
// gets a file it can open. Network access arrives only through `PageSource`, so no
// transport type appears in this layer at all — `KomgaAPISource` adapts the real
// client at the facade, and every test injects a fake.

/// Anything the reader needs from the server.
public protocol PageSource: Sendable {
    /// `GET /api/v1/books/{id}/pages` before normalization.
    func fetchPages(bookID: String) async throws -> [RawPage]
    /// Bytes + the response `Content-Type`, which decides the cached extension.
    func fetchPage(bookID: String, number: UInt32) async throws -> (Data, String)
}

public enum LoaderError: Error, Sendable, Equatable {
    /// Server answered with no pages: there is nothing to read.
    case empty
    /// Not an image-paged book (EPUB/PDF) — needs another viewer.
    case notPaged
    /// Asked for a page the book does not have.
    case outOfRange(page: UInt32, pageCount: UInt32)
    /// The server could not be reached or refused. Cached pages are unaffected.
    case network(String)
    case disk(String)
    case store(String)
}

/// Where the manifest for this open came from — the difference between a reading
/// session that needs a network and one that does not.
public enum ManifestSource: Sendable, Equatable {
    /// Read straight out of SQLite: no request was made.
    case mirror
    /// Fetched now and mirrored for next time.
    case network
}

public enum PageAcquisition: Sendable, Equatable {
    case cache
    case network
}

/// A page resolved to something the UI can open.
public struct PageRef: Sendable, Equatable {
    public var number: UInt32
    public var url: URL
    public var size: Int64
    public var source: PageAcquisition

    public init(number: UInt32, url: URL, size: Int64, source: PageAcquisition) {
        self.number = number
        self.url = url
        self.size = size
        self.source = source
    }
}

/// Outcome of one prefetch pass. Failures are recorded, never propagated: a
/// neighbor that could not load must not break the page on screen.
public struct PrefetchReport: Sendable, Equatable {
    public var requested: [UInt32]
    public var loaded: [UInt32]
    public var failed: [UInt32]

    public init(requested: [UInt32] = [], loaded: [UInt32] = [], failed: [UInt32] = []) {
        self.requested = requested
        self.loaded = loaded
        self.failed = failed
    }
}

/// Mirrors the manifest and resolves pages to local files.
///
/// Rust's loader takes `&Connection` per call; GRDB owns the connection inside the
/// store, so the same sequence becomes one `await` here. State that must survive
/// across awaits (`fetchCalls`, `manifestCalls`) lives in an actor-side counter set
/// owned by this class, which is why the class is `@unchecked Sendable`: the store
/// serializes its own writes and the counters are only ever touched from the
/// single task driving one reader.
public final class PageLoader: @unchecked Sendable {
    public let bookID: String
    public private(set) var manifest: PageManifest
    public private(set) var manifestSource: ManifestSource
    private let source: any PageSource
    private let cache: PageCache
    private let store: KomgaStore

    public init(
        bookID: String,
        manifest: PageManifest,
        manifestSource: ManifestSource,
        source: any PageSource,
        cache: PageCache,
        store: KomgaStore
    ) {
        self.bookID = bookID
        self.manifest = manifest
        self.manifestSource = manifestSource
        self.source = source
        self.cache = cache
        self.store = store
    }

    public var pageCount: UInt32 { manifest.pageCount }
    public var pageCache: PageCache { cache }

    /// Open a book. With a mirrored manifest present this touches no network at
    /// all — which is what lets a previously-opened book reopen offline.
    public static func open(
        store: KomgaStore,
        serverID: String,
        bookID: String,
        bookMediaType: String?,
        source: any PageSource,
        cache: PageCache,
        now: String,
        refreshManifest: Bool = false
    ) async throws -> PageLoader {
        let mirrored = try store.bookPages(serverID: serverID, bookID: bookID)
        if !refreshManifest && !mirrored.isEmpty {
            let manifest = PageManifest.fromRows(
                serverID: serverID, bookID: bookID,
                bookMediaType: bookMediaType, rows: mirrored
            )
            if manifest.emptyError { throw LoaderError.empty }
            return PageLoader(
                bookID: bookID, manifest: manifest, manifestSource: .mirror,
                source: source, cache: cache, store: store
            )
        }

        let raw = try await source.fetchPages(bookID: bookID)
        let manifest = PageManifest.fromRaw(
            serverID: serverID, bookID: bookID,
            bookMediaType: bookMediaType, raw: raw
        )
        if manifest.emptyError {
            // Keep whatever mirror exists: an outage on the manifest endpoint
            // must not destroy a readable book.
            throw LoaderError.empty
        }
        try store.replaceBookPages(
            serverID: serverID, bookID: bookID,
            rows: manifest.pages.map { $0.toRow() }, now: now
        )
        return PageLoader(
            bookID: bookID, manifest: manifest, manifestSource: .network,
            source: source, cache: cache, store: store
        )
    }

    public func layout(
        mode: ReadMode,
        direction: Direction,
        firstPageSingle: Bool
    ) -> Layout {
        Paging.layout(
            pageCount: manifest.pageCount,
            mode: mode,
            direction: direction,
            firstPageSingle: firstPageSingle,
            unpairable: manifest.unpairable()
        )
    }

    /// Cache-only lookup: what the UI renders when there is no connection, and
    /// the input to the next prefetch plan. Offline downloads take priority over
    /// transient cache.
    public func cachedPage(number: UInt32, now: String) throws -> PageRef? {
        if let downloadURL = try? store.read({ db in
            try DownloadRecovery.usablePage(
                db: db,
                serverID: manifest.serverID,
                bookID: bookID,
                pageNumber: Int(number)
            )
        }) {
            let size = Int64((try? FileManager.default.attributesOfItem(atPath: downloadURL.path)[.size] as? UInt64) ?? 0)
            return PageRef(number: number, url: downloadURL, size: size, source: .cache)
        }
        guard let location = try cache.lookup(key: manifest.cacheKey(number), now: now) else {
            return nil
        }
        return PageRef(number: number, url: location.url, size: location.size, source: .cache)
    }

    public func cachedPages() throws -> Set<UInt32> {
        var pages = try cache.cachedPages(manifest: manifest)
        if let downloaded = try? store.read({ db in
            try DownloadStore.completePages(db: db, serverId: manifest.serverID, bookId: bookID)
        }) {
            for num in downloaded {
                pages.insert(UInt32(num))
            }
        }
        return pages
    }

    /// Resolve one page for display. Cache first, then the network; a network
    /// failure leaves the cached copy (if any) in place, so an outage cannot turn
    /// a readable page into an error.
    public func page(number: UInt32, now: String) async throws -> PageRef {
        guard manifest.isPaged else { throw LoaderError.notPaged }
        guard number > 0, number <= manifest.pageCount else {
            throw LoaderError.outOfRange(page: number, pageCount: manifest.pageCount)
        }
        if let hit = try cachedPage(number: number, now: now) { return hit }
        let (bytes, contentType) = try await source.fetchPage(bookID: bookID, number: number)
        let location = try cache.store(
            key: manifest.cacheKey(number), bytes: bytes, contentType: contentType, now: now,
            kind: .page, declaredSize: declaredSize(number)
        )
        return PageRef(number: number, url: location.url, size: location.size, source: .network)
    }

    /// The size the server's own manifest reported for one page, which is the
    /// only witness able to prove a response arrived short. Zero (unknown) is
    /// reported as nil rather than as a claim.
    private func declaredSize(_ number: UInt32) -> Int64? {
        guard let size = manifest.get(number)?.sizeBytes, size > 0 else { return nil }
        return size
    }

    /// Prefetch the window around `center` (a spread index). Everything already
    /// cached is skipped before any request is made.
    public func prefetch(
        spreads: [[UInt32]],
        center: Int,
        window: PrefetchWindow,
        now: String
    ) async throws -> PrefetchReport {
        let plan = Prefetch.plan(
            spreads: spreads, center: center,
            window: window, cached: try cachedPages()
        )
        var report = PrefetchReport(requested: plan.queue)
        for number in plan.queue {
            let key = manifest.cacheKey(number)
            if try cache.isCached(key: key) { continue }
            do {
                let (bytes, contentType) = try await source.fetchPage(bookID: bookID, number: number)
                // The prefetch tier, and with the manifest's own declared size:
                // bytes that arrive short must be refused here rather than cached
                // and discovered later as a broken image.
                try cache.store(
                    key: key, bytes: bytes, contentType: contentType, now: now,
                    kind: .prefetch, declaredSize: declaredSize(number)
                )
                report.loaded.append(number)
            } catch {
                report.failed.append(number)
                // Same words, same place as Rust's prefetch warning: one
                // line naming the book, the page and why, because after the
                // break there is nothing else in the record to say where the
                // window stopped and why.
                CoreLog.shared.warning(
                    "KomgaReader.PageLoader",
                    "prefetch \(bookID) page \(number): \(error)"
                )
                // Stop on the first failure: a page that will not load is a
                // server-side signal, and hammering it for the rest of the window
                // turns one outage into N requests.
                break
            }
        }
        return report
    }
}

/// Durable reading state for one book: the display page plus the layout it was
/// shown with. Mirror of the two free functions at the tail of `loader.rs`.
public func saveReaderPosition(
    store: KomgaStore,
    serverID: String,
    bookID: String,
    page: UInt32,
    mode: ReadMode,
    direction: Direction,
    now: String
) throws {
    try store.saveReaderPosition(
        serverID: serverID, bookID: bookID, page: Int64(page),
        mode: mode.rawValue, direction: direction.rawValue, now: now
    )
}

public func loadReaderPosition(
    store: KomgaStore,
    serverID: String,
    bookID: String
) throws -> ReaderPositionRecord? {
    try store.readerPosition(serverID: serverID, bookID: bookID)
}

// MARK: - Transport adapter
//
/// The one place the reader meets the API layer: it converts wire DTOs into
/// `RawPage` / `(Data, Content-Type)` and maps failures onto `LoaderError`, so the
/// loader itself stays transport-free. Rust does the same adaptation in its facade
/// (`api::page::PageStreaming` → `reader::loader::PageSource`).

/// Wire shape of one `PageDto` entry. Required-ness follows
/// `specs/openapi/komga-openapi.yaml` (Komga 1.26.3,
/// `PageDto.required = [fileName, mediaType, number, size]`): a DTO may not be
/// looser than the server contract.
public struct PageDTO: Decodable, Sendable, Equatable {
    public let fileName: String
    public let mediaType: String
    public let number: Int
    public let size: String
    public let height: Int?
    public let width: Int?
    public let sizeBytes: Int?

    public init(
        fileName: String, mediaType: String, number: Int, size: String,
        height: Int? = nil, width: Int? = nil, sizeBytes: Int? = nil
    ) {
        self.fileName = fileName
        self.mediaType = mediaType
        self.number = number
        self.size = size
        self.height = height
        self.width = width
        self.sizeBytes = sizeBytes
    }

    public var rawPage: RawPage {
        RawPage(
            fileName: fileName,
            mediaType: mediaType,
            number: Int64(number),
            width: width.map(Int64.init),
            height: height.map(Int64.init),
            sizeBytes: sizeBytes.map(Int64.init)
        )
    }
}

/// `GET {base}/api/v1/books/{bookId}/pages` -> `array<PageDto>`
public func bookPagesURL(baseURL: String, bookID: String) -> String {
    baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        + "/api/v1/books/\(bookID)/pages"
}

/// One page image.
///
/// `zero_based=false` is sent explicitly rather than relied on as a default:
/// asking for page N and silently being served page N-1 would offset every spread
/// in the reader by one, and the reader has no way to notice.
public func bookPageURL(baseURL: String, bookID: String, number: UInt32) -> String {
    bookPagesURL(baseURL: baseURL, bookID: bookID) + "/\(number)?zero_based=false"
}

/// A live page source over URLSession. Authentication is attached per request and
/// never stored on this type.
public struct RemotePageSource: PageSource {
    public let auth: AuthMethod
    public let session: URLSession
    public let baseURL: String

    public init(baseURL: String, auth: AuthMethod, session: URLSession = KomgaTransport.makeDefaultSession()) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
    }

    public func fetchPages(bookID: String) async throws -> [RawPage] {
        var request = URLRequest(url: URL(string: bookPagesURL(baseURL: baseURL, bookID: bookID))!)
        auth.apply(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LoaderError.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LoaderError.network("status \(http.statusCode)")
        }
        do {
            let dtos = try JSONDecoder().decode([PageDTO].self, from: data)
            return dtos.map(\.rawPage)
        } catch {
            throw LoaderError.network("undecodable page list: \(error)")
        }
    }

    public func fetchPage(bookID: String, number: UInt32) async throws -> (Data, String) {
        var request = URLRequest(url: URL(string: bookPageURL(baseURL: baseURL, bookID: bookID, number: number))!)
        auth.apply(to: &request)
        // `image/*` only, so a server that content-negotiates toward a PDF page
        // answers 406 here instead of handing the reader bytes it cannot draw.
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LoaderError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return (data, http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
        case 401, 403:
            throw LoaderError.network("unauthenticated")
        default:
            throw LoaderError.network("status \(http.statusCode)")
        }
    }
}
