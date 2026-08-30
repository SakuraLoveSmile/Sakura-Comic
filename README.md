# Comic — Komga 全平台媒体库客户端

Local-first Komga media library client for Apple platforms and Android.

> 网络负责同步，本地数据库负责展示。
> UI 不直接依赖实时网络请求；所有媒体库页面优先从本地索引读取。

## 核心架构

```text
Komga Server
     ↓  REST + SSE
   Sync Engine
     ↓
     SQLite (local mirror)
     ↓
   Query Layer
     ↓
     UI
```

- **Local First** — UI 的唯一主要数据源是本地数据库
- **Server Authority** — Komga 服务端是远端权威状态，客户端维护本地镜像
- **Multi-Server Safe** — 所有远端 ID 以 `(serverId, remoteId)` 为复合主键
- **Mutation Outbox** — 本地先写、后台上传、失败重试，不丢用户操作

## 仓库布局

```text
Comic/
├── apple/          Apple 平台：ComicApp (iOS/macOS/tvOS/visionOS) + KomgaKit Swift Package
├── android/        Android 平台：Flutter shell (android/app) + Rust Core (android/komga_core)
├── specs/          OpenAPI / SSE 事件 / Behavior 契约 / Shared Fixtures
├── docs/           架构、同步引擎、数据库、阅读器、离线存储
└── .github/        CI workflows
```

## 阶段路线

| Phase | 目标 |
| --- | --- |
| Phase 0 | Architecture Vertical Slice（真实服务器 → SQLite → 封面墙） |
| Phase 1 | Media Library（封面墙 / 搜索 / Home / Series Detail） |
| Phase 2 | Reliable Sync（增量 / SSE / Outbox / 冲突处理）— Stage 5 Bootstrap + Reconcile，Stage 6 SSE + Mutation Outbox |
| Phase 3 | Reader（单页 / 双页 / Webtoon）— Stage 7 阅读器基础版（Product MVP），**Stage 8 性能与缓存** |
| Phase 4 | Offline（缓存 / 下载 / 离线浏览） |
| Phase 5 | Platform Polish（macOS / tvOS / visionOS） |

## 本期明确不做

Windows / Linux 客户端、全平台 Rust Shared Core、OCR、内容识别、本地图像处理、
自建转码、云端账户、OPDS Server、Komga 服务端管理。

## Phase 0 验证指南

```bash
chmod +x scripts/*.sh   # 首次

# 1. 三方代码检查（cargo fmt/clippy/test、swift build/test、flutter analyze/test）
bash scripts/verify.sh

# 2. FFI 接线（一次性；codegen 2.13 + cargo-ndk 4，生成绑定 + 三 ABI jniLibs）
bash scripts/frb_wire.sh

# 3. Android 模拟器/真机运行（需先完成步骤 2，否则 UI 回退 Stub 模式）
cd android/app && flutter build apk --debug && flutter install

# 4. 真实服务器垂直切片验收（phase0_smoke：认证 → 前 10 个 Series → SQLite → 封面缓存）
export KOMGA_BASE_URL=http://192.168.1.10:25600
export KOMGA_API_KEY=your-api-key
bash scripts/e2e_smoke.sh
```

iOS 侧：`cd apple/ComicApp && xcodegen generate && xcodebuild -scheme ComicApp_iOS -sdk iphonesimulator build`（.xcodeproj 为生成物，不入库）。

验收细节与勾选状态见 [docs/phase0-checklist.md](docs/phase0-checklist.md)。

## Stage 2 — API 契约与服务器管理

双端验收链：`添加服务器 → 登录 → 验证 Komga → 获取服务器信息 → 保存 Server Profile`。

- **API 契约**：OpenAPI 快照 `specs/openapi/komga-openapi.yaml`（Komga 1.26.3）为唯一事实来源；
  Swift/Rust 以共享 fixture（`specs/contracts/fixtures/connection/`）对齐 DTO、分页与错误模型；
  版本兼容策略见 [specs/openapi/compatibility.md](specs/openapi/compatibility.md)。
- **Server Profile**：多服务器 CRUD + 测试连接 + 切换；认证信息只存
  Keychain（Apple）/ Android Keystore（Keystore 通道），数据库只存 `credential_ref`；
  远端实体一律 `(serverId, remoteId)` 隔离。
- **离线验收**：
  ```bash
  bash scripts/verify.sh
  cd android/komga_core && cargo run --bin stage2_smoke -- --fixture --db /tmp/comic-stage2.sqlite
  ```
- **真实服务器验收**（需 API Key）：
  ```bash
  export KOMGA_BASE_URL=http://192.168.0.69:25600
  export KOMGA_API_KEY=your-api-key
  bash scripts/e2e_stage2.sh
  ```
  勾选状态与实现位置见 [docs/stage2-checklist.md](docs/stage2-checklist.md)。

## Stage 3 — Local Store 与 Vertical Slice

首次打通完整核心链路 `Komga → API → SQLite → Cache → UI`，核心原则：
**网络负责同步，本地数据库负责展示**（UI 只读 SQLite，禁止 View → Komga API）。

- **SQLite Schema v3**：servers / libraries / series / books / collections / readlists /
  sync_state / pending_mutations / **thumbnails**（封面缓存记账，v3 新增）——
  双端 DDL 镜像（GRDB ↔ rusqlite），远端实体一律 `(serverId, remoteId)`。
- **Series**：API → Local Model 转换 → 批量 upsert 入库 → 分页查询（双端 + 共享 fixture）。
- **Cover Cache**：下载 → 磁盘缓存（`cache/thumbnails/`，多服务器安全 key）→
  SQLite 记账；**缓存缺失自动补齐**（`ensure_cover` / `ensure_covers` 幂等回填）。
- **封面墙**：列表与封面路径均来自 SQLite；Android 端 `Image.file` 渲染磁盘封面，
  附离线「演示」模式（fixture Series + 生成 PNG，无服务器）。
- **离线验收**：
  ```bash
  bash scripts/verify.sh
  cd android/komga_core && cargo run --bin phase0_smoke -- --fixture \
    --db /tmp/comic-stage3-fixture/comic.sqlite --server-id demo
  ```
- **真实服务器验收**（需 API Key）：
  ```bash
  export KOMGA_BASE_URL=http://192.168.0.69:25600
  export KOMGA_API_KEY=your-api-key
  bash scripts/e2e_stage3.sh
  ```
  勾选状态与实现位置见 [docs/stage3-checklist.md](docs/stage3-checklist.md)。

## Stage 4 — 完整媒体库

客户端扩展为可离线使用的完整 Komga 媒体库浏览器。核心原则不变：
**网络负责同步，本地数据库负责展示** — 搜索、筛选、排序、分页全部基于 SQLite（FTS5 + 归一化表）。

- **Library**：列表页（每库本地 series/book/已读 计数 + 根路径 + 可用性）/ 详情页
  （统计 + 阅读进度 + 本库内 FTS 搜索 + 该库封面墙分页）/ 切换（书架 chips、
  「设为书架筛选」、服务器切换入口），全部读 SQLite（`library_counts` / `library_detail`）
- **Series**：封面墙 / 详情（Metadata、Tags、Genres、Status、作者、出版社、阅读方向、
  所属合集）/ 阅读计数器
- **Books**：列表（封面缩略图 `variant='book'`、阅读状态）/ 详情 / 阅读状态本地变更
  （写 `pending_mutations` Outbox：READ_PROGRESS / MARK_READ / MARK_UNREAD）
- **Collections / Readlists / Continue Reading**：成员关系入 SQLite（`collection_series`、
  `readlist_books` 保序），书架直接从本地 `read_progress` 派生
- **本地查询**（`store/query.rs`，双端镜像）：FTS5 搜索、Library/Tag/Genre/Status 筛选、
  5 种 Series 排序（名称/排序名/加入日期/最近更新/册数）、3 种 Book 排序（册数/标题/加入日期）、
  LIMIT/OFFSET 分页 + 总数
- **Schema v4**：归一化筛选表 + 成员关系表 + 完整元数据列 + 服务器作用域 FTS（双端 DDL 镜像）
- **FullSync**：Series → Books → Collections → Readlists → On-Deck Progress 全量分页镜像
- **离线验收**：
  ```bash
  bash scripts/verify.sh
  bash scripts/e2e_stage4.sh          # fixture 电池 + 离线重放
  ```
- **真实服务器验收**（需 API Key：同步 → 断网重放同一数据库）：
  ```bash
  export KOMGA_BASE_URL=http://192.168.0.69:25600
  export KOMGA_API_KEY=your-api-key
  bash scripts/e2e_stage4.sh
  ```
  勾选状态与实现位置见 [docs/stage4-checklist.md](docs/stage4-checklist.md)。

## Stage 5 — 同步引擎

把「一次性镜像」升级为「长期可靠的同步系统」。本阶段落地 **Bootstrap Sync** 与
**Reconcile Sync**，目标是：**即使 SSE 完全失效，本地数据库仍能依靠 Reconcile 最终恢复到正确状态。**

- **Bootstrap Sync**（`sync/full.rs` ↔ `KomgaSync/FullSync.swift`）：按契约顺序
  Libraries → Series → Books → Collections → Readlists → Read Progress；每页一个事务，
  并在同一写入路径记录续跑游标（`page=N` / `series=<id>|page=<n>`）。中断后重启从游标续跑，
  已完成步骤直接跳过；失败只标 `error` 并保留游标，已镜像数据照常可浏览
- **Sync State**（Schema v6）：`sync_state` 主键改为 `(server_id, entity_type)`，
  每类实体记录 `lastSyncAt` / `syncCursor` / `syncStatus`；`full` 行承载服务器级
  `lastFullSync` / `lastSuccessfulSync` 供 UI 显示「最近同步」
- **Reconcile Sync**（`sync/reconcile.rs` ↔ `KomgaSync/ReconcileSync.swift`）：
  App 启动 / 回前台 / 网络恢复 / SSE 重连 / 手动刷新五种触发走同一条全量 id 扫描路径
  （前两种受 60s 节流）→ upsert Added/Changed → **扫描完整后**才 prune Deleted。
  半途失败最多推迟一个删除，绝不删服务器还拥有的数据
- **Deleted 传播**（`store/prune.rs`）：Series / Book / Collection / Readlist 各自的级联
  范围明确，含封面记录 + 磁盘文件 + FTS + Outbox 条目；删除写入墓碑表
  `deleted_entities`（`cause ∈ reconcile | cascade | event`），同一 id 重现时清除
- **双端共享验收**：`specs/contracts/fixtures/sync/*.json` 脚本化 Komga 侧历史
  （新建 / 修改 / 删除 Series、新增 Book、改 Metadata、离线后重连、同步中途失败恢复），
  每步比对「本地 SQLite == 服务器快照」+ 墓碑 + `sync_state` + 请求次数；
  两个场景都标注 `"sse": "disabled"`
- **真实 HTTP 回环验收**：`komga_fixture_server` 用真实 TCP 提供同一批快照（可在客户端
  运行期间切换），把注入式 fetcher 测不到的 `KomgaClient` 路径（URL、`X-API-Key`、
  `page`/`size` 切片、分页信封、错误映射）也纳入自动验收
- **验收**：
  ```bash
  bash scripts/e2e_stage5.sh          # 场景重放 → 真实 HTTP 回环 → 真实服务器(需 Key) → Swift 同契约
  bash scripts/verify.sh
  ```
  真实服务器链路（Bootstrap → Reconcile → 逐 series 校验镜像 == 服务器 → 再扫一次 clean）：
  ```bash
  export KOMGA_BASE_URL=http://192.168.0.69:25600
  export KOMGA_API_KEY=your-api-key
  bash scripts/e2e_stage5.sh
  ```
  勾选状态与实现位置见 [docs/stage5-checklist.md](docs/stage5-checklist.md)。

## Stage 6 — SSE 与 Mutation Outbox

补上同步引擎的后两半：**实时刷新**（Event Driven Sync）与**可靠的客户端写操作**
（Mutation Upload）。完成条件：实时事件丢失不影响最终一致性，客户端写操作在异常退出与
断网之后仍能恢复。

- **SSE**（`api/sse.rs` + `sync/sse.rs` ↔ `KomgaAPI/SSEClient.swift`）：连
  `GET /sse/v1/events`（1.26.3 源码核实，事件目录见
  `specs/events/komga-sse-events.md`）。帧解析器逐字节处理 LF/CRLF/CR、被切断的
  UTF-8、多行 `data:`、注释心跳 `:heartbeat`；退避复用 Outbox 那份共享策略
  （base 2s / factor 2 / cap 300s），服务端 `retry:` 只能抬高下限。**重连后必须先跑一次
  完整 Reconcile 再消费事件**，期间到达的帧只缓存不应用 —— 服务端从不发 `id:`，不存在续传。
  握手不合格（非 200 / 不是 `text/event-stream`）就停在 `ReconcileOnly` 且不再重连：
  实时性降级，正确性不降级。
- **事件只给 id**：`classify` → `DirtySet` 合并 → `GET /api/v1/books/{id}` → 走既有镜像
  写入路径进 SQLite → UI 重读本地库。认不出的事件一律「全局脏」，代价只是一次 Reconcile。
- **Mutation Outbox**（`store/outbox.rs` + `sync/upload.rs` ↔ `KomgaStore+Outbox.swift` +
  `KomgaSync/OutboxUpload.swift`）：Schema v7 加 `state` / `next_retry_at`；重试、指数退避、
  `failed` 终态、同族合并（只保留用户最后一次表态）、重启恢复（到期时间是写在库里的绝对戳）、
  成功后清理。故意不设 in-flight 标记：Komga 的进度写幂等，所以「at-least-once + 崩溃重放」
  就是全部恢复机制。写端点按导出文档：`PATCH /api/v1/books/{id}/read-progress`
  （`ReadProgressUpdateDto {page?, completed?}`，成功 204 **无 body**，因此不得伪造服务器
  时间戳），Mark Unread 是同路径 `DELETE`。
- **冲突规则写进 Behavior Contract**，两条偷懒解法被明确禁止且各有反例测试：不是
  `Server Always Wins`（断网动作恢复后照旧上传），也不是统一 `max(page)`（判据只有
  「谁的动作时间更晚」+「显式 Mark 压过被动进度」，于是本地 page 3 能覆盖服务器 page 90，
  反之远端 page 3 也能覆盖本地 page 90）。R4 取的是 `readProgress.lastModified`，
  不是不随进度推进的 `book.lastModified`。
- **双端共享验收**：`specs/contracts/fixtures/outbox/{conflict,backoff,coalescing}.json` 与
  `specs/contracts/fixtures/sse/{parse,handshake}.json` 是唯一数据源，Rust
  （`store::outbox::contract_tests`、`tests/sse_contract.rs`）与 Swift 各加载同一批文件。
- **验收**：
  ```bash
  bash scripts/e2e_stage6.sh      # 断网 → 阅读 → kill -9 → 重启 → 恢复网络 → 自动上传（以服务器 journal 为证）
                                  # → 注入故障跑退避阶梯 / 400 / 401 → 真流 SSE 重连顺序 → Swift 同契约
  bash scripts/verify.sh
  ```
  勾选状态与实现位置见 [docs/stage6-checklist.md](docs/stage6-checklist.md)。

## Stage 7 — 阅读器基础版（Product MVP）

可以日常使用的漫画阅读器：三种模式 × 三种方向、六项阅读设置、
`Reader → Page Manifest → Cache → Local File → Decode → Render` 的加载管线、
节流上传的阅读进度、相邻页预取。

- **语义先行**：`specs/contracts/fixtures/reader/{paging,manifest,prefetch,throttle}.json`
  是双端唯一事实来源（Rust `reader/*::contract_tests` 与 Swift `ReaderContractTests` 各加载同一批文件）。
  配对与方向、清单归一化、预取窗口次序、进度节流规则（本地永远立即写、网络只在节拍上走、
  显式动作与退出/后台立刻冲、末页 ≠ 标已读、回翻合法）逐例钉住；改动契约必改两端。
- **模式与方向**（`reader/paging.rs` ↔ `KomgaReader/Paging`）：单页 / 双页（含封面单独、末尾落单、
  宽或高未知的页不配对）/ 条漫；LTR / RTL / Vertical 决定屏内先后与手势，
  **不改变「下一页是哪一页」**。
- **页面加载**（`reader/{manifest,cache,loader}.rs` ↔ `KomgaReader/{PageManifest,PageCache,PageLoader}`）：
  清单镜像进 `book_pages`，开过的书离线可开；页缓存 `cache_entries` 记账 +
  `cache/pages/<key>.<ext>` 落盘（`.part` + rename，半文件不可能是命中），
  LRU 按预算淘汰且永不删离线下载。**UI 只拿到本地文件路径，结构上无法自己发请求。**
- **阅读进度**（`reader/{session,throttle}.rs` ↔ `KomgaReader/{ReaderSession,ProgressThrottle}`，
  Schema v8 的 `reader_position`）：翻页在同一个调用里落
  位置 + `read_progress` + `pending_mutations`，节流只管网络；30 页突发 = 1 行队列 = 1 个请求；
  普通进度 / Mark Read / Mark Unread 三者各自送达（线上 body 复用 Stage 6 的 `request_for`，不另写一份）。
- **Android**：FFI 面 `reader_*`（`ffi/bridge.rs`）+ `lib/src/reader_{api,controller,screen}.dart`；
  屏幕常亮与亮度走平台通道 `comic/reader`（`MainActivity.kt`），不新增 pub 依赖。
  **Apple**：`KomgaReader` + `ComicApp/Shared/Reader{Model,Screen}.swift`，
  iOS 全屏 / macOS 弹窗，包依赖图已声明 `KomgaReader → KomgaSync`（复用 Stage 6 的线上格式）。
- **验收**：
  ```bash
  bash scripts/e2e_stage7.sh   # 打开 / 三种模式 / 快翻只发一次 / 重开原位 / 断网续读 / 预取 / 三路同步
                               # 真机腿：真实书的清单尺寸 == 实际像素，翻页写进去再原样还原
  bash scripts/verify.sh       # cargo fmt+clippy+test · swift build+test · flutter analyze+test
  ```
  勾选状态、已知限制与本阶段顺带修掉的回环服务器路由遮蔽缺陷，见
  [docs/stage7-checklist.md](docs/stage7-checklist.md)。

## Stage 8 — Reader 性能与缓存

Stage 7 让阅读器能用，这一阶段让它经得起长期日常使用：大图、大页数、长会话三类
压力场景下的内存、请求数与延迟都有实测数字，缓存坏掉能自愈。

- **语义先行**：`specs/contracts/fixtures/reader/window.json`（20 例 + 6 例 slot）
  是「预取多少、并发几个、内存层多大」的唯一事实来源，Rust `reader/window.rs` 与
  Swift `KomgaReader/WindowPlanner` 各加载同一文件。七步次序（内存 → 页成本 → 装得下
  几页 → 模式 → 字节上限 → 网络 → 是否稳定）逐例钉住；反空转断言要求五个命名输入里
  每一个都至少有一对「只差它且结果不同」的用例，而 `direction` 反过来要求
  「只差方向的用例结果必须相同」——它不该改变窗口。
- **缓存分三层**（`cache/mod.rs` ↔ `DiskImageCache`）：`thumbnails/` · `pages/`（读者
  真看过的）· `prefetch/`（猜来的、还没看过的）。淘汰次序 download 永不参与 → prefetch
  先于 page（**与新旧无关**）→ 同层按 `last_access`；且触发淘汰的那一条本身不可淘汰。
- **内存层是字节预算 LRU**（`reader/memory.rs` ↔ `ByteBudgetCache`）：峰值恒 ≤ 预算，
  单项超预算只拒绝不驱逐，重插替换不重复计数；预取页落盘的同时驻留内存，所以磁盘被
  淘汰的预取页能从内存重新落盘而不是重下。Swift 侧原先那个**永不淘汰**的
  `[UInt32: Data]` 就是本阶段要修的 iOS 泄漏。
- **完整性即自愈**（`reader/integrity.rs`）：写入时全量走容器（PNG 逐 chunk CRC、
  JPEG 段长与 EOI、GIF 结束符、WebP RIFF 长度），命中时只读头尾；截断页与「被当成 .jpg
  缓存下来的 HTML 错误页」一律拒收并丢弃，连拒两次停止重试。AVIF/HEIC/BMP/JXL 判为
  「看不懂但保留」——不能走它的容器不等于它坏了。
- **Android 图片链路的两条硬规则由测试守着**（`tests/reader_architecture.rs` +
  Dart 源码断言）：页面/封面接口出现 `u8`/`Uint8List` 即失败；`flutter_rust_bridge`
  出现在 `src/ffi/` 之外即失败；手写 reader 层出现 `Image.network` / `Image.memory` 即失败。
- **UI 侧落地**：`reader_device.dart` 是唯一能回答「这设备有多少内存、这块屏解码一页
  要多少字节」的地方，核心探不到也不猜；`ImageCache` 的 `maximumSizeBytes` /
  `maximumSize` 全部来自核心下发的计划，关书即还原；路径 memo 从「无界」改成按窗口定界。
- **下载保护是结构不是约定**：`store::cache::protected_paths` 把 `downloads` /
  `download_pages` 两张表与账本里的 download 行一起当作不可删除集合，淘汰、清层、
  清书、开书清扫四处都问它——因为离线下载（Phase 4）还是空壳，保护若依赖"将来有人会
  写那行账"，忘记的那一天就是用户书架被清扫删掉的那一天。
- **对外接口也被走了一遍**：`--phase facade` 用 App 真正暴露的 `reader_*` 入口驱动，
  证明清扫发生在设备档案上报时、预取字节确实镜像进内存、显示预取页会把文件从
  `prefetch/` 改名进 `pages/`（目录文件数 4→3 与 2→3）、用户清理只丢猜来的字节。
- **验收**：
  ```bash
  bash scripts/e2e_stage8.sh   # 63 项检查：520 页整本 / 真 4K / 120 次跳翻 / 300 次条漫滚动 /
                               # 弱网 / 断网 / 网络切换 / 内存压力 / 后台恢复 / 截断页自愈
                               # 每个相位独立进程，同时采样 RSS 与服务端日志的请求增量
  bash scripts/verify.sh       # cargo fmt+clippy+test · Android 目标交叉检查 · swift · flutter
  ```
  数字、六条被证据逼出来的真实缺陷、以及尚未验证的部分（真机帧率与低内存边界、真实
  Komga 大书、iOS 模拟器），见 [docs/stage8-checklist.md](docs/stage8-checklist.md)。
- **真机腿**：`bash scripts/e2e_stage8_device.sh` 构建 profile APK 装进 Android 模拟器，
  用路由 `/reader-stress` 驱动**真实阅读器**读真 HTTP 服务器，采样 `dumpsys meminfo` 与
  服务端页日志：160 次翻页 PSS 108.4→108.4 MB（后 1/4 与首采样持平）、82 次页读取全是
  不同页（零重复请求）、中途窗口从 13 收到 1、平台通道真的报出了 4.1 GB 物理内存、
  ImageCache 上限等于核心下发的预算；`am send-trim-memory` 让进程真的交还 49 MB PSS
  而屏幕上那页仍在；`svc wifi disable` 把网络栈真的关掉之后，读者把链路认成 `offline`
  并且此后一个请求都不再发出；强迫 1.5 GB 设备类别时同一份构建把层从 256 MiB/25 槽
  收到 192 MiB/19 槽。16 项检查全绿。
  帧成本：暖页 p50 25ms / p95 36ms，4K 暖页 p95 21ms（`-gpu host`；换回软件光栅这两
  个数字会变成 1020ms / 36ms，脚本因此默认 host 并把它写进注释）。

## 文档入口

- [架构](docs/architecture.md)
- [同步引擎](docs/sync-engine.md)
- [数据库 Schema](docs/database-schema.md)
- [阅读器](docs/reader.md)
- [离线存储](docs/offline-storage.md)
- [Stage 7 验收清单](docs/stage7-checklist.md)
- [Stage 8 验收清单](docs/stage8-checklist.md)
- [Behavior 契约与 Fixtures](specs/behavior.md)
