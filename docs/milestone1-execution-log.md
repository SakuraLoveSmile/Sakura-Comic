# Android 第一里程碑 · 执行记录

只记录**实际执行过**的命令、结果与未验证范围。计划本身见会话中的
《Comic Android 第一里程碑：日常阅读体验成型执行计划》；本文件不重复它。

---

## P0 · 实施基线（对应 Kaneo #8）

### 环境与工具链（实测）

| 项 | 结果 |
|---|---|
| 仓库 | `/Users/sakurasep/Documents/Code/Project/Personal Project/Comic`，分支 `main`，跟踪 `origin/main` |
| 工作区 | **65 个文件已修改 / 若干未跟踪文件**（用户既有改动，未清理、未回退、未计入本次成果） |
| Flutter | 3.41.3（Dart 3.11.1），`/Users/sakurasep/flutter/bin` |
| Rust | cargo 1.98.0 / rustc 1.98.0；cargo-ndk 4.1.2 |
| Android SDK | `$HOME/Library/Android/sdk`，NDK 28.2.13676358，targetSdk 36 / minSdk 24 |
| JDK | 系统默认 JDK 是 1.8（**不能**构建 Android）；构建需 `JAVA_HOME=/opt/homebrew/opt/openjdk@17` |
| 设备 | `emulator-5554`（sdk_gphone64_arm64，arm64-v8a，1080×2400 @420dpi，SDK 35）。**没有一加 Ace 5** |
| AGENTS.md | 仓库内**不存在**（计划要求阅读，实际没有该文件） |
| Kaneo 访问 | 本会话没有 Kaneo 工具；`~/.config/kaneo-mcp` 的 tRPC 探测返回 404，任务 #1–#9 状态**未核实** |

### 缺项修复（环境问题，不是代码问题）

- `android/app/.dart_tool/` 不存在，导致 `flutter analyze --no-pub` 报 6947 条
  `Target of URI doesn't exist: package:flutter/...`。执行 `flutter pub get`
  后恢复：`flutter analyze --no-pub` → **No issues found**。
  结论：本机必须先 `pub get`，否则 `--no-pub` 的结论完全不可信。

### 基线检查结果

| 命令 | 结果 |
|---|---|
| `flutter analyze --no-pub` | PASS（No issues found） |
| `flutter test --no-pub test/reader_test.dart test/media_library_test.dart test/downloads_test.dart test/settings_and_diagnostics_test.dart` | PASS（49 项） |
| `flutter test --no-pub`（全量） | PASS（**129** 项） |
| `cargo fmt --check` | PASS |
| `cargo test store::position` | PASS（2 项） |
| `cargo test --lib store::` | PASS（92 项，含 v8→v9 迁移三项：`open_in_memory_migrates`、`a_v8_download_row_survives_the_v9_migration_untouched`、`a_migrated_v8_download_table_has_the_fresh_shape`） |
| `cargo test --lib reader` | PASS（105 项） |
| `cargo clippy --all-targets -- -D warnings` | PASS |

**注意**：计划第五节写的 `cargo test store::schema` 在本仓库**匹配不到任何测试**
（schema 迁移测试在 `src/store/mod.rs` 的 `mod tests` 里，名字不含 `schema`）。
真实有效的过滤是 `cargo test --lib store::`。第一次执行时因为管道吃掉了退出码，
`exit=0` 是 `tail` 的退出码而不是 cargo 的，已重跑并单独记录退出码。

### 基线截图（模拟器，旧构建）

`/tmp/p0_shots/01_shelf_first_run.png` — 首次启动的书架（FFI 已连接，
`db=/data/user/0/dev.sakurasep.comic/app_flutter/comic.sqlite`），深色、空态。

### 未验证（BLOCKED）

- 一加 Ace 5 上的首次开书/翻页/缩放/后台恢复/下载耗时：**BLOCKED**（无该设备）。
- 真实 Komga 服务器验收：**BLOCKED**（本会话未使用真实凭据与专用验收漫画）。
- profile 构建的帧耗时 p50/p95、超帧比例、内存变化：**BLOCKED**（需要真机）。

---

## P1 · Flutter 可交互原型（对应 #1、#2、#3、#5、#7、#9）

### 新增文件

| 文件 | 职责 |
|---|---|
| `android/app/lib/main_preview.dart` | 预览入口；release 模式拒绝启动；强制竖屏；不初始化 Rust core / 数据库 / 凭据 / 网络 |
| `android/app/lib/src/preview/theme.dart` | 设计令牌（间距 8/12/16/24、48×48 触控区、2:3 封面框、黑/灰/白纸张）与 `comicTheme()` |
| `android/app/lib/src/preview/models.dart` | 原型视图模型：`PreviewSeries` / `PreviewBook` / `ReadIntent` / `CatalogCompleteness` / `DownloadState` / 统一排序 `compareBooks` |
| `android/app/lib/src/preview/preview_data.dart` | 内存数据：12 个系列，覆盖在读/未读/全读/空系列/重复序号/NULL 序号/镜像不完整；6 条下载覆盖五种状态 |
| `android/app/lib/src/preview/components.dart` | 共享组件：封面、状态面、banner、状态 chip、分区标题、绘制页、`ReaderViewState`、定高网格委托 |
| `android/app/lib/src/preview/shelf_toolbar.dart` | 书架工具区：搜索 / 筛选 / 排序（有状态，控制器不随 rebuild 重建） |
| `android/app/lib/src/preview/shelf_screen.dart` | 书架：继续阅读窄轨、工具区、大封面网格、五种异常状态 |
| `android/app/lib/src/preview/series_detail_screen.dart` | 系列详情：元数据、主按钮四态、册列表与下载状态、只看已下载 |
| `android/app/lib/src/preview/reader_screen.dart` | 阅读器：显隐工具栏、单击/双击/拖动、缩放 1–4×、单页/双页/条漫、下一册面板、逐页失败重试、音量键 |
| `android/app/lib/src/preview/downloads_screen.dart` | 下载：空/排队/进行中/暂停/失败/完成、单册忙碌态、删除确认、存储卡片 |
| `android/app/lib/src/preview/settings_screen.dart` | 设置：服务器、外观（深色+竖屏）、全局阅读默认值、系统栏/音量键、系列覆盖、密度、同步与存储 |
| `android/app/lib/src/preview/list_screens.dart` | 合集 / 书单 / 服务器切换（页面状态保留） |
| `android/app/lib/src/preview/preview_app.dart` | 原型外壳：四入口底部导航、`IndexedStack` 保留页面状态、统一阅读入口、审阅工具条 |
| `android/app/test/preview_test.dart` | 原型结构测试：360/393/412 × 文字 1.0/1.3/2.0 无溢出；主按钮四态；排序规则；下一册证明；下载摘要；中心单击不翻页 |

### 布局验证（自动化）

`flutter test --no-pub test/preview_test.dart` → **21 项全部通过**，覆盖：

- 书架在 360/393/412 × 1.0/1.3/2.0 共 9 组尺寸下挂载，**没有任何 RenderFlex 溢出**；
- 系列详情（393/1.3）、下载（412/2.0）、阅读器（单页/双页/条漫，393/1.0）挂载；
- 整壳（四入口底部导航）挂载；
- `main_preview.dart` 确实带有 `if (kReleaseMode)` 拒绝逻辑。

排查过程中修掉的三类真实布局问题（都是"文字放大就崩"）：

1. 系列卡片原先用固定 `childAspectRatio: 0.52`，文字 2.0 时溢出 65px
   → 改为 `GridViewExtentDelegate`，卡片高度由 `seriesCardHeight()` 用**真实
   TextStyle + MediaQuery.textScaler** 量出来（封面 2:3 + 文字实际行数）。
2. 继续阅读窄轨原先固定 104px 高（实际需要 ~181px，本身就在溢出）
   → 改为 `IntrinsicHeight` + 水平 `SingleChildScrollView`，高度完全由最高的那张卡决定。
3. 状态 chip / 存储键值行 / 审阅工具条在 2.0 文字下横向溢出
   → 分别加 `Flexible` + 省略号、把审阅工具条改成可横向滚动。

同时修掉一个**测试自身的错误**：早期测试把 `comicTheme(textScale:)` 和
`MediaQuery.textScaler` 同时设成 1.3/2.0，等于把文字放大了两次，造出真实设备上
不会出现的溢出。现在测试只设 `MediaQuery.textScaler`（系统真实做法）。

### 真机（模拟器）验证

- 构建：`flutter build apk --debug -t lib/main_preview.dart` → OK；
  正式入口 `flutter build apk --debug` → OK。
- `flutter run -t lib/main_preview.dart -d emulator-5554` 启动成功，
  VM service `ext.flutter.debugDumpApp` 确认渲染树是 `PreviewRoot → PreviewApp`。
- 截图（`/tmp/p1_shots/`）：`20_shelf.png`、`21_downloads.png`、`30_detail.png`、
  `31_reader.png`（工具栏隐藏，中部为页面）、`32_reader_toolbar.png`（中心单击后
  工具栏出现：顶部/底部深色带内出现浅色像素）。
- 全程 logcat **没有** Flutter 异常、RenderFlex 溢出或 error 级日志。

### 原型默认参数（待用户确认）

- 深灰底 `#121215` + 分层表面 `#17171B / #1C1C21 / #232329 / #2A2A31`，靛色强调（沿用现有 seed）。
- 间距 8 / 12 / 16 / 24；主触控区 ≥ 48；圆角卡片 12、面板 16、chip 全圆。
- 大封面 2:3 定框，标题在封面下方，最多两行；卡片另有两行：`已读 X/Y 册` + 下载摘要。
- 新安装默认「舒适」密度（maxCrossAxisExtent 144 / 间距 12）；紧凑 112/8、宽松 184/16。
- 阅读默认：单页 · 左→右 · 完整显示不裁切；音量键**默认关闭**。
- 继续阅读窄轨：卡片宽 208，封面 56 宽 + 概要两行 + 进度条。

---

## P2 · 本地查询与阅读偏好（已完成并验证；位置存储由 v10 承接，见 P4）

### 已完成：`series_read_target` / `next_book_in_series`

`android/komga_core/src/store/query.rs` 新增一段「统一阅读入口」的纯查询：

| 名称 | 作用 |
|---|---|
| `ReadIntent` | `continue` / `start` / `reread` / `empty` —— 同一个按钮上的四种文案 |
| `ReadTarget` | 该打开哪一本 + 它在系列里的位置 + 为什么是它 |
| `OrderedBooks` | 系列顺序 + `book_count` + `complete`（本地目录是否完整） |
| `series_read_target` | ①最新未读完 ②第一本未读 ③全读完则第一本 ④无可读 → `None` |
| `next_book_in_series` | 系列顺序里的下一本；目录不完整时返回 `None` |
| `ordered_books` | 排序规则落在一处：有编号在前、`number_sort` 升序、标题不区分大小写、`remote_id` 兜底 |

设计上的两个决定：

- **目录不完整就不给"下一册"。** 服务器说 5 本、本地只有 2 本时，"最后镜像的一本"
  并不是"最后一本"，此时提供下一册就是在提供一个可能不存在的书。UI 文案对应
  「本地目录尚未完整同步」。
- **`series_read_target` 是唯一入口。** 书架和系列详情调同一个函数，两处不可能给出
  不同的"继续阅读"目标。

10 个新测试，含：排序边界（NULL 序号 / 同序号大小写 / remote_id 兜底）、
镜像不完整不提供下一册、全读完 → 重新阅读、空系列、跨服务器隔离、
以及"第一本未读"而不是"第一行"。

### 已完成：`volumeKeysEnabled` + 每系列覆盖

- `reader/settings.rs`：`ReaderSettings` 增加 `volume_keys_enabled`，**默认 false**。
  测试钉住两件事：默认是关的；**旧版本写下的 JSON 文档（没有这个字段）读出来仍然是关的**——
  升级不能替用户同意"占用音量键"。
- `android/komga_core/src/reader/series_override.rs`（新文件）：每系列覆盖。
  `app_state` 一行一个被覆盖的系列，键是 `reader_override:["serverId","seriesId"]`
  （JSON 数组而不是 `|` 拼接——id 里迟早出现分隔符，有专门测试钉这一点）。
  `resolve_for_series(全局, 覆盖)` 是两级规则的唯一实现，且**返回副本、不改全局**。

9 个新测试，含：残留的旧覆盖不影响别的系列、半覆盖（只改方向不改模式）、
条漫覆盖自动清掉 `first_page_single`、损坏的行退回全局而不是让阅读器打不开、
`list_overrides` 只返回本服务器的系列、**"打开一本书不会写全局偏好"**。

### 已完成：FFI 绑定同步

`ReaderSettingsDto` 加了字段 ⇒ **两端必须同时更新**：Dart 侧解码从 11 个字段变成 12 个，
旧的原生库遇到新 Dart 会在解码时抛异常。已重新生成绑定（3 个生成文件，共 +19/−5 行），
并重建 arm64 的 `libkomga_core.so`。

### 验证

| 命令 | 结果 |
|---|---|
| `cargo fmt --check` | exit 0 |
| `cargo test --lib` | **408 passed**（本轮新增 19 个：query 10 + series_override 9；settings 2） |
| `cargo clippy --all-targets -- -D warnings` | exit 0 |
| `cargo ndk -t arm64-v8a check --features frb` | exit 0 |
| `bash scripts/check_frb_drift.sh` | 「FRB bindings in sync」 |
| `flutter analyze --no-pub` | No issues found |
| `flutter test --no-pub` | **129 项通过**（其中原型 21 项） |
| `cargo ndk -t arm64-v8a build --release --features frb` | 见下方"未完成" |

### 未完成（因为要等你确认）

- **`reader_position.page_offset_ratio`（条漫页内偏移）没有做。** 它需要 v9 → v10 迁移，
  提案在 `specs/contracts/v10-migration/README.md`，等你确认。
- **新的查询与偏好还没有接到 FFI 与 UI 上。** 接 FFI 要把 `ReaderBookDto` 的
  模式/方向来源改掉（`session.rs:102-109` 现在是"本书记住的优先"），
  那属于 P3/P4 的接线，不是 P2 的存储层。
- 两个新查询目前**只有单测覆盖**，没有在真实库上跑过。

## P3 · 统一阅读入口（进行中：目标查询已通到生产 UI）

### 已完成并验证

`series_read_target` 现在是**一条从 SQLite 到按钮的完整链路**，不再是"只有单测的查询"：

| 层 | 文件 | 内容 |
|---|---|---|
| 查询 | `android/komga_core/src/store/query.rs` | 新增 `ReadTargetRow`（book/intent/position/book_count/complete）与 `series_read_target_row()`；空系列也返回一行 `intent="empty"`，而不是 `None` —— UI 需要"这个系列没有册"这个答案，而不是再判断一种空形状 |
| FFI | `android/komga_core/src/ffi/application.rs`、`ffi/bridge.rs` | `App::series_read_target` + `series_read_target(db_path, server_id, series_id)` |
| 绑定 | `lib/src/rust/**`（codegen 产物，未手改） | `ReadTargetRow`、`seriesReadTarget` |
| API | `lib/src/rust_core_api.dart`、`rust_core_frb.dart` | 抽象默认返回 `null`（核心答不上来时不编一个目标） |
| 仓储 | `lib/src/library_repository.dart` | `LibraryRepository.readTarget`；`RustLibraryRepository` 接真实现 |
| 模型 | `lib/src/models.dart` | `ReadIntent`（四态 + 未知值降级为 empty）、`ReadTarget` |
| UI | `lib/src/series_detail.dart` | `_readAction`：主按钮文案、副行、打开哪一册全部来自同一个核心答案；目录不完整时显式说明 |

### 命令与结果

| 命令 | 结果 |
|---|---|
| `cargo test --lib` | 410 passed（新增 `the_ffi_row_carries_the_completeness_answer_even_with_no_target`） |
| `cargo clippy --all-targets -- -D warnings` | exit 0 |
| `cargo fmt --check` | exit 0 |
| `bash scripts/check_frb_drift.sh` | FRB bindings in sync |
| `flutter analyze --no-pub` | No issues found |
| `flutter test --no-pub` | 133 passed（新增 5 项：四态文案 + 打开目标册 + 目录不完整提示 + 无答案时不显示按钮） |
| `flutter build apk --debug` + `adb install -r` | Success |
| 设备启动日志 | `[RustCore] FFI connected (libkomga_core loaded)` —— 新符号在真机 ABI 上加载成功、哈希校验通过 |

### 一个必须记下来的构建陷阱

`cargo ndk -t arm64-v8a build --release --features frb` **没有把新的 `.so` 覆盖到
`app/android/app/src/main/jniLibs/`**：APK 里打进去的是旧库，运行时 FRB 抛
`Content hash on Dart side (-277530366) is different from Rust side (1517323386)`，
debug 下静默回落到 Stub 仓储（屏幕照常渲染，只是没有数据）。

判断方法（可复用）：`strings -a <so> | grep series_read_target` —— 旧库为 0，新库为 1。
拿到新库后必须**手动 copy 到 jniLibs 再重新 build APK**。

### 同时修掉的 P1 问题

原型的主按钮只检查"有没有读到一半的册"，于是 BLAME！（第 1、2 卷已读完）显示
「开始阅读」+「从第 3 卷开始」——自相矛盾，且与核心判定不一致。已改为与
`series_read_target` 相同的判定顺序，并补 4 项测试。

### 未验证范围（重要）

- **`readTarget` 到 UI 的端到端从未在设备上跑过。** 唯一一次设备验证只到
  "原生库加载成功"，Dart 侧的 `seriesReadTarget` 调用没有真正执行过。
  好在它是纯本地查询、无网络、无凭据依赖，剩余风险主要在解码器；
  Rust 结构体 5 个字段与 Dart 解码器 `arr.length != 5` 已逐字对齐核对。
- **模拟器在 03:06 之后不可用**：`emulator-5554` 的 QEMU 主循环与 CPU0 线程挂死
  （`detected a hanging thread 'QEMU2 main loop'`），冷启动、关 Vulkan、清快照、
  软件 GPU 四种方式重启均复现。**在此之前的白屏不能归因于本次改动**，
  白屏时段设备 `Total frames rendered: 1`，是模拟器渲染层的问题。

## P4 · 条漫定位与两级模型（已实施并验证）

### 用户裁定（2026-09-11）

| 决定 | 选择 |
|---|---|
| 历史 `reader_position.mode/direction` | 列保留、继续写、打开时不再读它做决策 |
| 阅读器内切换写到哪里 | 当前系列的覆盖（`reader_override:[serverId,seriesId]`） |
| 迁移前是否备份 | 本次不备份（纯加列，失败只让某本书回到页首） |
| 补 `docs/database-schema.md` | 授权，一并补齐 |
| 设备验证 | 用户明确表示**不作为阻塞项** |

### 已完成

- **v10 迁移**：`SCHEMA_VERSION = 10`、`V10_ALTER_STATEMENTS`（单条可空列）、
  `position::save_with_offset`（比例夹紧 0..1）、`Position.page_offset_ratio`。
- **两级模型真正生效**：`ffi/application.rs::reader_open` 不再读本书记住的模式/方向，
  改为 `series_override::resolve_for_series(全局, 本系列)`；UI 显式传入的模式/方向
  仍然赢（那是"用户刚改的"到达打开路径的方式）。
- **阅读器内切换不再污染全局**：`reader_controller` 删掉了 `_persistSettings`
  （它把单本操作写回全局 `reader_settings`，就是"按一下双页，B 书也变双页"的根），
  改为回调 `onSeriesLayoutChanged`；`SeriesDetailScreen` 负责落库并提示
  "已把此系列设为双页・左→右"。
- **偏移随下一次 persist 落库**，不在滚动时写：滚动是连续上报，每帧过一遍
  SQLite 会把整行位置写穿。

### 命令与结果

| 命令 | 结果 |
|---|---|
| `cargo test --lib` | 416 passed（+2 迁移、+2 位置、+2 FFI 两级模型） |
| `cargo clippy --all-targets -- -D warnings` | exit 0 |
| `cargo fmt --check` | exit 0 |
| `bash scripts/check_frb_drift.sh` | FRB bindings in sync |
| `flutter analyze --no-pub` | No issues found |
| `flutter test --no-pub` | 140 passed（+2：切换只改系列 / 全局仍可单独改） |
| `bash scripts/verify.sh --skip-swift` | **ALL GREEN** |
| `cargo ndk ... build --release --features frb` + 手动同步 jniLibs | 完成，`strings` 校验新符号在位 |
| `flutter build apk --debug` | ✓ Built（203,699,806 bytes） |

### 测试当场抓到的两个真问题

1. **列序分叉**：新列写进 `CREATE_STATEMENTS` 时放在 `updated_at` 之前，
   而受保护的 `ALTER` 只能追加到最后 —— 两条路径的 `pragma_table_info` 不同。
   `a_migrated_v9_reader_position_has_the_fresh_shape` 直接失败，已统一到 `updated_at` 之后。
2. **恢复页码误会**：保存第 3 页 + 单页模式，恢复出来是第 2 页 —— 因为那一行记的是
   双页跨页，"第 3 页"在该布局里是跨页的第二张。测试断言按真实布局语义修正，
   而不是去改代码迎合断言。

### 未验证范围

- **仍未在设备上跑过。** 模拟器 03:06 起 QEMU 主循环挂死，四种重启方式均复现；
  用户已确认设备验证不作为本阶段阻塞项。APK 已构建待装。
- **条漫偏移还没被 UI 消费**：`ReaderBookDto.startPageOffsetRatio` 已经跨过 FFI
  （解码器 10 个字段与结构体逐字对齐），但阅读器画面还没有把它用在滚动恢复上，
  也还没有把滚动比例回报给 `reader_set_page_offset`。核心与 FFI 这一段是有测试的，
  UI 那一段没有。

## P5 · 条漫页内定位接通（已实施并验证）

### 三层各自负责什么

| 层 | 职责 | 测试 |
|---|---|---|
| `reader_offset.dart` | 纯几何：视口 → (页, 比例)，比例 → 滚动偏移 | `reader_offset_test.dart` 10 例 |
| `reader_controller` | 策略：节流、去抖、换页清空、关书 flush | `reader_test.dart` 6 例 |
| `reader_screen` | 接线：滚动通知 → 测量 → 上报；打开 → 恢复 | 由上面两层覆盖（见下） |

几何被**抽成纯函数**而不是留在 widget 里，是因为它要能在真实数字上验：
widget 测试里 `Image.file` 解不出高度，渲染盒全是 0，量不到任何东西。
抽出来之后，这个函数同时是画面调用的那一个，测的就是上线的那份。

### 测试逐条钉住的语义

- **页首报 `null`，不是 `0.0`** —— 数据库里"没记录"和"在页首"是两个断言。
- **已经离开的那一页不再报位置** —— 边界模糊到最多一个 margin 宽，
  两页会短暂各说各话。如果前一页硬报 `1.0`、后一页报 `0.02`，
  存下来的位置会在每次交接时往回跳。
- **过冲回弹的越界值夹紧**，不拒绝：页面仍然值得记录。
- **换页清空**，且清空的是**库里那一行**，不只是内存 —— 否则第 41 页会顶着第 40 页的"60%"打开。
- **关书那一次必须绕过节流** —— 这正是"读到一半关掉"能成立的那一次写。

### 途中发现并修掉的两个真 bug

1. **关书顺序反了。** `ReaderController.dispose()` 先置 `_isClosed = true`，
   flush 到那里直接短路返回，而 `api.close()` 紧随其后把 session 落库 ——
   等于用两秒前的位置覆盖刚滚到的位置。现在 flush 的 future 被存下来，
   关库之前先 await 它。注释写明了为什么顺序不能换。
2. **页码变化没有清偏移。** FFI 测试先红：`turn_to(3)` 之后重新打开，
   页码是 3 而比例还是 `Some(0.62)`。修在 `ReaderSession::turn_to` 里，
   而不是"让 UI 记得清" —— 换页的调用方可能来自任何语言，
   规则要落在规则的拥有者身上。

### 一个测试自身的坑

`readers()` 是**进程级全局**注册表，而 `mod tests` 里别的测试也在用 `("s1","b1")`。
单跑绿、全量跑红。两个新 FFI 测试改成独占 key 之后稳定。

### 命令与结果

| 命令 | 结果 |
|---|---|
| `cargo test --lib` | 419 passed |
| `cargo clippy --all-targets -- -D warnings` | exit 0 |
| `cargo fmt --check` | exit 0 |
| `check_frb_drift.sh` | in sync |
| `flutter analyze --no-pub` | No issues found |
| `flutter test --no-pub` | 156 passed |
| `scripts/verify.sh --skip-swift` | **ALL GREEN** |
| `cargo ndk ... --features frb` + jniLibs 同步 | 符号校验通过 |
| `flutter build apk --debug` | ✓ Built（203,699,806 bytes） |

### 仍未验证

- **仍未在设备上跑过**（模拟器 QEMU 挂死，用户已列为非阻塞）。
  滚动一个真实条漫、杀进程、重开是否回到原处 —— 这条只有真机能证。
- widget 层没有端到端断言：`Image.file` 在 widget 测试里解不出高度。
  这是**已知的测试能力缺口**，不是"已验证"。

## 尚未开始

- P6：未开始。

## 视觉规格已确认（用户裁定）

用户裁定：**视觉效果按原型截图为准**。因此 `android/app/lib/src/preview/` 这一套
就是本里程碑的视觉与交互基准，生产实现照它对齐，不再重新设计。

实现时必须对齐的既有数值（直接取自 `preview/theme.dart`，不要另起一套）：

| 令牌 | 值 |
|---|---|
| 背景 / 表面 | scaffold `#121215`、surfaceContainer `#1C1C21`、强调色沿用 indigo seed |
| 间距 | 8 / 12 / 16 / 24；主触控区 ≥ 48 |
| 圆角 | 卡片 12、面板 16、chip 全圆 |
| 封面 | 2:3 定框，标题在封面下，最多两行 |
| 网格密度 | 舒适（默认）144 / 12；紧凑 112 / 8；宽松 184 / 16 |
| 继续阅读卡片 | 宽 208，封面 56，两行概要 + 进度条 |
| 阅读纸张 | 黑 `#0B0B0D` / 灰 `#3A3A3E` / 白 `#F5F5F5` |

一个必须一起带过去的**行为**（截图里看不出来，但同一份裁定的一部分）：
主按钮文案由「继续阅读 / 开始阅读 / 重新阅读 / 没有册」四态决定，判定顺序与
`store::query::series_read_target` 完全一致 —— **系列没读完但已有读完的册，仍算"继续阅读"**。
原型最初漏了这一条，截图里表现为「开始阅读」+「从第 3 卷开始」自相矛盾，已修（见下方 P1 修正）。

## 仍然待确认

**没有。** v10 的三个决定已由用户裁定并在 P4 实施完毕
（见上方"用户裁定"表）；`specs/contracts/v10-migration/README.md` 保留为提案存档。

下一件需要人拍板的事是 P5/P6 的验收方式：设备验证已被用户明确列为非阻塞项，
所以 P5–P6 会继续走"可脚本验证的部分做到全绿、需要真机的部分标 BLOCKED"这条路。

## 2026-09-12 · Android 日常使用可靠性 T1–T4

本次在 `main`（HEAD `0509c49`）既有大量未提交改动上实施，不回退既有工作；不提交、推送或发布。用户确认 Android 优先。

| 任务 | 用户效果 | 状态 |
|---|---|---|
| T1 | 同步失败不报成功，离线队列状态可信 | 待体验 |
| T2 | 设置可靠保存，失败不伪装成功 | 待体验 |
| T3 | 搜索、筛选和换服务器不被旧结果覆盖 | 待体验 |
| T4 | 条漫图片加载后恢复实际页内位置 | 待体验 |

验收范围：同步异常与重复操作、设置文件异常与版本兼容、异步查询乱序、真实图片解码后的 widget 几何、Flutter 全量分析及测试。必要技术验证通过后标待体验，用户确认后才能标已验收。设备或真实服务缺口独立记录。

环境检查：`adb devices -l` 检出小米 10（两条无线连接记录）；未提供 `KOMGA_BASE_URL` / `KOMGA_API_KEY` 环境变量。不会读取或改动用户真实阅读记录充当验收夹具。


### 本次实现与适用验证（2026-09-12）

上述状态是本轮 T1–T4 状态，不替代前文历史里程碑；本次未进行用户验收。代码版本为 `0509c49` 加当前工作树，不能把 HEAD 单独视为本次产物源码。

- **T1**：`manual_sync_result.dart` 定义成功、失败、未执行结果；`series_grid.dart` 的手动同步保留原异常、阻止重复任务，设置页只根据返回结果提示。`settings_screen.dart`、`outbox_sheet.dart` 将读取中、读取失败和确认空队列分开，合计 pending + waiting + failed，空队列仅说明没有待上传操作，支持重读。
- **T2**：`library_repository.dart` 串行保存完整快照，在目标文件同目录创建临时文件，flush、关闭后 rename；异常抛出，旧文件不动。损坏配置必须显式恢复默认，未来版本始终禁止覆盖。`app_settings.dart` 逐字段校验；设置页加载/保存期间禁止编辑，成功才发布设置，失败可重试；统计刷新不再重新加载并覆盖设置。`main.dart` 防止迟到的启动读取覆盖后来成功保存的设置。
- **T3**：`series_grid.dart` 按查询及服务器代次守卫列表、封面、错误、finally 和辅助数据。搜索保留 350ms 防抖但立即作废旧查询；追加错误保留内容并手动重试。真实服务器管理入口也执行失效。必要依赖 `live_sync.dart` 在停止/销毁后拒绝旧续体；仓库 SSE 会话固定到原服务器，迟到的凭据查询不能重启已停会话。保留每页 50 条、页范围封面和视口网格。
- **T4**：`reader_screen.dart` 等目标图片真实解码和布局，逐步定位未挂载页面，按图片盒（不含 gap）恢复并测量实际比例；图片失败、无进展或 30 秒就绪期限到达显示恢复重试。用户滚动取消恢复，尺寸变化重新恢复，旧控制器回调失效。缓存图片 Future 避免重建抹掉失败结果，普通阅读也提供“重试图片”。`reader_controller.dart` 合并同页在途下载，串行等待偏移写入，成功后才标记已写，关闭前重试失败写入；翻页 await 后再次核对代次。屏幕离开前捕获最后滚动帧，解决 80ms 防抖尚未完成即退出丢位置。底栏限制实际高度，避免透明区域截获条漫拖动。

### 本次实际执行的检查

Flutter 命令工作目录：`android/app`；Flutter 可执行文件：`/Users/sakurasep/flutter/bin/flutter`。本轮未改 Rust 接口或数据库版本，未重跑 Rust/Apple 全量验证。

| 检查 | 本次实际结果 | 记录入口 |
|---|---|---|
| `flutter analyze --no-pub` | PASS，No issues found | `/tmp/comic-analyze-final.log` |
| `flutter test --no-pub` | PASS，212 tests passed | `/tmp/comic-full-test.log` |
| `git diff --check`（仓库根目录） | PASS，exit 0 | 本轮终端输出 |
| `JAVA_HOME=/opt/homebrew/opt/openjdk@17 flutter build apk --debug --no-pub` | PASS，生成 debug APK | `/tmp/comic-apk-build.log` |

新增/扩展测试入口：`settings_persistence_test.dart`、`settings_and_diagnostics_test.dart`、`shelf_sync_result_test.dart`、`shelf_race_test.dart`、`repository_sse_lifecycle_test.dart`、`live_sync_test.dart`、`reader_test.dart`、`reader_position_write_test.dart`。已有 `reader_offset_test.dart` 和 `shelf_scale_test.dart` 同在本次全量通过范围内。

阅读器 widget 用真实可解码的不同高度 PNG 和延迟路径，经生产 ListView/Image 布局检查，不是仅测试几何纯函数。覆盖未挂载目标、延迟图片、末页夹紧、旋转、用户实际拖动、立即退出、控制器替换、失败重试，位置误差断言不超过 2 个逻辑像素。文件读写测试使用临时目录；没有操作真实阅读记录。

**断言能否抓住旧故障：**

- T1：在隔离副本跳过失败分支，失败同步出现“同步已完成”，针对测试 FAIL（0 passed / 1 failed），`/tmp/comic-sync-red.log`。
- T2：隔离副本恢复吞掉保存异常，写入失败测试因 Future 正常结束而 FAIL（0 / 1），`/tmp/comic-settings-red.log`。
- T3：恢复前书架实现运行乱序回归，2 passed / 5 failed；覆盖迟到结果、追加、旧错误、缺重试和仓库替换，`/tmp/comic-shelf-red.log`。
- T4：隔离副本改为直接报告请求比例，末页测试实际得到 0.95，违反应小于 0.95 的夹紧断言，FAIL（0 / 1），`/tmp/comic-reader-red.log`。本轮还实际复现并修正立即退出只保存 0.2、未保存实际 0.2625 的问题。

隔离副本仅改变待测错误行为，不修改工作树；这些有意失败记录不是最终测试失败。最终工作树全量 212 项通过。

APK：`android/app/build/app/outputs/flutter-apk/app-debug.apk`。
SHA-256：`a455c519be9ba4b01d1fff9f5dee9dd443a4e6fb663ff5af5d4d0a5a18a15249`。
构建沿用工作区现有原生依赖；未安装覆盖设备上的个人应用，未发布。

### 剩余体验与明确限制

- `adb devices -l` 本次确认有小米 10；缺少专用 Komga 服务凭据和可操作的测试书，真实“离线标记→联网实际上传”和“真实条漫读到一半→退出→重开”尚未验证。此缺口不影响其余自动检查，但不能宣称真机流程通过。
- 本轮证明 Dart 关闭顺序和实际布局恢复；现有 Rust `reader_background` 不持久化页内偏移，不能扩大宣称后台进程被杀后也已解决。正常关闭、强杀进程是不同场景。
- Apple、PDF/EPUB、新下载能力、视觉重设计和进一步性能测量均不在本轮实现范围。
- 体验入口：安装本轮 APK 后，在设置页尝试同步/保存及错误重试；书架快速搜索和筛选；条漫中等待图片后退出重开、旋转、手动打断恢复。真实上传验证须使用专用测试记录。
- 后续遇到阻塞只暂停受影响步骤；同一阻塞两次不同依据尝试仍未解决就保留预期、实际及证据，不降低断言；不覆盖用户改动，不提交、推送或发布。用户确认效果后才能把对应 T 编号改为“已验收”。
