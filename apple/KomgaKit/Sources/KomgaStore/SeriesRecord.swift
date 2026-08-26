import Foundation
import KomgaAPI

/// A series row in the local store (mirror of the remote SeriesDto;
/// read counters + sortName from the metadata titleSort).
public struct SeriesRecord: Sendable, Equatable, Identifiable {
    public let serverID: String
    public let remoteID: String
    public let libraryID: String
    public let name: String
    public let sortName: String?
    public let status: String?
    public let createdAt: String?
    public let lastModified: String?
    public let booksCount: Int?
    public let booksReadCount: Int?
    public let booksUnreadCount: Int?
    public let booksInProgressCount: Int?

    public var id: String { remoteID }

    public init(
        serverID: String,
        remoteID: String,
        libraryID: String,
        name: String,
        sortName: String? = nil,
        status: String? = nil,
        createdAt: String? = nil,
        lastModified: String? = nil,
        booksCount: Int? = nil,
        booksReadCount: Int? = nil,
        booksUnreadCount: Int? = nil,
        booksInProgressCount: Int? = nil
    ) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.libraryID = libraryID
        self.name = name
        self.sortName = sortName
        self.status = status
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.booksCount = booksCount
        self.booksReadCount = booksReadCount
        self.booksUnreadCount = booksUnreadCount
        self.booksInProgressCount = booksInProgressCount
    }

    /// Map from the transport DTO. The store stays transport-agnostic; this
    /// is the documented mapping point (sortName rides on metadata.titleSort).
    public init(serverID: String, dto: SeriesDTO) {
        self.init(
            serverID: serverID,
            remoteID: dto.id,
            libraryID: dto.libraryId,
            name: dto.name,
            sortName: dto.metadata?.titleSort ?? dto.name,
            status: dto.metadata?.status,
            createdAt: dto.created,
            lastModified: dto.lastModified,
            booksCount: dto.booksCount,
            booksReadCount: dto.booksReadCount,
            booksUnreadCount: dto.booksUnreadCount,
            booksInProgressCount: dto.booksInProgressCount
        )
    }
}