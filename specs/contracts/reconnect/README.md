# Behavior Contract — SSE Reconnect / Event Driven Sync

核心原则（和 Stage 5 的完成条件同源）：

> SSE 只是「数据可能变了」的提示，**不是可靠消息队列**。丢掉任意多个事件，最终一致性
> 必须仍然成立。

事件处理流程：

```text
SSE Event → 取 Entity ID → API 重新拉取（Targeted Re-fetch）→ SQLite 更新 → UI 自动刷新
```

## 传输

`GET /sse/v1/events`，`Accept: text/event-stream`，认证与 REST 相同（`X-API-Key` 头）。

**路由存废状态：仍未在真实服务器上验证。** 依据与限制：

- 你自己服务器导出的 OpenAPI（1.26.3）里 **0 个** `/sse*` 路径；上游 master 导出的
  `openapi.json` 同版本也只有 `/api/*` + `/actuator/info`，且全文无 `text/event-stream`。
  这符合 SpringDoc 省略 event-stream 端点的惯例，**不能**据此判定路由不存在。
- 无凭据实测无法区分存废：`/sse/v1/events`、`/sse/v1/<瞎写的路径>`、
  `/api/v1/<瞎写的路径>` 全部返回 `401` —— Komga 的认证过滤器在路由**之前**
  （对照证据：不存在的路径 `/totally-bogus-xyz` 返回 `200`，是 SPA 兜底页，
  而任何 `/api/*`、`/sse/*` 前缀一律 401）。所以 401 在这里不是存废信号。
- 结论：接入前必须带 `KOMGA_API_KEY` 实测一次，判据写死为三条（见 `sse/handshake.json`）：
  状态码 200、`Content-Type` 以 `text/event-stream` 开头、能收到至少一帧（心跳也算）。
  三条里任何一条不满足 → 客户端**退回纯 Reconcile 模式**并把原因报给用户，
  不得按本文件照抄路径继续跑。

## 解析器（`fixtures/sse/parse.json` 钉死，两端同一份）

按 WHATWG SSE 规范的字面要求实现，逐条有对应测试：

- 字段行：`event:` / `data:` / `id:` / `retry:`；冒号后的**一个**前导空格要剥掉
- 值为空的字段（`data:` 单独一行）也要追加一个空 data 行
- 无 `event:` 时事件类型为 `message`
- 以 `:` 开头的行是注释（心跳），必须忽略但不能忽略「它把一帧断开」的作用
- 多行 `data:` 用 `\n` 连接；**帧尾的空行**才 dispatch
- CRLF / LF / CR 三种行结束符都算合法（含 CRLF 被切在两个网络块之间的情况）
- 未知字段名必须忽略（服务端加字段不能让我们报错）
- 一帧未以空行结束就断流 → **不 dispatch**（半帧丢弃，等重连后的 Reconcile 兜底）
- 一个 UTF-8 字符被切在块边界 → 不得产生乱码或 panic
- `retry:` 是整数毫秒，取为后续重连退避的**下限**（`max(retry, backoff)`）
- `id:` 记录为 `last_event_id`；重连时以 `Last-Event-ID` 头带回。**注意**：带不带都必须
  Reconcile，因为服务端不保证能补发（见下）

## 重连与生命周期

- 断线 → 指数退避（同 Outbox 的 `backoff.json` 策略：base 2s、factor 2、cap 300s），
  `retry:` 帧可抬高下限。
- **每次成功重连后，顺序固定**：
  1. 先跑一次完整 Reconcile（`ReconcileTrigger::SseReconnected`，不受 60s 节流约束）
  2. 再恢复事件消费
  禁止假设连接期间没有漏事件。
- 连接期间收到的事件只累积进 dirty 集合（按实体类型合并），不做逐事件全量扫描 —— 否则
  一次 series 扫描会打爆服务器。
- App 生命周期：前台连接、后台断开（断开时不发 Reconcile，回前台再补）；网络恢复
  （`NWPathMonitor` / Flutter 侧等价物）立刻断开重连并走上面的顺序。
- 收到 401/403 → **停止重连风暴**，退避到「凭据问题解决」为止，UI 显示明确的连接状态。

## 事件 → 动作映射（`fixtures/sse/dirty.json`）

| 事件语义 | 取哪个 id | 动作 |
| --- | --- | --- |
| Book Added/Changed | `bookId` | Targeted re-fetch 该 book（+ 其 series 的派生计数） |
| Book Deleted | `bookId` | 按删除传播处理；**不得**丢掉该书未上传的 Outbox 行 |
| Series Added/Changed/Deleted | `seriesId` | Targeted re-fetch / 删除传播 |
| Collection / ReadList 变更 | `collectionId` / `readListId` | Targeted re-fetch 成员 |
| 阅读进度变更 | `bookId` | Targeted re-fetch —— 且**必须**先过 `sync_write_for`：本地有未上传意图时不许覆盖 |
| 库刷新 / 任务 / 无法识别的事件 | 无 | 记为「全局脏」→ 下一次 Reconcile |

映射表里的**事件名以上游源码实测为准**（导出文档里没有事件模型，`ServerEventDto`
不在 OpenAPI 中），未确认前客户端对未知事件一律走「全局脏」这条兜底路径 —— 这也是
「SSE 不可靠」原则的体现：漏事件、认错事件，代价都只是多跑一次 Reconcile。

## Shared Fixtures

| 文件 | 钉住什么 |
| --- | --- |
| `fixtures/sse/parse.json` | 帧解析：分块切割（LF / CRLF / CR、多行 data、注释、`id` 与 `retry`、半帧、被切断的 UTF-8） |
| `fixtures/sse/handshake.json` | 连接必须证明什么（200 + `text/event-stream` + 至少一帧），以及不合格如何退化 |
| `fixtures/sse/events.json` | 事件名到目标实体的完整映射表，含两条「按名字关键词猜」必错的用例 |
| `fixtures/sse/stream.raw` | 回环服务器回放的真实字节流（CRLF 心跳 + LF 帧 + `id:` 帧 + 结尾半帧） |

Rust：`api::sse::tests`、`tests/sse_contract.rs`、`tests/sse_events_contract.rs`。
Swift：`SSEParserTests`、`SSEEventContractTests`。两端加载同一批文件。

## 明确不做

- 不把事件当作写操作的确认（写确认只来自 Outbox 上传的 204）。
- 不做「事件里带着的字段直接写库」——事件只给 id，内容一律回 API 拉。
- 不依赖 `/api/v1/history`（`HistoricalEventDto`，要求 **ADMIN** 角色）作为兜底通道；
  普通 API Key 角色拿不到它。
