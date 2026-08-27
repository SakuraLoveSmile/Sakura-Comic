import Foundation
import KomgaAPI

/// A library row in the local store (subset of the remote LibraryDto),
/// keyed by `(serverID, remoteID)` like every mirrored entity.
public struct LibraryRecord: Sendable, Equatable, Identifiable {
    public let serverID: String
    public let remoteID: String
    public let name: String
    public let root: String?
    public let unavailable: Bool

    public var id: String { remoteID }

    public init(
        serverID: String,
        remoteID: String,
        name: String,
        root: String? = nil,
        unavailable: Bool = false
    ) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.name = name
        self.root = root
        self.unavailable = unavailable
    }

    /// Map from the transport DTO (documented mapping point).
    public init(serverID: String, dto: LibraryDTO) {
        self.init(
            serverID: serverID,
            remoteID: dto.id,
            name: dto.name,
            root: dto.root,
            unavailable: dto.unavailable ?? false
        )
    }
}