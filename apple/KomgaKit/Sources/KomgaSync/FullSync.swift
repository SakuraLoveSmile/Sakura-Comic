import Foundation
import KomgaAPI
import KomgaStore

/// Fetching abstraction so full sync can be tested without network.
/// KomgaTransport conforms via the extension below.
public protocol LibraryFetching: SeriesPageFetching {
    func fetchBooksPage(seriesID: String, request: PageRequest) async throws -> BookPageDTO
    func fetchOnDeckPage(request: PageRequest) async throws -> BookPageDTO
    func fetchCollectionsPage(request: PageRequest) async throws -> CollectionPageDTO
    func fetchReadlistsPage(request: PageRequest) async throws -> ReadListPageDTO
}

extension KomgaTransport: LibraryFetching {}

/// Page size used by the local mirror (remote pagination slices).
public let fullSyncPageSize = 100

/// Result of a full mirror run.
public struct FullSyncSummary: Sendable, Equatable {
    public var serverID: String
    public var series: Int
    public var books: Int
    public var collections: Int
    public var readlists: Int
    public var readProgress: Int
    public var seriesPages: Int
    public var bookPages: Int

    public init(
        serverID: String, series: Int, books: Int, collections: Int,
        readlists: Int, readProgress: Int, seriesPages: Int, bookPages: Int
    ) {
        self.serverID = serverID
        self.series = series
        self.books = books
        self.collections = collections
        self.readlists = readlists
        self.readProgress = readProgress
        self.seriesPages = seriesPages
        self.bookPages = bookPages
    }
}

/// FullSync — mirrors the whole media library into SQLite:
/// Series → Books → Collections → Readlists → On-Deck Progress.
/// Local-first: the UI reads SQLite while sync runs; every query works
/// with the network disconnected afterwards.
public enum FullSync {
    public static func run(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> FullSyncSummary {
        var summary = FullSyncSummary(
            serverID: serverID, series: 0, books: 0, collections: 0,
            readlists: 0, readProgress: 0, seriesPages: 0, bookPages: 0
        )

        // Series: every page (books follow series with a non-zero count).
        var seriesIDs: [String] = []
        var page = 0
        while true {
            let response = try await fetcher.fetchSeriesPage(PageRequest(page: page, size: fullSyncPageSize))
            let written = try store.upsertSeriesBatch(serverID: serverID, series: response.content)
            summary.series += written
            summary.seriesPages += 1
            seriesIDs += response.content
                .filter { ($0.booksCount ?? 0) > 0 }
                .map(\.id)
            if response.last { break }
            page += 1
        }

        // Books per series (each series may span several pages).
        for seriesID in seriesIDs {
            page = 0
            while true {
                let response = try await fetcher.fetchBooksPage(
                    seriesID: seriesID,
                    request: PageRequest(page: page, size: fullSyncPageSize)
                )
                summary.readProgress += response.content.filter { $0.readProgress != nil }.count
                let written = try store.upsertBooksBatch(serverID: serverID, books: response.content)
                summary.books += written
                summary.bookPages += 1
                if response.last { break }
                page += 1
            }
        }

        // Collections (membership is embedded in each CollectionDto).
        page = 0
        while true {
            let response = try await fetcher.fetchCollectionsPage(request: PageRequest(page: page, size: fullSyncPageSize))
            let written = try store.upsertCollectionsBatch(serverID: serverID, collections: response.content)
            summary.collections += written
            if response.last { break }
            page += 1
        }

        // Readlists (membership is embedded in each ReadListDto).
        page = 0
        while true {
            let response = try await fetcher.fetchReadlistsPage(request: PageRequest(page: page, size: fullSyncPageSize))
            let written = try store.upsertReadlistsBatch(serverID: serverID, readlists: response.content)
            summary.readlists += written
            if response.last { break }
            page += 1
        }

        // On-deck shelf: remote read-progress hint for continue reading.
        let onDeck = try await fetcher.fetchOnDeckPage(request: PageRequest(page: 0, size: fullSyncPageSize))
        for book in onDeck.content {
            guard let progress = book.readProgress else { continue }
            try store.upsertSyncedReadProgress(
                serverID: serverID,
                bookID: book.id,
                page: progress.page.map(Int64.init),
                completed: progress.completed ?? false,
                serverUpdatedAt: progress.lastModified
            )
            summary.readProgress += 1
        }

        // last_full_sync stamp + successful-sync record.
        try store.recordFullSync(serverID: serverID)
        return summary
    }
}