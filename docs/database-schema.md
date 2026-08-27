# 数据库 Schema

## 原则

- 所有表的主键为 `(server_id, remote_id)`；read_progress 为 `(server_id, book_id)`；
  app_state 为 `(key)` 单值状态表
- Apple：GRDB；Android(Rust)：rusqlite（Flutter 不直接访问数据库）
- 连接设置（两端一致）：`foreign_keys=ON`、`journal_mode=WAL`、
  `synchronous=NORMAL`、`temp_store=MEMORY`、`cache_size=8MB`。
  这是可随时从服务器重建的镜像库，不该为每条语句 fsync；WAL 下进程崩溃仍不丢已提交事务
- 打开已建好且 `user_version` 已是当前版本的库，迁移直接短路返回一次 PRAGMA 查询：
  同步引擎每页开一次连接（`Connection` 不能跨 await 持有），规模测试里
  1000 series / 20000 books 一次扫描要开上千次连接
- 需要验证：Migration / Foreign Key / Cascade / 多服务器隔离 / 事务回滚 / 大库性能
- 当前 Schema 版本：**v6**（v2 新增 `app_state`；v3 新增 `thumbnails`；
  v4 新增归一化筛选表 / 成员关系表 / 完整元数据列 / 服务器作用域 FTS；
  v5 为 `libraries` 补齐详情列；v6 让 `sync_state` 按实体类型记账并新增墓碑表；
  两端用幂等 `CREATE TABLE IF NOT EXISTS` + 受保护的 `ALTER TABLE ADD COLUMN`
  应用迁移并写 `PRAGMA user_version`）

## 主要表

servers / app_state / libraries / series / books / collections / readlists /
read_progress / series_metadata / book_metadata / **sync_state (v6 复合主键)** /
**deleted_entities**（v6 墓碑）/ pending_mutations / downloads / download_pages /
**thumbnails** / cache_entries /
**series_genres / series_tags / series_authors / book_tags / book_authors /
collection_series / readlist_books**（v4）/ **series_fts / book_fts**（v4 服务器作用域）

## v6 变更（同步引擎）

- `sync_state` 主键从 `server_id` 改为 `(server_id, entity_type)`，新增
  `entity_type` / `last_sync_at` / `sync_cursor`；一行一个实体类型
  （`libraries` / `series` / `books` / `collections` / `readlists` /
  `read_progress`），另有一行 `full` 承载服务器级汇总
  （`last_full_sync` / `last_successful_sync`）。`sync_cursor` 是被中断扫描的
  续跑点：`page=N`（按页扫描）或 `series=<id>|page=<n>`（Books 逐 series 扫描）；
  `sync_status ∈ idle | syncing | error`
- v5 老库迁移：检测到旧表形状（无 `entity_type`）时重建表，把原单行搬进
  `entity_type = 'full'`，时间戳原样保留（`schema.rs::migrate_sync_state_shape`
  与 `Schema.swift` 等价实现）
- 新增 `deleted_entities(server_id, entity_type, remote_id, deleted_at, cause)`
  墓碑表：Reconcile 发现远端已删除时写入，`cause ∈ reconcile | cascade | event`；
  镜像行本身级联删除（`store/prune.rs`），封面记录与 Outbox 条目一并失效
- `delete_server_mirror` 覆盖墓碑表，删服务器时不留残余

## v5 变更

- `libraries` 增加 `root`（扫描根路径）与 `unavailable`（服务端可用性标记）——
  两端的 Library DTO 本来就带这两个字段，此前在入库时被丢弃，
  导致 Library 详情页无 Metadata 可渲染
- Library 列表 / 详情统一由一条聚合 SQL 提供（相关子查询计数，避免 join 行数放大）：
  `series_count` / `book_count`（books 经 series 归属到库）/ `read_count`
  （`read_progress.completed = 1`）—— Rust `store/query.rs::library_counts` +
  `library_detail`，Swift `KomgaStore+MediaLibrary.libraryCounts` + `libraryDetail`

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
- Rust：`android/komga_core/src/store/schema.rs`（CREATE_STATEMENTS + V4/V5_ALTER_STATEMENTS + FTS 形状迁移）
- Swift：`apple/KomgaKit/Sources/KomgaStore/Schema.swift`（createStatements + v4/v5AlterStatements）

搜索域：标题 / Sort Title / 作者 / 出版社 / 标签 / 简介（FTS5，前缀查询，
用户输入被转义为 `"term"* AND ...`）。
筛选：Library / Status / Tags / Genres（归一化表，EXISTS 子查询）。
排序：Series：名称 / 排序名 / 加入日期 / 最近更新 / 册数；
Books：册数（number_sort，NULL 排最后）/ 标题 / 加入日期。
阅读状态：`read_progress.completed=1`（已读）、`page>0 && completed=0`（进行中）、
其余为未读；本地变更写 `pending_mutations`（READ_PROGRESS / MARK_READ / MARK_UNREAD）。

性能目标：10,000 Series、100,000 Books 下搜索与分页流畅；本地搜索 < 100ms。