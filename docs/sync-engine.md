# 同步引擎

四部分：**BootstrapSync / ReconciliationSync / EventDrivenSync / MutationUploadSync**。
Stage 5 落地前两种，Stage 6 补齐后两种。Stage 5 那条完成条件在补齐之后**依然成立**：
即使 SSE 完全失效（或被判定不可用而停在 `ReconcileOnly`），Reconcile 仍能把本地库收敛
回正确状态 —— 这一点由带着 `"sse": "disabled"` 的共享场景契约持续守着。

实现位置（两端同语义，逐字镜像同一套 DDL）：

| | Rust (Android core) | Swift (Apple) |
| --- | --- | --- |
| Bootstrap | `komga_core/src/sync/full.rs` | `KomgaSync/FullSync.swift` |
| Reconcile | `komga_core/src/sync/reconcile.rs` | `KomgaSync/ReconcileSync.swift` |
| Sync State | `store/sync_state.rs` | `KomgaStore/SyncStateRecord.swift` |
| 删除传播 | `store/prune.rs` | `KomgaStore/Prune.swift` |
| 场景重放 | `sync/scenario.rs` | `KomgaSync/SyncScenario.swift` |
| SSE 解析 / 会话 | `api/sse.rs` + `sync/sse.rs` | `KomgaAPI/SSEClient.swift` |
| Outbox 队列 | `store/outbox.rs` | `KomgaStore/KomgaStore+Outbox.swift` |
| Mutation 上传 | `sync/upload.rs` + `api/mutation.rs` | `KomgaSync/OutboxUpload.swift` |

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

## Event Driven Sync（Stage 6 已落地）

端点 `GET /sse/v1/events` —— 1.26.3 源码核实（`SseController.kt` 里
`@GetMapping("sse/v1/events")`）；完整事件目录与三条关键限制见
[specs/events/komga-sse-events.md](../specs/events/komga-sse-events.md)。

| | Rust | Swift |
| --- | --- | --- |
| 帧解析 | `api/sse.rs::SseParser` | `KomgaAPI/SSEClient.swift` |
| 连接 + 握手校验 | `api/sse.rs::SseClient` | 同上（`URLSession.bytes`） |
| 会话状态机 | `sync/sse.rs::SseSession` + `pump` | `KomgaSync` 同名语义 |
| 事件 → 动作 | `sync/sse.rs::{classify, DirtySet, apply_dirty}` | 同名语义 |

流程严格是「事件只给 id，内容回 API 拉」：

```text
SSE Event → classify 取 Entity ID → DirtySet 合并 → GET /api/v1/books/{id} → SQLite 更新 → UI 重读本地库
```

四条不靠约定、由测试钉住的规则：

1. **重连后先 Reconcile，再消费事件**。`pump` 在 `Phase::Reconciling` 期间把帧
   **缓存**而不是应用，`reconcile_done()` 之后才并入 dirty
   （`a_reconnect_reconciles_before_any_event_is_applied`）。必须如此是因为服务端
   **从不发 `id:`**（源码核实）：没有续传，`Last-Event-ID` 带回去也没东西可补。
2. **退避复用 Outbox 那份共享策略**（base 2s / factor 2 / cap 300s），服务端 `retry:`
   只能抬高下限（`the_server_retry_field_only_raises_the_floor`）。1.26.3 也根本不发
   `retry:`，所以这套退避完全是客户端自己的责任。
3. **握手不合格就退化成纯 Reconcile**：非 200、`Content-Type` 不是
   `text/event-stream`、或超时收不到任何一帧 → `Phase::ReconcileOnly` 且**不再重连**
   （`a_missing_route_parks_in_reconcile_only_without_a_retry_storm`）。实时性降级，
   正确性不降级。
4. **认不出的事件一律「全局脏」**（代价 = 一次 Reconcile）；`TaskQueueStatus` /
   `SessionExpired` 与镜像无关，直接忽略。心跳是**注释帧** `:heartbeat`（15s 一次），
   解析器把它计为「收到过帧」（证明连接活着）但不产生事件——空闲 ≠ 死连接。

生命周期由 App 驱动，Rust 内部不起线程：`SseSession` 没有时钟，`pump` 每 tick 被调用
一次，所以「后台断开、回前台立即重连并补一次 Reconcile」是显式状态迁移
（`backgrounding_stops_it_and_foreground_retries_immediately`）。

## Mutation Outbox（Stage 6 已落地）

```text
UI → SQLite(read_progress) → pending_mutations → Background Upload → Komga
```

| | Rust | Swift |
| --- | --- | --- |
| 队列读写 | `store/outbox.rs` | `KomgaStore/KomgaStore+Outbox.swift` |
| 上传器 | `sync/upload.rs::upload_outbox` | `KomgaSync/OutboxUpload.swift` |
| 写端点 | `api/mutation.rs`（`PATCH` / `DELETE` `read-progress`） | `KomgaTransport` |

Schema **v7** 给 `pending_mutations` 加了 `state`（`pending|failed`）和绝对到期时间
`next_retry_at`，两端同一份 DDL。**故意不设 in-flight 标记列**：Komga 的进度写幂等，
所以「at-least-once + 崩溃后重放」就是全部恢复机制；退避到期时间存在库里，因此重启
拿不到一次新的惩罚。

规则细节全部在
[specs/contracts/offline-mutation/README.md](../specs/contracts/offline-mutation/README.md)，
`specs/contracts/fixtures/outbox/{conflict,backoff,coalescing}.json` 是唯一数据源，
Rust 与 Swift 各自加载同一批文件断言（`store::outbox::contract_tests` ↔
`OutboxContractTests`）。

保留 Stage 5 的判断：**远端删除推断不丢队列**。级联删掉的是镜像行（可从服务器重新
拉回），队列里没上传过的动作丢了就再也回不来；只有上传阶段自己拿到 `404/410` 才允许
丢（`phase_gone` / `a_book_the_server_deleted_releases_its_queued_action`）。

## 阅读进度冲突

两条被明确禁止的偷懒解法，以及替代判据：

- **不是 `Server Always Wins`**：断网期间的阅读/标记在恢复后照旧上传（规则 R5）。
- **不是统一 `max(page)`**：页码大小不携带「谁更新」的信息。判据只有「谁的动作在时间上
  更晚」，外加「显式表态优先于被动进度」（R2）。fixture 里两条反例各有测试
  （`the_losing_side_is_never_chosen_because_its_page_is_bigger`）：
  本地 page 3 且更晚 → 本地赢，覆盖服务器 page 90；远端 page 3 且更晚 → 远端赢，
  覆盖本地 page 90。`MARK_UNREAD` 永远不会被远端的 page 50 复活。

三条优先级（`specs/contracts/fixtures/read-progress/offline-priority.json`）：

- **Passive Progress**：按本地动作时间 vs `readProgress.lastModified` 合并
- **Explicit Mark Read**：优先级高于任何远端被动进度
- **Explicit Mark Unread**：不能被 max(page) 类规则覆盖

R4 比较的时间戳是 **`readProgress.lastModified`**，不是 `book.lastModified`：后者不随
阅读进度推进（Stage 5 的增量写为了这点专门多比较了一次），用错就会对**所有**远端阅读
失明。镜像侧的判定实现在 `store/read_progress.rs::sync_write_for`（有未上传意图时扫描
不得改写），上传侧的判定在 `store/outbox.rs::decide`，两端各有一份同名 fixture 测试。

## 上传节流

阅读中禁止每翻一页就请求：Page → Local DB → debounce/throttle → PATCH。
App 被强杀前未上传的进度仍在 Outbox，下次启动继续上传 —— 由
`offline_actions_survive_a_kill_and_upload_after_recovery`（进程内重开同一个文件库）
和 `scripts/e2e_stage6.sh` 第 1 步（**真的 `kill -9`** 掉离线阶段的进程，再用新进程
打开同一个 SQLite 文件）两层验证。

## API 一致性门禁（`api/openapi.rs`）

同步引擎依赖 5 个列表端点，而 Komga 的 OpenAPI 文档（从运行中的服务器导出）就是它们
的存废事实。四条测试把它们钉住：

- 引擎调用的每个路径都必须在文档里存在
- 被标记 deprecated 的端点必须显式记录在允许清单里 —— 我们**目前**依赖
  `GET /api/v1/series` 与 `GET /api/v1/series/{id}/books`，两者在 1.26.3 已废弃
  （未废弃的后继是 `POST /api/v1/series/list` / `POST /api/v1/books/list`）。
  哪天再调用一个新废弃端点，测试会直接失败
- 分页信封的字段必须与客户端解码的字段互相覆盖（上游改名会立刻暴露，而不是被 serde 静默忽略）
- URL 构造器拼出来的路径必须能匹配到文档里的（含 `{param}` 模板）路径
- **解码安全**：客户端当作必填来解码的字段（`SeriesDto.id/libraryId/name`、
  `BookDto.id/seriesId/name`、`BookMetadataDto.title`、`CollectionDto.id/name`、
  `ReadListDto.id/name`、`LibraryDto.id/name/root`、`SeriesMetadataDto.title`）必须在
  文档里既是 `required` 又不可为 null —— 否则一次真实响应就会让整个 sweep 半途炸掉；
  反过来，客户端读取的每个属性都必须真的存在于文档中（否则它会永远静默解成 None）。
  一个例外是刻意记下来的：`SeriesMetadataDto` **没有** `authors`，所以 series 的作者取自
  `booksMetadata` 聚合 —— 测试钉住这点，Komga 哪天补上该字段时会提醒我们重新选择来源

Komga 对 deprecated 的处理是「下一个大版本移除」，所以这既是文档检查也是迁移提醒：
真要跟上 Komga 2.x，得把这两个端点换成 POST 搜索端点，而那是必须在真实服务器上验证的
传输层改动。

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
