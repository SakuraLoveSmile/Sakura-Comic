# 数据库 Schema

## 原则

- 所有表的主键为 `(server_id, remote_id)`；read_progress 为 `(server_id, book_id)`；
  app_state 为 `(key)` 单值状态表
- Apple：GRDB；Android(Rust)：rusqlite（Flutter 不直接访问数据库）
- 需要验证：Migration / Foreign Key / Cascade / 多服务器隔离 / 事务回滚 / 大库性能
- 当前 Schema 版本：**v4**（v2 新增 `app_state`；v3 新增 `thumbnails`；
  v4 新增归一化筛选表 / 成员关系表 / 完整元数据列 / 服务器作用域 FTS；
  两端用幂等 `CREATE TABLE IF NOT EXISTS` + 受保护的 `ALTER TABLE ADD COLUMN`
  应用迁移并写 `PRAGMA user_version`）

## 主要表

servers / app_state / libraries / series / books / collections / readlists /
read_progress / series_metadata / book_metadata / sync_state /
pending_mutations / downloads / download_pages / **thumbnails** / cache_entries /
**series_genres / series_tags / series_authors / book_tags / book_authors /
collection_series / readlist_books**（v4）/ **series_fts / book_fts**（v4 服务器作用域）

## v4 变更

- `series` 增加阅读计数器：`books_count / books_read_count / books_unread_count /
  books_in_progress_count`，以及 `fts_rowid`（FTS 增量维护）
- `books` 增加 `series_title / number / number_sort / pages_count / oneshot / fts_rowid`
- `collections` 增加 `ordered / filtered / created_date / last_modified_date`
- `readlists` 增加 `summary / ordered / filtered / created_date / last_modified_date`
- `series_metadata` 增加 `reading_direction / language / age_rating(TEXT) /
  title_sort / total_book_count`
- `book_metadata` 增加 `number / number_sort / isbn / release_date`
- **归一化筛选表**（本地筛选全部走 SQL，避免 JSON 解析）：
  `series_genres / series_tags / series_authors / book_tags / book_authors`
- **成员关系表**：`collection_series(collection_id, series_id)`、
  `readlist_books(readlist_id, book_id, position)`（书单保序）
- **FTS5 搜索索引**改为带 `server_id UNINDEXED` 的独立表：
  `series_fts(server_id, name, sort_name, authors, publisher, tags, summary)`、
  `book_fts(server_id, title, authors, publisher, tags, summary)`；
  由 `series.fts_rowid` / `books.fts_rowid` 增量维护（旧 v3 表在迁移时重建）

## DDL

实际 DDL 见实现（两端逐字镜像）：
- Rust：`android/komga_core/src/store/schema.rs`（CREATE_STATEMENTS + V4_ALTER_STATEMENTS + FTS 形状迁移）
- Swift：`apple/KomgaKit/Sources/KomgaStore/Schema.swift`

搜索域：标题 / Sort Title / 作者 / 出版社 / 标签 / 简介（FTS5，前缀查询，
用户输入被转义为 `"term"* AND ...`）。
筛选：Library / Status / Tags / Genres（归一化表，EXISTS 子查询）。
排序：Series：名称 / 排序名 / 加入日期 / 最近更新 / 册数；
Books：册数（number_sort，NULL 排最后）/ 标题 / 加入日期。
阅读状态：`read_progress.completed=1`（已读）、`page>0 && completed=0`（进行中）、
其余为未读；本地变更写 `pending_mutations`（READ_PROGRESS / MARK_READ / MARK_UNREAD）。

性能目标：10,000 Series、100,000 Books 下搜索与分页流畅；本地搜索 < 100ms。