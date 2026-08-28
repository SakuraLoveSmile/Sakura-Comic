# Stage 6 Checklist — SSE 与 Mutation Outbox

目标：把 Stage 5 的「镜像可靠」升级为「交互可靠」。补齐同步引擎的后两半
**Event Driven Sync** 与 **Mutation Upload Sync**。

完成条件：**实时事件丢失不影响最终一致性，客户端写操作在异常退出和断网后仍能恢复。**

```text
Bootstrap + Reconcile（Stage 5）+ SSE Event Sync + Mutation Upload（Stage 6）
```

## 验收结果

```bash
bash scripts/e2e_stage6.sh      # 断网→阅读→kill -9→重启→恢复网络→自动上传 → 注入故障阶梯 → SSE 真流 → 部署包核对 → Swift
KOMGA_BASE_URL=http://192.168.0.69:25600 bash scripts/e2e_stage6.sh   # 追加：无凭据核实事件表
KOMGA_API_KEY=... bash scripts/e2e_stage6.sh                          # 追加：带凭据握手 + 真实写往返
bash scripts/verify.sh          # cargo fmt/clippy/test + swift build/test + flutter analyze/test
```

一次真实运行的结果（2026-08-28，本机）：

| 层 | 结果 |
| --- | --- |
| Rust 单元 + 契约测试 | **151 passed / 0 failed**（lib）+ `sse_contract` **9** + `sse_events_contract` **2** |
| Rust 门禁 | `cargo fmt --check` 干净、`cargo clippy --all-targets -- -D warnings` 无输出 |
| Swift | **127 tests, 1 skipped(=live), 0 failures** |
| Flutter（Android 壳） | `flutter analyze` 无问题、**40 tests all passed**（Stage 5 时 26） |
| 回环 HTTP 验收 | `STAGE 6 ACCEPTANCE OK` |
| 真实服务器（无需凭据） | 部署包 `app.14b2997d.js` 含 `/sse/v1/events`，且我们事件表里 **18/18** 个真实事件名都被官方 UI `addEventListener` 订阅；SSE 与 REST 共用同一 URL 基址（含子路径） |
| **真机带凭据（已跑）** | `--phase live-sse`：握手 200 + `text/event-stream`，25s 内 5 帧、3 个事件（全 `TaskQueueStatus`，即 10s 管理端定时帧），心跳注释帧计为帧但不产生事件；`--phase live-write`：epub 被 R8 拦下（不发包），图像书 `PATCH -> 204` 并恢复原状 |

## 第 1 步：验收标准逐字跑通（真实 HTTP + 真实 `kill -9`）

`scripts/e2e_stage6.sh` 用 `komga_fixture_server`（本阶段长出 `PATCH` / `DELETE`
`read-progress`、`GET /api/v1/books/{id}`、以及 chunked 的 `/sse/v1/events`）
驱动 `stage6_smoke` 的五个相位。**离线相位跑完后脚本对进程执行 `kill -9`**，
重启相位是一个新进程重新打开同一个 SQLite 文件 —— 不是模拟，不是内存重放。

```text
断网   → 3 个动作入队，上传整轮 deferral，队列一条不少
kill -9 → 进程被强杀（三条队列行的 retry_count=1、next_retry_at 都已落盘）
重启   → 新连接读回 3 行，惩罚与到期时间原样存在
恢复   → 3 条自动上传，Outbox 清零，mutation_pending=0，server_updated_at=NULL
```

证据不是客户端自己的 summary，而是**服务器侧的 journal**：

```json
{"body":"{\"page\":30,\"completed\":false}","bookId":"book-1-1","method":"PATCH"}
{"body":"{\"completed\":true}","bookId":"book-1-2","method":"PATCH"}
{"body":"","bookId":"book-1-3","method":"DELETE"}
```

翻页动作原样到达（page 30）、Mark Read 成为 `completed:true`、Mark Unread 是
`DELETE` —— 三条都没有因为断网 + 强杀而丢失或变形。

同一相位还验了 `404` 语义：服务器确认书已不存在时，队列行才被释放（`phase gone`）。

### 退避阶梯与结果分类（`--fault-file` 注入真实 HTTP 状态）

| 注入 | 期望 | 结果 |
| --- | --- | --- |
| `503` 连续 8 次 | 依共享策略 `2,4,8,16,32,64,128,256s` 逐级退避，第 8 次进 `failed`，之后**不再自动重试**（哪怕把时间推到 2030） | `backoff ladder 7 then failed` |
| `400` | 直接 `failed`，且**不消耗**重试次数（载荷被拒，重试同一无意义） | 通过 |
| `401` | 整轮立即停止、一个包都不发、每条队列行的 `retry_count` 与到期时间**分毫不动** | 通过 |
| `404`（refetch） | 服务器确认实体已删 → 释放该条 | 通过 |

## 第 2 步：SSE 真流

```text
ok: 5 events parsed, 8 hints coalesced, reconnect reconciled before consuming
```

回环服务器把 `specs/contracts/fixtures/sse/stream.raw`（CRLF 心跳注释帧 + CRLF 帧 +
LF 帧 + `id:` 帧 + 未知事件名 + **结尾半帧**）按 **7 字节一块**发出，所以帧一定跨越
读取边界。断言项：

- 5 个事件解析出来；心跳注释帧没有变成事件；**结尾半帧没有被 dispatch**（丢帧交给
  重连后的 Reconcile 兜底，而不是猜内容）
- 8 个 hint 合并成少量目标（事件只给 id，内容一律回 API 重新拉取）
- 断流 → 退避到期前**不允许**立刻重连（防风暴）→ 到期后重连 →
  **先返回 Reconcile，且此时连一次 socket read 都不做** → `reconcile_done()` 之后
  才恢复消费（`a_reconnect_reconciles_before_any_event_is_applied`）
- 路由不存在/不是 event-stream → `ReconcileOnly` 且**不再拨号**（数月后仍然 0 次尝试）

## 契约与实现位置

| 契约 | 共享 fixture | Rust | Swift |
| --- | --- | --- | --- |
| 冲突规则 R1–R6 | `fixtures/outbox/conflict.json`（12 例，含两条反 `max(page)`） | `store/outbox.rs::decide` | `OutboxUpload.decide` |
| 合并 | `fixtures/outbox/coalescing.json` | `store/outbox.rs::coalesce` ← `enqueue_mutation` | `KomgaStore+Outbox` |
| 退避 / 终态 | `fixtures/outbox/backoff.json` | `store/outbox.rs::{backoff_seconds, record_outcome}` | 同名语义 |
| 帧解析 | `fixtures/sse/parse.json`（20 例） | `api/sse.rs::SseParser` | `SSEParser.swift` |
| 握手与退化 | `fixtures/sse/handshake.json` | `api/sse.rs::SseClient::connect` | `SSEClient.classifyHandshake` |
| 事件 → 目标 | `fixtures/sse/events.json`（25 例） | `sync/sse.rs::classify` | `EventClassifying.classify` |
| 上传器编排 | 同上 | `sync/upload.rs` | `KomgaSync/OutboxUpload.swift` |
| 会话与生命周期 | `reconnect/README.md` | `sync/sse.rs::SseSession` + `pump` | `LibraryViewModel.streamLoop` + `scenePhase` |

Schema **v7**：`pending_mutations` 加 `state` / `next_retry_at` + `pending_mutations_due`
索引，两端逐字同一份 DDL（详见 [database-schema.md](database-schema.md)）。

## 两端 App 生命周期

| | Apple | Android |
| --- | --- | --- |
| 前台起流 / 后台停 | `LibraryViewModel` 观察 `scenePhase` | `_SeriesGridScreenState.didChangeAppLifecycleState` → `LiveSyncController.start/stop` |
| 网络恢复立即重连 | `NWPathMonitor` → `resume` | 扫描成功后与 `didChangeAppLifecycleState(resumed)` → `resume()` → `sse_resume` |
| 重连先 Reconcile | `reconcile(trigger: .sseReconnected)` 之后才消费 | `tick()` 内 `reconcile('sse_reconnected')` → `sseReconciled` 顺序写死 |
| UI 自动刷新 | 事件只给 id → 重读 SQLite | `refresh()` 只重读本地库（`_loadWall` + `_loadSyncState`） |
| 后台上传 | 5s Outbox tick | 20s tick + 每次本地写 3s 去抖后 `uploadOutbox`（翻页不等于发请求） |
| 队列可见性 | `待上传 N` 徽标 | AppBar 徽标：`cloud_upload`（待传）/ `cloud_off`（已放弃，点击重试） |

Android 侧的编排是**薄**的：会话状态以不透明 JSON 往返于核心（`stateJson`），退避、冲突
判定、清理全在 Rust；壳只决定「什么时候问一次」。测试因此盯的是**顺序**而不是数值：
`['ssePoll:', 'reconcile:sse_reconnected', 'sseReconciled:s1', 'refresh']`
（`test/live_sync_test.dart`，14 例）。核心 FFI 面：`upload_outbox` / `outbox_status` /
`retry_failed_mutations` / `sse_poll` / `sse_reconciled` / `sse_resume` / `sse_stop`。

## 变异测试：两条禁令真的是禁令

「不能简单采用 Server Always Wins / 不能统一采用 max(page)」要能被证伪，否则只是口号。
把 `store/outbox.rs::decide` 逐个改坏后跑同一批契约测试（每次都还原）：

| 变异 | 结果 |
| --- | --- |
| R4 改成「远端更晚一律成立」（= Server Always Wins） | `conflict_rules_match_the_shared_fixture` + `the_losing_side_is_never_chosen_because_its_page_is_bigger` **双双失败** |
| R4 改成「远端 page 更大就让它赢」（= max(page)） | 同上两条**失败** |
| 去掉 R2（显式 Mark 不再压过远端被动值） | `conflict_rules_match_the_shared_fixture` **失败** |
| 还原 | 10 passed / 0 failed |

也就是说：这两种偷懒解法一旦被写进实现，测试立刻红；契约是真的在管实现。

共享 fixture 规模：`conflict.json` 12 例 + `coalescing.json` 7 例 + `backoff.json` 4 例 +
`parse.json` 20 例 + `events.json` 25 例 = **68 条两端共读的用例**。

## 本阶段抓到的两个真问题

1. **Swift 侧原本按事件名关键字匹配**（`name.contains("book")`）。这会把
   `ThumbnailBookDeleted` 判成「书被删了」——仅仅因为一张海报记录被删就抹掉本地镜像的
   书；同时 `ReadProgressChanged`（名字里没有 book，载荷里有 bookId）会被降级成整库扫描。
   修复：两端都改成按核实过的事件名字面量精确映射，并把这张表放进
   `fixtures/sse/events.json` 让两端同时断言（含这两条专门的反例测试）。
2. **回环服务器把请求头用 `BufReader` 读、请求体用裸 socket 读**，于是 body 被缓冲吞掉、
   任何带 body 的请求永久阻塞。修成同一个 buffered reader 一路读到底。

## 真机跑出来的两条新规则（R7 / R8）

第一次带凭据真机运行就把契约打个洞：`stage6_smoke --phase live-write` 对
`PATCH read-progress` 收到 **400**，而回环 fixture 一律接受。量出来的是：

| 发出的东西 | 真实结果 |
| --- | --- |
| `{"page":0,...}` | 400 `must be greater than 0` |
| `{"completed":false}` | 400 `{"violations":[]}` |
| `{"completed":true}` | 204，服务器自己把 page 置成 pagesCount |
| `{"page":N>=1}` 图像书 | 204 |
| `{"page":N>=1}` epub/pdf | 400 `epub book is not Divina compatible` |
| `DELETE` | 204，两种版式都有效 |

于是加了 R7（没页码又没读完 = `drop_no_op`，不发包、也不算失败）与
R8（可重排版的翻页 = `unsupported_format`，**不发包**、把行停靠并写明原因，
而不是烧完 8 次退避去撞同一个 400）。两端与 `conflict.json`（现 17 例）同步钉住。
R8 的正式出口是 `PUT /api/v1/books/{id}/progression`，那是阅读器版面定位的活儿，
归 Reader 阶段；本阶段的要求是**不许把它伪装成成功**。

## 尚未验证 / 已知限制

- ~~带凭据的真机握手与真实写往返~~ **已跑**（见上表）；剩下的是把真机核对纳入常规流程：
  `KOMGA_BASE_URL=... KOMGA_API_KEY=... bash scripts/e2e_stage6.sh` 现在会自动执行 2c/2d。
- **事件目录已在你的真实服务器上核实（不需要凭据）**：`GET /` 引到的 Web 包
  `app.14b2997d.js`（HTTP 200）含 `/sse/v1/events` 字面量、`new EventSource`，
  以及逐个事件名的 `addEventListener`，与本阶段采用的表逐个吻合。
  仍未测到的只剩**带凭据的那一次握手**与一次真实上传往返。
- **原判断（保留）**：
  无凭据实测不可能得出结论：`/api/*` 与 `/sse/*` 一律 401（认证过滤器在路由之前；
  对照瞎写路径 200）。带 Key 跑脚本第 2c 步即可确认握手：
  ```bash
  KOMGA_BASE_URL=http://192.168.0.69:25600 KOMGA_API_KEY=<你的 key> bash scripts/e2e_stage6.sh
  ```
  读路由的形状（`PATCH` body `{page?, completed?}`、`DELETE` 表 Mark Unread、成功 204
  无 body）来自**你自己服务器导出的 OpenAPI**，这一条是有据的。
- **`ReadProgress*` 事件是 `userIdOnly` 投递**：另一个账号读了什么，本设备不会收到事件，
  只能靠 Reconcile 发现 —— 这是服务端的投递语义，不是客户端缺陷。
- 回声（我们自己 PATCH 成功后服务器推回的事件）走 `sync_write_for` 判定，未上传成功的
  本地意图优先，因此不会把服务器值当新数据盖回来；但这依赖 Key 到位后的真机验证。
- Dart/Flutter 侧的 SSE + Outbox 接线与 `待上传` UI 属本阶段最后一环，状态见
  「下一步」；Rust 核心的可轮询 `sse_poll` 面在收口中。

## 下一步

1. 带 `KOMGA_API_KEY` 跑一次真机：SSE 握手 + 一次真实阅读进度上传往返 + Mark Unread，
   把结论写回本文件（与 Stage 5 那条未完成项一起做）。
2. Dart 侧接线完成后，`scripts/e2e_stage6.sh` 去掉 `--rust-only` 全链路 + `verify.sh`。
3. Reader 侧接 `upload_outbox` 触发点（翻页 debounce → 本地写 → 队列），属 Stage 3 阅读链
   的收尾，不改变本阶段契约。
