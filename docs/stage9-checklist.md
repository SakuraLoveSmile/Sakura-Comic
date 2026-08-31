# Stage 9 验收清单 — 离线下载（Full Mobile v1）

**阶段目标**：实现真正独立于 Cache 的离线阅读系统。Download Manager 支持整书下载 /
暂停 / 恢复 / Retry / 删除 / 下载队列 / 下载进度 / 存储空间统计 / 失败恢复；文件结构
`downloads/{serverId}/{bookId}/manifest.json + 0001.jpg …`，**不打包 ZIP**；
Cache 可以自动删，Offline Download 只能由用户删；读者优先级
`Offline Download → Page Cache → Network`；断网仍能开 App、逛媒体库、看已缓存封面、
找到已下载的书、完整阅读、存本地进度；恢复网络后 `pending_mutations` 自动上传。

**共享契约**：`specs/contracts/fixtures/downloads/{states,errors,pump,layout,manifest}.json`。
前两份是**运行期读取**的（`include_str!` 编进库，因为 `specs/` 不在 APK 里）。

**门禁（2026-08-30 实跑，全部为当前树的结果）**

| 门禁 | 结果 |
| --- | --- |
| `scripts/verify.sh` | **ALL GREEN**：cargo fmt / clippy `-D warnings` / **352** 个单元测试 + 14 个集成测试 / `cargo ndk check --features frb` / frb 胶水无漂移 / **219** 个 Swift（Apple 侧本轮未改，见"尚未验证"）/ **75** 个 Flutter |
| `scripts/e2e_stage9.sh` | **110 项检查全绿**（loopback，四个 fixture 服务器） |
| `scripts/e2e_stage9_device.sh` | **47 项检查全绿**（API 35 AVD `-gpu host`，真开关射频） |

## 语义：先写契约，再写两端

| 契约 | 钉住的东西 | 反例（钉不住会怎样） |
| --- | --- | --- |
| `states.json` | 书 5 态 / 页 3 态的**全部**合法迁移与 `illegal` 反例，且区分 actor | 泵能"顺手恢复"用户的暂停；完成的 book 被某个 pass 重新打开再下一遍 |
| `errors.json` | 哪个信号属于"这页坏了"、哪个属于"链路断了"，**只有前者烧尝试** | 五小时隧道花掉那一页真正需要的三次重试；或反过来把坏页当链路问题无限重试 |
| `pump.json` | 15 例：队列 + 三重上界 + 链路 + 读者位置 → 精确页序与停止原因 | 计量网络上自动开跑；未知链路开出新书；一页超预算就永远下不完 |
| `layout.json` | `%04d` 补齐、扩展名取自**嗅探**、`safe_key` 目录名、`.part` 后缀、downloads 是 cache 的**兄弟** | 两端写出互不可读的树；下载被写进 `cache/pages/` 从而可被清扫 |
| `manifest.json` | 清单字段逐字 + 一个**故意部分完成**的例子 | `pagesCount` 与 `pages.len()` 混为一谈，边下边读失去依据 |

反空转断言：`the_allowed_actors_per_pair_are_exactly_the_ones_the_table_lists` 比较的是
**允许的 actor 全集**，不是"列出来的那几个允许"——后者对多开一扇门完全无感。
`the_contract_cases_are_distinguishable_from_each_other` 要求 drained/budget/bytes/
linkBlocked/lowSpace/parked/idle 每一个停止原因都有用例，缺一个就红。

## 结构（目标 → 落地）

| 项 | 位置（Rust） | 状态 |
| --- | --- | --- |
| 下载树 | `downloads/manifest.rs::DownloadRoot`，`<db 目录>/downloads/{safeKey(server)}/{safeKey(book)}/` | ✅ 与 `cache/` 兄弟，构造期拒绝落在 cache 之下 |
| 页文件 | `{0001..}.png`，扩展名来自 `integrity::Format` 嗅探 | ✅ 逐页 rename 落地，`.part` 暂存 + `sync_all` |
| 清单 | `manifest.rs`，字段与 `docs/offline-storage.md` 逐字一致 | ✅ 不逐页重写（入队 / 终态 / 愈合后写） |
| 队列 | `downloads/store.rs` + `queue.rs`（纯函数，读契约） | ✅ 状态全在 SQLite，暂停/恢复/重试都是 `UPDATE` |
| 泵 | `downloads/engine.rs::run_pass` + `App::download_pump` | ✅ 三重上界（4 页 / 32 MiB / 1000 ms），`Ok(None)` = 别的泵在持有 |
| 失败恢复 | `queue::classify` + `recover::sweep` | ✅ 链路类不写不烧；坏页烧一次并继续本书 |
| 进度 | 复用 Stage 6 outbox（`reader_turn` → `pending_mutations`） | ✅ 断网存本地，复网自动上传（服务端 journal 为证） |
| 读者优先级 | `App::reader_page_path` 先问 `recover::usable_page` | ✅ 下载 → 缓存 → 网络，一处生效两条路径 |
| 隔离 | 下载**不写** `cache_entries`；`prefetch_warm_set` 视已下载为暖 | ✅ 见缺陷 22 |

**Android 只拿到本地文件路径这条规则没破**：新增 11 个 FFI 入口里只有
`download_pump` 能发请求，其余全是 SQLite 读写与目录删除；`reader_page*` 仍然返回
绝对路径字符串。

## 三条不可让的不变量（以及它们怎么被钉住）

1. **任何自动清理都删不掉离线下载**——是**结构**而不是纪律：`PageCache` 只能通过
   rooted 在 `cache/` 的 `DiskCache` 拼路径，说不出下载树里的路径；下载也不在 LRU 账本里。
   `scripts/e2e_stage9.sh` 的 `survives-everything` 用四次攻击（预算=1、`clear_prefetch`、
   `clear_tier(page)`、`reconcile`、镜像清扫、新进程）**逐条**断言文件数不变。
   变异检查：把 `prune::delete_book` 里那两条 `DELETE` 放回去 →
   `a_download_survives_every_automatic_cleanup_and_dies_only_by_a_user_gesture` 变红；
   把两张表放回 `delete_server_mirror` → 服务器那条独立变红。
2. **磁盘是证人，但清扫的权力不同**：缓存清扫能删它无法解释的东西，下载清扫不能。
   没有行的可用文件**收养**而不是删掉（"行提交丢了而字节落地"在写争用下是真事件）；
   数据库没有行的目录**只计数不动手**，仍可由 `download_delete_all` 删。
3. **一次链路故障不许花掉任何一页的重试**：`linkDown`/`blocked`/`gone`/`throttled`
   什么都不写。设备腿把它测成了最硬的一条：计量链路上**服务端一页请求都没收到**
   （`the server was asked for nothing at all (0)`），因为队列压根没开始。

## 蜂窝与 Wi-Fi（真机测出来的三种状态）

| 射频状态 | `linkClass` | 队列行为（设备实测） |
| --- | --- | --- |
| Wi-Fi 关、数据开 | `metered` | 拒绝开跑：`linkBlocked`、served=0、diskFiles=0、服务端 0 次读取 |
| 同上 + 用户点"用蜂窝下载" | `metered` | 60 页 15 趟下完，服务端正好 60 次读取，53 页/秒 |
| Wi-Fi 连上 `AndroidWifi`、数据关 | `unmetered` | 无需任何同意自动推进到 completed |
| 全关 | `unknown` | 可读已下载的整本（60 页全部来自 `downloads/`），服务端 0 次读取 |

问题问的是 `ConnectivityManager.isActiveNetworkMetered()`，不是 `transport == WIFI`。
两个方向都踩过：**只 `svc wifi enable` 时模拟器没有任何已关联网络**，
`activeNetwork == null` → `unknown`（不是 unmetered），所以设备腿必须
`cmd wifi connect-network AndroidWifi open`；而 AVD 的默认网络是 CELLULAR →
`metered`，所以"默认仅 Wi-Fi 自动推进"在模拟器上恰恰**不能**靠默认状态验证。

## 中断、断网与复网（设备腿实测）

| 场景 | 实测 |
| --- | --- |
| 真 `am force-stop` 打断一本正在下的书 | 死前已提交 4 页；第二次启动（`mode=resume`，**不重新 enqueue**）从第 5 页继续，恰好取回剩下的 56 页，completed、60 个文件、0 个 `.part` |
| 飞行模式下整本读完 | 60 页全部命中 `downloads/` 树，0 页失败，进程存活，服务端页读取日志**零增长** |
| 飞行模式下翻页存进度 | `position_saved=3`，`pending_mutations` 排队 1 条而不是丢掉 |
| 恢复网络 | 那条写自动上传，`pending_after=0`，**服务端 journal 里出现了带 `"page":3` 的 PATCH** |
| 断网整本（loopback） | 同一件事在 120 页的书上再测一遍（`served_from_downloads=120`） |

## 回环验收里几条"两个证人"的断言

- `enqueue-pump`：rows / 目录 / manifest **三处**字节数必须相等（7,805,760），
  文件数 120，30 趟 × 4 页，服务端读取 120 且**是 120 个不同页**。
- `rotten-repair`：`--truncate-every 3` 下 40 页坏掉、每页正好 3 次尝试、其余 80 页照常；
  换健康服务器后**重试恰好花 40 次请求**（脚本与服务端 journal 各说一遍）。
- `interrupted-write`：五种中断形状各自单独计数
  （`stale_parts=1 / ghost_rows=1 / adopted_files=1 / corrupt=1 / size_mismatch=1`）。
  坏文件必须**长度恰好等于声明值**，否则尺寸检查先拦住它，容器走那条分支就成了空断言。
- 文件系统由 shell 自己 `find`/`stat` 复核，不信核心的报告：文件名恰为
  `0001.png … 0120.png`，完成后 `find -name '*.part' | wc -l == 0`，
  `du` 等于 `bytes_disk`，`manifest.json` 的 `pagesCount` 等于列举数。
- 账本对立面：`SELECT COUNT(*) FROM cache_entries WHERE kind='download'` 必须为 0。

## 过程中被证据逼出来的真实缺陷（编号接 Stage 8 的 13）

**14 — `set_state` 把"这一行存在"当成了"这次写发生了"。** 乐观 UPDATE 改动 0 行时它返回
`Ok(get(...).is_some())`，于是泵在用户暂停之后仍然"成功" settle，把 paused 洗成
completed。暂停是粘的这条规则，在代码里其实是失效的。修成 `Ok(moved > 0)`，
测试 `a_pause_that_lands_mid_pass_wins_the_write` 直接钉住（变异检查：改回旧写法必红）。

**15 — "要不要认领这本书"和"这本书是否已经开始"被当成同一件事。** `claims: !started`
让第二趟泵跳过认领写入，而 `land_page` 只在 `state == downloading` 时提交——于是**任何
已经有一页在盘上的书，此后每一趟都落不下一页**。是引擎测试里 `(2, 0, 0)` 这个
"第二趟下了 0 页"把它暴露出来的。分开成 `claims = state == waiting`，并在文档里写清
这两个问题不同。

**16 — 剩余空间/链路未知时，"已经开始了"用的是瞬态 `downloading`。** 每趟结束都会
settle 回 `waiting`，所以那本"已经在跑"的书在下一趟眼里永远是新书：平台不报剩余空间的
设备上，下载恰好推进一趟就永久停住。改成"盘上有完成的页 = 已开始"，
`pump.json` 补了 `unknown-link-finishes-what-is-running` 一例钉住方向。

**17 — 恢复清扫没有生产调用点。** `recover::sweep` 写完了、单测全绿，但只有显式
`download_sweep` 会跑它——进程被杀之后留在盘上的 `.part` 和漂移的计数没人管。
这与 Stage 8 在 Swift 侧发现的 `PageCache.evictToBudget` 无调用点、
以及 iOS 没有内存压力回调，是同一类缺陷：**一条存在但从不被到达的恢复路径，
和一条不存在的路径在测试里长得一模一样。** 现在 `download_pump` 的第一步与
`download_list` 都会跑一次（每进程每库一次），并把修了几处回报在 `download_pump` 的
结果里（`repairs/partsSwept/adopted/ghostRows`）——不回报就等于无法区分"跑了但没事"
和"没跑"。测试 `the_first_pass_of_a_process_reconciles_the_tree` 断言第一趟修了 2 处、
第二趟修 0 处。

**18 — `completed` 对所有 actor 都粘，于是坏掉的离线副本永远修不好。**
`usable_page` 读到坏文件会把行愈合回 `pending`，但书还是 completed，而 completed 的书
不是队列该跑的：那本书将永远显示"已完成"，缺一页。修法不是放宽表，而是分清问题：
`settle_state` 新增 `SettleMode::{Pass, Sweep}`——**只有刚读过磁盘的一方**有权把
completed 收回 waiting；状态写入仍记为 `settle`。契约里加了 `healReopens` 一条规则。
（这是写设备腿的续传用例时撞上的：清扫把 `.jpg` 收养回来后 `land_page` 的换名分支
再也没有可达路径，顺着这条线才发现真正的问题在完成态的粘性上。）

**19 — Android 的两个新 MethodChannel handler 算出了值却没有 `result.success(...)`。**
`freeDisk` 与 `linkClass` 写成 Kotlin `when` 分支的表达式值，编译通过、类型也过，
但平台**永远不回复**：Dart 侧的 future 永不完成，下载在第一趟泵处静默卡死，
设备日志里只留下 `startState=waiting` 之后的一片空白。回环门禁结构上看不见它
（那是 Kotlin）。两处补 `result.success(...)`；另外把 `ReaderDevice` 的探测从
`Future.timeout` 改成**显式竞速 + 两侧都 cancel 看门狗**：一个永不回复的平台问题
必须降级成 `unknown`（这本来就是"平台不说"的合法答案），而不是变成停摆；
`timeout` 本身在 widget 测试里会留下一个越过 teardown 的 pending timer。

**20 — 对一本已在排队的书再点一次"下载"会抛 IllegalTransition。** `waiting → waiting`
不在表里。补上这条迁移，并让重新入队**保留 `position`**——多点一下按钮就把书挪到队尾，
是用户永不原谅的那种"聪明"。

**21 — 镜像清扫一直在吃用户的下载记账。** `prune::delete_book` 与
`delete_server_mirror` 都 `DELETE FROM downloads / download_pages`，而**从不删文件**：
行没了，文件留在 `cache/` 之外谁也扫不到，磁盘泄漏；更糟的是"这一轮没扫到"这个弱推断
有权销毁用户唯一不可恢复的数据。两条都改掉了，并同步改了
`specs/contracts/delete-propagation/README.md`（那是两端共读的契约，不是 Rust 私事）。
书没了本地这份仍可整本读，UI 标"已失效"（`stale`）。

**22 — `CacheStatsDto.download_bytes` 恒为 0。** 它读 `bytes_of_kind('download')`，
而那一 kind 从来没有生产写入者。改成从 `download_pages` 求和；这也顺带钉死了
"下载不进 LRU 账本"——真要写进去，`evict_to_budget_except` 会看到
`used > budget` 永久成立而候选集为空，此后每一次缓存写都在追一个永远追不上的数字。
`check "and no download ever entered the LRU ledger"` 与
`a_download_reports_its_bytes_without_entering_the_cache_ledger` 各测一遍。

**23 — fixture 服务器会为一本书发页，却对它本身返回 404。** 上传前的 Targeted Re-fetch
因此把整本书判成"远端已消失"（Stage 6 的 R1 规则，行为正确），复网腿于是只能证明
"行没了"而不是"行传上去了"。给服务器补了 `stress_book` DTO（`pagesCount`/几何取自同一个
`--stress` spec，两者不可能互相矛盾）。这条延续 Stage 5 立下的规矩：
**fixture 不许比真响应更宽松**——这里甚至是更不合格。

**24 — 我自己写的门禁差点用错"不同页计数"。** 累计去重数**不可相减**：第二轮读到同样
120 个不同页时 `after - before == 0`，看起来像"什么都没下"。改成按日志行窗口计
（`distinct_pages <label> <server>`），并要求每个阶段各自记录起始行号。
（同一条陷阱 Stage 8 已经写过一次，我又踩了一遍。）

**25 — 契约用例有一例是空的。** `attempts-exhausted-stops-queuing-that-page` 里被跳过的
页状态是 `failed`，于是"尝试次数达上限就不再排"这条过滤即使整条删掉用例仍然通过——
变异检查（删掉 attempts 过滤）当场证实。补了 `pending-but-out-of-attempts` 一例：
状态 `pending` 而 attempts 已到上限，这才是那条过滤器唯一能咬到的形状。

## 变异检查（每一条都被证明会红）

**Rust 25 项、Dart 3 项**，逐条注入 → 跑对应测试 → 还原 → 再跑全绿。清单：

| 注入 | 变红的测试 |
| --- | --- |
| `transition_allowed` 忽略 actor | 3（含 exact-set 那条） |
| 未知链路允许开新书 | 2 |
| 页数上界失效 | 2 |
| attempts 上限过滤删掉 | 1（**先补了 `pending-but-out-of-attempts` 用例才咬得住**，见缺陷 25） |
| `set_state` 把"行存在"当"写成功" | 1 |
| retry 连 complete 行一起重置 | 1 |
| park 不看状态 | 1 |
| 状态写不查契约表 | 1 |
| `ApiError::Network` 映射成坏页 | 1 |
| `land_page` 不复查书是否还被持有 | 1 |
| 同页兄弟文件不清理 | 1 |
| 终态不写 manifest | 1 |
| 连续坏页不结束本趟 | 1 |
| 清扫不收养 | 3 |
| 尺寸漂移不检 | 1 |
| `usable_page` 不愈合 | 2（单元 + facade 各一） |
| `usable_page` 跳过完整性 | 2 |
| 读者层次序调换成"缓存优先" | 2 —— 前提是**先在 `cache/pages/` 播一个不同长度的同名页**，否则调换顺序也能通过 |
| 预取不把已下载当暖页 | 1 |
| `prune::delete_book` 放回两条 DELETE | 1 |
| `delete_server_mirror` 放回两张表 | 1 |
| 恢复清扫没有调用点 | 1 |
| `settle_state` 忽略 `SettleMode` | 1 |
| v9 ALTER 链不接 | 2 |
| serde 改一个字段名 | 1 |
| Dart：暂停按钮发 delete / 一个回合只跑一趟 / `hasWork` 恒真 | 各 1 |

另有两处**不是**注入而是"写完立刻被自己的测试打死"的真 bug（缺陷 15、16）：
它们在被注入之前就以红测试的形式存在，所以不再计入上表。

## 与 spec 字面不一致之处（逐条列出）

1. **断点续传的粒度是"页"**，不是字节。`src/api` 全无 `Range:` 与流式 body，
   spec 列的四条好处（断点续传 / 单页重试 / 边下边读 / 文件校验）在页粒度上全部成立；
   半页恢复需要引入 Range 与内容一致性判断，本轮不做。
2. **不打包 ZIP** ✅ 按 spec；页名 `0001.png` 而非 `0001.jpg`：扩展名取自**字节嗅探**，
   spec 里的 `.jpg` 只是示例。
3. **存储空间统计里的"剩余空间"由平台报**，核心从不自己探测（无 `libc`/`nix` 依赖，
   Android scoped storage 下自探还会探错）；`0` = 平台不说 → 保守。
4. **App 退到后台泵就停**（下次前台自动接上）。系统级后台下载需要
   Android 前台服务 / WorkManager，明确不在本轮。
5. **Apple 侧未移植**：Rust 定的这些规则需要 KomgaKit 独立镜像一遍（与 Stage 8 同处理）。
6. 页级状态只有 `pending / complete / failed`，**没有"下载中"**：一次被打断的写入的证据
   是它的 `.part` 文件，再造一个内存态标记只是多一个需要同步的真相。
7. 队列驱动是"核心持队列 + UI 轮询泵"（用户选定）。核心不 spawn 任何常驻任务：
   frb 的 runtime 是每次调用新建再丢弃的 current-thread。

## 尚未验证（不写成已完成）

1. **真实 Komga 服务器上的整本下载 + 断流阅读**。脚本里有这一腿
   （`KOMGA_BASE_URL` + `KOMGA_API_KEY` + `KOMGA_BOOK_ID`，缺就跳过并说明），
   本轮**从未跑过**。命令：
   `KOMGA_BASE_URL=http://192.168.0.69:25600 KOMGA_API_KEY=… KOMGA_BOOK_ID=0Q9FQVFC4TTJQ scripts/e2e_stage9.sh`
   （那台服务器上最大的单本是 292 页 / 48 MB）。
2. **物理手机**。本轮只有 AVD；`svc data disable` 造出的"Wi-Fi 关、数据开"与真机上
   一张 SIM 的蜂窝网络不是一回事，`isActiveNetworkMetered()` 的真值分布也只有真机能给。
   `scripts/e2e_stage9_device.sh --device <phone-serial>`。
3. **Apple 侧的下载与 v9 迁移**：`apple/KomgaKit` 仍停在 schema 8、无下载表写入者、
   `Tier.fromKind` 仍把 `download` 折成 `.page`；tvOS 那条（`UIScreen.main.brightness`、
   `Slider`）也没修，见 Stage 8 清单。
4. **大书压力**：真库里最大单本 292 页，本轮合成书测到 120 页 / 7.8 MB；
   500+ 页 × 4K 的下载内存曲线仍未测（泵的字节上界是为此设的，但没在真数据上看过）。
5. **磁盘紧张路径**：`lowSpace` 的判断规则有单元测试与契约用例，
   但没在真的快满的卷上跑过一次（`free_bytes` 是平台报的，本轮只测了"报 0"与"报得很大"）。

## 顺带修掉的（不属本阶段）

- `docs/offline-storage.md` 里同一段"保护是结构而不是约定"**重复了两遍**，删掉一份；
  第 5 行"pages/ … plus offline downloads"这句与最终布局矛盾，改成事实。
- `integrity::Format` 补 `content_type()`：清单里的 `mediaType` 要写 `image/png`
  而不是 `png`，与服务器自己的措辞一致。
- **没有**清掉 `android/app/.frb-verify-backup.96075/`：那是 Stage 8 某次被中断的
  `verify.sh` 留下的构建产物备份（`.gitignore` 里明说"残留意味着跑被中断了，不是在制品"）。
  本轮的 `verify.sh` 跑完整并自己删掉了它的临时目录，所以这个旧目录确认无用——
  但它不是本轮创建的，删除留给用户决定。
- frb 代码生成对**同名类型**会"随机挑一个"（`PageRow`、`StoreError`、`Attempt`
  与既有模块重名）。核心不关心，但生成物关心：全部改名
  （`DownloadPageRow` / `QueueError` / `PageAttempt`）后重跑 codegen，
  只剩 Stage 6 就存在的 `Snapshot` 一条告警。

## 完成条件

Stage 9 的验收清单到这里，**Full Mobile v1** 的四段（Bootstrap / Reconcile / SSE /
Mutation Upload）加阅读、性能、离线，在 Android 一侧全部有真 HTTP、真进程死亡、
真射频断流的证据；Apple 一侧缺离线这一块（见"尚未验证"第 3 条）。
