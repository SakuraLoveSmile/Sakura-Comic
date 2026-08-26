# Phase 0 验收清单

目标：证明整个技术架构成立 —— 两端都能「添加真实 Komga 服务器 → 认证 →
拉取 Series → 写入本地 SQLite → 从 SQLite 展示封面墙（含封面缓存）」。

> **Stage 1 基建已完成（本环境实测）**：Swift 6.4 / xcodebuild 可用；cargo 1.98 /
> flutter 3.41 (Dart 3.11) / flutter_rust_bridge_codegen 2.13 / cargo-ndk 4 均可用。
> FRB 已接线（生成绑定 + cargo-ndk 三 ABI jniLibs），Android 模拟器实测
> `listServers` 经 FFI 调用 Rust 成功；iOS App 模拟器目标 **BUILD SUCCEEDED**。
> 本机未安装 iOS Simulator Runtime（下载约 7GB），iOS 启动验收由 CI（macos
> runner 自带 Simulator）完成；Android 启动验收已在本机模拟器完成。

## 基建

- [x] Monorepo 结构（apple / android / specs / docs / CI）
- [x] KomgaKit Swift Package（5 个 Target，依赖分层）
- [x] Flutter 壳 + komga_core（8 个模块，FFI 边界隔离）
- [x] flutter_rust_bridge codegen 接线（`scripts/frb_wire.sh`；bridge.rs 全量镜像，
      生成 `ffi/generated/frb_generated.rs` + `lib/src/rust/*`，`frb` feature 门控）
- [x] cargo 构建 / fmt / clippy / test 通过（komga_core：26 测试 + frb feature 构建通过）
- [x] swift build / test 通过（KomgaKit：28 测试）
- [x] flutter analyze / test 通过（3 widget 测试；模拟器实测 FFI 调用 Rust）

## 数据层

- [x] Server Profile + URL 规范化 + 认证头（Swift + Rust）
- [x] 真实服务器认证成功（192.168.0.69 实测：X-API-Key → 200；无凭证 → 401）
- [x] OpenAPI 快照已导出（Komga 1.26.3 / OpenAPI 3.1.0 / 139 路径，specs/openapi/komga-openapi.yaml）
- [x] Series API 契约对照真实响应（分页字段一致；publisher/genres 差异已记录兼容性文档）
- [x] SQLite Schema v1（Swift GRDB / Rust rusqlite 镜像一致）
- [x] Server CRUD（双侧 + 单测）
- [x] Series API 客户端 + 分页 + 错误映射（双侧）
- [x] Series Local Store（批量 upsert / 分页查询 / 多服务器隔离 + 单测）
- [x] BootstrapSync（Rust Fake Fetcher + Swift SeriesPageFetching 协议注入，均有单测）
- [x] 磁盘封面缓存骨架（Swift + Rust + 单测）
- [x] 封面服务层（Rust CoverStore / Swift CoverLoader：缓存命中优先，miss 下载后落盘，单测覆盖）
- [x] 纵向切片离线测试（Rust Facade bootstrap_with fake-fetcher 全链路；Swift VerticalSliceTests：Bootstrap→SQLite→读回→封面缓存）
- [x] 封面下载 → 磁盘缓存链路（**host 验证**：`phase0_smoke --fixture` 已把封面落盘到 `cache/thumbnails/`；真实服务器走同一代码路径）
- [x] **Schema v3 `thumbnails` 表（双端 DDL 镜像）**：封面记录 `(server_id, remote_id, variant) → local_path`；
      封面的本地文件路径由 SQLite 管理 —— UI 只读 SQLite 即可解析封面文件（本地数据库负责展示）
- [x] **封面记账写入（双端）**：Rust facade `ensure_cover` / `ensure_covers`（缺失清单 LEFT JOIN +
      文件存在性检查，幂等补齐）；Swift `KomgaStore.upsertThumbnail` + `LibraryViewModel.coverData`
      先查 SQLite 路径再读盘，miss 才下载并记账
- [x] **sync_state 写入**：Bootstrap 成功后 `touch_successful_sync` / `recordSuccessfulSync`（双端）
- [x] **删除服务器级联清理封面**：Rust facade + Swift `deleteServer` 删记录 + 删磁盘文件（+ 单测）

## UI

- [x] Flutter LibraryGrid（stub repository，widget 测试就绪）
- [x] Flutter RustCoreApi 契约（与 ffi/bridge.rs 签名对齐）
- [x] FFI 门控骨架（ffi/application.rs Facade + 可选 frb feature 的 bridge.rs；默认编译不受影响）
- [x] phase0_smoke 验收工具（真实链路 CLI + 新增 `--fixture` 离线模式；scripts/verify.sh、frb_wire.sh、e2e_smoke.sh 一键执行）
- [x] SwiftUI LibraryGrid 接通本地优先链路（iOS）：`LibraryViewModel` 负责 server 配置 → 认证 → BootstrapSync → 本地 store → `CoverLoader` 封面墙；含离线 **Demo 模式**（注入共享 fixture + 生成封面，无需服务器）
- [x] iOS 应用数据层已用 host 可执行包对 KomgaKit 真实模块编译 + 运行验证（Bootstrap→GRDB→读回→封面缓存全通过）
- [x] macOS 应用接通同一本地优先链路（`Shared/` 共享视图；`xcodegen generate` + `xcodebuild` **BUILD SUCCEEDED**；Demo 模式可离线展示封面墙）
- [x] Flutter Grid 接通 Rust（`RustLibraryRepository` + FRB 绑定；Android 模拟器实测：
      `[RustCore] listServers -> 0 servers`，真实 rusqlite 查询经 FFI 返回）
- [x] Android 封面墙渲染（SQLite 路径 → `Image.file`）：`RustLibraryRepository.fetchCoverPaths`
      ← `list_thumbnails`；缺封面显示占位符；AppBar 刷新 = bootstrap + 补齐；离线「演示」模式
      （facade `bootstrap_demo`：fixture Series + 生成 PNG 封面，无服务器）已 host/单测验证
- [ ] 真实封面墙展示（模拟器 / 真机）：已具备完整数据链路与演示模式；连接真实服务器展示
      待用户环境执行（`e2e_stage3.sh` + 模拟器 Demo + API Key 验证）

## 验收（vertical slice）

- [x] Android 核心纵向切片（host / fixture 验证）：`phase0_smoke --fixture` → BootstrapSync → rusqlite → 读回 3 个 Series → 封面落盘 `cache/thumbnails/`。真实服务器走同一代码路径。
- [x] Apple 核心纵向切片（host / 单测验证）：KomgaKit 28 测试 + 主机 appcheck（用真实 KomgaKit 模块跑通 Bootstrap→GRDB→读回→CoverLoader）。真机/模拟器展示需 Xcode + Simulator。
- [x] cargo fmt / clippy / test 通过（含 `--features frb` 全部目标 clippy）
- [x] swift build / test 通过
- [x] flutter analyze / test 通过（本机 Flutter 3.41）

## Stage 1 基建验收（本阶段补齐）

- [x] Android App 可启动：`flutter build apk --debug` 成功，模拟器安装/启动成功
- [x] Flutter 可调用 Rust 方法：sim 实测 `RustLib.init`（.so 加载）+ `listServers` FFI 调用
- [x] iOS App 可构建并链接 KomgaKit：`xcodebuild -scheme ComicApp_iOS`（模拟器 SDK）BUILD SUCCEEDED；
      启动验收由 CI iOS job（simctl boot + install + launch）完成
- [x] CI 双端基础构建：rust-core / android-core-ndk（三 ABI 交叉编译）/ flutter-app（analyze/test/apk）/
      swift-package / ios-app（xcodegen + xcodebuild + 模拟器启动）
- [x] lint / format / test 基线：cargo fmt+clippy+test、swift build+test、flutter analyze+test 全绿
- [x] git 仓库初始化（含 .gitignore：jniLibs/.so、xcodeproj、构建产物不入库）

## 本轮修复 / 新增（环境内完成）

- [x] 修复 KomgaKit 编译错误：`DiskImageCache.safeKey`（`UnicodeScalar` 可选值）、`KomgaStore.deleteServer`（GRDB `execute` 返回 Void，改用 `changesCount`）、`CoverLoaderTests`（`await` 移出 `XCTAssertEqual` autoclosure）、`SeriesStoreTests`（断言排序后取错行）
- [x] 修复 komga_core 编译：reqwest 0.12 已移除 `sse` feature（SSE 留待 Phase 2）；`SeriesPage` 改为 `pub use`；`HeaderName::from_static` 非 fallible；`phase0_smoke` 的 `list_series` 错误映射
- [x] `phase0_smoke` 新增 `--fixture` 离线模式（fake fetchers，无网络）
- [x] iOS 应用接通本地优先纵向切片 + 离线 Demo 模式
- [x] **Stage 3**：Schema v3 `thumbnails` 表 + 封面记账（双端）；sync_state 写入；
      Rust demo PNG 生成器（纯 Rust stored-deflate，`file`/`sips` 实测 200×300 合法 PNG）；
      facade `cover_path`/`ensure_cover`/`ensure_covers`/`bootstrap_demo` + FRB 重新 codegen
      （coverPath/listThumbnails/ensureCover/ensureCovers/bootstrapDemo）；
      Android 封面墙渲染 + 同步/演示动作 + widget 测试；`e2e_stage3.sh` + `docs/stage3-checklist.md`
