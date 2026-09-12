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
- 当前 Schema 版本：**v11**（v2 新增 `app_state`；v3 新增 `thumbnails`；
  v4 新增归一化筛选表 / 成员关系表 / 完整元数据列 / 服务器作用域 FTS；
  v5 为 `libraries` 补齐详情列；v6 让 `sync_state` 按实体类型记账并新增墓碑表；
  v7 给 `pending_mutations` 加上 Outbox 消费所需的 `state` / `next_retry_at`；
  v8 为阅读器加 `book_pages` 与 `cache_entries` 的 LRU 索引；
  v9 给 `downloads` / `download_pages` 补上可续传所需的列；
  v10 给 `reader_position` 加 `page_offset_ratio`；
  v11 只加媒体库列表索引，不加列不加表；
  两端用幂等 `CREATE TABLE IF NOT EXISTS` + 受保护的 `ALTER TABLE ADD COLUMN`
  应用迁移并写 `PRAGMA user_version`）
- **本文件的版本号曾经漂移**：代码到 v9 时这里写的是 v7，而 v8 / v9 两节其实已经
  写好并排在下面。v10 实施时一并订正标题，并补上这一条，免得下一次再漂。
- **v11 实施后两端 `user_version` 差 2**：Apple 停在 v9，Rust 到 v11。这个差距
  不影响可读性——v11 不动任何列或表，所以 `pragma_table_info` 一类的形状收敛测试
  不受影响，Apple 打开 v11 库也不会因为形状而失败。照上面的规矩，把漂移**写下来**，
  别让它悄悄变成第三个数字。

## v11 变更（只加索引）

在此之前，整个库里只有两个索引（`pending_mutations_due` 与 `cache_entries_lru`），
没有一个是给媒体库列表查询用的。后果是书架墙每一页都要在临时 B 树里排一次
全服务器的 `series`（页一次、它的 `COUNT(*)` 再一次），而列一个系列的书要扫
全服务器的 `books`（`books` 主键是 `(server_id, remote_id)`）。

新增（`V11_INDEX_STATEMENTS`，执行在 ALTER 循环**之后**）：

| 索引 | 列 | 服务 |
| --- | --- | --- |
| `series_name_nocase` | `(server_id, name COLLATE NOCASE)` | 按名称排序 |
| `series_sort_name_nocase` | `(server_id, COALESCE(sort_name, name) COLLATE NOCASE)` | 按排序名 |
| `series_created_at` | `(server_id, created_at)` | 按加入日期 |
| `series_last_modified` | `(server_id, last_modified)` | 按最近更新 |
| `series_books_count` | `(server_id, books_count)` | 按册数 |
| `series_library` | `(server_id, library_id)` | 库筛选 + `library_counts` 的驱动顺序 |
| `books_series_order` | `(server_id, series_id, number_sort)` | 一个系列的书 |

三条容易踩空的：

1. **`COLLATE NOCASE` 是索引的一部分，不是装饰。** BINARY 序的索引满足不了
   `ORDER BY name COLLATE NOCASE`，规划器会静默退回临时 B 树。一个索引同时服务
   ASC 与 DESC（反向扫描），所以没有降序孪生索引。
2. **`series_sort_name_nocase` 是表达式索引**，只有当 `SeriesSort::order_expr`
   与它逐字匹配（除 `s.` 别名）时才会被选中。`store/query.rs` 里那个测试就是
   为了在某次改动悄悄重新引入 filesort 时响起来。
3. **统计信息与索引同等重要。** 实测 1200 series / 12000 books：同一批索引，
   没有 `sqlite_stat1` 时 `library_counts` 走 1,539,860 VM 步，有统计信息后
   119,068（12.9×）。而 `migrate()` 跑在空库上，那时 `PRAGMA optimize` 对
   `series` / `books` 收集不到任何统计（实测只给两张 FTS config 表写了行）。
   所以统计信息必须在**镜像有数据之后**收集——见 `sync::full` 末尾的
   `PRAGMA optimize`。详见 [large-library-performance.md](large-library-performance.md)。

索引成本（`dbstat` 实测，10000 series / 100000 books）：新增约 **3.8 MB**
（`books_series_order` 2.67 MB，六个 `series` 索引合计 1.16 MB），
在一个约 16 MB 的镜像上约 +24%。

## 索引策略的教训：索引要建在 ALTER 之后的列上

`pending_mutations_due` 曾在 `CREATE_STATEMENTS` 里，而它索引的 `state` /
`next_retry_at` 由 `V7_ALTER_STATEMENTS` 添加。`migrate()` 先跑
`CREATE_STATEMENTS`，于是 pre-v7 的库直接以 `no such column: state` 打不开——
用户的离线队列被一个拒绝打开的库挡住。它现在在 `POST_ALTER_INDEX_STATEMENTS`
里，由 `a_v6_outbox_row_survives_the_migration_and_gains_its_retry_columns` 钉住。
上面那句"建在新列上的索引会失败"不是推测，是已经踩过的坑。

## 主要表

servers / app_state / libraries / series / books / collections / readlists /
read_progress / series_metadata / book_metadata / **sync_state (v6 复合主键)** /
**deleted_entities**（v6 墓碑）/ pending_mutations / downloads / download_pages /
**thumbnails** / cache_entries /
**series_genres / series_tags / series_authors / book_tags / book_authors /
collection_series / readlist_books**（v4）/ **series_fts / book_fts**（v4 服务器作用域）

## v10 变更（Stage 10 条漫定位）

### `reader_position.page_offset_ratio REAL NULL`

条漫是一根很长的列，"第 62 页"本身说不清人在哪儿：没有页内偏移，重新打开会把
读到一半的那一页拉回顶部。

- 单页 / 双页模式**不写**这一列，`NULL` —— 它对分页阅读器就等于"页首"，
  而且预 v10 的每一行也都是 `NULL`。两者是同一个事实，但不是 `0.0`：
  存 0 会把"没有记录"说成"在页首"，下次打开就会把滚到一半的读者拽回去。
- `save_with_offset` 把比例**夹紧**在 0..1 而不是拒绝：过冲回弹会报出 1.02，
  而页码仍然值得保存，为了一个比例丢掉页码是笔亏本买卖。
- 偏移随下一次 persist 落库，不在滚动时写：滚动是连续上报的，
  每帧过一遍 SQLite 会把整行位置写穿。翻页、改模式、关书都会触发 persist。

### 这是本项目唯一一个"丢不了东西"的迁移

`migrate()` 仍然不是事务性的，但每一步都是幂等且带守卫的，重跑安全。
纯加一个可空列，失败模式是"某本书回到页首"，不是像 v9 那样丢掉用户的下载记账。

### 形状收敛

`CREATE_STATEMENTS` 与 `V10_ALTER_STATEMENTS` 必须落到同一形状
（`a_migrated_v9_reader_position_has_the_fresh_shape` 用 `pragma_table_info` 逐列对比）。
这次差点踩到：新列写进 CREATE 时放在 `updated_at` **之前**，而 ALTER 只能追加到
**最后** —— 两条路径的列序不同，测试当场抓住。现在新列统一排在 `updated_at` 之后。

### 行存活

`a_v9_reader_position_row_survives_the_v10_migration_untouched` 用纯 v9 DDL 建库、
插一行、迁移，断言页码 / 模式 / 方向 / 时间戳原样存活、新列为 `NULL`。

## v9 变更（Stage 9 离线下载）

版本戳 `PRAGMA user_version = 9`。`downloads` / `download_pages` 两张表从 v1 就在，
但**一直没有写入者**——v9 给它们一个，并补上"可续传"需要的列。两条路径（全新建库的
`CREATE_STATEMENTS` 与 v8 库上的 `V9_ALTER_STATEMENTS`）必须收敛到同一个形状，
`a_migrated_v8_download_table_has_the_fresh_shape` 用 `pragma_table_info` 逐列对比钉住：
只加进 CREATE 而忘了 ALTER 的列，平时全绿，升级用户一打开就查一个不存在的列。

| 表 | 新列 | 为什么砍不掉 |
| --- | --- | --- |
| `downloads` | `position` | 队列次序 = 用户点击次序。rowid 既不是它也不稳定 |
| | `bytes_total` / `bytes_done` | 存储页与"空间不够就别开新书"的判断，一次查询而不是走目录 |
| | `created_at` / `updated_at` | 清单的 `downloadedAt`；陈旧判断 |
| | `last_error` / `next_retry_at` | 失败要能解释；凭据被拒时把整台服务器的队列停到一个约定时间 |
| | `remote_last_modified` | `books.last_modified` 跑过它 → UI 说"内容已更新"而不是悄悄供旧内容 |
| | `book_title` / `series_title` | 书被远端删掉后仍要能显示这本是什么（下载不随镜像级联消失） |
| | `allow_cellular` | 计量网络上"花我的流量"是**每本**一次的确认，不是一个全局偏好 |
| `download_pages` | `size_bytes` / `media_type` | 落地时实测的字节数与容器；读时要按它做完整性快查 |
| | `attempts` / `last_error` / `updated_at` | 单页重试的计数与理由——链路故障**不**烧尝试，坏的页才烧 |

`pages_total` / `pages_done` / `file_path` / `manifest_path` 仍是可空列：SQLite 不能在不
重建表的前提下改已有列的可空性，而重建表正是一条失败模式为"丢掉用户下载记账"的迁移
（`a_v8_download_row_survives_the_v9_migration_untouched` 用纯 v8 DDL 建库、插一行部分
下载的暂停中书籍、跑 `migrate`，断言它原样活着而新列取默认值）。所有读路径 COALESCE。

**没有新索引**：`downloads` 每本一行，是用户亲手点的；`download_pages` 的热查询是
`WHERE server_id=? AND book_id=? AND state<>?`，本就是主键前缀的范围扫。想加
`downloads(state, position)` 之前记住一个陷阱：`CREATE_STATEMENTS` 跑在 ALTER 循环**之前**，
所以建在新列上的索引在 v8 升级库上会直接失败。

`downloads` / `download_pages` 已从 `delete_server_mirror` 与 `prune::delete_book`
的级联名单里移出（Stage 9 的决定，理由写在
`specs/contracts/delete-propagation/README.md`）。

## v8 变更（Stage 7 阅读器）

版本戳 `PRAGMA user_version = 8`。三处新增，都是「本地负责展示」在阅读链路上的延伸。

### `book_pages` — 页清单镜像

| 列 | 说明 |
| --- | --- |
| `server_id, book_id, number` | 复合主键。`number` 是**规范页号**（数组位置 + 1，1 起），不是服务器给的 `PageDto.number` |
| `file_name, media_type` | 归一化后的页属性；`media_type` 决定这本书能不能进图像阅读器 |
| `width, height` | 0 = 未知；未知的页不参与双页配对 |
| `size_bytes` | 清单给的字节数（`PageDto.size` 是给人看的字符串，不解析） |
| `fetched_at` | 镜像新鲜度 |

整本替换（先删后插，一个事务）：清单没有「部分更新」这种合法状态，半份清单会让每个规范页号错位。
有了它，**开过的书离线也能打开** —— 第二次 open 是数据库读取，回环验收用服务器日志的零增长证明。

### `reader_position` — 屏幕上显示的那一页

| 列 | 说明 |
| --- | --- |
| `server_id, book_id` | 主键，一本书一行 |
| `page` | 阅读器当时显示的那一页 |
| `mode, direction` | 当时用的版式（`single/double/webtoon` × `ltr/rtl/vertical`） |
| `updated_at` | 本地时间戳 |

它和 `read_progress` **不是一回事**：`read_progress.page` 是与 Komga 同步的那一份，受 Stage 6 冲突规则约束；
`reader_position` 是本地显示状态，永不上云。分开才能精确还原 —— 合上书时停在双页 RTL 的某个跨页，
再打开就该回到那个跨页那个版式，而不是回到第 N 页 + 全局默认方向。

### `cache_entries` 的 LRU 索引

```sql
CREATE INDEX IF NOT EXISTS cache_entries_lru ON cache_entries (kind, last_access)
```

表在 v3 就建好了，一直没有写入方；页缓存是它的第一个用户。`kind ∈ {page, prefetch, download}`，
淘汰按 `last_access`（同刻以 `key` 定序，保证两次运行淘汰结果一致），
**`download` 不参与淘汰**（离线下载是用户的，见 [离线存储](offline-storage.md)）。
命中 = 记账在 + 文件在；文件丢了记账行当场删掉，让记账向磁盘收敛。

`delete_server_mirror` 一并级联 `book_pages` 与 `reader_position`；页文件的清理走
`cache_entries` 的 key 前缀 `{serverId}-{bookId}-p`。

## v7 变更（Mutation Outbox 可消费）

`pending_mutations` 从「只记录」变成「可消费」，两列：

| 列 | 作用 |
| --- | --- |
| `state`（取值 `pending` 或 `failed`，默认 `pending`） | `failed` 是**终态**：不再自动重试，只能被用户的新动作顶掉，或被显式重试清零 |
| `next_retry_at`（绝对 RFC 3339 时间，NULL 表示立即可试） | 退避到期时间；**存在库里而不是内存计时器**，所以杀掉 App 重启不会把惩罚清零 |

配套索引 `pending_mutations_due (server_id, state, next_retry_at)`：上传器每轮只问
「现在有哪些到期该传的」，不该为一次退避扫全表。

**故意没有 in-flight 标记列。** Komga 的 read-progress 写是幂等的
（`PATCH {page, completed}` 或 `DELETE`），所以「至少一次 + 崩溃后重放」就是完整的
恢复策略；加一个 `uploading` 状态只会引入「进程被杀时永远停在 uploading」这类需要
额外清理的假状态。迁移沿用 v4/v5 那套「列存在才 ALTER」的 guard，两端 DDL 逐字一致。

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