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
bash scripts/e2e_stage5.sh        # 场景重放 12/12 PASS（无需网络，双端同一份 JSON）
bash scripts/verify.sh            # cargo fmt/clippy/test + swift build/test + flutter analyze/test
                                  # → ALL GREEN：Rust 98 / Swift 85（1 skip=live）/ Flutter 24
```

> **未在本机执行的半程**：`stage5_smoke` 的真实服务器链路（Bootstrap → Reconcile →
> 逐 series 本地计数 == 服务器 `totalElements` → 二次扫描 clean）需要 `KOMGA_API_KEY`。
> 本环境只能访问到 `http://192.168.0.69:25600`（未带凭据返回 401），密钥不在仓库里，
> 因此这一半**尚未跑过**，需要持有 Key 时执行：
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
| 网络恢复 | Apple：`NWPathMonitor` 由不可达转可达 → `networkRecovered`（`LibraryViewModel.startSyncTriggers`）；Flutter 壳无连通性插件，该时刻由回前台触发覆盖（`network_recovered` 在核心与场景测试中均已实现/验证） | 否 |
| SSE 重连 | `sse_reconnected` 触发名已接，走完整 Reconcile（事件流本身属下一阶段） | 否 |
| 用户手动刷新 | Flutter `RefreshIndicator`（下拉）→ `manual_refresh`；SwiftUI `.refreshable` → `model.reconcile(.manualRefresh)` | 否 |

- 实现：`sync/reconcile.rs` / `KomgaSync/ReconcileSync.swift`
- 流程：逐实体类型做远端**全量 id 扫描** → upsert（Added / Changed，靠 `lastModified`
  比对）→ 扫描完整后 prune（本地多余 id → 级联删除 + 墓碑）
- 安全规则：**prune 只在扫描到 `last = true` 后执行**；续跑时已提交页的 id 由本地行播种
  进 seen 集合 → 失败的同步最多推迟一个删除，绝不会删掉服务器还有的数据
  （`scenario-interrupt` 步 3 断言：全量故障下镜像 == 断网前的 s3）

## Deleted 状态传播

```text
Komga 删除 → Reconcile 扫描发现缺失 → SQLite 级联删除 + deleted_entities 墓碑 → UI 重读本地库
```

| 实体 | 级联范围（`store/prune.rs`，两端一致） | 证据 |
| --- | --- | --- |
| Series | 其 Books（递归走 Book 规则）+ metadata/tags/genres/authors + FTS 行 + `collection_series` 成员 + 封面记录与磁盘文件；子 Book 墓碑 `cause = cascade` | `series_delete_cascades_to_books_and_children`、场景步 3 |
| Book | 自身行 + metadata/tags/authors + FTS + `read_progress` + `readlist_books` 成员 + `downloads`/`download_pages` + 封面 + **该书的 Outbox 条目** | `book_delete_clears_membership_and_search`、场景步 3 |
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
| 修改 Metadata | s1 改 series-1 的 summary/genres/tags → 快照比对覆盖归一化表 |
| App 离线后重新上线 | interrupt 步 3（全量故障，镜像不变）→ 步 4（恢复后收敛到 s2） |
| 同步中途失败后恢复 | interrupt 步 1/2（series 第 2 页故障 → 游标续跑）+ 步 3/4（**Books 扫到某个 series 的中途**故障，游标 `series=<id>|page=1` → 重启从该 series 该页续跑，最终镜像 == s3） |
| 最终 SQLite == Komga | 每步 `diff_mirror`；收敛后再扫一次 `clean == true` |

`bash scripts/e2e_stage5.sh` 的 `--scenario` 半程在无网络条件下跑完全部步骤；
`stage5_smoke` 的 live 半程（提供 `KOMGA_BASE_URL` / `KOMGA_API_KEY` 时）额外校验
「本地 series/books/collections/readlists 计数 == 服务器 `totalElements`」，
以及第二次扫描 `clean == true`。

## 覆盖测试

- **Rust（98 通过）**：`sync::scenario`（两个共享场景 10 步全绿）、`sync::full`（镜像完整性 /
  fresh 幂等 / 已完成步骤不再重镜）、`store::sync_state`（按实体独立、失败保留游标、
  多服务器隔离）、`store::prune`（级联 / 作用域内 book prune / 墓碑读写）、
  `ffi::application`（删除传播打到磁盘文件）、schema v6 迁移
- **Flutter（24 通过，含新增 6 项）**：`test/sync_triggers_test.dart`（冷启动分叉 Bootstrap/Reconcile、
  回前台对账、下拉刷新后删除项从墙上消失、中断状态横幅、对账失败仍可用）
- **Swift（85 通过，1 skip=live）**：`SyncScenarioTests`（同一份场景 JSON，10 步全绿）、
  `PruneStoreTests`、`SyncStateStoreTests`、Schema v6 迁移（v5 单行 → `full` 行）、
  FullSync 续跑/幂等（fresh 重跑 == 首次）
- **Smoke**：`stage5_smoke --scenario` 12/12 PASS
- **UI 构建**：ComicApp iOS + macOS scheme BUILD SUCCEEDED；flutter analyze 0 issues
- **删除传播落盘**：Reconcile 摘要携带真实封面路径（`Pruned.coverPaths` 两端一致），
  Apple 侧 `LibraryViewModel.reconcile` 逐个 `cache.remove(...)`，Android 侧由
  facade `remove_cover_files` 完成

## 已知边界

- SSE 事件流（`/sse/v1/events`）尚未接入：本阶段只留了 `sse_reconnected` 触发入口，
  完整正确性由 Reconcile 承担（这正是本阶段的完成条件）
- Outbox 上传（MutationUploadSync）仍未实现：本地变更照常落库并记 `pending_mutations`
- Reconcile 是全量 id 扫描，成本与库规模线性相关（Stage 4 的性能目标下可接受）；
  未来可加「远端 `totalElements` + 本地计数一致 ⇒ 跳过 prune」的快路径，
  但 prune 仍必须来自完整扫描
- 服务端 `modifiedSince` 一类的增量参数未使用：它只能给出「变化」，给不出「删除」，
  用它做 seen 集合会破坏安全规则
