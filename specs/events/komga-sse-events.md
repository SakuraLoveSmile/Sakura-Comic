# Komga SSE 事件契约

端点：`GET /sse/v1/events` —— **已核实**（1.26.3 源码一手证据，见下）。
注意它**不在** `/api` 前缀下，且只有 v1，没有 v2 版本。

核实依据（不是推测，是读到的源码）：

```kotlin
// komga/src/main/kotlin/org/gotson/komga/interfaces/sse/SseController.kt (tag 1.26.3)
@GetMapping("sse/v1/events")
fun sse(@AuthenticationPrincipal principal: KomgaPrincipal): SseEmitter {
```

- 官方 Web UI 里同样是字面量 `const API_SSE = '/sse/v1/events'`。
- 我们自己服务器导出的 OpenAPI（1.26.3）与上游 tag 1.26.3 的 `docs/openapi.json` 内容一致：
  139 个路径，`sse` / `event` 命中数为 0，全文无 `event-stream`。**所以「导出文档里没有」
  是 SpringDoc 省略 event-stream 端点的惯例，不代表路由不存在。**
- 无凭据实测在这台服务器上无法判定存废：`/api/*` 与 `/sse/*` 一律 401（认证过滤器在路由
  之前），而瞎写的 `/totally-bogus-xyz` 反而 200（SPA 兜底）。401 不是存废信号。

## 传输与认证

- `Accept: text/event-stream`；服务端用 Spring 的 `SseEmitter`，每帧 `event:` + `data:`，
  `data:` 是 `application/json`。
- `X-API-Key` 可用：`SecurityConfiguration` 的 `@Order(1)` 链覆盖 `"/api/**", "/opds/**",
  "/sse/**"`，并挂了 `HeaderApiKeyAuthenticationConverter("X-API-Key", ...)`。Basic 与
  session cookie 同样可用。（浏览器 `EventSource` 发不了自定义头，官方 UI 因此走 cookie；
  我们的 Rust/Swift 客户端不受此限制。）

## 三条直接影响实现的实测事实

1. **没有断点续传。** 服务端从不调用 `.id(...)`，因此线上永远不会有 `id:` 字段，
   `Last-Event-ID` 无意义。→ 重连后必须 Reconcile 不是「稳妥起见」，而是**唯一**的兜底手段。
   解析器仍然实现 `id:`/`Last-Event-ID`（规范要求，且未来版本可能加上），但不要依赖它。
2. **没有 `retry:`。** 服务端从不调用 `reconnectTimeInMillis`。→ 退避完全由我们自己的策略
   决定（`fixtures/outbox/backoff.json`：base 2s、factor 2、cap 300s）。
3. **空闲≠死连接。** 两个定时器：每 15s 一个**注释帧**心跳 `:heartbeat\n\n`；每 10s 一个
   `TaskQueueStatus`（仅 ADMIN）。→ 「收到任何帧」只能证明连接活着，不能证明数据没变。
   解析器必须忽略 `:` 开头的行，同时把它计入「见过帧」。

## 事件目录（30 个，按线上 `event:` 名）

线上名是 `emitSse("...")` 里的**字符串字面量**，不是类名：`DomainEvent.LibraryUpdated` →
`LibraryChanged`、`BookUpdated` → `BookChanged`。JSON body 里**没有** `type`/`@type`
判别字段 —— 唯一的事件名来源是 SSE 的 `event:` 字段。（`DomainEvent` 那个 sealed class 是
Spring 内部事件总线类型，从不上 wire，别拿它的类名当契约。）

| `event:` | payload | 语义 → 动作 |
| --- | --- | --- |
| `LibraryAdded` / `LibraryChanged` / `LibraryDeleted` | `{libraryId}` | 全局脏 → Reconcile |
| `SeriesAdded` / `SeriesChanged` | `{seriesId, libraryId}` | Targeted Reconcile（series 派生计数） |
| `SeriesDeleted` | `{seriesId, libraryId}` | Delete Propagation |
| `BookAdded` / `BookChanged` | `{bookId, seriesId, libraryId}` | Targeted Re-fetch 该 book |
| `BookDeleted` | `{bookId, seriesId, libraryId}` | Delete Propagation |
| `CollectionAdded` / `CollectionChanged` / `CollectionDeleted` | `{collectionId, seriesIds[]}` | 合集脏 → Reconcile |
| `ReadListAdded` / `ReadListChanged` / `ReadListDeleted` | `{readListId, bookIds[]}` | 书单脏 → Reconcile |
| `ReadProgressChanged` / `ReadProgressDeleted` | `{bookId, userId}` | Targeted Re-fetch 该 book |
| `ReadProgressSeriesChanged` / `ReadProgressSeriesDeleted` | `{seriesId, userId}` | Targeted Reconcile 该 series |
| `ThumbnailBookAdded` / `ThumbnailBookDeleted` | `{bookId, seriesId, selected}` | book 封面变了 → re-fetch book |
| `ThumbnailSeriesAdded` / `Deleted` | `{seriesId, selected}` | series 封面 |
| `ThumbnailSeriesCollectionAdded` / `Deleted` | `{collectionId, selected}` | 合集封面 |
| `ThumbnailReadListAdded` / `Deleted` | `{readListId, selected}` | 书单封面 |
| `TaskQueueStatus` | `{count, countByType{}}` | 与镜像无关，忽略 |
| `SessionExpired` | `{userId}` | 与镜像无关（连接会重连） |
| `BookImported` | `{bookId?, sourceFile, success, message?}` | 有 bookId → re-fetch；否则全局脏 |
| 任何未识别事件 | — | **全局脏 → Reconcile**（兜底路径） |

`DomainEvent.LibraryScanned` → `Unit`，服务端明确不转发。

## 一个必须记在心的限制：阅读进度事件是按用户投递的

`ReadProgress*` 四类事件发送时带 `userIdOnly = true` —— **只有产生该进度的那个用户的连接会
收到**。也就是说：

- 别人（另一个账号）读了什么，我们这边不会有事件；只有 Reconcile 能发现。
- 我们自己 PATCH 成功后，服务器会把 `ReadProgressChanged` 推回给我们自己（回声）。
  回声必须无害：目标 re-fetch 走 `read_progress::sync_write_for`，Outbox 里还没上传成功的
  本地意图优先，镜像不会把自己的回显当成新数据盖回去。

## 原则

1. SSE 只是「数据发生变化」的提示，不能当作可靠消息队列。
2. 事件流程：`SSE Event → 取 Entity ID → API 重新拉取 → SQLite 更新 → UI Observe`。
3. 断开重连后必须先 `Reconciliation Sync` 再恢复事件消费；禁止假设连接期间没有漏事件
   —— 上面第 1 条事实（无 `id:`）说明这个假设在这台服务器上必然是错的。
4. 事件只给 id，不给内容：绝不允许把 `data:` 里的字段直接当镜像写库。


## 核实状态（2026-08-28）

| 事实 | 依据 |
| --- | --- |
| 路由存在且为 v1 | 上游 1.26.3 源码 `SseController.kt` 的 `@GetMapping(「sse/v1/events」)` |
| 路由存在于**你这台**服务器 | 公开静态资源 `app.14b2997d.js`（`GET /` 引到，HTTP 200）含字面量 `/sse/v1/events` 与 `new EventSource(...)` |
| 事件名表 | 同一份 bundle 里逐个 `addEventListener(「BookChanged」)`、`「ReadProgressChanged」`、`「ReadProgressSeriesChanged」`、`「ThumbnailBookAdded」`、`「TaskQueueStatus」`、`「SessionExpired」`、`「BookImported」` … 与上表逐个吻合 |
| 无 `id:` / 无续传 | 源码从不调用 `.id(...)`；bundle 也不读 `lastEventId` |
| 无 `retry:` | 源码从不调用 `reconnectTimeInMillis` |
| `X-API-Key` 在 `/sse/**` 可用 | `SecurityConfiguration` 的 `@Order(1)` 链覆盖 `/sse/**` 且挂了 `HeaderApiKeyAuthenticationConverter` |
| URL 基址 | bundle 里 SSE 与 `/api/v1/books/{id}/thumbnail` 共用同一个 `originNoSlash`（= 去掉尾斜杠的服务器基址，**含反向代理子路径**）；因此本项目的 `events_url(base) = base + /sse/v1/events` 与官方客户端一致 |
| **未验证** | 带凭据握手的实际返回（200 + `text/event-stream` + 首帧）；一次真实 `PATCH` 往返。都需要 `KOMGA_API_KEY` |
