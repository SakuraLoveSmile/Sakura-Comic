import Foundation

/// A cover-cache record: logical (server, remote entity) → local file path.
///
/// The UI resolves cover files from SQLite instead of scanning the disk
/// (local-first: 本地数据库负责展示). Rows are written by the cover pipeline
/// after a successful download; a row whose file vanished counts as a cache
/// miss and is backfilled on next access.
public struct ThumbnailRecord: Sendable, Equatable {
    /// Thumbnail variants (a book thumbnail may join series covers later).
    public static let variantSeries = "series"
    public static let variantBook = "book"

    public let serverID: String
    public let remoteID: String
    public let variant: String
    public let localPath: String
    public let sizeBytes: Int64
    public let lastAccess: Date

    public init(
        serverID: String,
        remoteID: String,
        variant: String = ThumbnailRecord.variantSeries,
        localPath: String,
        sizeBytes: Int64,
        lastAccess: Date = Date()
    ) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.variant = variant
        self.localPath = localPath
        self.sizeBytes = sizeBytes
        self.lastAccess = lastAccess
    }
}