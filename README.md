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
| Phase 2 | Reliable Sync（增量 / SSE / Outbox / 冲突处理） |
| Phase 3 | Reader（单页 / 双页 / Webtoon） |
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

## 文档入口

- [架构](docs/architecture.md)
- [同步引擎](docs/sync-engine.md)
- [数据库 Schema](docs/database-schema.md)
- [阅读器](docs/reader.md)
- [离线存储](docs/offline-storage.md)
- [Behavior 契约与 Fixtures](specs/behavior.md)
