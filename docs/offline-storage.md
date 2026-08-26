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
├── thumbnails/
└── pages/

downloads/
└── {serverId}/
    └── {bookId}/
```

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
