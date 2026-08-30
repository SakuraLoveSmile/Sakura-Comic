# Shared Fixtures

- JSON 文件，命名 snake_case，按契约目录组织
- 常用字段：`remote`（服务端状态）、`localPending`（本地未上传状态）、`expected`（期望合并结果）
- Swift XCTest 与 Rust cargo test 必须加载同一文件并断言同一 `expected`
- 只允许由 Behavior 变更驱动修改；两端实现同步更新

## 媒体库 Fixtures（`library/`，Stage 4）

完整媒体库演示/离线验收的唯一数据源：Rust `stage4_smoke --fixture`、Swift 演示模式与
两端 fixture 测试都加载这些文件。

| 文件 | 内容 |
| --- | --- |
| `libraries.json` | 2 个库（Manga Main / Webtoons） |
| `series-page.json` | 3 个 Series（One Piece / Berserk / Solo Leveling），完整元数据（genres/tags/authors/publisher/titleSort/readingDirection/ageRating/status/…）与阅读计数器 |
| `books-by-series.json` | `seriesId → BookPage`：共 7 本书（3/2/2），含 metadata（numberSort/isbn/releaseDate/authors/tags）与内联 readProgress（已读 2 本、进行中 1 本） |
| `collections-page.json` | 2 个合集，成员关系内嵌（`seriesIds`） |
| `readlists-page.json` | 2 个书单，成员关系内嵌（有序 `bookIds`） |
| `ondeck-page.json` | 1 本进行中的书（One Piece #2, page 12/20） |

一致性约束：series 的 booksCount 与 books-by-series 实际书数一致（3/2/2）；
ondeck 的书必须同时存在于 books-by-series（进度来自同一本）。

## `reader/`

| 文件 | 钉住 | 两端实现 |
| --- | --- | --- |
| `paging.json` | 页 → 跨页配对、轴、镜像、手势 | `komga_core::reader::paging` / `KomgaReader.Paging` |
| `manifest.json` | `PageDto[]` 归一化、EPUB/PDF 不进图像阅读器 | `reader::manifest` / `KomgaReader.PageManifest` |
| `prefetch.json` | 给定窗口时的出队次序与快翻取代 | `reader::prefetch` / `KomgaReader.Prefetch` |
| `window.json` | **窗口本身该多大**：内存/页尺寸/网络/方向/稳定性 → forward·back·cap·并发·内存层·解码槽位 | `reader::window` / `KomgaReader.WindowPlanner` |
| `throttle.json` | 进度写的节流与持久性 | `reader::throttle` / `KomgaReader.ProgressThrottle` |

`prefetch.json` 与 `window.json` 是两层：前者只管「给定 F/B/cap 时怎么排队」，
后者只管「F/B/cap 是多少」。分开是因为排队次序跨阶段不变，而窗口大小是设备事实。
