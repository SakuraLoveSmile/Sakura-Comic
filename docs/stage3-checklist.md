# Stage 3 Checklist — Local Store 与 Vertical Slice

验收标准（双端完整跑通）：

```text
添加 Komga Server → Authentication → 拉取 Series → 写入 SQLite → 下载 Cover
→ 从 SQLite 查询 Series → 展示本地封面墙
```

核心原则：**网络负责同步，本地数据库负责展示。**

## SQLite（第一版数据库，Schema v3）

| 表 | 状态 | 位置（双端 DDL 镜像一致） |
| --- | --- | --- |
| servers / libraries / series / books / collections / readlists | ✅ | `komga_core/src/store/schema.rs` ↔ `KomgaKit/Sources/KomgaStore/Schema.swift` |
| sync_state | ✅ 写入 | BootstrapSync 成功后 `recordSuccessfulSync` / `touch_successful_sync` |
| pending_mutations | ✅ DDL | Phase 2（Mutation Outbox）消费 |
| **thumbnails**（v3 新增） | ✅ 读写 | 封面缓存记账：`(server_id, remote_id, variant)` → `local_path` |
| read_progress / downloads / cache_entries / FTS | ✅ DDL | 后续阶段消费 |

所有远端对象均含 `serverId` + `remoteId` 复合主键（多服务器隔离）。

## Series（双端）

| 能力 | Apple | Android |
| --- | --- | --- |
| Series API + 分页 | `KomgaAPI/SeriesDTO.swift` → `fetchSeriesPage` | `api/series.rs`（共享 fixture `series-page.json` 解码测试） |
| API Model → Local Model | `SeriesRecord(serverID:dto:)` | `save_series_batch`（DTO → `SeriesRow` 字段映射） |
| 入库（批量 upsert） | `KomgaStore.upsertSeriesBatch`（幂等，冲突更新） | `store/series.rs::save_series_batch` |
| 查询 + 基础分页 | `fetchSeries(serverID:limit:offset:)` + `countSeries` | `list_series` / `count_series`（COLLATE NOCASE） |
| 入库即记录同步状态 | BootstrapSync → `recordSuccessfulSync` | `bootstrap_page_to_store` → `touch_successful_sync` |

## Cover Cache（双端）

| 能力 | Apple | Android |
| --- | --- | --- |
| Cover 下载 | `URLSessionCoverFetcher` | `KomgaClient` + `BytesFetcher` |
| 磁盘缓存 + Cache Key | `DiskImageCache`（`cache/thumbnails/`，`coverKey(serverID:seriesID:)`） | `DiskCache` + `cover_key`（safe_key 消毒） |
| 本地文件路径管理 | `thumbnails` 表：`ThumbnailRecord`（upsert / get / list / coverPath） | `store/thumbnails.rs`（record / get / list / delete_for_server） |
| 缓存缺失自动补齐 | `CoverLoader` miss → 下载落盘；`LibraryViewModel.coverData` 先查 SQLite 路径 → 下载后记账 | facade `ensure_cover` / `ensure_covers`（LEFT JOIN 缺失清单，幂等补齐） |
| 多服务器隔离 | `(server_id, remote_id)` 主键；删除服务器级联清记录 + 文件 | 同构；`deleteServer` 清理 `thumbnails` 行 + 磁盘文件 |

## UI：封面墙（只读 SQLite，禁止 View → Komga API）

| 平台 | 列表数据 | 封面数据 |
| --- | --- | --- |
| iOS / macOS | `LibraryViewModel.series` ← `KomgaStore.fetchSeries` | `coverData` 先查 `thumbnails` 表路径 → 磁盘加载；miss 才经 CoverLoader |
| Android | `SeriesGridScreen` ← `RustLibraryRepository.fetchSeries`（FFI → rusqlite） | `fetchCoverPaths` ← `list_thumbnails`（SQLite 路径）→ `Image.file` 渲染 |
| Android 演示 | `loadDemo` → facade `bootstrap_demo`（fixture 3 个 Series + 生成 PNG 封面，无网络） | 与 Swift App `DemoSupport` 对齐 |

网络访问只发生在显式同步动作（bootstrap / ensure_covers / refresh），页面渲染路径零网络。

## 本地验收

```bash
bash scripts/verify.sh   # cargo fmt/clippy/test + swift build/test + flutter analyze/test
cd android/komga_core && cargo run --bin phase0_smoke -- --fixture \
  --db /tmp/comic-stage3-fixture/comic.sqlite --server-id demo
```

`phase0_smoke` 输出 `== SQLite cover bookkeeping (thumbnails) ==`，断言封面行已记账且文件存在。

## 真实服务器验收（可选，需 API Key）

```bash
export KOMGA_BASE_URL=http://192.168.0.69:25600
export KOMGA_API_KEY=your-api-key
bash scripts/e2e_stage3.sh
```

## 模拟器封面墙演示（Android，无服务器）

1. `cd android/app && flutter build apk --debug && flutter install`
2. 启动 App → 点 AppBar 的 **演示**（✨ 图标）→ 封面墙展示 3 个 fixture Series + 生成封面
3. 或添加真实服务器 → 保存后自动 bootstrap → 点 **刷新** 补齐封面

## iOS 实机/模拟器

`xcodegen generate && xcodebuild -scheme ComicApp_iOS -sdk iphonesimulator build` 后运行：
点工具栏「演示」离线展示封面墙；添加真实服务器后 `refreshable` 触发 bootstrap。

## 覆盖测试

- Rust（58 通过）：thumbnails store（upsert/list/多服务器/缺失清单）、sync_state、
  demo PNG 结构性校验、facade（demo bootstrap / cover miss 补齐 / 全量补齐幂等 / 删除清理）、
  smoke fixture 全链路
- Swift（61 通过，1 skip=live）：`ThumbnailStoreTests`、VerticalSlice 扩展断言 sync_state
- Flutter：widget 测试新增「SQLite 路径 → 磁盘封面渲染」「演示封面墙动作」