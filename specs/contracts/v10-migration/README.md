# v9 → v10 迁移：影响面与恢复方案（实施前提交确认）

状态：**提案，未实施**。按第一里程碑计划，迁移执行前必须先提交本文并取得确认。

本文只描述**将要发生的改动**、依据（真实文件与行号）以及失败时的恢复路径。
它不是"迁移已完成"的记录。

---

## 1. 要改什么（一句话）

三件事，只有第三件动数据库：

| # | 改动 | 是否动库 |
|---|---|---|
| 1 | 新增本地查询 `series_read_target` / `next_book_in_series`（稳定排序） | 否，纯 SELECT |
| 2 | 新增阅读偏好：全局 `volumeKeysEnabled`（默认 false）+ 每系列覆盖 | 否，`app_state` 里的一份 JSON |
| 3 | `reader_position` 增加 `page_offset_ratio REAL NULL`，`user_version` 9 → 10 | **是** |

第 1、2 项完全复用既有容器：

- 阅读偏好存在 `app_state` 的 `reader_settings` 单行 JSON 文档里
  （`android/komga_core/src/reader/settings.rs:16` `SETTINGS_KEY`），该结构带
  `#[serde(default)]`，**加字段不需要迁移**——这正是它当初被设计成 JSON 文档的原因
  （`docs/reader.md:145`）。
- 每系列覆盖用 `app_state` 的另一类键：前缀 `reader_override:` + JSON 数组
  `[serverId, seriesId]`。用 JSON 编码的元组而不是 `serverId|seriesId` 拼接，
  是因为 server id / series id 都可能含任意字符，分隔符迟早撞车。

## 2. 为什么第 3 项需要动库

条漫（`webtoon`）的阅读位置不是"第 N 页"，而是"第 N 页 + 页内偏移比例"。
现在 `reader_position`（`android/komga_core/src/store/schema.rs:275`）只有
`page / mode / direction / updated_at`，没有偏移列，所以：

- 条漫里读到第 12 页的 70% 处，只能存成"第 12 页"，下次回到页顶；
- 想存偏移就必须加列。

## 3. 具体改动

### 3.1 DDL（与现有两条路径对齐）

```rust
pub const SCHEMA_VERSION: i64 = 10;

// CREATE_STATEMENTS 里 reader_position 的 DDL 增加一列
"CREATE TABLE IF NOT EXISTS reader_position (
   server_id TEXT NOT NULL,
   book_id TEXT NOT NULL,
   page INTEGER NOT NULL,
   mode TEXT NOT NULL,
   direction TEXT NOT NULL,
   page_offset_ratio REAL,
   updated_at TEXT NOT NULL,
   PRIMARY KEY (server_id, book_id)
 )",

// 新增，加入 migrate() 的 alters 链
pub const V10_ALTER_STATEMENTS: &[&str] = &[
    "ALTER TABLE reader_position ADD COLUMN page_offset_ratio REAL",
];
```

`migrate()`（`schema.rs:487`）会把这条 ALTER 加进 `V4 → V5 → V7 → V9 → V10` 的
链上，并由现成的 `table_has_column()` 守卫（`schema.rs:414`）跳过已存在的情况。
**不需要手写新的迁移逻辑**——这是本次改动风险低的主要原因。

### 3.2 `position.rs` 的签名变化

```rust
pub struct Position {
    pub page: i64,
    pub mode: String,
    pub direction: String,
    pub page_offset_ratio: Option<f64>,   // 新增
    pub updated_at: String,
}

pub fn save(conn, server_id, book_id, page, mode, direction,
            page_offset_ratio: Option<f64>, now) -> rusqlite::Result<()>
```

写入侧只有 **2 处**调用点，都要改：

- `android/komga_core/src/reader/session.rs:346`
- `android/komga_core/src/reader/loader.rs:471`

读取侧 1 处：`position::get`（`position.rs` 内 SELECT 列表 + 行映射）。
`page_offset_ratio` 为 `NULL` 时读成 `None`，语义是"页顶"，与旧行完全等价。

写库版本号：`docs/database-schema.md` 需要新增 v10 小节（该文档当前自述仍是 v7，
已经落后于代码里的 v9 —— 实施时一并修正）。

### 3.3 一个**产品规则**变化（不是技术问题，需要你拍板）

第一里程碑决定：

> 阅读器模式与方向严格遵循「系列覆盖 → 全局设置」，**不再**由"本书记录的方向"或
> 服务器推荐覆盖。

现在的代码恰恰相反，而且比文档写的还要绕。实测（不是照抄注释）：

1. `android/komga_core/src/reader/session.rs:102-109` —— 只要 `reader_position` 有行，
   **该行的 `mode`/`direction` 直接覆盖传入的 `settings`**：
   ```rust
   let mode = saved.map(|s| ReadMode::parse(&s.mode)).unwrap_or(settings.mode);
   let direction = saved.map(|s| Direction::parse(&s.direction)).unwrap_or(settings.direction);
   ```
   所以真实优先级是：**本书记住的 > UI 传入的方向 > 全局默认**。
2. `android/komga_core/src/ffi/application.rs:2294-2304` 在 `open` 之前构造 `settings`，
   它调用 `resolve_direction(书本记录, **None**, UI 传入方向)` —— 注意第二个参数是
   `None`，**并没有传服务器推荐方向**。`resolve_direction` 的「服务器推荐」那一档
   （`settings.rs:138`）在实际打开路径上是死的，只有单测在覆盖它。
3. `docs/reader.md:148` 宣称的优先级「上一本书记住的 > 服务器推荐 > 全局默认」
   与上面两条都不完全一致——文档漂了。

还有一处**比"按书记忆方向"更严重**的问题，是本次一并要治的根：

`android/app/lib/src/reader_controller.dart:263-273` 的 `_persistSettings` 会把
阅读器里**当场切换的模式与方向写回全局 `reader_settings`**。也就是说：

> 我在 A 书里按了一下"双页"，B 书下次打开也变成双页。全局默认被一次单本操作污染了。

里程碑决定的「系列覆盖 → 全局设置」两级模型，正好要求模式与方向**不再有每本书的记忆**、
且阅读器内的切换**不再改写全局**（要么写当前系列的覆盖，要么只作用于本次会话，见下）。

改成本里程碑的规则后，`reader_position.mode/direction` 不再参与决策。于是：

- **历史行里的 mode/direction 怎么办？** 三条路：
  1. **（推荐）列保留、继续写、但打开时不再读它做决策。** 旧数据一个字节不动，
     代价是：曾经手工把某本书设成 RTL 的用户，下次打开会回到系列覆盖/全局默认。
  2. 迁移时把这两列清空或改成哨兵值。**不建议**：为了 UI 决策去改写用户的历史记录，
     而且列一旦清空，"将来想恢复按书记忆"就永久失去了依据。
  3. 保留旧规则。这与里程碑决定冲突。
- **阅读器内的模式/方向切换写到哪里？** 三个选项：
  - **（推荐）写当前系列的覆盖**（`reader_override:[serverId,seriesId]`），
    并提示"已把此系列设为双页"。这符合"系列覆盖 → 全局"的两级模型，
    也满足里程碑"不按本书记忆"的要求。
  - 只作用于本次会话（关书即弃）。用户会抱怨"改了没用"。
  - 继续写全局（现状）。就是上面那个污染问题。
- **系列覆盖键怎么写？** 键为 `reader_override:[serverId,seriesId]`，值是
  `{"mode":"double","direction":"rtl"}`；缺字段表示该维度继续跟随全局。

## 4. 失败模式与恢复方案

### 4.1 影响面（先说结论：比 v9 小得多）

- v10 **只做 `ALTER TABLE ADD COLUMN`**，不重建表、不删列、不搬数据。
- 迁移只碰 `reader_position` 一张表。
- **不碰** `downloads` / `download_pages`。v9 是"唯一一条失败模式是丢掉用户记账的迁移"
  （`schema.rs:19-20`），v10 不属于这一类。
- 每本书最多丢一行显示状态，即"这一本从上次停的地方回到页顶"。

### 4.2 已知的两个粗糙处（本次不修，记录在案）

1. **`migrate()` 没有事务包裹。** 若在 ALTER 之后、写 `user_version` 之前进程被杀，
   下次打开会**重跑**整条链。因为每一步都是 `IF NOT EXISTS` 或 `table_has_column` 守卫，
   重跑是幂等的——但这是"靠守卫幂等"而不是"靠事务原子"，属于既存设计而非本次引入。
   本里程碑不改它（改了要重新验证全部历史迁移），但值得单独立项。
2. **迁移前没有自动备份。** 现在也没有。是否要加，见下面第 5 节。

### 4.3 恢复步骤（按场景）

**场景 A：迁移后 App 打不开 / 崩溃在打开数据库。**

```
adb shell run-as dev.sakurasep.comic ls -l files/       # 注意：库在 app_flutter/ 下
adb shell run-as dev.sakurasep.comic cp app_flutter/comic.sqlite /sdcard/  # 取证
```
然后按 B 的方案二回滚。

**场景 B：只回滚代码（不动数据）。**
v10 库被 v9 代码打开时，`user_version`（10）≠ `SCHEMA_VERSION`（9），于是 `migrate()`
会重新跑一遍全部 DDL：所有 `CREATE TABLE IF NOT EXISTS` 不动现存表，
所有 `table_has_column` 守卫跳过已存在列，最后把 `user_version` 写回 **9**。
净效果：数据不变，多出来的 `page_offset_ratio` 列被旧代码无视。**这是首选恢复方式。**

注意：仓库当前有 **65 个用户既有改动**（见 `docs/milestone1-execution-log.md`），
所以"回滚"必须是**按文件回滚本次改动的几个文件**，`git reset --hard` /
`git checkout .` 绝对不能用——那会连带你自己的改动一起丢掉。

**场景 C：重建镜像库（最后手段）。**
库路径 `/data/user/0/dev.sakurasep.comic/app_flutter/comic.sqlite`。这个库按设计是
"可从服务器重建的镜像"（`docs/database-schema.md:10`），删掉重开即从零同步。
**代价**：`downloads` / `download_pages` 里的记账会全部消失。页文件本身还在磁盘上
（它们的路径就存在库里，见 `store/cache.rs:243`），但 App 不再认识它们，
表现为"下载列表空了、空间却被占着"。所以场景 C 之前先把库拷出来留档。

## 5. 请确认的三件事

1. **第 3.3 节的三条路选哪条？** 推荐路线 1（列保留、不再读）。若选 2，请说明是否接受
   永久失去"按书记忆方向"的依据。
2. **是否需要在迁移前做一次数据库文件备份？** 我的判断是**本次不必**：v10 是纯加列，
   失败不会丢记账，而备份逻辑本身是新代码 + 新失败模式（写失败、空间不足、留垃圾文件）。
   若你认为"迁移前一律备份"应成为项目规矩，我按规矩做。
3. **`docs/database-schema.md` 当前自述 v7、代码已是 v9** —— 是否授权我在实施 v10 时
   一并补齐 v8/v9/v10 三节？

## 6. 实施与验证计划（确认后执行）

1. 改 `schema.rs`（版本号 + DDL + `V10_ALTER_STATEMENTS` + 链）、`position.rs`、
   两处 `save` 调用点、`resolve_direction` 的调用点。
2. 新增测试：
   - `a_v9_reader_position_row_survives_the_v10_migration_untouched`
     （用纯 v9 DDL 建库 → 插一行 → `migrate` → 断言行原样存活、新列为 NULL）；
   - `a_migrated_v9_reader_position_has_the_fresh_shape`
     （`pragma_table_info` 逐列对比 CREATE 与 ALTER 两条路径收敛）；
   - 条漫偏移往返：`save(page, ratio)` → `get` → 比例一致；旧行 `get` → `None`。
3. 跑 `cargo fmt --check`、`cargo test --lib store::`、`cargo test --lib reader`、
   `cargo clippy --all-targets -- -D warnings`，并重新生成 FRB 绑定后跑
   `bash scripts/check_frb_drift.sh` 与 `bash scripts/verify.sh --skip-swift`。
4. 只在你确认后才执行第 1 步。在此之前，P2 的其余部分（查询 + 偏好）可以先做，
   因为它们不碰数据库形状。
