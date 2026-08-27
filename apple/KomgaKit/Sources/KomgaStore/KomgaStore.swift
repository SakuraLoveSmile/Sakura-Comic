import Foundation
import GRDB
import KomgaAPI

/// Local-first store on GRDB.
///
/// All reads and writes go through `dbQueue` (serialized per transaction),
/// so observers see consistent snapshots. Credentials are never stored here —
/// only `credentialRef` references into Keychain.
public final class KomgaStore: @unchecked Sendable {
    let dbQueue: DatabaseQueue

    /// Opens (or creates) the database at `path` and applies migrations.
    public init(path: String) throws {
        self.dbQueue = try DatabaseQueue(path: path)
        try self.migrate()
    }

    /// In-memory store for tests and previews.
    public init() throws {
        self.dbQueue = try DatabaseQueue()
        try self.migrate()
    }

    public func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try Schema.migrate(db)
        }
    }

    // MARK: - Server profiles

    /// Insert or update a server profile.
    public func upsertServer(_ profile: ServerProfile) throws {
        try dbQueue.write { db in
            _ = try db.execute(
                sql: """
                INSERT INTO servers (id, display_name, base_url, auth_type, credential_ref, capabilities, last_successful_connection)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  display_name = excluded.display_name,
                  base_url = excluded.base_url,
                  auth_type = excluded.auth_type,
                  credential_ref = excluded.credential_ref,
                  capabilities = excluded.capabilities,
                  last_successful_connection = excluded.last_successful_connection
                """,
                arguments: [
                    profile.id,
                    profile.displayName,
                    profile.baseURL,
                    profile.authType.rawValue,
                    profile.credentialRef,
                    Self.encodeCapabilities(profile.capabilities),
                    profile.lastSuccessfulConnection.map(Self.rfc3339),
                ]
            )
        }
    }

    /// All server profiles, ordered by display name.
    public func fetchServers() throws -> [ServerProfile] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM servers ORDER BY display_name")
                .map(Self.profile(from:))
        }
    }

    public func server(id: String) throws -> ServerProfile? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM servers WHERE id = ?", arguments: [id])
                .map(Self.profile(from:))
        }
    }

    /// Returns true if a row was deleted.
    @discardableResult
    public func deleteServer(id: String) throws -> Bool {
        try dbQueue.write { db in
            // Deleting the active server clears the active state with it.
            if try activeServerID(db: db) == id {
                try db.execute(sql: "DELETE FROM app_state WHERE key = ?", arguments: [Self.activeServerKey])
            }
            // Cascade: the full mirrored rows for this server go away
            // (cover files are removed by the caller through DiskImageCache).
            let tables = [
                "series", "books", "series_metadata", "book_metadata",
                "series_tags", "series_genres", "series_authors",
                "book_tags", "book_authors",
                "collections", "collection_series",
                "readlists", "readlist_books",
                "read_progress", "libraries", "sync_state", "pending_mutations",
                "thumbnails", "downloads", "download_pages", "deleted_entities",
            ]
            for table in tables {
                try db.execute(sql: "DELETE FROM \(table) WHERE server_id = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM series_fts WHERE server_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM book_fts WHERE server_id = ?", arguments: [id])
            // The servers delete runs last so changesCount reflects it.
            try db.execute(sql: "DELETE FROM servers WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    // MARK: - Active server

    private static let activeServerKey = "active_server_id"

    public func setActiveServer(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO app_state (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [Self.activeServerKey, id]
            )
        }
    }

    public func activeServerID() throws -> String? {
        try dbQueue.read { db in try self.activeServerID(db: db) }
    }

    private func activeServerID(db: GRDB.Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM app_state WHERE key = ?",
            arguments: [Self.activeServerKey]
        )
    }

    /// The server profile currently marked active, if any.
    public func activeServerProfile() throws -> ServerProfile? {
        guard let id = try activeServerID() else { return nil }
        return try server(id: id)
    }

    // MARK: - Libraries

    /// Batch upsert remotely fetched libraries (multi-server safe).
    @discardableResult
    public func upsertLibraries(serverID: String, libraries: [LibraryDTO]) throws -> Int {
        try dbQueue.write { db in
            var written = 0
            for library in libraries {
                let record = LibraryRecord(serverID: serverID, dto: library)
                _ = try db.execute(
                    sql: """
                    INSERT INTO libraries (server_id, remote_id, name, root, unavailable)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(server_id, remote_id)
                    DO UPDATE SET name = excluded.name, root = excluded.root,
                                  unavailable = excluded.unavailable
                    """,
                    arguments: [
                        record.serverID, record.remoteID, record.name,
                        record.root, record.unavailable ? 1 : 0
                    ]
                )
                written += 1
            }
            return written
        }
    }

    /// All libraries for one server, ordered by name.
    public func fetchLibraries(serverID: String) throws -> [LibraryRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM libraries WHERE server_id = ? ORDER BY name COLLATE NOCASE",
                arguments: [serverID]
            ).map { row in
                let root: String? = row["root"]
                let unavailableFlag: Int? = row["unavailable"]
                return LibraryRecord(
                    serverID: row["server_id"],
                    remoteID: row["remote_id"],
                    name: row["name"],
                    root: root,
                    unavailable: (unavailableFlag ?? 0) != 0
                )
            }
        }
    }

    // MARK: - Series

    /// Batch upsert remotely fetched series (local-first mirror).
    @discardableResult
    public func upsertSeriesBatch(_ records: [SeriesRecord]) throws -> Int {
        try dbQueue.write { db in
            var written = 0
            for record in records {
                _ = try db.execute(
                    sql: """
                    INSERT INTO series (server_id, remote_id, library_id, name, sort_name, status, created_at, last_modified)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(server_id, remote_id) DO UPDATE SET
                      library_id = excluded.library_id,
                      name = excluded.name,
                      sort_name = excluded.sort_name,
                      status = excluded.status,
                      created_at = excluded.created_at,
                      last_modified = excluded.last_modified
                    """,
                    arguments: [
                        record.serverID,
                        record.remoteID,
                        record.libraryID,
                        record.name,
                        record.sortName,
                        record.status,
                        record.createdAt,
                        record.lastModified,
                    ]
                )
                written += 1
            }
            return written
        }
    }

    /// Paged query ordered by name (case-insensitive).
    public func fetchSeries(serverID: String, limit: Int, offset: Int) throws -> [SeriesRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM series WHERE server_id = ? ORDER BY name COLLATE NOCASE LIMIT ? OFFSET ?",
                arguments: [serverID, limit, offset]
            ).map(Self.seriesRecord(from:))
        }
    }

    public func countSeries(serverID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM series WHERE server_id = ?", arguments: [serverID]) ?? 0
        }
    }

    // MARK: - Thumbnails (cover-cache bookkeeping)

    /// Insert or refresh the cover record for one remote entity.
    public func upsertThumbnail(_ record: ThumbnailRecord) throws {
        try dbQueue.write { db in
            _ = try db.execute(
                sql: """
                INSERT INTO thumbnails (server_id, remote_id, variant, local_path, size_bytes, last_access)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(server_id, remote_id, variant) DO UPDATE SET
                  local_path = excluded.local_path,
                  size_bytes = excluded.size_bytes,
                  last_access = excluded.last_access
                """,
                arguments: [
                    record.serverID,
                    record.remoteID,
                    record.variant,
                    record.localPath,
                    record.sizeBytes,
                    Self.rfc3339(record.lastAccess),
                ]
            )
        }
    }

    /// The cover record for one entity, if any.
    public func thumbnail(
        serverID: String,
        remoteID: String,
        variant: String = ThumbnailRecord.variantSeries
    ) throws -> ThumbnailRecord? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM thumbnails WHERE server_id = ? AND remote_id = ? AND variant = ?",
                arguments: [serverID, remoteID, variant]
            ).map(Self.thumbnail(from:))
        }
    }

    /// All cover records for one server (the grid maps remoteID → path).
    public func listThumbnails(serverID: String) throws -> [ThumbnailRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM thumbnails WHERE server_id = ? ORDER BY remote_id",
                arguments: [serverID]
            ).map(Self.thumbnail(from:))
        }
    }

    /// The local cover file path for one entity, resolved from SQLite only.
    public func coverPath(serverID: String, remoteID: String) throws -> String? {
        try thumbnail(serverID: serverID, remoteID: remoteID)?.localPath
    }

    // MARK: - Sync state

    /// Record a successful sync: timestamp + status back to idle, error
    /// cleared. Returns the refreshed rollup row (mirror of Rust
    /// `touch_successful_sync`).
    @discardableResult
    public func recordSuccessfulSync(serverID: String) throws -> SyncStateRecord {
        let now = Self.rfc3339Text(Date())
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (server_id, entity_type, last_sync_at, sync_status, last_successful_sync)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(server_id, entity_type) DO UPDATE SET
                  last_sync_at = excluded.last_sync_at,
                  sync_status = excluded.sync_status,
                  last_error = NULL,
                  last_successful_sync = excluded.last_successful_sync
                """,
                arguments: [serverID, SyncEntity.full, now, SyncStatus.idle, now]
            )
        }
        guard let row = try syncState(serverID: serverID) else {
            throw GRDB.DatabaseError(resultCode: .SQLITE_ERROR, message: "sync_state row missing")
        }
        return row
    }

    /// The server-level rollup (the `full` row), if any.
    public func syncState(serverID: String) throws -> SyncStateRecord? {
        try entityState(serverID: serverID, entityType: SyncEntity.full).map(SyncStateRecord.init)
    }

    // MARK: - Row mapping

    private static func thumbnail(from row: Row) throws -> ThumbnailRecord {
        let lastAccess: String = row["last_access"]
        return ThumbnailRecord(
            serverID: row["server_id"],
            remoteID: row["remote_id"],
            variant: row["variant"],
            localPath: row["local_path"],
            sizeBytes: row["size_bytes"],
            lastAccess: date(from: lastAccess) ?? Date()
        )
    }

    private static func seriesRecord(from row: Row) throws -> SeriesRecord {
        SeriesRecord(
            serverID: row["server_id"],
            remoteID: row["remote_id"],
            libraryID: row["library_id"],
            name: row["name"],
            sortName: row["sort_name"],
            status: row["status"],
            createdAt: row["created_at"],
            lastModified: row["last_modified"]
        )
    }

    // MARK: - Helpers

    private static func encodeCapabilities(_ capabilities: [String]) -> String {
        let data = (try? JSONEncoder().encode(capabilities)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// RFC 3339 with fractional seconds so millisecond-truncated Dates
    /// round-trip exactly (verified empirically; sub-second precision is
    /// otherwise lost and equality breaks). Instances are created per call
    /// (formatting/parsing are rare, and ISO8601DateFormatter is not
    /// Sendable, so no shared state under Swift 6 strict concurrency).
    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Prefer fractional; fall back to plain (older rows, other clients).
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func profile(from row: Row) throws -> ServerProfile {
        let capabilitiesJSON: String? = row["capabilities"]
        let capabilities = (try? JSONDecoder().decode(
            [String].self,
            from: Data((capabilitiesJSON ?? "[]").utf8)
        )) ?? []
        let authTypeRaw: String? = row["auth_type"]
        let lastRaw: String? = row["last_successful_connection"]
        return ServerProfile(
            id: row["id"],
            displayName: row["display_name"],
            baseURL: row["base_url"],
            authType: AuthType(rawValue: authTypeRaw ?? "") ?? .apiKey,
            credentialRef: row["credential_ref"],
            capabilities: capabilities,
            lastSuccessfulConnection: lastRaw.flatMap(Self.date(from:))
        )
    }
}
