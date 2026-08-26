import Foundation
import KomgaAPI
import KomgaStore

/// Fetching abstraction so bootstrap can be tested without network.
/// KomgaTransport conforms via the extension below.
public protocol SeriesPageFetching: Sendable {
    func fetchSeriesPage(_ request: PageRequest) async throws -> SeriesPageDTO
}

extension KomgaTransport: SeriesPageFetching {}

/// Result of a bootstrap run (Phase 0 mirrors the first page only).
public struct BootstrapSummary: Sendable, Equatable {
    public let serverID: String
    public let syncedSeries: Int
    public let totalElements: Int
    public let hasMorePages: Bool

    public init(serverID: String, syncedSeries: Int, totalElements: Int, hasMorePages: Bool) {
        self.serverID = serverID
        self.syncedSeries = syncedSeries
        self.totalElements = totalElements
        self.hasMorePages = hasMorePages
    }
}

/// BootstrapSync — fetch the first page of Series (size 10) and mirror it
/// into the local store. UI reads SQLite, never the network.
public enum BootstrapSync {
    public static func run(
        fetcher: any SeriesPageFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> BootstrapSummary {
        let page = try await fetcher.fetchSeriesPage(PageRequest(page: 0, size: 10))
        let records = page.content.map { SeriesRecord(serverID: serverID, dto: $0) }
        let written = try store.upsertSeriesBatch(records)
        // Stage 3: record the successful sync in `sync_state`.
        try store.recordSuccessfulSync(serverID: serverID)
        return BootstrapSummary(
            serverID: serverID,
            syncedSeries: written,
            totalElements: page.totalElements,
            hasMorePages: !page.last
        )
    }
}
