# Stage 8 验收清单 — Reader 性能与缓存

阶段目标：**解决大图、大页数和长时间阅读场景下的性能问题**。Stage 7 让阅读器能用，
Stage 8 让它能被长期日常使用：内存不增长、快速翻页不打重复请求、缓存坏掉时能自愈。

共享契约：`specs/contracts/fixtures/reader/window.json`（新）——动态预取窗口的唯一
语义事实来源，Rust（`reader/window.rs`）与 Swift（`KomgaReader/WindowPlanner`）各自
加载同一文件，两端逐例断言。四个既有 reader 契约不变。

## 语义：先写契约，再写两端

| 契约 | 钉住的东西 | 反例（被明确禁止的偷懒解法） |
| --- | --- | --- |
| `window.json`（20 例 + 6 例 slot） | 内存 → 页成本 → 装得下几页 → 模式 → 字节上限 → 网络 → 是否稳定，这七步的**次序**；`decodeSlots` 的双端钳制 | 「把 2/1/12 当常量」：Stage 7 的占位值；「越大越好」：页数×页字节必须永远 ≤ 2×内存层，否则一页 4K 就是一次 OOM |
| 反空转断言 | 每个输入都至少有一对「只差这一个输入且结果不同」的用例；`direction` 反过来要求「只差方向的用例结果必须相同」 | 「读了但不用」的输入：五个命名输入里任何一个若被忽略，配对断言立刻失败 |
| `prefetch.json`（Stage 7，12 例） | 窗口次序、缓存页仍占名额、快翻时旧窗口作废但在途不砍 | 未改；其 `window` 规则文本改为指向 `window.json`，静态默认值降级为「没有设备档案时的兜底」 |

## 缓存结构（目标 → 落地）

| 项 | 位置 | 状态 |
| --- | --- | --- |
| `Cache/{thumbnails,pages,prefetch}/` 三层目录 | Rust `cache/mod.rs::TIERS`；Swift `DiskImageCache` | ✅ 三层真实创建并各自计数 |
| Memory Cache（字节预算 LRU） | Rust `reader/memory.rs`；Swift `KomgaReader/ByteBudgetCache` | ✅ 峰值恒 ≤ 预算；单项超预算只拒绝不驱逐；重插替换不重复计数 |
| Disk Cache + LRU | Rust `reader/cache.rs` + `store/cache.rs`；Swift `PageCache` | ✅ 记账在 `cache_entries`，命中 = 行在 + 文件在 + 完整性通过 |
| Cache Size Limit | `DEFAULT_BUDGET_BYTES`，UI 可下发覆盖；每次写入后 `enforce_budget` | ✅ 用免 stat 的 `SUM` 判热路径，全量对账只在 open 时扫一次 |
| Prefetch | `reader/prefetch.rs`（窗口）+ `reader/window.rs`（窗口大小从设备算） | ✅ 预取字节落 `prefetch/` 且驻留内存 |
| Cache Cleanup | `PageCache::reconcile`：`.part` 残片、幽灵行、孤儿文件、字节数对不上、kind 与目录不符 | ✅ 逐项计数，磁盘是证人、账本跟随 |
| 缓存损坏恢复 | `reader/integrity.rs`（PNG 逐 chunk CRC / JPEG 段与 EOI / GIF / WebP）+ 读时 head+tail 快检 | ✅ 截断/HTML 错误页被拒取、被丢弃、可重下；AVIF/HEIC/BMP/JXL 判为「看不懂但保留」，绝不当损坏删掉 |

## Android 图片链路（目标的两条硬规则）

```text
Komga → Rust 下载 → 磁盘缓存 → Flutter 本地文件 → 图像解码     ✅ 现状
Rust → FFI 字节数组 → Flutter                                    ⛔ 禁止
```

| 规则 | 由什么保证 |
| --- | --- |
| 页面/封面接口只回文件路径，不回字节 | `android/komga_core/tests/reader_architecture.rs`：扫描 `ffi/bridge.rs` 的函数签名，出现 `u8`/`Uint8List` 即失败 |
| `flutter_rust_bridge` 只出现在 `src/ffi/` | 同一测试遍历 `src/` 全部 `.rs`，非 ffi 目录下出现即失败 |
| UI 不自己发网络请求 | Dart 侧源码断言（`test/reader_test.dart`）：手写 reader 文件里不得出现 `Image.network` / `Image.memory` / `Uint8List`，且必须走 `Image.file` + `cacheWidth` |

## 预取窗口：五个输入怎么起作用

| 输入 | 规则 | 实测 |
| --- | --- | --- |
| 内存 | `clamp(RAM/8, 16MiB, 256MiB)` | 256MiB 层 → 1080p 页 25 个解码槽；32MiB 层的进程 RSS 比 256MiB 层低 75MB（229→154MB） |
| 页尺寸 | 层字节 ÷ 平均页字节，再取 1/4 作前瞻 | 同一档设备：2MiB 页 → 前看 8 跨、名额 26；24MiB 页 → 前看 2、名额 6 |
| 网络 | offline=0，weak=3/单并发，cellular=名额减半/并发 2，unknown 按受限算 | 弱网相位：in_flight=1、cap=3，服务器只收到 3 次页请求 |
| 阅读方向 | **不**改变窗口（窗口按阅读序跨页计）；契约用 ltr/rtl 成对用例钉死 | `rtl-webtoon-matches-its-ltr-twin` 与竖排版逐字段相等 |
| 设备性能 | 无档案时一律走保守值；快翻中（stable=false）窗口缩到当前跨 | 120 次跳翻：请求 120 = 去重后 120，中途名额从 13 降到 1 |

## 压力测试与验收（`scripts/e2e_stage8.sh`，70 项检查全绿）

每个相位是**独立进程**，脚本同时采样它的 RSS 与服务端日志里它带来的增量请求。

| 场景 | 实测 |
| --- | --- |
| 500+ 页漫画 | 520 页整本读完：520 次页请求（=去重后页数），清单 1 次，RSS 峰值 13MB，池 33.8MB ≤ 64MB；后 1/4 与前 1/4 每跨均耗 6367us vs 6620us（**不增长**） |
| 4K 大图 | 真 3840×2160（24,887,323 字节/页）：计划窗口 cap=1；显示路径逐页一次请求；同一本书同一池子，Stage 7 占位窗口 15 次、计划窗口 7 次 |
| 快速连续翻页 | 120 次跳翻：请求数 = 去重页数（无重复），服务器独立计数一致 |
| 长时间条漫滚动 | 300 次推进：暖页翻页 p50 153us / p95 182us / p99 200us；内存层峰值不超预算 |
| 弱网 | 服务器每请求延后 120ms：窗口 in_flight=1、cap=3，实际发出 3 次 |
| 断网 | 预热 21 页后指向不可达端口：页请求 0、清单请求 0，21 页全部来自磁盘 |
| Wi-Fi / 蜂窝切换 | wifi 13 > cellular 6 > weak 3 > offline 0；离线队列长度 0 |
| App 内存压力 | 2MiB 层塞 40 页：峰值 57240 ≤ 65536、驱逐发生；响应=**只交还 RAM**（预取层的文件与离线下载文件都留在磁盘上，见缺陷 12）|
| App 后台恢复 | 第二个进程恢复页码并从缓存读：读者自报 0 请求，服务器独立确认 0 增量 |
| 后台/前台 ×6（`--phase resume-loop`）| 一轮循环 = `onTrimMemory` 响应 + 重新上报设备（顺带跑清扫）+ 重新暖同一跨：服务端 **18 次读取 = 18 个不同页**，窗口填满之后的四次循环一个请求都不发 |
| 缓存损坏 | 服务器每 3 页截断一次：4 页被拒（原因可读）、8 页正常、0 个截断页进缓存、重试自止；读者计数与服务端日志一致（16） |
| 带 tEXt 的页（`padded-walk`）| 唯一一本页面带辅助 chunk 的书：平均页字节 **恰好 300000**、6 页 = 6 次请求 = 6 个不同页。缓存会拒收完整性走查判坏的页，所以这一档是缺陷 13 的端到端哨兵 |

## 走一遍真正对外的那张脸（`--phase facade`）

其余相位都是直接驱动 `ReaderLoader` / `PageCache`：对算法是对的层级，对产品是错的层级
——App 调的是 `App::reader_*`。`facade` 用同一批入口跑一遍，钉住只在接缝里才会坏的东西：

| 断言 | 结果 |
| --- | --- |
| 设备档案上报时**真的做了对账清扫** | 预埋的孤儿文件与 `.part` 残片都被清掉（`swept_freed_bytes=4`） |
| 预取落进 prefetch 层 | `prefetch_bytes=260192` |
| 预取字节同时驻留内存 | `memory_bytes=260192`（与磁盘同量，镜像真的发生） |
| 每次调用只取 `in_flight` 页 | `landed=4`，而窗口本可容 13 页 |
| **显示预取页会把它提升到 pages 层** | 目录文件数 `pages 2→3`、`prefetch 4→3`，返回路径落在 `.../cache/pages/` |
| 用户主动清理只丢猜来的字节 | 清掉 3 个预取页，`page_bytes_after_clear=195144` 全部保留 |
| 账本与磁盘一致（否则淘汰依据是假的） | `ledger_bytes` 与 `disk_bytes` 相差 ≤ 4KB |

这个相位还顺手抓到一个测试自己的错误假设：`App` 的缓存目录是**从数据库路径推导**的
（`<db 目录>/cache`），不接收外部传入的 cache 目录。对产品是合理的单一来源，对测试不是——
第一版把损坏埋在 `--cache` 指的目录里，于是清扫"什么也没找到"。

## 真机腿（`scripts/e2e_stage8_device.sh`，20 项检查全绿）

`--soak` 那一档专门回答「长时间使用」：240 跳、23 次 PSS 采样、期间持续注入
**递增严重度**的 trim-memory（`RUNNING_MODERATE → RUNNING_LOW → RUNNING_CRITICAL → COMPLETE → BACKGROUND`）。
结果 PSS 97,931 → 101,548 KB（峰值 102,052，即约 +3.7% 后趋稳）、122 次页读取里 1 次重复
（一次瞬时失败后的重试，不是窗口算错）、进程始终是同一个。
为什么是「递增」而不是「同一级别发五次」：Flutter 的 Android 嵌入层只在前向严重度**上升**时
才转发 `onTrimMemory`，五次相同的 `COMPLETE` 只会有一次回调 —— 断言次数等于要求操作系统
不承诺的东西，所以这里断言的是「回调到了、且每次之后屏幕上那页仍然可读」。

Android APK 现在能构建了（见下），于是本阶段最后两条只能在设备上取证的验收线有了真数据：
profile 构建装进 API 35 模拟器（`-gpu swift_shader_indirect`、4 GB RAM），
用一个路由（`/reader-stress`）驱动**真实的** ReaderScreen / ReaderController / FrbReaderApi /
ReaderDevice 读真 HTTP 回环服务器，脚本同时采样 `dumpsys meminfo` 与服务端页日志。

| 设备实测 | 数字 |
| --- | --- |
| 平台通道上报的物理内存 | **4,111,405,056 字节** —— `MainActivity.kt` 的 `totalMemory` 在设备上真的答了（此前无法编译验证的那块） |
| UI 是否落实了核心下发的预算 | `ImageCache.maximumSizeBytes = 268435456` == 计划的 memoryBudget；`maximumSize = 25` == decodeSlots |
| 160 次翻页期间的进程内存 | PSS 首采样 105,479 KB → 后 1/4 峰值 108,957 KB（**+3.3%，不随会话增长**） |
| 重复请求 | 服务端共 89 次页读取、89 个不同页号 —— **整场驱动式阅读里没有一页被服务两次** |
| 快翻时窗口是否收窄 | 中途上报 `cap=1`（开书时 settled 窗口是 13）—— 动态调整在硬件上被观测到 |
| 每页耗时（`-gpu host`）| 冷页 p50 58ms / p95 59ms；**暖页 p50 25ms / p95 36ms**；4K 暖页 p95 21ms |
| 200 倍重的页对内存的代价 | 4K 峰值 PSS 238,209 KB vs 小页 119,784 KB —— 有界倍数，不是无界 |
| **真·内存压力**（`am send-trim-memory COMPLETE`）| 平台回调到达（`events=1`）；4K 一档 **PSS 187,610 → 138,693 KB，交还 49 MB**；小页一档无可还时也如实报 236 KB 且不增长；两种情形下 `stillReadable=true` |
| **真·断网 / 切换**（`svc wifi disable && svc data disable`）| 来宾侧 `ping` 直接 `Network is unreachable`，即真的动了网络栈。读到手边、cache 边缘之后：**链路状态被推出 `offline`**、切无线之后服务端再没收到过任何一个请求（`requests after the cut: 0`）、进程不死、已缓存页继续可读 |
| **低内存设备档**（`--device-ram 1610612736`，即 1.5 GB）| 同一份构建报回 `memoryBudget=201,326,592`（192 MiB）、`decodeSlots=19`；对照 2.5 GB 档的 256 MiB / 25 槽 —— 「设备性能决定数量」在 Android 上是量出来的，不是推出来的 |

**冷页 1 秒之谜已经解开，而且答案不是「模拟器慢」那么含糊**：那 ~900ms 是
`-gpu swift_shader_indirect` 的软件光栅。同一份构建换 `-gpu host` 之后冷页 p95 从
1020ms 掉到 **59ms**、暖页 36ms。脚本现在默认 `-gpu host`，头部注释里也写死了这条，
免得下一次又拿软件光栅的毫秒去当设备结论。

一条踩过的坑：`-memory 1536` **不会**改变 `ActivityManager.totalMem`（那样的模拟器仍
旧上报 2,592,759,808 字节），所以「小内存设备档」必须由 `--device-ram` 强制注入才测得到
计划的收缩；`-memory` 能改的是**真实稀缺度**——同样 120 次翻页，稀缺设备暖页 p95 从
~100ms 涨到 354ms，这本身就是「设备性能影响体验」的正向证据。

两个测量前提写在这里，因为它们会让所有数字失真：模拟器必须 `svc power stayon true`
并且保持唤醒——屏幕一熄，应用被推进 `paused()`（清空 live 图片）、光栅器停摆，
测出来的就是一个空闲应用而不是阅读中的应用（这也是 gfxinfo 一直报 0 帧的直接原因）。

**这台仪器不能证明什么**。软件光栅 + NAT 回环，绝对毫秒远差于真手机；
`dumpsys gfxinfo <pkg>` 在 API 35 的 Flutter 构建上恒报 0 帧（`--package` 有数，
但 reset 之后仍为 0），所以帧证据来自「每翻页都穿过一个已绘制帧」的应用自测墙钟。

冷页 1020ms 这个数**不属于阅读管线**，这一点是对照出来的：同一份核心代码、同一个
回环服务器，主机上 520 页整本读下来每跨均耗 6.4–7.1 ms，模拟器上同一动作冷页 1020ms、
暖页 107ms。差出来的 150 倍全在模拟器这一侧（合成/光栅/来宾网络），不在两端共用的
那条路径里。为证实这一点顺手做了两项改进（预取写入合并成一个事务、`KomgaClient`
进程内连接复用），它们在原理上都是对的、也留下了测试，但**在这台仪器上没能动到那 1 秒**
——所以本报告不声称它们治好了冷页；真机上这 1 秒是否根本不在于是仍需一次设备复测。

## 真实 Komga 腿（2026-08-30 第一次跑通）

密钥到手之后 `--live` 不再是跳过项。局域网那台 Komga（`192.168.0.69:25600`）上最大的一本真书是
**292 页 / 48 MB 的 JPEG**（`0Q9FQVFC4TTJQ`，DIVINA / zip 容器），不是合成的 520 页——于是
`stage8_smoke` 的页数下限改成参数 `--min-pages`（回环仍用 500，live 腿用 100）。搬过去的是那条
**与规模无关的不变量**，不是「500」这个数。

| 实测 | 数字 |
| --- | --- |
| 整本读完 | 292 页全部显示，每页路径逐个断言存在 |
| 页请求 | **292 次 = 292 个不同页，零重复** |
| 清单请求 | 1 次（整本一次镜像） |
| 内存层峰值 | 1,974,940 字节 |

仍未被真实数据覆盖的是「500+ 页」这一档本身：真实库里没有那么大的单本，它仍只由合成书证明。

## 过程中被证据逼出来的真实缺陷（编号按发现顺序，本文件只展开其中几项）

1. **刚写入的条目会被自己触发的驱逐删掉**：`last_access` 只到毫秒，预取与显示常落在同一毫秒，
   平局按 key 排序 → 池子只装得下一点五页时，刚缓存的页立刻成为受害者，读者转而重新下载它。
   4K 相位实测每页 2 次请求。修法是 `evict_to_budget_except`：触发驱逐的那一条正是不可驱逐的那一条。
2. **内存层里的字节够不着**：驱逐同时删行和删文件，而 `lookup` 只在「有行、无文件」时才回看内存。
   于是驻留字节变成谁也拿不到的死重，而页仍在走网络。现在无行也查内存，命中就重新落盘。
3. **`cached_pages` 每页一次查询 + 一次 stat**：500 页的书每翻一跨要 stat 500 次。改为一次
   `LIKE` 前缀查询（不校验文件），校验只在真正交付路径 `lookup` 上做——预取以为暖、实际冷的页
   会在被显示时自愈，这个取舍写进了 `store/cache.rs::cached_keys` 的注释。
12. **内存压力响应删掉了磁盘上的预取层**：只有真机那一档（`--lifecycle`）抓到了它，回环的
   每一个相位都是绿的。证据链：5 次 HOME/回前台让服务端读了 **20 次页、只有 4 个不同页**；
   账本里 `p12..p15` 的行和字节数一直没变，而那 4 个文件的 mtime 恰好跳到手动触发 resume 的
   那一刻；logcat 里 `onTrimMemory` 就落在两次设备上报之间。错在两处：**文件不占 RAM**，
   删它对内存毫无帮助；而 Android 是在**普通退到后台**时就发这个信号，不是等到濒危才发。
   于是每按一次 HOME 回来，都要把刚预取好的整窗重新下一遍。
   修法是 `App::reader_release_prefetch`：只交还内存镜像，层留在磁盘上。回环新增
   `--phase resume-loop` 重放这一循环——改动前它会失败（变异检查：18 次读取 / 14 个不同页），
   改动后 18 次读取全不重复，窗口填满之后的 4 次循环一个请求都不发。
   iOS 侧不存在这个缺陷，因为它**根本没有内存压力响应**（见「尚未验证」）。
13. **fixture 比自己的检查器更宽松**：`encode_rgb_png_padded` 把 `tEXt` 写在 `IHDR`
   之前，而 `inspect_png` 对任何排在 IHDR 前面的 chunk 都判「结构非法」—— 也就是说
   只要 `--stress` 里 PAD>0，整本书会被一页一页拒收。没人看见它，有两层原因：所有应力
   书形态用的都是 `PAD=0`；而唯一那个名字里带 padded 的测试要求「至少 5000 字节」，
   page 2 的裸编码却已经 ~19570 字节 → `pad` 算出来是 0，**它测的从来不是填充路径**。
   顺着这条又挖出第二个：`large_page_padded_len` 直接返回 `max(bare, min)`，而一个
   `tEXt` 最少要 17 字节 —— 目标落在 `bare+1 ..= bare+16` 时清单声明的字节数比真实响应
   多，客户端会以 ShortRead 拒收。现在编码器与长度公式共用同一个 `text_pad()`。
   补的钉分三层：单元测试把三种填充深度的真输出送进**读者自己那套**完整性走查、
   长度公式跨整个尴尬区间扫一遍、门禁新增 `padded-walk` 相位真的服务并读完一本带
   tEXt 的书。变异检查：把顺序改回去，相位当场死在
   `page 1 arrived unusable: png structure invalid: tEXt precedes IHDR`。
   这与 Stage 5 定下的那条是同一条原则：**fixture 不能比真实响应更宽松**。

## 尚未验证（不写成已完成）


- **真机（带 GPU 的手机）上的帧率判定与低内存 OOM 边界**。低内存档现在是
  「强迫设备类别」测出来的（`--device-ram`），不是真的 1.5 GB 手机；OOM 余量
  仍需真机。跑法：`scripts/e2e_stage8_device.sh --device <serial> --base-url … --key … --book …`
  （`verify.sh` 现含一步 Android 交叉检查
  `cargo ndk -t arm64-v8a check --features frb`，缺 cargo-ndk/NDK 时自动跳过）：仪器只有
  模拟器这一台（脚本默认 `-gpu host`，软件光栅的毫秒已在「冷页 1 秒之谜」一节排除）。
  它证实了 PSS 不增长、证实了窗口收窄与缓存价值，但「不明显掉帧」的绝对判定、
  「不频繁 OOM」的低内存机型边界，都还需要一台真手机。
- **冷页 1 秒**：这个数在真机上是否成立未测；已确认它是「回环 + 平台线程排队」的合成结果，
  并按缺陷 4 做了改动，改动后的真机复测仍未做（脚本重跑即可）。
- **真实 Komga 上的 500+ 页单本**：`--live` 腿已经跑通（292 页真书、292 次请求零重复），
  但真实库里最大的单本就是 292 页，「500+ 页」那一档仍只有合成书证明；其余相位
  （4K、损坏页、断网、切换）也都还只在回环那台替身上跑过。
- **Apple 目标**：`ComicApp_iOS -sdk iphonesimulator` 编译通过（2026-08-30 实测，
  `** BUILD SUCCEEDED **`）；`ComicApp_tvOS` **仍编译不过**，两处都是 Stage 7 留下的行——
  `ReaderModel.swift:415` 的 `UIScreen.main.brightness` 与 `ReaderScreen.swift:172` 的
  `Slider` 在 tvOS 上都不存在。`ComicApp_visionOS` 未尝试。两端都只是**编译过**，
  没有在模拟器或真机上跑过阅读流程。
- **Apple 侧没有内存压力响应**：修缺陷 12 时顺手查了两端，`ComicApp` 与 `KomgaKit` 里没有任何
  代码观察 `UIApplicationDidReceiveMemoryWarningNotification`，所以 `reader_release_prefetch`
  这一步在 Swift 端没有对应物。`ByteBudgetCache` 本身就是有界的，RAM 不会失控，因此这不是同一个
  缺陷；但「系统要内存时主动交还」这条能力 iOS 目前是缺的。补它需要先在模拟器/真机上量出
  「收到警告 → 驻留字节下降 → 那一页仍可显示」，否则只是加一段没人验证的回调。
- **蜂窝/ Wi-Fi 的真实切换信号**：核心不监听系统广播（不申请权限），改由「连续两次取页失败」
  推断离线、由「响应慢」推断弱网。真实切换事件下这个推断是否够快，未测。

## 顺带修掉的（不属本阶段）

`sync/upload.rs` 的 R4 用例把「对端比我晚」写死成 `2026-08-28T23:00:00Z`，而本地动作时间取的是
真实时钟——这条断言在写完次日就变成了假失败。改为相对当前时间取「一小时后」。

同一天复验（2026-08-30）又抓到一条同类：**在 `:memory:` 上断言 `journal_mode == "wal"`**。
SQLite 对内存库永远答 `memory`，这条断言从写下那刻起就不可能成立，于是 `verify.sh` 停在
`cargo test`，后面的 Android 交叉检查、frb 同步、Swift、Flutter 四步**全部没跑**——
而 `set -e` 让这种「前面红了后面静默跳过」看起来只是一次普通失败。
WAL 断言移到了走生产 `open()` 的文件库上，并补了 `synchronous == NORMAL`；
变异检查：删掉 `configure` 里的 WAL pragma，断言立刻变成 `left: "delete"`。
教训记一条：**内存库证明不了任何只有文件库才有的行为**。
