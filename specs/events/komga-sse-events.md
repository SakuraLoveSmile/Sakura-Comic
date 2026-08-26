# Komga SSE 事件契约

端点：`/sse/v1/events`

## 事件类型

（以服务端实际导出为准，导出 OpenAPI 时逐项核对）

| 事件 | 语义 |
| --- | --- |
| SeriesAdded | 系列新增 → 标记 Dirty → Targeted Reconcile |
| SeriesChanged | 系列/元数据变化 → 同上 |
| SeriesDeleted | 系列删除 → Delete Propagation |
| BookAdded | 书本新增 → 同上 |
| BookChanged | 书本/元数据变化 → 同上 |
| BookDeleted | 书本删除 → Delete Propagation |
| ReadProgressChanged | 阅读进度变化 → Targeted Reconcile |
| 其他服务端事件 | 按服务端文档处理 |

## 原则

1. SSE 只是「数据发生变化」的提示，不能当作可靠消息队列。
2. 事件流程：`SSE Event → Mark Dirty → Targeted Reconcile → SQLite Update → UI Observe`。
3. 断开重连后必须执行 `Reconciliation Sync` 再恢复 Event Driven Sync；
   禁止假设连接期间没有漏事件。
