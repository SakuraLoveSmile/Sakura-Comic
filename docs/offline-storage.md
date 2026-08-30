# 离线存储

## Cache 与 Offline Download 分离

| 类型 | 自动清理 | 用户主动 |
| --- | ---: | ---: |
| Thumbnail Cache | 是 | 否 |
| Page Cache | 是 | 否 |
| Prefetch Cache | 是 | 否 |
| Download Temp | 是 | 否 |
| Offline Download | 否 | 是 |

磁盘结构：

```text
cache/
├── thumbnails/   # 封面文件（本地路径记录在 SQLite `thumbnails` 表）
├── pages/        # 读者真正显示过的页（kind='page'）
└── prefetch/     # 预取来但还没看过的页（kind='prefetch'）

downloads/
└── {serverId}/
    └── {bookId}/
```

封面文件路径由 SQLite `thumbnails` 表管理（v3）：UI 从数据库解析本地路径后
直接读盘渲染；`cache_entries` 表负责通用 LRU 记账（Stage 7 起有写入者，Stage 8 起分两层）。
命中 = 记录存在 + 文件存在 + 完整性通过；任一缺失即视为 miss，由读取路径自愈
（丢行、丢文件、重新取）。

Stage 8 的三条淘汰次序，都写进 `store/cache.rs::evictable_order`：

1. `kind='download'` 永不进候选 —— LRU 永远不能删除 Offline Download；
2. `kind='prefetch'`（没被看过）先于 `kind='page'`（被看过）淘汰，**与新旧无关**：
   一页刚预取到的字节不如一小时前读过的一页值钱；
3. 同 kind 内按 `last_access`，再按 `key` 定序保证可重放。

保护是**结构**而不是约定：`store::cache::protected_paths` 把
`downloads.manifest_path`、`download_pages.file_path` 与账本里 `kind='download'` 的行
一起 UNION 起来，淘汰、`delete_of_kind`、按前缀清书、开书清扫四处一律跳过这些路径。
只靠"下载会记得写一行 `kind='download'`"是不够的——离线下载目前是空壳，谁都可能忘，
而忘记的代价是用户的书架被清扫删掉。被保护的行也**不会**从账本里删除：文件留下而行没了，
下一轮就会把它当孤儿。

保护是**结构**而不是约定：`store::cache::protected_paths` 把 `downloads.manifest_path`、
`download_pages.file_path` 与账本里 `kind='download'` 的行 UNION 起来，淘汰、`delete_of_kind`、
按前缀清书、开书清扫四处一律跳过这些路径。只靠"下载将来会记得写一行 `kind='download'`"
是不够的——离线下载（Phase 4）现在是空壳，谁都可能忘，而忘记的代价是用户的书架被清扫删掉。
被保护的行也**不会**从账本里删除：文件留下而行没了，下一轮就会把它当孤儿。

另有一条反直觉但实测必要的规则：**触发淘汰的那一条本身不可淘汰**
（`evict_to_budget_except`）。`last_access` 精度到毫秒，预取与显示常落在同一毫秒，
平局按 key 排序会把刚写下的那页选为受害者，读者于是转身再下一遍——
40 MiB 池装 24 MiB 的 4K 页时实测每页 2 次请求。

账实对账 `PageCache::reconcile`（开书时跑一次）：幽灵行、孤儿文件、`.part` 残片、
字节数不符、kind 与所在目录不符——分歧时以磁盘为准，因为磁盘是证人。

内存层（Rust `reader/memory.rs`、Swift `ByteBudgetCache`）是**字节预算**的 LRU：
峰值恒不超预算，单项超过整个预算只拒绝不驱逐，预取页落盘的同时驻留内存，
所以磁盘被淘汰的预取页可以从内存重新落盘而不重下。预算由 `window.json` 算出。

## Download Manifest（不打包 ZIP）

```json
{
  "serverId": "",
  "bookId": "",
  "pagesCount": 120,
  "downloadedAt": "",
  "remoteLastModified": "",
  "pages": []
}
```

优点：断点续传 / 单页重试 / 边下边读 / 无需二次解压 / 易于删除 / 易于完整性检查。

Download Manager 状态：Waiting / Downloading / Paused / Completed / Failed，
并显示 Downloaded Pages / Total Pages。
