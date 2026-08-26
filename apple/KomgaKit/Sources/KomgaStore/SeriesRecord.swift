import Foundation
import KomgaAPI

/// A series row in the local store (subset of the remote SeriesDto).
public struct SeriesRecord: Sendable, Equatable, Identifiable {
    public let serverID: String
    public let remoteID: String
    public let libraryID: String
    public let name: String
    public let sortName: String?
    public let status: String?
    public let createdAt: String?
    public let lastModified: String?

    public var id: String { remoteID }

    public init(
        serverID: String,
        remoteID: String,
        libraryID: String,
        name: String,
        sortName: String? = nil,
        status: String? = nil,
        createdAt: String? = nil,
        lastModified: String? = nil
    ) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.libraryID = libraryID
        self.name = name
        self.sortName = sortName
        self.status = status
        self.createdAt = createdAt
        self.lastModified = lastModified
    }

    /// Map from the transport DTO. The store stays transport-agnostic; this
    /// is the documented mapping point.
    public init(serverID: String, dto: SeriesDTO) {
        self.init(
            serverID: serverID,
            remoteID: dto.id,
            libraryID: dto.libraryId,
            name: dto.name,
            status: dto.metadata?.status,
            createdAt: dto.created,
            lastModified: dto.lastModified
        )
    }
}
