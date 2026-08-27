# Stage 5 Checklist — 同步引擎

目标：建立长期可靠的数据同步系统，本阶段落地 **Bootstrap Sync + Reconcile Sync**，
并把「即使 SSE 完全失效，本地库仍能依靠 Reconcile 最终恢复到正确状态」变成可验证事实。

```text
Bootstrap Sync + Reconcile Sync + (SSE Event Sync: 触发入口已留，事件流未接入)
              + (Mutation Upload: 后续阶段)
```

核心原则延续 Stage 4：**网络负责同步，本地数据库负责展示**；同步失败只让数据变旧，
不让书架失效。

## 验收结果

```bash
bash scripts/e2e_stage5.sh        # 场景 16/16 → 回环 HTTP（含凭据被拒 11/11）→ 真实服务器 → Swift 同契约
KOMGA_BASE_URL=http://192.168.0.69:25600 bash scripts/e2e_stage5.sh   # 追加 3a：真实服务器认证失败恢复
bash scripts/verify.sh            # cargo fmt/clippy/test + swift build/test + flutter analyze/test
                                  # → ALL GREEN：Rust 120 / Swift 99（1 skip=live）/ Flutter 26
```

### 第 2 步：真实 HTTP 回环（`komga_fixture_server`）

注入 fetcher 的测试绕过了 `KomgaClient` 本身。这个二进制把同一批快照用真实 TCP
提供出来（`--snapshot-file` 每请求重读，脚本 `echo s1 > snapshot` 就能「在客户端运行
期间改掉服务器」），于是走的是真正的 HTTP 路径：URL 构造
（`/api/v1/series/{id}/books`）、`X-API-Key` 头、`page`/`size` 切片、Spring Data 分页
信封、状态码到错误模型的映射。链路：

| 步骤 | 断言 |
| --- | --- |
| 无凭据 / 错 Key / 正确 Key | 401 / 401 / 200（证明客户端真的把配置的密钥发出去了） |
| Bootstrap + Reconcile（s0） | 13/13 PASS：libraries=2 series=3 books=7 collections=2 readlists=2，逐 series 本地计数 == 服务器 `totalElements`，二次扫描 `clean=true` |
| 服务器变成 s1 → `--reconcile-only` | 10/10 PASS：series +2/~2、books +4，镜像 == 服务器 |
| 服务器变成 s2 → `--reconcile-only` | 11/11 PASS：series -1、books -2、collections -1、readlists -1，且**留下 `cause=reconcile` 的墓碑** |
| 断网离线重放 | 无凭据可读：无游标残留、无孤儿 Book、FTS 命中 |
| 凭据被拒（`--auth-failure`） | 11/11 PASS：报 `authentication failed` → `sync_status=error` + `last_error`；镜像一行不多一行不少（前后计数相同）；书架照常可读；下一次健康扫描 `clean=true` 且失败标记被清除 |

**这一项已经在你的真实 Komga 上跑过**：`KOMGA_BASE_URL=http://192.168.0.69:25600 bash scripts/e2e_stage5.sh`
的第 3a/4 步用一个**故意错误的 key** 打真实服务器（只读 GET，真实 Komga 回 401），
断言全部通过 —— 不需要谁的凭据，也已经在该服务器上验证过真实 HTTP 语义（真实 401
→ 统一错误模型 → sync_state → 镜像不变 → 恢复）。

> **仍未执行的半程**：第 3b 步（真实 Komga 上的完整 Bootstrap + Reconcile 一致性）
> 需要 `KOMGA_API_KEY`。本环境能连到 `http://192.168.0.69:25600`（未带凭据 401），
> 密钥不在仓库里，所以那一半**没跑过**（3a 认证失败那半已在真实服务器上跑过）。
> 它和第 2 步跑的是同一套断言，只是将回环服务器换成真服务器：
> `export KOMGA_BASE_URL=... KOMGA_API_KEY=... && bash scripts/e2e_stage5.sh`。
> 不要把「没跑」当成「跑过」。

## Bootstrap Sync（可中断恢复的首次镜像）

| 要求 | 实现 | 证据 |
| --- | --- | --- |
| 顺序 Libraries → Series → Books → Collections → Readlists → Progress | `sync_state::BOOTSTRAP_ORDER` + `full.rs::full_sync_from`（Swift `FullSync.swift` 同序）；Stage 4 漏掉的 **Libraries 已成为第 1 步** | 场景步 1 断言 `requests` 逐步发生；`full_sync_mirrors_everything_from_shared_fixtures` |
| 分页 | `PAGE_SIZE = 100`，逐页拉取至 `last = true` | 场景 s1/s3 多页快照；`seriesPages` / `bookPages` 计数 |
| 批量写入 SQLite | 每页一次事务（`save_*_batch`） | Stage 4 既有断言 + 场景镜像比对 |
| 同步状态记录 | 每步一行 `(server_id, entity_type)`：`last_sync_at` / `sync_cursor` / `sync_status` | `store/sync_state.rs`；场景断言每步 `idle` 且游标清空 |
| 中断恢复 | 每提交一页写下一页游标（`page=N`；Books 为 `series=<id>|page=<n>`）；重启从游标续跑；已完成步骤跳过 | `scenario-interrupt` 步 1/2：注入 series 第 2 页故障 → 重启 `resumed_steps == ["series"]`，且**请求次数证明没重下已提交的页** |
| 错误恢复 | 步骤失败写 `error` 并**保留游标**；服务器级 `full` 行记 `last_error`；本地已镜像数据不受影响 | `failure_keeps_the_resume_cursor`；`scenario-interrupt` 步 1 断言 `failedEntities` + 游标仍在 |

## Sync State

v6 `sync_state`：主键 `(server_id, entity_type)`，字段
`serverId` / `entityType` / `lastSyncAt` / `syncCursor` / `syncStatus`
（+ `lastError`；`entity_type = 'full'` 行保留 `lastFullSync` / `lastSuccessfulSync`
供 UI「最近同步」使用）。状态词表 `idle | syncing | error`。
旧库（v5 每服务器一行）由 `migrate_sync_state_shape` 重建，原时间戳搬进 `full` 行。

## Reconcile Sync（不依赖 SSE 的最终一致）

| 触发 | 接线位置 | 节流 |
| --- | --- | --- |
| App 启动 | Flutter `SeriesGridScreen._maybeAutoSync`（已镜像过 → `app_launch`；从未镜像 → Bootstrap 续跑）；SwiftUI `LibraryView.initialLoad` → `model.syncLibrary(.appLaunch)` 同样的分叉 | 是（60s） |
| App 回到前台 | Flutter `WidgetsBindingObserver.didChangeAppLifecycleState(.resumed)` → `did_become_active`；SwiftUI `.onChange(of: scenePhase) == .active` | 是（60s） |
| 网络恢复 | Apple：`NWPathMonitor` 由不可达转可达 → `networkRecovered`（`LibraryViewModel.startSyncTriggers`）。Flutter：壳里没有连通性插件，改用**有界重试**探测同一台服务器——失败的同步会被安排成 15s / 60s / 300s 三次 `network_recovered` 重试，成功即视为恢复并清空阶梯（`SeriesGridScreen._scheduleRecoveryRetry`） | 否 |
| SSE 重连 | `sse_reconnected` 触发名已接，走完整 Reconcile（事件流本身属下一阶段） | 否 |
| 用户手动刷新 | Flutter `RefreshIndicator`（下拉）→ `manual_refresh`；SwiftUI `.refreshable` → `model.reconcile(.manualRefresh)` | 否 |

- 实现：`sync/reconcile.rs` / `KomgaSync/ReconcileSync.swift`
- 流程：逐实体类型做远端**全量 id 扫描** → upsert（Added / Changed，靠 `lastModified`
  比对）→ 扫描完整后 prune（本地多余 id → 级联删除 + 墓碑）
- 安全规则：**prune 只在扫描到 `last = true` 后执行**；续跑时已提交页的 id 由本地行播种
  进 seen 集合 → 失败的同步最多推迟一个删除，绝不会删掉服务器还有的数据
  （`scenario-interrupt` 步 3 断言：全量故障下镜像 == 断网前的 s3）

## 离线阅读进度不被同步扫描吃掉

`specs/contracts/fixtures/read-progress/offline-priority.json` 之前只是躺在那里：
没有任何代码实现它。而 `upsert_synced_read_progress` 无条件覆盖本地行并把
`mutation_pending` 清零——也就是说**一次普通 Reconcile 就会把用户没传上去的阅读进度
连同排队中的 Outbox 语义一起吃掉**。现在按契约实现成扫描前的判定：

| 情形 | 结果 |
| --- | --- |
| 本地有未上传的 MARK_READ / MARK_UNREAD | 远端被动值一律不覆盖（即使时间戳更新） |
| 本地有未上传的被动进度，且更早 | 保留本地，Outbox 保持排队 |
| 本地有未上传的被动进度，但远端确实更新 | 采纳远端值，**但保留排队条目**（这里丢弃等于丢用户动作） |
| 本地没有未上传意图 | 照常镜像 |

`newer()` 用 RFC3339 解析比较，不靠字符串对齐（秒/毫秒精度混在真实数据里）。
两端各自实现并各自变异校验：去掉判定后 Rust 4 条、Swift 4 条测试立刻失败；
Swift 那条契约测试读的也是同一份 `offline-priority.json`。

## 规模（`stage5_smoke --scale`，并入常跑验收 1b/4）

1000 series / 20000 books 的安静复测：bootstrap 3.7s，无变化 Reconcile 4.7s
（优化前 11.1s），第二次扫描 `clean=true`，SQLite 行数与 FTS 行数 == 服务器行数、
零孤儿 Book。300 series / 6000 books 的小档每次 `e2e_stage5.sh` 都跑。

## Deleted 状态传播

```text
Komga 删除 → Reconcile 扫描发现缺失 → SQLite 级联删除 + deleted_entities 墓碑 → UI 重读本地库
```

| 实体 | 级联范围（`store/prune.rs`，两端一致） | 证据 |
| --- | --- | --- |
| Series | 其 Books（递归走 Book 规则）+ metadata/tags/genres/authors + FTS 行 + `collection_series` 成员 + 封面记录与磁盘文件；子 Book 墓碑 `cause = cascade` | `series_delete_cascades_to_books_and_children`、场景步 3 |
| Book | 自身行 + metadata/tags/authors + FTS + `read_progress` + `readlist_books` 成员 + `downloads`/`download_pages` + 封面；**Outbox 条目保留**（见下） | `book_delete_clears_membership_and_search`、场景步 3 |
| Collection | `collections` + `collection_series` | 场景步 3（`col-2`） |
| Readlist | `readlists` + `readlist_books` | 场景步 3（`rl-2`） |

墓碑表 `deleted_entities(server_id, entity_type, remote_id, deleted_at, cause)`，
`cause ∈ reconcile | cascade | event`；同一 id 重新出现时清除墓碑（场景最后一步验证）。
封面失效由 facade 负责删文件：`reconcile_propagates_remote_delete_and_orphan_covers`
断言行与磁盘文件一起消失。

## 验收场景（双端同一份 JSON）

`specs/contracts/fixtures/sync/scenario-reconcile.json` 与
`scenario-interrupt.json`（由 `scripts/gen_stage5_fixtures.py` 生成），
两者都声明 `"sse": "disabled"` —— 全程零事件，收敛只靠 Reconcile。

每步之后把本地 SQLite 与服务器快照逐项比对：5 类实体 id 集合、series
name/status/lastModified、归一化 genres 与 summary、book title、合集/书单成员、
阅读进度集合、FTS 行数、无孤儿 Book、墓碑集合、`sync_state` 状态与**请求次数**。

| 验收标准 | 场景步骤 |
| --- | --- |
| 新建 Series | reconcile s0→s1：`series_added == 2`（含跨页新增） |
| 修改 Series | 同上：`series_changed == 2`（改名 / 状态） |
| 删除 Series | reconcile s1→s2：`series_removed == 1` + 级联 + 墓碑 |
| 新增 Book | s1（`book-3-3` 进已有 series、`book-4-*` 进新 series）→ `books_added == 4` |
| 修改 Metadata | **s5**：服务器改一本书的 summary / tags / numberSort / pagesCount，并搬走一个 library 的 root（+ unavailable）→ 逐字段镜像；**s1** 改 series 的 summary/genres/tags |
| App 离线后重新上线 | interrupt 步 3（全量故障，镜像不变）→ 步 4（恢复后收敛到 s2） |
| 同步中途失败后恢复 | **Bootstrap**：步 1/2（series 第 2 页故障 → 游标续跑）、步 3/4（Books 扫到某 series 中途故障，游标 `series=<id>|page=1` → 从该页续跑）；**Reconcile**：步 5/6（Books 在 series 边界被打断，游标 `series=series-5|page=0` → 下一轮只再请求 1 次 books 即完成收敛） |
| 最终 SQLite == Komga | 每步 `diff_mirror` —— 比对深度：series 名称/状态/lastModified/四个阅读计数、归一化 genres 与 summary、book 标题/summary/tags/numberSort/pagesCount/lastModified、合集成员、书单保序成员、阅读进度集合、FTS 行数、library root+unavailable、无孤儿 Book、墓碑集合、`sync_state` 与请求次数；收敛后再扫一次 `clean == true` |

`bash scripts/e2e_stage5.sh` 的 `--scenario` 半程在无网络条件下跑完全部步骤；
`stage5_smoke` 的 live 半程（提供 `KOMGA_BASE_URL` / `KOMGA_API_KEY` 时）额外校验
「本地 series/books/collections/readlists 计数 == 服务器 `totalElements`」，
以及第二次扫描 `clean == true`。

## 覆盖测试

- **Rust（111 通过）**：`sync::scenario`（两个共享场景 16 步全绿）、`sync::full`（镜像完整性 /
  fresh 幂等 / 已完成步骤不再重镜）、
  `store::read_progress`（离线进度保护 + 共享 fixture 契约）、
  `store::books::a_failed_page_write_rolls_back_the_whole_page`（一页一个事务：
  中途失败不留半页，游标也不动；Swift 侧 `StoreRollbackTests` 同断言）
  —— 补上 docs/database-schema.md 里「需要验证：事务回滚」这一项，两端各一条。
  `sync::reconcile`（节流：后台触发在 60s 窗口内不扫、显式触发永远扫、时间戳缺失或
  不可解析时宁可重扫；五种触发名双向映射）、`store::sync_state`（按实体独立、
  失败保留游标、多服务器隔离）、`store::prune`（级联 / 作用域内 book prune / 墓碑读写）、
  `ffi::application`（删除传播打到磁盘文件）、schema v6 迁移
- **Flutter（26 通过，含新增 8 项）**：`test/sync_triggers_test.dart`（冷启动分叉
  Bootstrap/Reconcile、回前台对账、下拉刷新后删除项从墙上消失、中断状态横幅、
  对账失败仍可用、失败后按 `network_recovered` 重试并在成功时停止、重试次数有上界）
- **Swift（99 通过，1 skip=live）**：`SyncScenarioTests`（同一份场景 JSON，10 步全绿）、
  `PruneStoreTests`、`ReadProgressSyncTests`（离线进度保护，含直接读共享 fixture 的一条）、
  `ScaleSyncTests`（300×20 规模镜像 + 幂等对账）、`SyncStateStoreTests`、Schema v6 迁移（v5 单行 → `full` 行）、
  FullSync 续跑/幂等（fresh 重跑 == 首次）
- **Smoke**：`stage5_smoke --scenario` 16/16 PASS
- **UI 构建**：ComicApp iOS + macOS scheme BUILD SUCCEEDED；flutter analyze 0 issues
- **删除传播落盘**：Reconcile 摘要携带真实封面路径（`Pruned.coverPaths` 两端一致），
  Apple 侧 `LibraryViewModel.reconcile` 逐个 `cache.remove(...)`，Android 侧由
  facade `remove_cover_files` 完成

## 从你自己服务器的 OpenAPI 导出里查出来的两件事

`specs/openapi/` 是 Komga 1.26.3 从 `http://192.168.0.69:25600` 导出的文档，属于
可离线核对的事实。据此新增了一道 API 一致性门禁（`api/openapi.rs`，4 条测试，
变异校验过：改坏一个 URL 构造器就报错）：

1. **同步引擎踩在两个已废弃端点上** —— `GET /api/v1/series` 与
   `GET /api/v1/series/{id}/books` 在 1.26.3 标记 deprecated，Komga 的策略是
   「下一个大版本移除」。未废弃的后继是 `POST /api/v1/series/list` 与
   `POST /api/v1/books/list`（带搜索 body）。换端点是传输层改动，必须在真实服务器上
   验证，所以本阶段不动，只把它钉成显式清单：将来任何新调用到废弃端点的代码都会让
   测试失败。
   核对结果里的好消息：客户端**必填解码**的字段（id/name/libraryId/seriesId/root 等）在
   文档里全都是 `required` + 非 nullable，客户端读取的每个属性也确实存在 —— 也就是说
   真实响应不会把一次 sweep 解到一半炸掉。唯一例外是刻意记录的：`SeriesMetadataDto` 没有
   `authors`，series 作者取自 `booksMetadata` 聚合，测试把这个来源钉住了。
2. **`/sse/v1/events` 在文档里根本不存在**（整个 spec 没有任何 `/sse*` 路由）。
   这大概率是 SpringDoc 不导出 `text/event-stream`，但也可能是路径不对 ——
   已在 `specs/events/komga-sse-events.md` 标注「未经验证」，接入 SSE 之前必须实测。
   这不影响本阶段的完成条件：那正是「不靠 SSE 也能收敛」。

## 已知边界

- SSE 事件流（`/sse/v1/events`）尚未接入：本阶段只留了 `sse_reconnected` 触发入口，
  完整正确性由 Reconcile 承担（这正是本阶段的完成条件）
- Outbox 上传（MutationUploadSync）仍未实现：本地变更照常落库并记 `pending_mutations`
- Reconcile 是全量 id 扫描，成本与库规模线性相关（Stage 4 的性能目标下可接受）；
  未来可加「远端 `totalElements` + 本地计数一致 ⇒ 跳过 prune」的快路径，
  但 prune 仍必须来自完整扫描
- 服务端 `modifiedSince` 一类的增量参数未使用：它只能给出「变化」，给不出「删除」，
  用它做 seen 集合会破坏安全规则
