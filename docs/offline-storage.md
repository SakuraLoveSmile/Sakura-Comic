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
└── pages/

downloads/
└── {serverId}/
    └── {bookId}/
```

封面文件路径由 SQLite `thumbnails` 表管理（v3）：UI 从数据库解析本地路径后
直接读盘渲染；`cache_entries` 表负责通用 LRU 记账（pages/prefetch，后续阶段）。
命中 = 记录存在 + 文件存在；两者任一缺失即视为缓存 miss，由 `ensure_cover` /
`ensure_covers` 自动补齐。

LRU Cache 永远不能删除 Offline Download。

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
