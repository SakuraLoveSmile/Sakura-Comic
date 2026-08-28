//! SQLite schema (mirrors `docs/database-schema.md`).
//!
//! DDL lives here once and is kept in sync with the Swift side
//! (`apple/KomgaKit/Sources/KomgaStore/Schema.swift`).

use rusqlite::{Connection, OptionalExtension};

/// Bump on every migration; stored in `PRAGMA user_version`.
pub const SCHEMA_VERSION: i64 = 7;

/// Individual DDL statements, applied in order. `CREATE TABLE IF NOT EXISTS`
/// keeps existing databases untouched, so older installs get their missing
/// columns through `V4_ALTER_STATEMENTS` (guarded by column checks).
pub const CREATE_STATEMENTS: &[&str] = &[
    "CREATE TABLE IF NOT EXISTS servers (
      id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      base_url TEXT NOT NULL,
      auth_type TEXT NOT NULL,
      credential_ref TEXT,
      capabilities TEXT NOT NULL DEFAULT '[]',
      last_successful_connection TEXT
    )",
    // v2: single-value app state (active server id, ...).
    "CREATE TABLE IF NOT EXISTS app_state (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )",
    // v5: root + unavailable so the Library list/detail screens have real
    // metadata to render from SQLite.
    "CREATE TABLE IF NOT EXISTS libraries (
      server_id TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      name TEXT NOT NULL,
      root TEXT,
      unavailable INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (server_id, remote_id)
    )",
    // v4: per-series read counters + `fts_rowid` (incremental FTS5 updates).
    "CREATE TABLE IF NOT EXISTS series (
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
    )",
    // v4: book display fields + page count + `fts_rowid`.
    "CREATE TABLE IF NOT EXISTS books (
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
    )",
    "CREATE TABLE IF NOT EXISTS collections (
      server_id TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      name TEXT NOT NULL,
      ordered INTEGER NOT NULL DEFAULT 0,
      filtered INTEGER NOT NULL DEFAULT 0,
      created_date TEXT,
      last_modified_date TEXT,
      PRIMARY KEY (server_id, remote_id)
    )",
    "CREATE TABLE IF NOT EXISTS readlists (
      server_id TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      name TEXT NOT NULL,
      summary TEXT,
      ordered INTEGER NOT NULL DEFAULT 0,
      filtered INTEGER NOT NULL DEFAULT 0,
      created_date TEXT,
      last_modified_date TEXT,
      PRIMARY KEY (server_id, remote_id)
    )",
    "CREATE TABLE IF NOT EXISTS read_progress (
      server_id TEXT NOT NULL,
      book_id TEXT NOT NULL,
      page INTEGER,
      completed INTEGER NOT NULL DEFAULT 0,
      local_updated_at TEXT,
      server_updated_at TEXT,
      mutation_pending INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (server_id, book_id)
    )",
    // v4: full series metadata (summary/publisher/etc. + FTS 搜索列).
    "CREATE TABLE IF NOT EXISTS series_metadata (
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
    )",
    "CREATE TABLE IF NOT EXISTS book_metadata (
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
    )",
    // v6: one row per (server, entity type). `sync_cursor` is the resume
    // point of an interrupted sweep and `sync_status` tells the UI whether a
    // step is idle / running / failed, so Bootstrap can pick up where it
    // stopped instead of starting over. The `full` entity type carries the
    // server-level rollup (`last_full_sync` / `last_successful_sync`).
    "CREATE TABLE IF NOT EXISTS sync_state (
      server_id TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      last_sync_at TEXT,
      sync_cursor TEXT,
      sync_status TEXT NOT NULL DEFAULT 'idle',
      last_error TEXT,
      last_full_sync TEXT,
      last_successful_sync TEXT,
      PRIMARY KEY (server_id, entity_type)
    )",
    // v6: remote deletions discovered by Reconcile. The mirrored row itself
    // is removed (cascade); the tombstone records that it is gone, so a
    // late-arriving event or a stale Outbox mutation can be recognised.
    "CREATE TABLE IF NOT EXISTS deleted_entities (
      server_id TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      deleted_at TEXT NOT NULL,
      cause TEXT NOT NULL DEFAULT 'reconcile',
      PRIMARY KEY (server_id, entity_type, remote_id)
    )",
    // v7: `state` + `next_retry_at` make the Outbox consumable — a queued write
    // survives a kill, and its backoff deadline is absolute so a restart cannot
    // reset the penalty.
    "CREATE TABLE IF NOT EXISTS pending_mutations (
      id TEXT PRIMARY KEY,
      server_id TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      mutation_type TEXT NOT NULL,
      payload TEXT NOT NULL,
      created_at TEXT NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      state TEXT NOT NULL DEFAULT 'pending',
      next_retry_at TEXT
    )",
    "CREATE INDEX IF NOT EXISTS pending_mutations_due
       ON pending_mutations (server_id, state, next_retry_at)",
    "CREATE TABLE IF NOT EXISTS downloads (
      server_id TEXT NOT NULL,
      book_id TEXT NOT NULL,
      manifest_path TEXT,
      pages_total INTEGER,
      pages_done INTEGER,
      state TEXT NOT NULL,
      PRIMARY KEY (server_id, book_id)
    )",
    "CREATE TABLE IF NOT EXISTS download_pages (
      server_id TEXT NOT NULL,
      book_id TEXT NOT NULL,
      page_number INTEGER NOT NULL,
      file_path TEXT,
      state TEXT NOT NULL,
      PRIMARY KEY (server_id, book_id, page_number)
    )",
    // v3: cover-cache bookkeeping — the UI resolves a cover's local file
    // path from SQLite (local-first: 本地数据库负责展示). Kept separate from
    // `cache_entries` (generic LRU cache for pages/prefetch, later phases).
    "CREATE TABLE IF NOT EXISTS thumbnails (
      server_id TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      variant TEXT NOT NULL DEFAULT 'series',
      local_path TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      last_access TEXT NOT NULL,
      PRIMARY KEY (server_id, remote_id, variant)
    )",
    "CREATE TABLE IF NOT EXISTS cache_entries (
      key TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      path TEXT NOT NULL,
      size INTEGER NOT NULL,
      last_access TEXT NOT NULL
    )",
    // v4: normalized filter tables — tags / genres / authors are queryable
    // (本地查询：筛选全部发生在 SQLite，避免 JSON 解析)。
    "CREATE TABLE IF NOT EXISTS series_genres (
      server_id TEXT NOT NULL,
      series_id TEXT NOT NULL,
      genre TEXT NOT NULL,
      PRIMARY KEY (server_id, series_id, genre)
    )",
    "CREATE TABLE IF NOT EXISTS series_tags (
      server_id TEXT NOT NULL,
      series_id TEXT NOT NULL,
      tag TEXT NOT NULL,
      PRIMARY KEY (server_id, series_id, tag)
    )",
    "CREATE TABLE IF NOT EXISTS series_authors (
      server_id TEXT NOT NULL,
      series_id TEXT NOT NULL,
      name TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (server_id, series_id, name, role)
    )",
    "CREATE TABLE IF NOT EXISTS book_tags (
      server_id TEXT NOT NULL,
      book_id TEXT NOT NULL,
      tag TEXT NOT NULL,
      PRIMARY KEY (server_id, book_id, tag)
    )",
    "CREATE TABLE IF NOT EXISTS book_authors (
      server_id TEXT NOT NULL,
      book_id TEXT NOT NULL,
      name TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (server_id, book_id, name, role)
    )",
    "CREATE TABLE IF NOT EXISTS collection_series (
      server_id TEXT NOT NULL,
      collection_id TEXT NOT NULL,
      series_id TEXT NOT NULL,
      PRIMARY KEY (server_id, collection_id, series_id)
    )",
    "CREATE TABLE IF NOT EXISTS readlist_books (
      server_id TEXT NOT NULL,
      readlist_id TEXT NOT NULL,
      book_id TEXT NOT NULL,
      position INTEGER NOT NULL,
      PRIMARY KEY (server_id, readlist_id, book_id)
    )",
    // v4: FTS5 search indexes — `server_id` is UNINDEXED so a full rebuild
    // stays server-scoped; `fts_rowid` on series/books keeps updates
    // incremental. 搜索、筛选和排序全部基于 SQLite。
    "CREATE VIRTUAL TABLE IF NOT EXISTS series_fts USING fts5(server_id UNINDEXED, name, sort_name, authors, publisher, tags, summary)",
    "CREATE VIRTUAL TABLE IF NOT EXISTS book_fts USING fts5(server_id UNINDEXED, title, authors, publisher, tags, summary)",
];

/// v3 → v4: columns added to tables that already exist on disk.
/// Applied one by one, skipped when the column is already present.
pub const V4_ALTER_STATEMENTS: &[&str] = &[
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
];

/// v4 → v5: libraries gained their detail columns.
pub const V5_ALTER_STATEMENTS: &[&str] = &[
    "ALTER TABLE libraries ADD COLUMN root TEXT",
    "ALTER TABLE libraries ADD COLUMN unavailable INTEGER NOT NULL DEFAULT 0",
];

/// v6 → v7: the Outbox grew its retry/scheduling columns.
pub const V7_ALTER_STATEMENTS: &[&str] = &[
    "ALTER TABLE pending_mutations ADD COLUMN state TEXT NOT NULL DEFAULT 'pending'",
    "ALTER TABLE pending_mutations ADD COLUMN next_retry_at TEXT",
];

/// True when a table exists and has the given column.
fn table_has_column(conn: &Connection, table: &str, column: &str) -> rusqlite::Result<bool> {
    let mut stmt = conn.prepare(&format!(
        "SELECT COUNT(*) FROM pragma_table_info('{table}') WHERE name = ?1"
    ))?;
    let count: i64 = stmt.query_row([column], |row| row.get(0))?;
    Ok(count > 0)
}

/// Rename the FTS tables' old column shape (pre-v4: no `server_id` column)
/// so the new server-scoped index can be created. Derived data only — the
/// next sync rebuilds it.
fn migrate_fts_shape(conn: &Connection) -> rusqlite::Result<()> {
    for table in ["series_fts", "book_fts"] {
        let sql: Option<String> = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [table],
                |row| row.get(0),
            )
            .optional()?;
        let needs_recreate = match sql {
            Some(ddl) => !ddl.contains("server_id"),
            None => false, // never existed → CREATE later builds the new shape
        };
        if needs_recreate {
            conn.execute(&format!("DROP TABLE IF EXISTS {table}"), [])?;
        }
    }
    Ok(())
}

/// v5 → v6: `sync_state` gains `entity_type` as part of its primary key, so
/// an existing table has to be rebuilt (SQLite cannot alter a PK). The old
/// single row per server becomes the `full` rollup row.
fn migrate_sync_state_shape(conn: &Connection) -> rusqlite::Result<()> {
    let ddl: Option<String> = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'sync_state'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    let Some(ddl) = ddl else {
        return Ok(()); // never existed → CREATE builds the v6 shape
    };
    if ddl.contains("entity_type") {
        return Ok(());
    }
    conn.execute_batch(
        "CREATE TABLE sync_state_v6 (
           server_id TEXT NOT NULL,
           entity_type TEXT NOT NULL,
           last_sync_at TEXT,
           sync_cursor TEXT,
           sync_status TEXT NOT NULL DEFAULT 'idle',
           last_error TEXT,
           last_full_sync TEXT,
           last_successful_sync TEXT,
           PRIMARY KEY (server_id, entity_type)
         );
         INSERT INTO sync_state_v6 (server_id, entity_type, last_sync_at, sync_status,
                                    last_error, last_full_sync, last_successful_sync)
           SELECT server_id, 'full',
                  COALESCE(last_successful_sync, last_full_sync),
                  sync_status, last_error, last_full_sync, last_successful_sync
           FROM sync_state;
         DROP TABLE sync_state;
         ALTER TABLE sync_state_v6 RENAME TO sync_state;",
    )?;
    Ok(())
}

/// Apply all statements and stamp the schema version.
pub fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    // The sync engine opens a connection per page (a `Connection` must never be
    // held across an `await`), so this runs hundreds of times per sweep. The
    // version stamp makes repeat opens one query instead of ~40 DDL statements;
    // `user_version` is only written after a migration succeeded, so a
    // half-applied database is never skipped.
    let version: i64 = conn.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    if version == SCHEMA_VERSION {
        return Ok(());
    }
    migrate_fts_shape(conn)?;
    migrate_sync_state_shape(conn)?;
    for statement in CREATE_STATEMENTS {
        conn.execute(statement, [])?;
    }
    // Column additions for tables that already exist on disk (skip when present).
    let alters: Vec<&str> = V4_ALTER_STATEMENTS
        .iter()
        .chain(V5_ALTER_STATEMENTS)
        .chain(V7_ALTER_STATEMENTS)
        .copied()
        .collect();
    for statement in &alters {
        // "ALTER TABLE {t} ADD COLUMN {c} ..." → split off the column name.
        let rest = statement
            .strip_prefix("ALTER TABLE ")
            .expect("alter statements are ALTER TABLE");
        let (table, col_part) = rest.split_once(" ADD COLUMN ").expect("alter shape");
        let column = col_part
            .split_whitespace()
            .next()
            .expect("column name present");
        if !table_has_column(conn, table, column)? {
            conn.execute(statement, [])?;
        }
    }
    conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    Ok(())
}
