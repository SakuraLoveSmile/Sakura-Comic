# 离线存储

## Cache 与 Offline Download 分离

| 类型 | 自动清理 | 用户主动 |
| --- | ---: | ---: |
| Thumbnail Cache | 是 | 否 |
| Page Cache | 是 | 否 |
| Prefetch Cache | 是 | 否 |
| Download Temp（`.part`） | 是 | 否 |
| Offline Download | 否 | 是 |

磁盘结构（两者都从数据库文件的位置派生，`App::cache_root()` 与
`DownloadRoot::for_db()` 是同一段代码里的兄弟）：

```text
<数据库所在目录>/
├── comic.sqlite
├── cache/                 # LRU 可以删掉这里的任何东西
│   ├── thumbnails/        # 封面文件（本地路径记录在 SQLite `thumbnails` 表）
│   ├── pages/             # 读者真正显示过的页（kind='page'）
│   └── prefetch/          # 预取来但还没看过的页（kind='prefetch'）
└── downloads/             # 只有用户能删
    └── {serverId}/
        └── {bookId}/
            ├── manifest.json
            ├── 0001.png
            └── 0002.png
```

**为什么是兄弟而不是 cache 的一个 tier**：`PageCache` 只能通过 `DiskCache` 拼路径，
而 `DiskCache` 的根就是 `cache/`。所以淘汰、按层清、按前缀清、开书清扫——**没有一处
需要"记得跳过下载"**，它们根本说不出下载树里的路径。`DownloadRoot::at()` 还会在构造时
拒绝落在 cache 根之下，所以这条性质不是纪律，是构造不出来就报错。

Stage 8 留在账本里的那道围栏还在：`store::cache::protected_paths` 把
`downloads.manifest_path`、`download_pages.file_path` 与账本里 `kind='download'` 的行
UNION 起来，淘汰、`delete_of_kind`、按前缀清书、开书清扫四处都跳过它们。
但它是**围栏而不是机制**：下载既不写 `cache_entries` 行，也不住在 `cache/` 里，
今天没有任何生产路径会命中它。留着它是因为"偏又把下载文件停进 pages/"这一动作
仍然可能有人做，而那一次的代价是用户的书架被清扫删掉。

`kind='download'` 也**不进账本**，这条不是风格选择而是修 bug：
`evict_to_budget_except` 用 `total_bytes`（含所有 kind）算 `used`，却用
`evictable_order`（排除 `download`）走候选。一本 400 页的下载若记了账本行，
`used > budget` 就**永久成立而候选集为空**，此后每一次缓存写都会为了追一个永远追不上的
数字把其余页面全删掉。所以 `download_pages` 是下载字节的唯一事实源，
`CacheStatsDto.download_bytes` 也从它求和。

Stage 8 的三条淘汰次序，都写进 `store/cache.rs::evictable_order`：

1. `kind='download'` 永不进候选；
2. `kind='prefetch'`（没被看过）先于 `kind='page'`（被看过）淘汰，**与新旧无关**：
   一页刚预取到的字节不如一小时前读过的一页值钱；
3. 同 kind 内按 `last_access`，再按 `key` 定序保证可重放。

另有一条反直觉但实测必要的规则：**触发淘汰的那一条本身不可淘汰**
（`evict_to_budget_except`）。`last_access` 精度到毫秒，预取与显示常落在同一毫秒，
平局按 key 排序会把刚写下的那页选为受害者，读者于是转身再下一遍——
40 MiB 池装 24 MiB 的 4K 页时实测每页 2 次请求。

账实对账 `PageCache::reconcile`（开书时跑一次）：幽灵行、孤儿文件、`.part` 残片、
字节数不符、kind 与所在目录不符——分歧时以磁盘为准，因为磁盘是证人。
下载树另有一套对账（`downloads::recover::sweep`），规则相同但**权力不同**，见下。

内存层（Rust `reader/memory.rs`、Swift `ByteBudgetCache`）是**字节预算**的 LRU：
峰值恒不超预算，单项超过整个预算只拒绝不驱逐，预取页落盘的同时驻留内存，
所以磁盘被淘汰的预取页可以从内存重新落盘而不重下。预算由 `window.json` 算出。

## Download Manifest（不打包 ZIP）

```json
{
  "serverId": "s1",
  "bookId": "0Q9FQVFC4TTJQ",
  "pagesCount": 120,
  "downloadedAt": "2026-08-30T04:52:00Z",
  "remoteLastModified": "2024-05-11T18:07:33Z",
  "pages": [
    { "number": 1, "fileName": "0001.png", "mediaType": "image/png",
      "sizeBytes": 19570, "width": 520, "height": 720 }
  ]
}
```

字段与命名由 `specs/contracts/fixtures/downloads/manifest.json` 与 `layout.json` 钉住，
两端加载同一份。三条值得单独说：

* `serverId`/`bookId` 存**原值**而不是目录的 sanitised 名字——`safe_key` 撞车时
  这是唯一还能说清"这本到底是哪本"的地方；
* `pagesCount` 是书的总页数，`pages` 只列已经在盘上的页。**部分下载才是这份文件
  平时的样子**（契约里的例子就故意少一页），边下边读靠的就是这个差；
* 不逐页重写。数据库本就逐页提交，逐页重写清单是 O(n) 写放大换不到一点额外耐久性，
  而目录列举已经证明了什么在这儿。写在入队、书籍终态转换、以及任何一次愈合之后。

优点：断点续传 / 单页重试 / 边下边读 / 无需二次解压 / 易于删除 / 易于完整性检查。

## 队列：状态、泵、失败

Download Manager 状态：Waiting / Downloading / Paused / Completed / Failed，
并显示 Downloaded Pages / Total Pages。页级状态只有 `pending / complete / failed`——
**没有"下载中"的页**：一次写入被打断的证据是它的 `.part` 文件，再造一个内存态标记
只是多一个需要同步的真相。

三件事决定这张表不是文档而是约束：

1. **迁移表被运行期读取**（`queue.rs` 用 `include_str!` 把
   `specs/contracts/fixtures/downloads/{states,errors}.json` 编进库里）。
   每一次状态写都要过 `transition_allowed(from,to,actor)`，
   而写本身是乐观的 `UPDATE ... WHERE state = <期望>`：
   用户按暂停时不需要信号、锁或取消标志——泵的下一次写改动 0 行，它就停了。
2. **`pages_done`/`bytes_done` 是派生的**，全仓库没有一处 `+= 1`：每次落地都在同一个
   事务里从 `download_pages` 重算。一条丢掉的行 otherwise 会让这本书永远差一页完成。
3. **暂停是粘的，完成对泵是粘的、对清扫不粘**。`settle_state` 的
   `SettleMode::{Pass,Sweep}` 就是这条区别：只有刚读过磁盘的一方有权把
   `completed` 收回 `waiting`，否则一本文件坏掉的离线书会永远挂着"已完成"，
   而 completed 的书不是队列该跑的——再也修不好。

`download_pump` 是有界的一步，沿用 `sse_poll`/`reader_tick` 的"停放 + 轮询"惯例：
核心不 spawn 任何常驻任务（frb 的 runtime 是**每次调用新建再丢弃**的 current-thread，
`tokio::spawn` 的任务会随调用返回被取消，而 Rust 线程本来也活不过进程被杀）。
一次调用受三重上界：**页数**（4）、**字节**（32 MiB）、**墙钟**（1000 ms，每页开始前查，
一页都没成时允许越界一次以保证有进展）。页数是测试能精确说出的那个，
字节是 4K 大图书会失控的那个，墙钟是泵与 `reader_page` 共享进程时必须让出的那个。
`Ok(None)` = 另一个泵正持有这个数据库，与 `sse_poll` 同契约。

失败分类的关键一行：**"链路断了"和"这页坏了"不共用一个计数器**。
`linkDown`/`blocked`/`gone`/`throttled` 什么都不写、一页的尝试也不烧——
五小时隧道不该花掉那一页真正需要的三次重试；这与 Stage 6 的
`outbox::record_outcome`（`BlockedAuthentication` no-op）和
`sync::upload`（`Decision::Defer`）是同一策略在三处的表达。
`badPage`（5xx / 短读 / 容器走不通 / 小于地板）烧一次，`MAX_PAGE_ATTEMPTS=3` 后
该页 `failed`，**本书继续往下走**；一次泵内连坏 3 页就当成病了的服务器结束本趟，
所以垂死的服务器花 3 次尝试而不是每页 3 次。

## 清扫：磁盘是证人，但清扫的权力不同

缓存的清扫可以删掉任何它无法解释的东西；下载的清扫不行——那些文件是用户要的。
所以它的活是**让账本对上磁盘**，而不是把空间拿回来。两个方向因此值得读两遍：

* 没有行、但整个可用的文件 → **收养**。"行提交丢了而字节落地了"在写争用下是真事件
  （`store::configure` 的 `busy_timeout` 注释解释了它以前为什么常见），
  反过来删掉等于把用户可能在计量网络上花过的钱扔掉；
* 数据库没有行的书目录 → **只计数不动手**。它仍然可删：路径由 `(serverId,bookId)` 派生，
  而 `download_delete_all` 是一次明确的用户动作。

OWNERSHIP：整个程序里只有三处能删 `downloads/` 下的东西，每处都有 `OWNERSHIP:` 注释——
用户的删除；泵清理自己的 `.part` 与刚证明不是那一页的文件；清扫删掉走不通容器、
尺寸漂移、或页号超出书本体页数的文件。

中断形状的每一条都有指标，回归时能说出是哪一条：`stale_parts`、`ghost_rows`、
`corrupt`、`size_mismatch`、`adopted_files`、`counters_repaired`、
`manifests_rewritten`、`pages_removed`、`unowned_books`/`unowned_bytes`。
`freed_bytes` 沿用缓存清扫的口径：幽灵行的字节本来就不在盘上，算成"释放"会重复计数。

清扫跑在**每个进程每个数据库一次**（`sweep_once`），调用点是 `download_pump` 的
第一步与 `download_list`——不是"有人显式要求"。一个没有生产调用点的恢复路径，
和一条不存在的恢复路径，看起来一模一样。

## 服务端删了这本书，怎么办

**下载留下**。`prune::delete_book` 不再触碰 `downloads`/`download_pages`：镜像清扫
靠"这一轮没看到它"推断远端删除，而 Stage 5 自己的结论是这种推断证据很弱
（offset 分页就能造成），被删的又是无法从服务器重新推导的东西。
`store::delete_server_mirror` 同样不动这两张表——断开一台服务器是关于连接的动作，
不是关于书架的；删掉已下载的书另有 `download_delete`/`download_delete_all`。
UI 上这本书标成"已失效"（`DownloadBookDto.stale`：书行没了，或
`books.last_modified` 已经跑过下载时记下的那个时间），本机这份照样能读。

`specs/contracts/delete-propagation/README.md` 里原先把这两张表列进级联，
Stage 9 一并改掉了——那是两端共读的契约，不是 Rust 的私事。

## 读者加载优先级

```text
Offline Download  →  Page Cache  →  Network
```

一个插入点：`App::reader_page_path`（同步、不碰网络，UI 先画它）先问
`downloads::recover::usable_page`——行说 `complete` **且** 文件在 **且**
`integrity::quick_check_file` 按行里记的字节数通过；任一不符就**顺手写下愈合**
（行回 `pending`、坏文件删掉），然后落到 Page Cache。
`reader_page` 第一步就调 `reader_page_path`，所以显示路径与取页路径共用同一条优先级。
预取也算已下载的页为"暖"（`prefetch_warm_set`），否则它会把用户已经付过的每一页
重新排一遍，再往缓存层写第二份。

下载页**不** `touch` 账本、**不**建 LRU 行：它不是缓存状态，记了会让缓存的淘汰统计
开始对用户拥有的字节撒谎。

## 存储统计

`download_storage(free_volume_bytes)` 同时给**派生的**（SQL 求和）与**实测的**
（目录走一遍）两组数字，两者的差就是清扫还没来得及收的残片——
沿用 `total_bytes_fast` 与 `total_bytes` 的分工，实测的那一组只在用户点开的这次调用里走。

剩余空间由平台报，核心从不自己猜（`Cargo.toml` 里没有 `libc`/`nix`，
Android 的 scoped storage 下自己猜还会猜错）：
Android 侧 `StatFs(filesDir)`，Apple 侧 `volumeAvailableCapacityForImportantUsageKey`，
**0 表示"平台不说"**，规则是不对称的：不说可以继续一本已经在跑的书，
但不能开新书——就像链路类型未知时一样。链路类型问的是
`ConnectivityManager.isActiveNetworkMetered()` 而不是 `transport == WIFI`：
模拟器答 ETHERNET，用 transport 判定会让所有下载永远卡住，看起来像核心的 bug。
