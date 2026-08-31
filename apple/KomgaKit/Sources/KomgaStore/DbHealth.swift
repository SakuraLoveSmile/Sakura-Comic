import Foundation
import GRDB

// MARK: - The database's own account of itself (mirror of Rust `diagnostics::snapshot`)
//
// Every hardening claim — "an upgrade loses nothing", "cache corruption is
// recoverable", "sync is stable over a long run" — is a claim about this store.
// These are the answers the store gives about itself, so a gate can compare them
// against an outside witness (`sqlite3` on the command line, or `find`) instead
// of trusting a number the code printed about its own work.
//
// Reads only. Nothing in here repairs, prunes or migrates.

/// Row count for one table.
public struct TableRows: Codable, Sendable, Equatable {
    public var table: String
    public var rows: Int
}

/// The pragmas that decide whether this connection is the one the store was
/// configured to open, plus the size of the mirror table by table.
public struct DatabaseHealth: Codable, Sendable, Equatable {
    public var schemaVersion: Int64
    /// `"ok"`, or the first complaint from `PRAGMA integrity_check`.
    public var integrity: String
    public var journalMode: String
    public var pageSize: Int64
    public var pageCount: Int64
    public var freelistCount: Int64
    public var busyTimeoutMs: Int64
    public var foreignKeysOn: Bool
    /// `page_size * page_count`. The `-wal` and `-shm` siblings are deliberately
    /// left out: their size depends on when a checkpoint last ran, which is not a
    /// fact about the data.
    public var fileBytes: Int64
    public var tables: [TableRows]
}

public extension KomgaStore {
    /// Suffixes SQLite gives the shadow tables of an FTS index. They are physical
    /// storage, not content, and a gate that counted them beside `series` and
    /// `books` would be comparing a mirror against its own index.
    static let ftsShadowSuffixes = ["_content", "_idx", "_docsize", "_config", "_data"]

    /// Double-quote an identifier. Every name passed here came out of
    /// `sqlite_master` for this very database, so it is a real table; the quoting
    /// is for names containing characters that need it, not for trust.
    static func quotedIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func userTables() throws -> [String] {
        try dbQueue.read { db in try Self.userTables(db: db) }
    }

    static func userTables(db: GRDB.Database) throws -> [String] {
        let names = try String.fetchAll(
            db,
            sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """
        )
        return names.filter { name in
            !ftsShadowSuffixes.contains { name.hasSuffix($0) }
        }
    }

    static func countRows(db: GRDB.Database, table: String) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM \(quotedIdentifier(table))"
        ) ?? 0
    }

    /// `count(*)` for one table, or nil when the table is not there — so a
    /// diagnostic can ask about a table a given schema version may not have
    /// introduced without turning "not yet" into an error.
    static func countRowsIfTable(db: GRDB.Database, table: String) throws -> Int? {
        let exists = try String.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        )
        guard exists != nil else { return nil }
        return try countRows(db: db, table: table)
    }

    func tableCounts() throws -> [TableRows] {
        try dbQueue.read { db in try Self.tableCounts(db: db) }
    }

    static func tableCounts(db: GRDB.Database) throws -> [TableRows] {
        try userTables(db: db).map { TableRows(table: $0, rows: try countRows(db: db, table: $0)) }
    }

    static func integrityCheck(db: GRDB.Database) throws -> String {
        try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "no verdict"
    }

    private static func pragmaInt(_ db: GRDB.Database, _ pragma: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: pragma) ?? 0
    }

    func databaseHealth() throws -> DatabaseHealth {
        try dbQueue.read { db in try Self.databaseHealth(db: db) }
    }

    static func databaseHealth(db: GRDB.Database) throws -> DatabaseHealth {
        let pageSize = try pragmaInt(db, "PRAGMA page_size")
        let pageCount = try pragmaInt(db, "PRAGMA page_count")
        return DatabaseHealth(
            schemaVersion: try pragmaInt(db, "PRAGMA user_version"),
            integrity: try integrityCheck(db: db),
            journalMode: (try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "").lowercased(),
            pageSize: pageSize,
            pageCount: pageCount,
            freelistCount: try pragmaInt(db, "PRAGMA freelist_count"),
            busyTimeoutMs: try pragmaInt(db, "PRAGMA busy_timeout"),
            foreignKeysOn: try pragmaInt(db, "PRAGMA foreign_keys") == 1,
            fileBytes: pageSize * pageCount,
            tables: try tableCounts(db: db)
        )
    }
}
