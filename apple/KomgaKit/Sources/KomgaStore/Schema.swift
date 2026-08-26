import GRDB

/// SQLite schema DDL, kept in sync with `docs/database-schema.md`
/// and the Rust side (`android/komga_core/src/store/schema.rs`).
public enum Schema {
    /// Bump when migrations are added; stored in `PRAGMA user_version`.
    public static let currentVersion: Int64 = 4

    public static let createStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS servers (
          id TEXT PRIMARY KEY,
          display_name TEXT NOT NULL,
          base_url TEXT NOT NULL,
          auth_type TEXT NOT NULL,
          credential_ref TEXT,
          capabilities TEXT NOT NULL DEFAULT '[]',
          last_successful_connection TEXT
        )
        """,
        // v2: single-value app state (active server id, ...).
        """
        CREATE TABLE IF NOT EXISTS app_state (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS libraries (
          server_id TEXT NOT NULL,
          remote_id TEXT NOT NULL,
          name TEXT NOT NULL,
          PRIMARY KEY (server_id, remote_id)
        )
        """,
        // v4: per-series read counters + `fts_rowid` (incremental FTS5 updates).
        """
        CREATE TABLE IF NOT EXISTS series (
          server_id TEXT NOT NULL,
          remote_id TEXT NOT NULL,
          library_id TEXT NOT NULL,
          name TEXT NOT NULL,
          sort_name TEXT,
          status TEXT,
          created_at TEXT,
          last_modified TEXT,
          books_count INTEGER,
          books_read_count INTEGER,
          books_unread_count INTEGER,
          books_in_progress_count INTEGER,
          fts_rowid INTEGER,
          PRIMARY KEY (server_id, remote_id)
        )
        """,
        // v4: book display fields + page count + `fts_rowid`.
        """
        CREATE TABLE IF NOT EXISTS books (
          server_id TEXT NOT NULL,
          remote_id TEXT NOT NULL,
          series_id TEXT NOT NULL,
          series_title TEXT,
          title TEXT NOT NULL,
          number TEXT,
          number_sort REAL,
          file_size INTEGER,
          media_type TEXT,
          pages_count INTEGER,
          created_at TEXT,
          last_modified TEXT,
          oneshot INTEGER NOT NULL DEFAULT 0,
          fts_rowid INTEGER,
          PRIMARY KEY (server_id, remote_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS collections (
          server_id TEXT NOT NULL,
          remote_id TEXT NOT NULL,
          name TEXT NOT NULL,
          ordered INTEGER NOT NULL DEFAULT 0,
          filtered INTEGER NOT NULL DEFAULT 0,
          created_date TEXT,
          last_modified_date TEXT,
          PRIMARY KEY (server_id, remote_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS readlists (
          server_id TEXT NOT NULL,
          remote_id TEXT NOT NULL,
          name TEXT NOT NULL,
          summary TEXT,
          ordered INTEGER NOT NULL DEFAULT 0,
          filtered INTEGER NOT NULL DEFAULT 0,
          created_date TEXT,
          last_modified_date TEXT,
          PRIMARY KEY (server_id, remote_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS read_progress (
          server_id TEXT NOT NULL,
          book_id TEXT NOT NULL,
          page INTEGER,
          completed INTEGER NOT NULL DEFAULT 0,
          local_updated_at TEXT,
          server_updated_at TEXT,
          mutation_pending INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (server_id, book_id)
        )
        """,
        // v4: full series metadata (summary/publisher/etc. + FTS 搜索列).
        """
        CREATE TABLE IF NOT EXISTS series_metadata (
          server_id TEXT NOT NULL,
          series_id TEXT NOT NULL,
          summary TEXT,
          publisher TEXT,
          reading_direction TEXT,
          language TEXT,
          age_rating TEXT,
          title_sort TEXT,
          total_book_count INTEGER,
          authors TEXT NOT NULL DEFAULT '[]',
          tags TEXT NOT NULL DEFAULT '[]',
          PRIMARY KEY (server_id, series_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS book_metadata (
          server_id TEXT NOT NULL,
          book_id TEXT NOT NULL,
          summary TEXT,
          number TEXT,
          number_sort REAL,
          isbn TEXT,
          release_date TEXT,
          authors TEXT NOT NULL DEFAULT '[]',
          tags TEXT NOT NULL DEFAULT '[]',
          PRIMARY KEY (server_id, book_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS sync_state (
          server_id TEXT PRIMARY KEY,
          last_full_sync TEXT,
          last_successful_sync TEXT,
          last_error TEXT,
          sync_status TEXT NOT NULL DEFAULT 'idle'
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS pending_mutations (
          id TEXT PRIMARY KEY,
          server_id TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          mutation_type TEXT NOT NULL,
          payload TEXT NOT NULL,
          created_at TEXT NOT NULL,
          retry_count INTEGER NOT NULL DEFAULT 0,
          last_error TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS downloads (
          server_id TEXT NOT NULL,
          book_id TEXT NOT NULL,
          manifest_path TEXT,
          pages_total INTEGER,
          pages_done INTEGER,
          state TEXT NOT NULL,
          PRIMARY KEY (server_id, book_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS download_pages (
          server_id TEXT NOT NULL,
          book_id TEXT NOT NULL,
          page_number INTEGER NOT NULL,
          file_path TEXT,
          state TEXT NOT NULL,
          PRIMARY KEY (server_id, book_id, page_number)
        )
        """,
        // v3: cover-cache bookkeeping — the UI resolves a cover's local file
        // path from SQLite (local-first: 本地数据库负责展示). Kept separate from
        // `cache_entries` (generic LRU cache for pages/prefetch, later phases).
        """
        CREATE TABLE IF NOT EXISTS thumbnails (
          server_id TEXT NOT NULL,
          remote_id TEXT NOT NULL,
          variant TEXT NOT NULL DEFAULT 'series',
          local_path TEXT NOT NULL,
          size_bytes INTEGER NOT NULL,
          last_access TEXT NOT NULL,
          PRIMARY KEY (server_id, remote_id, variant)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS cache_entries (
          key TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          path TEXT NOT NULL,
          size INTEGER NOT NULL,
          last_access TEXT NOT NULL
        )
        """,
        // v4: normalized filter tables — tags / genres / authors are queryable
        // (本地查询：筛选全部发生在 SQLite，避免 JSON 解析)。
        """
        CREATE TABLE IF NOT EXISTS series_genres (
          server_id TEXT NOT NULL,
          series_id TEXT NOT NULL,
          genre TEXT NOT NULL,
          PRIMARY KEY (server_id, series_id, genre)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS series_tags (
          server_id TEXT NOT NULL,
          series_id TEXT NOT NULL,
          tag TEXT NOT NULL,
          PRIMARY KEY (server_id, series_id, tag)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS series_authors (
          server_id TEXT NOT NULL,
          series_id TEXT NOT NULL,
          name TEXT NOT NULL,
          role TEXT NOT NULL DEFAULT '',
          PRIMARY KEY (server_id, series_id, name, role)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS book_tags (
          server_id TEXT NOT NULL,
          book_id TEXT NOT NULL,
          tag TEXT NOT NULL,
          PRIMARY KEY (server_id, book_id, tag)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS book_authors (
          server_id TEXT NOT NULL,
          book_id TEXT NOT NULL,
          name TEXT NOT NULL,
          role TEXT NOT NULL DEFAULT '',
          PRIMARY KEY (server_id, book_id, name, role)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS collection_series (
          server_id TEXT NOT NULL,
          collection_id TEXT NOT NULL,
          series_id TEXT NOT NULL,
          PRIMARY KEY (server_id, collection_id, series_id)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS readlist_books (
          server_id TEXT NOT NULL,
          readlist_id TEXT NOT NULL,
          book_id TEXT NOT NULL,
          position INTEGER NOT NULL,
          PRIMARY KEY (server_id, readlist_id, book_id)
        )
        """,
        // v4: FTS5 search indexes — `server_id` is UNINDEXED so a full rebuild
        // stays server-scoped; `fts_rowid` on series/books keeps updates
        // incremental. 搜索、筛选和排序全部基于 SQLite。
        "CREATE VIRTUAL TABLE IF NOT EXISTS series_fts USING fts5(server_id UNINDEXED, name, sort_name, authors, publisher, tags, summary)",
        "CREATE VIRTUAL TABLE IF NOT EXISTS book_fts USING fts5(server_id UNINDEXED, title, authors, publisher, tags, summary)",
    ]

    /// v3 → v4: columns added to tables that already exist on disk.
    /// Applied one by one, skipped when the column is already present
    /// (mirror of Rust `V4_ALTER_STATEMENTS`).
    public static let v4AlterStatements: [String] = [
        "ALTER TABLE series ADD COLUMN books_count INTEGER",
        "ALTER TABLE series ADD COLUMN books_read_count INTEGER",
        "ALTER TABLE series ADD COLUMN books_unread_count INTEGER",
        "ALTER TABLE series ADD COLUMN books_in_progress_count INTEGER",
        "ALTER TABLE series ADD COLUMN fts_rowid INTEGER",
        "ALTER TABLE books ADD COLUMN series_title TEXT",
        "ALTER TABLE books ADD COLUMN number TEXT",
        "ALTER TABLE books ADD COLUMN number_sort REAL",
        "ALTER TABLE books ADD COLUMN pages_count INTEGER",
        "ALTER TABLE books ADD COLUMN oneshot INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE books ADD COLUMN fts_rowid INTEGER",
        "ALTER TABLE collections ADD COLUMN ordered INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE collections ADD COLUMN filtered INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE collections ADD COLUMN created_date TEXT",
        "ALTER TABLE collections ADD COLUMN last_modified_date TEXT",
        "ALTER TABLE readlists ADD COLUMN summary TEXT",
        "ALTER TABLE readlists ADD COLUMN ordered INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE readlists ADD COLUMN filtered INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE readlists ADD COLUMN created_date TEXT",
        "ALTER TABLE readlists ADD COLUMN last_modified_date TEXT",
        "ALTER TABLE series_metadata ADD COLUMN reading_direction TEXT",
        "ALTER TABLE series_metadata ADD COLUMN language TEXT",
        "ALTER TABLE series_metadata ADD COLUMN age_rating TEXT",
        "ALTER TABLE series_metadata ADD COLUMN title_sort TEXT",
        "ALTER TABLE series_metadata ADD COLUMN total_book_count INTEGER",
        "ALTER TABLE book_metadata ADD COLUMN number TEXT",
        "ALTER TABLE book_metadata ADD COLUMN number_sort REAL",
        "ALTER TABLE book_metadata ADD COLUMN isbn TEXT",
        "ALTER TABLE book_metadata ADD COLUMN release_date TEXT",
    ]

    /// Applies the full migration set on a connection (mirror of the Rust
    /// `schema::migrate`): FTS shape repair → CREATE statements → guarded
    /// v4 ALTER column additions → `PRAGMA user_version`.
    public static func migrate(_ db: GRDB.Database) throws {
        try repairFTSShape(db)
        for statement in createStatements {
            try db.execute(sql: statement)
        }
        for statement in v4AlterStatements {
            // "ALTER TABLE t ADD COLUMN column ..." → skip when present.
            guard let rest = statement.split(separator: " ADD COLUMN ").first,
                  let column = statement.split(separator: " ADD COLUMN ").dropFirst().first?
                    .split(separator: " ").first
            else { continue }
            let hasColumn = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?",
                arguments: [String(rest.replacingOccurrences(of: "ALTER TABLE ", with: "")), String(column)]
            ) ?? 0
            if hasColumn == 0 {
                try db.execute(sql: statement)
            }
        }
        try db.execute(sql: "PRAGMA user_version = \(currentVersion)")
    }

    /// Renames the pre-v4 FTS shape (no `server_id` column) so the
    /// server-scoped index can be created. Derived data only — the next
    /// sync rebuilds it (mirror of Rust `migrate_fts_shape`).
    private static func repairFTSShape(_ db: GRDB.Database) throws {
        for table in ["series_fts", "book_fts"] {
            let ddl = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [table]
            )
            if let ddl, !ddl.contains("server_id") {
                try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
            }
        }
    }
}