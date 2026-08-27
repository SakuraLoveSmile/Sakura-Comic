# Stage 4 Checklist — 完整媒体库

验收标准（双端完整跑通）：

```text
FullSync（Series → Books → Collections → Readlists → Progress → Covers）
→ 浏览 Library / Series / Book（Metadata / Tags / Genres / Status）
→ 本地搜索 / 筛选 / 排序 / 分页（全部 SQLite）
→ 断开 Komga 网络后上述一切依旧可用
```

核心原则：**网络负责同步，本地数据库负责展示。**

## 验收结果

```bash
bash scripts/verify.sh        # cargo fmt/clippy/test + swift build/test + flutter analyze/test 全绿
bash scripts/e2e_stage4.sh    # fixture 电池 30/30 PASS → 离线重放 27/27 PASS（无服务器）
```

> `verify.sh` 的 Flutter 分支依赖 `flutter` 在 PATH 上（本机安装位置示例：
> `export PATH="$HOME/flutter/bin:$PATH"`）。不在 PATH 上时该分支会直接失败退出，
> 不要把「没跑」当成「跑过」。

真实服务器链路（需 API Key，同步 → 无凭据离线重放同一数据库）：
```bash
export KOMGA_BASE_URL=http://192.168.0.69:25600
export KOMGA_API_KEY=your-api-key
bash scripts/e2e_stage4.sh
```

## SQLite Schema v5（双端 DDL 镜像）

| 变更 | Rust | Swift |
| --- | --- | --- |
| 归一化筛选表 series_genres/series_tags/series_authors/book_tags/book_authors | ✅ `store/schema.rs` | ✅ `KomgaStore/Schema.swift` |
| 成员关系表 collection_series / readlist_books(保序) | ✅ | ✅ |
| 完整元数据列（reading_direction/language/age_rating/title_sort/total_book_count、book number/number_sort/isbn/release_date） | ✅ | ✅ |
| v3→v4 列迁移（PRAGMA table_info 守卫的 ALTER）+ FTS 形状重建 | ✅ | ✅（`Schema.migrate(db:)`）|
| 服务器作用域 FTS5（server_id UNINDEXED）+ fts_rowid 增量维护 | ✅ `store/fts.rs` | ✅ `KomgaStore+MediaLibrary.swift::FTS` |
| v5：libraries.root / libraries.unavailable（DTO 本来就带，之前入库被丢弃） | ✅ `V5_ALTER_STATEMENTS` | ✅ `Schema.v5AlterStatements` |

## Library

| 能力 | Android (Rust + Flutter) | Apple (Swift) |
| --- | --- | --- |
| 列表 | 书架 AppBar「图书馆」→ `LibrariesScreen`：每库 name + 本地 series/book/已读 计数 + 根路径 + 不可用标记（`library_counts` 相关子查询聚合） | ✅ 同构（`LibrariesListView`，`store.libraryCounts`） |
| 详情 | `LibraryDetailScreen`：统计块 + 阅读进度条 + root + 可用性 + 本库内 FTS 搜索 + 该库 Series 封面墙（分页「加载更多」，点进 Series 详情） | ✅ `LibraryDetailView`（`store.libraryDetail` + `librarySeries` 分页墙） |
| 切换 | ① 书架 chips「全部 / Manga Main 2 / Webtoons 1」；② 列表/详情内「设为书架筛选」→ 回书架并带上 `library_id`；③ 服务器切换沿用 Servers 入口 | ✅ 同构（chips + `model.selectLibrary(id:)`；服务器切换在 `serverMenu`） |

## Series

| 能力 | Android | Apple |
| --- | --- | --- |
| 封面墙 | 书架 Tab：搜索框 + 库 chips + 状态/标签/题材筛选 + 排序菜单 + 升降序 + 无限滚动分页（共 N 个 Series 头部） | ✅ 同构（searchField/libraryChips/shelfControls/LazyVGrid 分页） |
| 详情 | `series_detail`：封面头 + 状态 chip + 已读/未读/阅读中计数 + 简介/作者/出版社/语言/阅读方向/分级 + 标签/题材 chips + 所属合集入口 | ✅ `SeriesDetailView` 同构 |
| Metadata | `series_metadata` 表（summary/publisher/reading_direction/language/age_rating/title_sort/total_book_count）随 FullSync 入库 | ✅ upsertSeriesBatch 同步写入 |
| Tags / Genres | 归一化表 + `filter_options`（去重排序）供筛选 chips | ✅ series_tags/series_genres + filterOptions |
| Status | series.status 列表展示 + 状态筛选 + 选项列表 | ✅ |

## Books

| 能力 | Android | Apple |
| --- | --- | --- |
| 列表 | Series 详情内 Books 区（number_sort 排序 NULL 最后 + 总数 + 加载更多） | ✅ queryBooks |
| Metadata | `book_detail`：summary/isbn/release_date/册数/页数/媒体类型/tags/authors（底部弹层） | ✅ BookDetailView sheet |
| 阅读状态 | read_status 三分区筛选（已读/进行中/未读）；标记已读/未读 → 本地行 + Outbox（READ_PROGRESS/MARK_READ/MARK_UNREAD） | ✅ setReadProgress/markRead/markUnread + pending_mutations |
| 封面 / 缩略图 | `variant='book'` thumbnails 记账；打开详情幂等回填（ensure_book_covers）；磁盘 Image 渲染 | ✅ variant "book" + bookCoverData 回填 |

## 其他内容

| 能力 | Android | Apple |
| --- | --- | --- |
| Collections | 合集 Tab：列表 → 详情成员封面墙（collection_series 成员关系随同步入库） | ✅ CollectionsView/CollectionDetailView |
| Readlists | 书单 Tab：列表 → 保序书籍列表（readlist_books.position） | ✅ ReadlistsView/ReadlistDetailView |
| Continue Reading | 书架「继续阅读」横滑架：`continue_reading`（page>0 且未读完，按最近活动排序，progress_pct 进度条），点击进入 Series 详情 | ✅ 同构（ContinueReadingCard）|

## 本地查询（全部基于 SQLite）

| 能力 | Android | Apple |
| --- | --- | --- |
| 搜索 | FTS5（series_fts/book_fts，server_id 作用域，`"term"* AND …` 转义，fts_rowid 增量更新；书架搜索 350ms 防抖） | ✅ 同语义 FTS.matchQuery + MATCH 子查询 |
| 筛选 | Library / Tag / Genre / Status（EXISTS 子查询组合） | ✅ |
| 排序 | Series：name/sortName/dateAdded/dateUpdated/booksCount ± asc/desc；Books：number（NULL 最后）/title/dateAdded | ✅ 同枚举映射同一批 SQL |
| 分页 | LIMIT/OFFSET + COUNT(*) 总数（墙 50/页无限滚动；Books 100/页加载更多） | ✅ |

## 同步

| 能力 | Rust | Swift |
| --- | --- | --- |
| FullSync | `sync/full.rs`：Series(size=100 分页至 last) → 每本 Series 的 Books（readProgress 内联入库）→ Collections（seriesIds 成员）→ Readlists（bookIds 保序）→ On-Deck 进度回填 → record_full_sync | ✅ `KomgaSync/FullSync.swift` 同序 |
| 幂等 | 双跑计数一致（fixture 全链路测试） | ✅ testFullSyncIsIdempotent |
| 演示模式 | `bootstrap_demo` 种子完整媒体库（2 库/3 Series/7 Books/2 合集/2 书单/1 本进行中 + Series/Book 封面 PNG） | ✅ DemoLibraryFetcher 读共享 fixtures + FullSync |
| 共享 Fixtures | `specs/contracts/fixtures/library/`（series-page/books-by-series/collections-page/readlists-page/ondeck-page/libraries.json）双端同源 | ✅ |

## 覆盖测试

- **Rust（87 通过）**：books/collections/readlists/read_progress store、FTS 转义与增量维护、
  query 层（搜索/筛选/排序/分页/阅读状态分区/多服务器隔离、library_counts + library_detail
  聚合与库内计数隔离）、FullSync fixture 全链路与幂等、
  facade（详情/Outbox/书封面回填/删除级联）、API 解码共享 fixtures
- **Swift（65 通过，1 skip=live）**：新增 MediaLibraryStoreTests —— 共享 fixtures 解码、
  v3→v4/v5 迁移（旧 FTS 形状重建 + libraries.root/unavailable 落表 + user_version=5）、
  FullSync 种子（3/7/2/2/4）、
  本地查询电池（搜索/筛选/排序/分页/详情/阅读状态分区/Outbox/合集/书单/继续阅读/filter options/
  Library 列表计数与详情一致）
- **Flutter（18 通过）**：既有 11 项全绿（封面墙磁盘渲染/演示墙/服务器管理链路）+
  新增 7 项（搜索触发 FTS 查询、库 chips 筛选、继续阅读架渲染、合集 Tab 导航成员墙、
  书单 Tab 保序列表、Series 详情元数据 + 标记已读写 Outbox、
  图书馆列表 → Library 详情（统计/根路径/本库封面墙）→ 设为书架筛选）
- **Smoke**：`stage4_smoke --fixture` 30/30 PASS；`--offline` 重放 27/27 PASS（零网络路径）
- **UI 构建**：ComicApp iOS/macOS scheme BUILD SUCCEEDED；flutter analyze 0 issues

## 已知边界

- FTS5 unicode61 分词对 CJK 连续字串不切词——中文子串搜索需 trigram 分词器（后续阶段）
- 服务端删除的墓碑传播（tombstones）属于增量同步阶段；本期 FullSync 只做镜像合并
- Outbox 上传（MutationUploadSync）属后续阶段；本期本地变更安全落库待传