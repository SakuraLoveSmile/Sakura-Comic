import Foundation
import KomgaAPI

/// A library row in the local store (subset of the remote LibraryDto),
/// keyed by `(serverID, remoteID)` like every mirrored entity.
public struct LibraryRecord: Sendable, Equatable, Identifiable {
    public let serverID: String
    public let remoteID: String
    public let name: String

    public var id: String { remoteID }

    public init(serverID: String, remoteID: String, name: String) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.name = name
    }

    /// Map from the transport DTO (documented mapping point).
    public init(serverID: String, dto: LibraryDTO) {
        self.init(serverID: serverID, remoteID: dto.id, name: dto.name)
    }
}