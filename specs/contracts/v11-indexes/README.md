# v10 → v11 迁移：影响面与恢复方案

状态：**已实施**（2026-09-11）。与 v10 那份提案不同，这份在落地后写成，
所以它同时是改动说明与实施记录。

本文只描述**实际发生的改动**、依据（真实文件与行号）以及失败时的恢复路径。

---

## 1. 要改什么（一句话）

**只加索引，不加列、不加表。** `SCHEMA_VERSION` 10 → 11。

| # | 改动 | 是否动库 |
|---|---|---|
| 1 | 新增 7 个媒体库列表索引（`V11_INDEX_STATEMENTS`） | 是，纯 `CREATE INDEX` |
| 2 | `pending_mutations_due` 从 `CREATE_STATEMENTS` 移到 `POST_ALTER_INDEX_STATEMENTS` | 是，位置变化（见 §4） |
| 3 | `PRAGMA optimize`：`migrate()` 版本变化分支 + `sync::full` 末尾 | 否，只写 `sqlite_stat1` |
| 4 | FFI 新增 `cover_paths`（页范围封面查询） | 否，纯 SELECT |

没有 `V11_ALTER_STATEMENTS`——这一点正是本次迁移风险低的原因。

## 2. 为什么加这些索引

改动前，整个库只有两个索引（`pending_mutations_due`、`cache_entries_lru`），
没有一个给媒体库列表查询用。书架墙每一页都要临时 B 树排一次全服务器的
`series`（页一次、`COUNT(*)` 再一次），列一个系列的书要扫全服务器的 `books`。

依据与逐条理由见 [docs/database-schema.md](../../../docs/database-schema.md)
的「v11 变更」与 [docs/large-library-performance.md](../../../docs/large-library-performance.md)。

三条容易漏的：

1. `COLLATE NOCASE` 必须写进索引，否则 NOCASE 排序退回临时 B 树；
2. `series_sort_name_nocase` 是表达式索引，靠 `order_expr` 逐字匹配才生效，
   所以有一条测试专门钉住它；
3. 索引之外还要 `sqlite_stat1`——实测同一批索引，没有统计信息时
   `library_counts` 走 1,539,860 VM 步，有统计信息 119,068（12.9×）。

## 3. 迁移机制（为什么这不危险）

`migrate()` 在 `PRAGMA user_version` 等于当前版本时直接短路返回。既有 v10 库
`user_version = 10 ≠ 11`，于是重新进入，但：

- `CREATE TABLE IF NOT EXISTS` 循环全部 no-op；
- 受 `table_has_column` 守卫的 ALTER 循环一条都不执行（所有列都已存在）；
- 执行 `POST_ALTER_INDEX_STATEMENTS` 与 `V11_INDEX_STATEMENTS`（都是
  `CREATE INDEX IF NOT EXISTS`，幂等）；
- 写 `user_version = 11`。

**没有数据搬迁，所以没有"迁到一半"的中间态**：最坏情况是部分索引已建、
`user_version` 未写，下次打开重跑一遍幂等的 `CREATE INDEX IF NOT EXISTS`。

## 4. 顺带修掉的一个现存 bug

`pending_mutations_due` 索引的 `state` / `next_retry_at` 由
`V7_ALTER_STATEMENTS` 添加，而它原先写在 `CREATE_STATEMENTS` 里——后者由
`migrate()` 在 ALTER 循环**之前**执行。后果：pre-v7 的库打开时直接
`no such column: state`，用户的离线队列被一个拒绝打开的库挡住。

复现与验证：`android/komga_core/src/store/mod.rs` 的
`a_v6_outbox_row_survives_the_migration_and_gains_its_retry_columns`
用纯 v6 DDL 建库、插一行、跑 `migrate()`，断言该行以 `state = 'pending'` /
`next_retry_at = NULL` 存活且索引已建。**变异检验：** 把索引搬回
`CREATE_STATEMENTS` → `migrate()` panic。

这条同时是给后续索引作者的规矩：**建在 ALTER 新增列上的索引必须放在
`POST_ALTER_INDEX_STATEMENTS`**。

## 5. 失败模式

| 失败模式 | 触发条件 | 后果 | 处理 |
| --- | --- | --- | --- |
| 索引建失败 | 磁盘满 | `migrate()` 返回 Err，`user_version` 未写 → 库打不开 | 释放空间后重开；无数据损失 |
| 磁盘占用增长 | 正常 | 10000 series / 100000 books 下约 +3.8 MB（约 +24% 的镜像） | 已测量并接受；索引可随时 `DROP` 重建 |
| 统计信息陈旧 | 库主要靠 reconcile 增长 | 规划器可能不选最优 join 顺序 | 已知后续项：reconcile 路径不跑 `PRAGMA optimize`（每次前台 sweep 都写 `sqlite_stat1` 是错误取舍），增量靠下次 bootstrap 刷新 |
| 表达式索引失效 | 有人改 `SeriesSort::order_expr` | 静默回到 filesort | `the_sort_name_expression_index_still_matches_the_order_expression` 会失败 |

## 6. 恢复方案

### 降级到 v10 代码

不需要动数据库。按 v10 迁移文档记录的既有行为（见
`../v10-migration/README.md`），较旧代码打开较新文件时会重跑幂等 DDL 并把
`user_version` **写回低值**；v11 的索引会**存续**并继续服务旧代码的查询。
没有新的失败模式。

### 完全回退索引

```sql
DROP INDEX IF EXISTS series_name_nocase;
DROP INDEX IF EXISTS series_sort_name_nocase;
DROP INDEX IF EXISTS series_created_at;
DROP INDEX IF EXISTS series_last_modified;
DROP INDEX IF EXISTS series_books_count;
DROP INDEX IF EXISTS series_library;
DROP INDEX IF EXISTS books_series_order;
PRAGMA user_version = 10;
```

索引是从表数据派生的，删除不丢任何用户数据（对比 v9 的 downloads 迁移，
那条才是唯一失败模式为"丢掉用户记账"的迁移）。

## 7. 两端 `user_version` 漂移：1 → 2

Apple 停在 v9，Rust 到 v11，差距从 1 变成 2。**本次不补齐 Apple**（Android-only
范围）。这个差距可接受的依据：

- 有运维后果的漂移是**列形状**——一个 v11 的库能否被 Apple 的 v9 代码正确读取。
  v11 加零列零表，所以 `pragma_table_info` 一类的形状收敛测试
  （`android/komga_core/src/store/mod.rs` 的形状测试与
  `SchemaV9MigrationTests`）不受影响，**没有任何 Apple 形状测试会因此开始失败**。
  两端*可读*形状的距离与改动前完全一致。
- 恢复场景不变（见 §6 第一小节）。
- 替代方案——不 bump 版本、在每次 `store::open()` 上跑
  `CREATE INDEX IF NOT EXISTS`——恰好重新引入版本戳短路的成本：一次书架刷新有
  约 27 次 FFI 调用，每次调用都会开一个新连接（`store/mod.rs` 的注释说明
  "一次 sweep 要开上千次连接"），把 7 条 DDL 乘进去是不可接受的。
- 按 `docs/database-schema.md` 已立的规矩，漂移**写下来**而不是藏起来。

## 8. 验证命令

```bash
cd android/komga_core && cargo test --lib      # 含 v6 迁移、排序计划、统计信息比值
cd android/app && flutter test                 # 含书架规模不变量、页范围封面
bash scripts/check_frb_drift.sh                # 生成物与仓库一致
```
