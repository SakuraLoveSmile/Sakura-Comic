# 同步引擎

四部分：**BootstrapSync / ReconciliationSync / EventDrivenSync / MutationUploadSync**。
Stage 5 落地了前两种，且**后两者不再被依赖**：即使 SSE 完全失效，Reconcile 也能把
本地库收敛回正确状态。

实现位置（两端同语义，逐字镜像同一套 DDL）：

| | Rust (Android core) | Swift (Apple) |
| --- | --- | --- |
| Bootstrap | `komga_core/src/sync/full.rs` | `KomgaSync/FullSync.swift` |
| Reconcile | `komga_core/src/sync/reconcile.rs` | `KomgaSync/ReconcileSync.swift` |
| Sync State | `store/sync_state.rs` | `KomgaStore/SyncStateRecord.swift` |
| 删除传播 | `store/prune.rs` | `KomgaStore/Prune.swift` |
| 场景重放 | `sync/scenario.rs` | `KomgaSync/SyncScenario.swift` |

## Bootstrap Sync

顺序：`Libraries → Series → Books → Collections → Readlists → Read Progress`
（`sync_state::BOOTSTRAP_ORDER`）。

- 分页：`PAGE_SIZE = 100`，每页一次请求 → 一次 SQLite 事务
- 检查点：每提交一页就把下一页写进 `sync_state.sync_cursor`
  （`page=N`；Books 按 series 扫描，游标是 `series=<id>|page=<n>`）
- 中断恢复：重启后从第一个未完成的步骤、未完成的页继续；已完成的步骤直接跳过
  （`skipped_steps` / `resumed_steps` 记在摘要里）
- 错误恢复：步骤失败写 `sync_status = error` 并**保留游标**，服务器不可达不会
  清空已镜像的库，UI 继续读本地数据
- 强制重建：`StartAt::Fresh` 清掉所有步骤游标重新镜像

## Sync State

`sync_state` 一行一个 `(server_id, entity_type)`：
`serverId` / `entityType` / `lastSyncAt` / `syncCursor` / `syncStatus`（+
`lastError`，以及 `full` 行上的服务器级汇总 `lastFullSync` / `lastSuccessfulSync`）。

`syncStatus` 词表：`idle`（无运行中 / 步骤完成）| `syncing`（运行中，或被中断且留有
续跑点）| `error`（上次尝试失败，游标仍可用）。

## Reconcile Sync

触发：App 启动 / 回到前台 / 网络恢复 / SSE 重连 / 用户手动刷新
（`ReconcileTrigger`）。其中 `app_launch`、`did_become_active` 受
`MIN_RECONCILE_INTERVAL_SECS = 60` 节流，其余立即执行。

Komga 没有变更日志，也没有「已删除 id」接口，因此对账的唯一可靠形式是
**全量 id 扫描**：逐页拉取远端列表 → upsert（区分 Added / Changed，靠比对
`lastModified`）→ 扫描完成后，把服务器不再报告的本地 id 删掉（Deleted →
级联 + 墓碑）。

**只写真正变化的行。** 扫描仍覆盖全量 id（删除判定需要完整集合），但写入是增量的：
只有「本地没有这个 id」或「`lastModified` 变了」才 upsert。此外还要比较三类
**时间戳不动、内容却会变**的字段，否则会静默漏更新：

| 实体 | 额外比较 | 为什么 |
| --- | --- | --- |
| Book | `read_progress` 的 `(page, completed, server_updated_at)` | 远端阅读进度变化不推进 book 的 `lastModified` |
| Series | 镜像里的 `booksCount` 与已读/未读/进行中计数 | 这些是派生计数，不推进 `series.lastModified` |
| Collection / Readlist | `collection_series` / `readlist_books` 成员（书单按顺序比） | 改成员未必改 `lastModifiedDate` |

这条不是推出来的，是被测出来的：只做时间戳比较时，共享场景契约里
「col-1 换了成员但没换时间戳」那一步立刻失败。

安全规则：**只有扫描跑到 `last = true` 之后才允许 prune。** 半途失败永远不删数据，
一次失败的同步最多把某个删除推迟一轮。从中断处续跑时，已提交页的 id 用本地行播种进
seen 集合（偏差方向同样是「宁可少删」）。

Books 的 prune 以「本次真正扫过的 series」为作用域，未扫过的 series 下的书不动。

## Deleted 状态传播

```text
Komga 删除 → Reconcile id 扫描发现缺失 → SQLite 级联删除 + deleted_entities 墓碑 → UI 重读本地库
```

- Series 删除：级联删其 Books（含 `book_metadata` / `book_tags` / `book_authors` /
  `read_progress` / `downloads` / FTS 行 / 封面记录与磁盘封面文件 / 该书的 Outbox 条目），
  并从 `collection_series` 摘除成员；书也留下 `cause = cascade` 的墓碑
- Book 删除：删自身相关行 + `readlist_books` 成员 + 进度 + 下载 + 封面 + Outbox
- Collection 删除：删 `collections` + `collection_series`
- Readlist 删除：删 `readlists` + `readlist_books`
- 远端又出现同一个 id（例如误删后恢复）：`clear_tombstone` 撤销墓碑

墓碑表 `deleted_entities(server_id, entity_type, remote_id, deleted_at, cause)`，
`cause ∈ reconcile | cascade | event`。它记录「服务端已经没有了」这一事实，让迟到的
SSE 事件或过期 Outbox 条目能被识别。

## Event Driven Sync（下一阶段）

SSE 端点 `/sse/v1/events`。事件只是「数据变了」的提示，不是可靠消息队列：
`SSE Event → Mark Dirty → Targeted Reconcile → SQLite Update → UI Observe`。
断开重连后必须先 Reconciliation Sync 再恢复事件订阅，禁止假设连接期间没漏事件。
当前仅落地了 `sse_reconnected` 这个触发入口（走完整 Reconcile），事件流本身尚未接入。

## Mutation Outbox（下一阶段）

本地先更新 → 写 `pending_mutations` → 后台上传 → 成功后删除。
支持 READ_PROGRESS / MARK_READ / MARK_UNREAD。字段：id / server_id / entity_id /
mutation_type / payload / created_at / retry_count / last_error。
实体被远端删除时，其未上传条目随级联一并丢弃（见上）。

## 阅读进度冲突

- **Passive Progress**：可结合本地更新时间、Mutation 是否上传、服务端更新时间合并
- **Explicit Mark Read**：优先级高于普通进度
- **Explicit Mark Unread**：不能被 max(page) 类规则覆盖

最终规则见 `specs/contracts/read-progress/`，由 Shared Fixture 验证两端行为一致。

## 上传节流

阅读中禁止每翻一页就请求：Page → Local DB → debounce/throttle → PATCH。
App 被强杀前未上传的进度仍在 Outbox，下次启动继续上传。

## 验收：共享场景重放

`specs/contracts/fixtures/sync/*.json`（由 `scripts/gen_stage5_fixtures.py` 生成）
脚本化一段 Komga 侧历史：命名快照 + 客户端动作（bootstrap / reconcile）+ 注入的传输故障。
每一步之后把本地 SQLite 与服务器快照逐项比对（5 类实体 id 集合、series
name/status/lastModified、genres/summary 归一化表、book title、合集/书单成员、
阅读进度集合、FTS 行数、无孤儿书、墓碑集合、`sync_state` 状态与请求次数）。

两个场景都带 `"sse": "disabled"` —— 全程没有任何事件，收敛只靠 Reconcile。
同一批 JSON 驱动 Rust（`sync::scenario`）与 Swift（`SyncScenarioTests`）两端。

```bash
bash scripts/e2e_stage5.sh            # 场景重放 → 真实 HTTP 回环 → 真实服务器(需 env) → Swift
```

回环那一步用 `komga_fixture_server`（`android/komga_core/src/bin/`）：同一个 Komga 形状
的 HTTP 服务（`/api/v1/series/{id}/books`、`X-API-Key` 认证、按 `page`/`size` 切片、
Spring Data 分页信封），提供同一批快照，且**每个请求重读快照名文件**，所以脚本可以在
客户端运行期间改掉服务器内容。它检验的是 `KomgaClient` 本身而不是注入的 fetcher。
