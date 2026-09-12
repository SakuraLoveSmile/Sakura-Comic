# 大库可用：书架墙的性能

> **主题四** 的实施记录。目标来自 [database-schema.md](database-schema.md) 早先写下的
> 那句话：「10,000 Series、100,000 Books 下搜索与分页流畅；本地搜索 < 100ms」。
>
> 本文只记录**实际执行过的命令、结果与源码行号**，不写"应该更快了"。
> 数字为 2026-09-11 在本机（macOS arm64，Flutter 3.41.3 / Dart 3.11.1，
> rustc 1.85.0）实跑所得。

## 问题：分页在渲染层被彻底废掉

`android/app/lib/src/series_grid.dart` 的书架墙原本是：

```dart
GridView.builder(
  shrinkWrap: true,                                   // ← 根因
  physics: const NeverScrollableScrollPhysics(),
  itemCount: _series.length,
  itemBuilder: (context, index) {
    if (index >= _series.length - 5) { _loadMore(); }  // ← 触发器在这里
    ...
```

`shrinkWrap: true` 让 `RenderShrinkWrappingViewport` 必须布局**每一个** child 才能
算出自身高度，于是 `itemBuilder` 对所有索引执行。而翻页触发器就写在 `itemBuilder`
里，于是形成级联：

> 构建到 `length - 5` → 触发翻页 → 追加 50 条 → `setState` 重建 → `itemBuilder`
> 又跑一遍更长的列表 → 在新的 `length - 5` 再次触发 …… 直到
> `_series.length >= _seriesTotal`。

**冷开书架墙，用户什么都不做，整库分页就被抽干。** 10,000 series 的库 = 200 次
串行 `querySeries` FFI 往返 + 构建 10,000 个瓦片 + 解析 10,000 张全尺寸封面。
`docs/stage4-checklist.md` 的「墙 50/页无限滚动」契约不是"有风险"，是已经死了。

两个放大器：

- 封面 `Image.file` 没有 `cacheWidth`，按原图分辨率解码进 110–180 逻辑px 的瓦片；
- `DownloadController` 每秒无条件 `setState(() {})` 重建整屏（`interval` 是 1 秒，
  `pumpTurn()` 在 `finally` 与空队列早返回处都调回调），于是空队列也让书架每秒
  全量重布局一次。

存储层同时缺索引：全仓库只有 2 个 `CREATE INDEX`，没有一个服务于媒体库列表查询。

## 修复与验证

### 1. 书架墙视口化（`series_grid.dart`）

`ListView(children:) + shrinkWrap GridView` → `CustomScrollView` + 两个 sliver
（头部一个 `SliverToBoxAdapter`，网格一个 `SliverGrid` + `SliverChildBuilderDelegate`）。
`cacheExtent: 600`，`AlwaysScrollableScrollPhysics` 保留，`ValueKey('shelf-list')` 保留
（两个既有下拉刷新测试依赖它做拖拽）。

`test/shelf_scale_test.dart` 用 5000 条 series 把不变量钉成整数：

| 断言 | 内容 | 修复前 | 修复后 |
| --- | --- | --- | --- |
| A | 首帧挂载的 `SeriesWallTile` 数 | **5000** | **< 60** |
| B | 首帧的 `(limit, offset)` 请求序列 | **100 条**（整库抽干） | `[(50, 0)]` |
| C | 一次拖拽后的页请求 | — | 恰好 2 条，`(50, 50)` |
| D | 总数文案 | — | `共 5000 个 Series`（来自服务器，不是页长） |
| E | 能否滚到最后一本 | — | 能，且累计 100 页 |

**变异检验（A/B）：** 把 `shrinkWrap: true` 的嵌套 GridView 放回去 →
测试 1 失败、测试 2 报 `Expected: <2> Actual: <100>`，即整库在首帧被抽干。
这就是那个 bug 本身。

### 2. 封面按瓦片尺寸解码（`SeriesWallTile`）

`Image.file(..., cacheWidth: <瓦片宽 × devicePixelRatio>)`，用 `LayoutBuilder` 量真实
槽宽（`maxCrossAxisExtent` 只是上界）。只用 `cacheWidth`，不用 `cacheHeight`——
单维度保持宽高比，`BoxFit.cover` 负责裁切。这是 `reader_screen.dart` 已有的模式。

注意：`ResizeImage` 在源图窄于目标时会**放大**。演示封面（`cache/demo_png.rs`）
硬编码 200×300，在 `spacious` 瓦片上目标宽度会超过它。真实 Komga 缩略图 ≥ 600px，
日常驱动路径永远是降采样。

`test/widget_test.dart` 的封面断言改为解包 `ResizeImage`：provider 必须是
`FileImage`、`width` 非空、`height` 为 null。**变异检验：** 删掉 `cacheWidth:` →
`img.image` 是裸 `FileImage` → `as ResizeImage` 抛 `_TypeError` → 失败。

**这是 Flutter 内置的解码期子采样**（`instantiateImageCodec` 分配更小的位图），
不写文件、不做转码、不做内容识别，且阅读器早已在用。它不属于 README
「本期明确不做」里的「本地图像处理」。

### 3. 每秒一次的全屏重建（`download_controller.dart`）

`DownloadController` 从手写单槽回调改为 `ChangeNotifier`，并加一个修订指纹：
空队列每秒产出完全相同的指纹，于是 `notifyListeners()` 不触发。书架只把 AppBar
的下载徽标包进 `ListenableBuilder`。

新增测试：空队列 `pumpTurn()` 连转 5 次通知 **0** 个监听器；队列真的动了通知 ≥1；
只有退避原因变了也通知（状态行读数来自 `stopReason`）。
**变异检验：** 删掉指纹守卫 → **10 次通知**（5 次 tick × 2 个通知点）→ 失败。

### 4. v11 列表索引 + 统计信息

见 [database-schema.md](database-schema.md) 的「v11 变更」。要点：

- 五种排序索引全部带 `COLLATE NOCASE`（BINARY 序索引满足不了 NOCASE 排序）；
- `books_series_order` 补上 `books.series_id` 从未有过的索引；
- **`PRAGMA optimize` 必须在镜像有数据之后跑**，否则统计信息缺失，规划器不会选
  更好的 join 顺序。

`store/query.rs` 的断言全是确定性整数，不用毫秒：

| 测试 | 断言 | 变异检验 |
| --- | --- | --- |
| `a_series_wall_page_never_sorts_in_a_temp_btree` | 5 种排序 × ASC/DESC 的 `StatementStatus::Sort == 0` | 索引去掉 `COLLATE NOCASE` → `Sort == 1`，计划退回 `USE TEMP B-TREE FOR ORDER BY` |
| `the_sort_name_expression_index_still_matches_the_order_expression` | 计划含 `series_sort_name_nocase` | 改 `order_expr` 后失效 |
| `a_series_book_page_reads_one_series_not_the_whole_library` | 12000 本书里取一个系列的 10 本，`VmStep < 2000` | — |
| `library_counts_drives_from_the_library_when_statistics_exist` | 统计后计划含 `series_library` + `books_series_order`，且**步数降到 1/5 以下** | 去掉统计信息 → 比值 ≈ 1 |
| `a_v6_outbox_row_survives_the_migration_and_gains_its_retry_columns` | pre-v7 库能打开 | 索引搬回 `CREATE_STATEMENTS` → `no such column: state` |

**实测数字（1200 series / 12000 books，4 个 library）：**

| 查询 | 无统计信息 | 有统计信息 |
| --- | --- | --- |
| `library_counts`（VM 步数） | 1,539,860 | **119,068**（12.9×） |

### 5. 封面查询改为页范围（`cover_paths`）

`fetchCoverPaths()` 原本拉取**整个服务器**的 `thumbnails` 表（series 与 book 两种
variant），在 Dart 里筛 `variant`，同时 Rust 侧对每一行做一次 `Path::exists()`。
一个 20,000 本书的镜像就是每次加载解码 20,000 行 + 20,000 次 `stat()`。

新的 FFI `cover_paths(db_path, server_id, variant, remote_ids)` 走**已有主键**
`(server_id, remote_id, variant)`，一次探测一个 id。`exists()` 过滤**保留**——
`list_series_missing_cover` 与 `cover_path` 都依赖"文件消失读作缓存未命中"来触发
回填，去掉它会让坏封面永远渲染占位图。现在它是 50 次 stat 而不是 20,000 次。

消费方全部改为按页请求：书架墙、库详情墙、系列详情的书封面、合集成页。
合集详情改为自己取（成员系列不一定在书架已加载的页里）。

**变异检验：**
- 书架改回请求"已加载的全部 series" → 测试报 `Expected: length 50, Actual: [100 个 id]`；
- facade 去掉 `exists()` 过滤 → `page_scoped_cover_paths_answer_the_page_and_still_drop_dead_files`
  报 `left: 3, right: 2`。

### 6. 一次刷新的 FFI 往返次数（`library_repository.dart`）

`_activeServerId()` 一次书架刷新被问 9 次，每次都是 `listServers` + `getActiveServer`
两次往返——27 次总往返里有 18 次花在这上面。现在缓存的是 **Future 而非值**，因为
那些加载器跑在 `Future.wait` 里（只缓存值的话它们会一起未命中，各付两次）。

**实测：** 一次刷新（10 个方法）从 **20 次**探测降到 **2 次**。
**变异检验：** 摘掉记忆化 → 回到 20 次。

不缓存 API Key：把解密后的凭证留在 Dart 字段里，对一个只有用户手势触发的路径是
安全性退化。只复用 id。

### 7. 删除死代码

`observeSeries()`（15 秒轮询流）在全仓库有声明与 8 处实现，**没有任何调用点**。
已删除。`fetchSeries()` 保留：它是 `querySeries` 默认实现（测试 double 用）的
依赖，S8 已把它从"调两次"改成"调一次并转发 limit/offset"。

## 仍未验证

**没有任何一腿测出"快了多少倍"的墙钟数字。** 本主题按用户指示移除了独立压测
harness 与设备腿，验证退化为"结构不变量与查询计划正确"，而不是"耗时从 X 降到 Y"。
具体缺口：

- **无墙钟基线**：没有 5000 series 设备腿的帧时序、`imageCache.currentSizeBytes`
  前后对比、滚动到底耗时。第 4 节那张表里唯一的跨版本数字是 `library_counts` 的
  VM 步数（1,539,860 → 119,068），它是**同进程同机器的相对量**，不是时间。
- **无真机验证**：所有断言都跑在 `flutter test`（宿主机）与 `cargo test`
  （内存库）上。书架墙的滑动帧率、低端机上的解码压力、真实 600×900 缩略图的
  内存曲线**都没有在设备上量过**。
- **超过 1000 个瓦片时的 ImageCache 槽位抖动没有被演示**：`cacheWidth` 降低的是
  单条目解码字节，而槽位上限（1000 条 / 100 MB）本身没动。本主题不声称修好了
  槽位抖动。
- **`fetchFilterOptions` 未优化**：它仍跑三次 `SELECT DISTINCT … ORDER BY …`
  全表扫描。没有实测它的耗时，所以也没有决定是否为 `series_tags` /
  `series_genres` 加索引。这是**记录在案的后续项**。
- **`PRAGMA optimize` 的挂载点形式没有测试覆盖**：`prepare` + `query_row` 与
  `execute` 的区别只在"优化真的采取行动"（大镜像）时才暴露，而 shared fixture
  只有 3 条 series，`PRAGMA optimize` 不会采取行动。实现选了更稳健的形式，但
  **没有断言钉住它**。
- **Apple 端未做任何改动**，仍是原来的实现与同一个问题；两端 `user_version`
  因此差 2（见 [database-schema.md](database-schema.md)）。

## 一处容易被误记成契约变更的事

`docs/stage4-checklist.md` 里那条分页契约（`LIMIT/OFFSET + COUNT(*) 总数`，
墙 50/页无限滚动）**没有改**。变的是代码终于开始遵守它——在本次改动之前，
`shrinkWrap` 让那个契约在渲染层彻底失效，文档说的和代码做的不是一回事。

写在这里是因为"文档本来就是对的、代码是错的"正是那种事后容易被误记成
"这次改了契约"的事。翻页大小、OFFSET 语义、总数来源全部未动。

## 复现命令

```bash
# Rust：索引与查询计划的断言（含 5 种排序 × 双向、统计信息比值、v6 迁移）
cd android/komga_core && cargo test --lib

# Flutter：书架墙的规模不变量、封面降采样、通知节流、页范围封面
cd android/app && flutter test

# 生成物与 FFI 绑定是否同步（隔离沙箱内重跑 codegen 后逐字节比对）
bash scripts/check_frb_drift.sh
```
