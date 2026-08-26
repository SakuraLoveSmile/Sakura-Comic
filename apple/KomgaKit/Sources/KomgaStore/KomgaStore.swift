import Foundation
import GRDB

/// Local-first store on GRDB.
///
/// All reads and writes go through `dbQueue` (serialized per transaction),
/// so observers see consistent snapshots. Credentials are never stored here —
/// only `credentialRef` references into Keychain.
public final class KomgaStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

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
            for statement in Schema.createStatements {
                try db.execute(sql: statement)
            }
            try db.execute(sql: "PRAGMA user_version = \(Schema.currentVersion)")
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
            try db.execute(sql: "DELETE FROM servers WHERE id = ?", arguments: [id])
            return db.changesCount > 0
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

    // MARK: - Row mapping

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

    private static func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func date(from string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
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
