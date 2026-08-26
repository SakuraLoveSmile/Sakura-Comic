//! SQLite schema (mirrors `docs/database-schema.md`).
//!
//! DDL lives here once and is kept in sync with the Swift side
//! (`apple/KomgaKit/Sources/KomgaStore/Schema.swift`).

use rusqlite::Connection;

/// Bump on every migration; stored in `PRAGMA user_version`.
pub const SCHEMA_VERSION: i64 = 1;

/// Individual DDL statements, applied in order.
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
    "CREATE TABLE IF NOT EXISTS libraries (
      server_id TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      name TEXT NOT NULL,
      PRIMARY KEY (server_id, remote_id)
    )",
    "CREATE TABLE IF NOT EXISTS series (
      server_id TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      library_id TEXT NOT NULL,
      name TEXT NOT NULL,
      sort_name TEXT,
      status TEXT,
      created_at TEXT,
      last_modified TEXT,
      PRIMARY KEY (server_id, remote_id)
    )",
    "CREATE TABLE IF NOT EXISTS books (
      server_id TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      series_id TEXT NOT NULL,
      title TEXT NOT NULL,
      number TEXT,
      file_size INTEGER,
      media_type TEXT,
      created_at TEXT,
      last_modified TEXT,
      PRIMARY KEY (server_id, remote_id)
    )",
    "CREATE TABLE IF NOT EXISTS collections (
      server_id TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      name TEXT NOT NULL,
      PRIMARY KEY (server_id, remote_id)
    )",
    "CREATE TABLE IF NOT EXISTS readlists (
      server_id TEXT NOT NULL,
      remote_id TEXT NOT NULL,
      name TEXT NOT NULL,
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
    "CREATE TABLE IF NOT EXISTS series_metadata (
      server_id TEXT NOT NULL,
      series_id TEXT NOT NULL,
      summary TEXT,
      publisher TEXT,
      authors TEXT NOT NULL DEFAULT '[]',
      tags TEXT NOT NULL DEFAULT '[]',
      PRIMARY KEY (server_id, series_id)
    )",
    "CREATE TABLE IF NOT EXISTS book_metadata (
      server_id TEXT NOT NULL,
      book_id TEXT NOT NULL,
      summary TEXT,
      authors TEXT NOT NULL DEFAULT '[]',
      tags TEXT NOT NULL DEFAULT '[]',
      PRIMARY KEY (server_id, book_id)
    )",
    "CREATE TABLE IF NOT EXISTS sync_state (
      server_id TEXT PRIMARY KEY,
      last_full_sync TEXT,
      last_successful_sync TEXT,
      last_error TEXT,
      sync_status TEXT NOT NULL DEFAULT 'idle'
    )",
    "CREATE TABLE IF NOT EXISTS pending_mutations (
      id TEXT PRIMARY KEY,
      server_id TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      mutation_type TEXT NOT NULL,
      payload TEXT NOT NULL,
      created_at TEXT NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT
    )",
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
    "CREATE TABLE IF NOT EXISTS cache_entries (
      key TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      path TEXT NOT NULL,
      size INTEGER NOT NULL,
      last_access TEXT NOT NULL
    )",
    // Standalone FTS5 tables for local search; populated by the sync engine.
    "CREATE VIRTUAL TABLE IF NOT EXISTS series_fts USING fts5(name, sort_name, authors, publisher, tags, summary)",
    "CREATE VIRTUAL TABLE IF NOT EXISTS book_fts USING fts5(title, authors, publisher, tags, summary)",
];

/// Apply all statements and stamp the schema version.
pub fn migrate(conn: &Connection) -> rusqlite::Result<()> {
    for statement in CREATE_STATEMENTS {
        conn.execute(statement, [])?;
    }
    conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    Ok(())
}
