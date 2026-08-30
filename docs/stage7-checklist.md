# Stage 7 验收清单 — 阅读器基础版

阶段目标：**完成可以日常使用的漫画阅读器**（单页 / 双页 / 条漫 × LTR / RTL / Vertical，
六项阅读设置，页面加载管线，阅读进度节流上传，相邻页预取）。完成后即为 Product MVP。

共享契约：`specs/contracts/fixtures/reader/{paging,manifest,prefetch,throttle}.json`
—— 四个文件是这一阶段唯一的语义事实来源，Rust 与 Swift 各自加载同一批文件。

## 语义：先写契约，再写两端

| 契约 | 钉住的东西 | 反例（被明确禁止的偷懒解法） |
| --- | --- | --- |
| `paging.json`（17 例） | 页→跨页的配对、轴、镜像、手势与点按半区、`page → spread` 的还原映射 | 「方向改变阅读顺序」：RTL 只改屏幕上的先后与手势方向，前进永远是页码增序；测试逐例断言 `advanceSwipe`/`tapNext` 且有一条「前进必单调」的性质测试 |
| `manifest.json`（9 例） | `PageDto[]` → 规范页号、尺寸缺失、`size` 是显示字符串不许解析、空清单、epub/pdf 不进图像阅读器 | 「信任服务器给的 number」：number 乱序/重复/从 0 起都不重排、不去重、不丢页，位置即次序；`drift` 只作诊断 |
| `prefetch.json`（12 例） | 以**跨页**为单位的窗口、出队次序、缓存页仍占名额、越界钳制、`cap` 从尾部裁、快翻时旧窗口作废但在途不砍 | 「按页而不是按跨页预取」：双页模式下会漏掉半个屏幕；「缓存近邻把更远一页拉进窗口」：名额被缓存页占住 |
| `throttle.json`（13 例，含 2 阶段） | 本地写永远立即、上传只在节拍上且过间隔、显式动作与退出/后台立刻冲、`page 0` 钳到 1、读完 ≠ 标已读、倒退是合法变更、杀掉进程后重开补送 | 「每页一个 PATCH」；「统一 max(page)」（Stage 6 已禁）；「Mark Read 顺手把本地页码也发上去」 |

## 阅读模式与方向

| 项 | 位置 | 状态 |
| --- | --- | --- |
| 单页 / 双页 / 条漫的配对（含 firstPageSingle、末尾落单页、无法配对页） | Rust `reader/paging.rs::pair`；Swift `KomgaReader/Paging` | ✅ 契约 17 例双端 |
| LTR / RTL / Vertical → 轴 + 是否镜像 | `paging.rs::axis_for` / `layout` | ✅ |
| 屏幕上的先后（`visualLeftToRight`） | `Layout::visual` | ✅ |
| 手势与点按半区（`advanceSwipe` / `tapNext`） | `Layout::nav` → Android `reader_screen.dart` `_handleTap` | ✅ |
| 尺寸未知的页不参与配对 | `manifest.rs::unpairable` → `pair` | ✅ |
| EPUB / PDF 不进图像阅读器 | `PageManifest::is_paged` / `writes_page_progress` | ✅（Stage 6 R8 在清单层的落实） |

## 阅读设置

| 设置 | 存储 | 位置 | 状态 |
| --- | --- | --- | --- |
| 阅读方向 | `app_state!reader_settings` | `reader/settings.rs`；Android `ReaderScreen` 方向 chips | ✅ |
| 页间距（0..=64 逻辑像素，钳制） | 同上 | 同上（滑块） | ✅ |
| 背景（黑/灰/白） | 同上 | 同上 | ✅ |
| 屏幕常亮 | 同上 | Android 平台通道 `comic/reader!setKeepScreenAwake`（`MainActivity.kt`） | ✅ |
| 基础亮度（0.05..=1.0，null=交还系统） | **不落库**（关书即复位） | `comic/reader!setBrightness` | ✅ |
| 阅读位置恢复（开关） | `app_state` | `settings.restore_position` + `reader_position` 表 | ✅ |
| 预取窗口（前向 / 后向 / 上限） | `app_state` | `prefetch::Window`，默认 2/1/12 | ✅ 数值留给性能阶段调 |

方向优先级：**上一本书记住的 > 服务器 series 元数据推荐 > 全局默认**
（`resolve_direction`，`settings.rs` 有独立单测）。漫画第一次打开就右起，不需要用户设置。

## 页面加载管线

```text
Reader(UI) → ReaderLoader → 清单镜像(book_pages) → 页缓存(cache_entries → cache/pages/<key>.<ext>) → 本地文件 → 解码/渲染
```

| 约束 | 实现 | 证据 |
| --- | --- | --- |
| UI 里没有网络请求，也没有 URL/路径拼装 | `ffi::bridge::reader_page*` 只回本地路径；Dart 侧 `ReaderApi` | `reader/mod.rs` 分层规则；`reader_api.dart` 文档 |
| 清单先镜像后使用：开过的书离线也能开 | `store/pages.rs::replace/list`，`ReaderLoader::open` 优先读镜像 | `stage7_smoke --phase reopen`：页日志行数**一字不动** |
| 命中 = 记录在 + 文件在 + 文件完整 | `reader/cache.rs::lookup`；写盘用 `.part` + rename | `store/cache.rs` 与 `reader/cache.rs` 单测（含"文件被删→记账收敛"） |
| 扩展名跟着**响应** Content-Type | `manifest.rs::extension_for_content_type` | 单测 + 契约 `contentTypes` 表逐行断言 |
| 缓存记账用落盘真实字节 | `cache/store` 取 `fs::metadata` | 单测断言记账 == 实际大小 |
| LRU 按预算淘汰，**永不**删离线下载 | `store/cache.rs::evict_to_budget`（kind != download，`last_access`+key 定序） | 单测：预算 0 也动不了 download 行 |
| 相邻页预取（当前 + 前向 + 后向） | `reader/prefetch.rs::plan` + `ReaderLoader::prefetch`；`reader_prefetch` FFI | `stage7_smoke --phase prefetch`：暖窗前 8 页全落盘，二次遍历零请求 |

## 阅读进度

```text
Reader → ReaderSession.turn_to → reader_position + read_progress + pending_mutations（同一调用内） → Upload::Now? → sync::upload::upload_outbox
```

| 规则 | 位置 | 状态 |
| --- | --- | --- |
| 本地写永远立即（节流只管网络，不管持久性） | `reader/session.rs::persist` + `store/read_progress.rs` | ✅ |
| 同族合并：一本书最多一行待上传 | Stage 6 `outbox::coalesce` | ✅ 30 页突发 1 行 1 请求 |
| 间隔判定只在节拍上发生（`UPLOAD_INTERVAL_MS = 5000`） | `reader/throttle.rs::due` + `session::tick`；节拍器在 `reader_controller.dart` | ✅ |
| 普通阅读进度 / Mark Read / Mark Unread 三者各走各的 | `Intent::{Progress,MarkRead,MarkUnread}` → `request_for` | ✅ 服务器日志：2 个带 page 的 PATCH、1 个只带 completed 的 PATCH、1 个 DELETE |
| Mark Read 不改写页码（线上与本地一致） | `request_for`（省 page）+ **本阶段修复**：`local_mutation` 的 `page = COALESCE(excluded.page, read_progress.page)` | ✅ Stage 6 的本地镜像此前会被标已读清空页码，现已与线上语义对齐 |
| `page 0` 永不外发 | `throttle::record_page` 钳到 1；`request_for` 再兜一层（R7） | ✅ |
| 翻到末页 = `completed=true` 的进度写，不是 MARK_READ | `record_page` | ✅ 线上两种 body 可区分 |
| 回翻是合法变更（新动作优先） | 契约 T7 + Stage 6 冲突规则 | ✅ |
| EPUB/PDF 不进这条流 | `writes_page_progress=false` 时 session 只写 `reader_position` | ✅ 单测断言 `read_progress` 无行、outbox 空 |

## 验收：`bash scripts/e2e_stage7.sh`

1. **回环真 HTTP**（总是跑）：`komga_fixture_server` 长出两个读端点
   （`/pages` 清单、`/pages/{n}` 图像），图像是**宽度编码页码**的确定性 PNG —— 于是
   「第 N 页真的是第 N 页」可以从磁盘字节验，而不是靠约定；每次页读取写进
   `--page-journal`，脚本用它的**增量**证明重开与离线时一个字都没问服务器。
   | 阶段 | 验收标准 | 实测 |
   | --- | --- | --- |
   | `open` | 正常打开漫画 | ✅ 24 页镜像 + 65218 字节落盘 + IHDR 宽 == 64+N |
   | `modes` | 单页 / 双页 / 条漫 × LTR / RTL / Vertical | ✅ 9 种版式逐一断言分区、轴、镜像、手势 |
   | `flip` | 快速翻页 | ✅ 23 次翻页 → 1 行队列 → **1 个**写请求 |
   | `reopen` | 重启后恢复位置 | ✅ 新进程恢复页 24 与双页 RTL 版式，页日志 0 增长 |
   | `offline` | 断网后继续阅读已缓存页面 | ✅ 缓存在页照常渲染，未缓存页只报单页网络错误，位置与队列仍落库 |
   | `prefetch` | 相邻页预取 | ✅ 暖窗前 8 页已在盘，二次遍历 0 请求 |
   | `sync` | 阅读状态最终同步 Komga | ✅ 三种动作各自送达，服务器状态读回核对 |
   另测：`page 0` 与 `page N+1` 必须 404（不给钳到末端的图）；两个读端点未认证一律 401。
2. **共享契约**：Rust `reader/*::contract_tests` 54 例（`cargo test --lib reader::`）。
3. **Swift 同一批文件**（`swift build && swift test`，138 例全绿）：
   `apple/KomgaKit/Tests/KomgaKitTests/ReaderContractTests.swift` 逐字段断言同一个
   `paging/manifest/prefetch/throttle.json`。**改动契约后两端同时失败**已实测：
   把 `spreadCount` 250 改成 249、把预取队列次序换成 `[5,6,7,8,4,3]` 之后，
   Rust 与 Swift 各自报出同名用例失败（不是某一侧独自变松）。
4. **真机（可选，需 Key）**：`KOMGA_BASE_URL=... KOMGA_API_KEY=... bash scripts/e2e_stage7.sh`
   → `--phase live-reader`：真实书的 `media.pagesCount` 与清单页数必须吻合，清单声明的宽高
   必须等于实际像素（PNG/JPEG 头解析），翻页写进去后再把原状态还原（数据保全）。

## 已修掉的既有缺陷（顺带发现，非本阶段范围但影响验收链）

- **回环服务器的路由遮蔽**：Stage 6 加 `GET /api/v1/books/{id}` 时把该模式放在
  `/api/v1/books/ondeck` 之前，于是 ondeck 被当成「id 为 ondeck 的书」→ 404，
  **Stage 5 的回环验收自那时起一直是断的**。现字面路径优先，`e2e_stage5.sh` 恢复
  11/11 PASS（含 Swift 侧同契约）。用 `git worktree` 在干净 HEAD 上复现，确认不是 Stage 7 引入。

## 尚未验证 / 已知限制

- **真机那一页还没翻过**：`--phase live-reader` 需要 `KOMGA_API_KEY`（凭据只在用户手上）。
  跑法见上面第 4 条；跑完把结论写回本文件。
- **`zero_based` 只验了客户端**：回环服务器照 Komga 语义处理缺省（1 起），同时把
  「这次请求有没有显式带 `zero_based=false`」记进日志并断言全带。真实 Komga 若改了缺省，
  这条断言仍成立，但真实服务器的行为要靠真机腿补。
- **prefetch 的 `forward/back/cap` 是占位值**（2/1/12）。阶段要求把数量留到性能测试阶段调，
  所以它们做成数据（`app_state` 里的 `Window`）而不是代码常量；契约用例里的数字同样是占位。
- **Apple 侧的屏幕常亮/亮度只在 iOS 生效**（`UIApplication.isIdleTimerDisabled` /
  `UIScreen.brightness`）；macOS 没有 per-app 亮度接口，滑块在 mac 上是空操作。
  页与跨页的**渲染**在两端都验过编译，但没有在真机/模拟器上手点过（无设备）。
- **解码仍在平台侧**：核心只交本地文件路径，PNG/JPEG 解码与内存缓存由
  Flutter（`Image.file` + `cacheWidth` 降采样）/ SwiftUI 负责。条漫列用的是虚拟化列表，
  但「500 页 4K 图连续快翻」的帧率与内存曲线属性能阶段，本阶段没有测。
- **`cache_entries` 预算固定 512 MB**（`reader/cache.rs::DEFAULT_BUDGET_BYTES`），
  暂不随磁盘剩余空间自适应；下载（Stage 4 的 `downloads`/`download_pages` 表）本阶段不写，
  所以 LRU 的「不删下载」目前只有单测证据，没有端到端证据。
- **Android 侧亮度/常亮经平台通道**，无新增 pub 依赖；通道不可用时静默降级
  （`ReaderSystemControls.supported`），因此 host 测试与桌面运行不会因此失败。
- **原生库已随本次接口重编**（`cargo ndk --features frb`：arm64-v8a / armeabi-v7a / x86_64 三个
  `libkomga_core.so` 全部更新，含 `reader_*` 导出），否则设备上会拿到旧库、`reader_*` 直接找不到符号。
  FRB 绑定也已重新生成（`lib/src/rust/**` + `src/ffi/generated/frb_generated.rs`），
  `cargo build --features frb` 通过。
- **Android APK 没在这台机器上链接过**：Gradle 需要 JDK 11+，本机 `java_home` 只能解析到
  Applet Plugin 的 JRE，`flutter build apk --debug` 因此失败（与代码无关）。
  受此影响，**`MainActivity.kt` 里新增的 `comic/reader` 通道（常亮 / 亮度）未经编译验证**；
  Dart 侧靠 `flutter analyze` + `flutter test`（49 例全绿）覆盖。
- **模块依赖图**：Swift 侧最初用 `@_exported import KomgaSync` 复用 Stage 6 的线上格式，
  但 `Package.swift` 里 `KomgaReader` 并未声明该依赖 —— `swift build`（命中缓存）没察觉，
  `xcodebuild` 的依赖扫描立刻报 `Unable to resolve module dependency`。现已把
  `KomgaSync` 声明为 `KomgaReader` 的依赖（`KomgaSync` 只引用 Foundation/KomgaAPI/KomgaStore，
  图仍是 DAG），**ComicApp_iOS（iphonesimulator）与 ComicApp_macOS 两个 scheme 均 BUILD SUCCEEDED**。
  教训：SPM 缓存下的 `swift build` 不能代替一次干净构建。
