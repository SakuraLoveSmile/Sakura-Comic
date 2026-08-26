# 数据库 Schema

## 原则

- 所有表的主键为 `(server_id, remote_id)`；read_progress 为 `(server_id, book_id)`
- Apple：GRDB；Android(Rust)：rusqlite（Flutter 不直接访问数据库）
- 需要验证：Migration / Foreign Key / Cascade / 多服务器隔离 / 事务回滚 / 大库性能

## 主要表

servers / libraries / series / books / collections / readlists / read_progress /
series_metadata / book_metadata / sync_state / pending_mutations /
downloads / download_pages / cache_entries

## DDL 草案

```sql
CREATE TABLE servers (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  base_url TEXT NOT NULL,
  auth_type TEXT NOT NULL,
  credential_ref TEXT,
  capabilities TEXT,
  last_successful_connection TEXT
);

CREATE TABLE series (
  server_id TEXT NOT NULL,
  remote_id TEXT NOT NULL,
  library_id TEXT NOT NULL,
  name TEXT NOT NULL,
  sort_name TEXT,
  status TEXT,
  created_at TEXT,
  last_modified TEXT,
  PRIMARY KEY (server_id, remote_id)
);

CREATE TABLE books (
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
);

CREATE TABLE read_progress (
  server_id TEXT NOT NULL,
  book_id TEXT NOT NULL,
  page INTEGER,
  completed INTEGER NOT NULL DEFAULT 0,
  local_updated_at TEXT,
  server_updated_at TEXT,
  mutation_pending INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (server_id, book_id)
);

CREATE TABLE pending_mutations (
  id TEXT PRIMARY KEY,
  server_id TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  mutation_type TEXT NOT NULL,
  payload TEXT NOT NULL,
  created_at TEXT NOT NULL,
  retry_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);

CREATE TABLE downloads (
  server_id TEXT NOT NULL,
  book_id TEXT NOT NULL,
  manifest_path TEXT,
  pages_total INTEGER,
  pages_done INTEGER,
  state TEXT NOT NULL,
  PRIMARY KEY (server_id, book_id)
);

CREATE TABLE cache_entries (
  key TEXT PRIMARY KEY,
  kind TEXT NOT NULL,          -- thumbnail | page | prefetch
  path TEXT NOT NULL,
  size INTEGER NOT NULL,
  last_access TEXT NOT NULL
);

CREATE VIRTUAL TABLE series_fts USING fts5(name, sort_name, authors, publisher, tags, summary, content='series');
CREATE VIRTUAL TABLE book_fts USING fts5(title, authors, publisher, tags, summary, content='books');
```

> FTS5 外部内容表/独立存储列的最终形态以实现阶段为准；此处为方向草案。

搜索域：标题 / Sort Title / 作者 / 出版社 / 标签 / 简介。
筛选：Library / Read Status / Tags / Authors / Publisher / Series Status。
排序：Title / Sort Title / Date Added / Date Updated / Release Date / Last Read / Progress。

性能目标：10,000 Series、100,000 Books 下搜索与分页流畅；本地搜索 < 100ms。
