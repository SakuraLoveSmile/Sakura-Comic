# Behavior Contract — Offline Mutation / Outbox Upload

本地写操作的唯一通路（两端逐字同语义）：

```text
UI → SQLite(read_progress) → pending_mutations → Background Upload → Komga
```

传输层事实（来自你自己服务器导出的 `specs/openapi/komga-openapi.yaml`，version 1.26.3，
与上游 master 导出的 `openapi.json` 同版本、同内容）：

| 动作 | 路由 | 请求体 | 成功 |
| --- | --- | --- | --- |
| 上传阅读进度 / Mark Read | `PATCH /api/v1/books/{bookId}/read-progress` | `ReadProgressUpdateDto {page:int32?, completed:bool?}`（**两个字段都不是 required**） | `204` 无响应体 |
| Mark Unread | `DELETE /api/v1/books/{bookId}/read-progress` | 无 | `204` 无响应体 |

两条关键后果：

1. **成功响应没有 body**（204）。客户端拿不到服务器写入后的 `lastModified`，因此上传成功后
   `server_updated_at` 只能置空表示「未知」，等下一次 Reconcile 再钉住。任何实现不得伪造
   一个服务器时间戳。
2. **PATCH 是无条件覆盖写**：没有 ETag / If-Unmodified-Since / 版本号。因此冲突判定只能在
   上传**之前**由客户端自己做，判据是「最后一次重新拉取到的服务器状态」+「本地动作时间」。

## Outbox 行状态机

`pending_mutations.state ∈ {pending, failed}`，加 `retry_count` / `next_retry_at` / `last_error`。

```text
enqueue ──▶ pending(next_retry_at = NULL)
              │  上传失败（可重试类）
              │  retry_count += 1
              │  next_retry_at = now + backoff(retry_count)
              ├──▶ pending(退避中) ── 到期 ──▶ 再次尝试
              │
              │  retry_count 达到 MAX_ATTEMPTS，或收到 400
              └──▶ failed(last_error)   ← 不再自动重试，仍可被新动作顶掉 / 由用户手动重试
```

- **at-least-once + 幂等写**：不设 in-flight 标记列。中途被杀就是重放同一条写；
  `PATCH {page,completed}` 重放两次结果相同，因此不需要锁行状态。崩溃恢复靠
  「重启后所有 `state = pending` 且 `next_retry_at` 到期或为 NULL 的行都重新 eligible」。
- `next_retry_at` 是**绝对时间**，不随重启重置：杀 App 不会把退避惩罚清零。
- 退避：`backoff(n) = min(BASE_SECONDS * 2^(n-1), MAX_SECONDS)`，
  `BASE_SECONDS = 2`、`MAX_SECONDS = 300`，`MAX_ATTEMPTS = 8`。
  序列（秒）：2, 4, 8, 16, 32, 64, 128, 256。第 8 次失败后进 `failed`。
  由 `fixtures/outbox/backoff.json` 钉死，两端读同一份。

## 结果分类（决定 retry / failed / 丢弃）

| 服务器结果 | 分类 | 行为 |
| --- | --- | --- |
| `204` | 成功 | 删除该 Outbox 行；清 `mutation_pending`；`server_updated_at = NULL` |
| 判定「服务器已经是我们要的值」 | 幂等成功 | 同上（不发包也算成功，见 conflict.json `already-applied`） |
| `404` / `410` | 服务器确认实体已不存在 | **丢弃**该 Outbox 行（Stage 5 规定只有上传阶段拿到确认才允许丢） |
| `400` | 载荷被拒 | 立即 `failed`，**不消耗**退避重试（重试同一无效） |
| `401` / `403` | 凭据被拒 | 整轮立即停止；`retry_count` **不变**、`next_retry_at` 不变、状态不变。凭据问题是全局的，逐条累加惩罚会把用户自己的动作饿死 |
| `408` / `429` / `5xx` / 传输层失败 | 可重试 | `retry_count += 1` + 退避 |

## Mutation 合并（coalescing）

同一 `(server_id, entity_id)` 上，阅读进度族（`READ_PROGRESS` / `MARK_READ` / `MARK_UNREAD`）
**只保留用户最后一次表态**：入队新动作时删掉同族旧行。

- 判定依据是「同族 + 同一实体」，不是「同类型」。`MARK_READ` 之后又翻页 → `READ_PROGRESS`
  顶掉 `MARK_READ`；反之亦然。用户最后做了什么，服务器就该变成什么。
- 已处于 `failed` 的同族行也会被新动作顶掉（用户重新操作等于重新授权一次上传，计数清零）。
- 不同实体之间永不合并。
- 合并只发生在入队侧；上传侧绝不主动丢行（除了上表两种确认情形）。

由 `fixtures/outbox/coalescing.json` 钉死。

## 冲突规则（本阶段的核心，禁止两种偷懒解法）

**禁止 `Server Always Wins`**：断网期间用户的阅读/标记必须在恢复后生效。
**禁止统一 `max(page)`**：页码大小不携带「谁更新」的信息——用户故意从头重读（page 3）时，
`max` 会把服务器上更旧的 page 90 顶回来，等于用户动作被吞；而另一台设备在**更早**时间读的
page 90 也不该覆盖我们**更晚**的 page 3。

判据只有一个：**谁的动作在时间上更晚**（用户动作时间 vs 服务器状态时间），
外加「显式表态优先于被动进度」这条优先级。

上传每条 `pending` 前，先做一次 Targeted Re-fetch（`GET /api/v1/books/{id}`），
拿到 `(server.page, server.completed, server.lastModified)`，再按下表决策：

| # | 条件（按顺序匹配，先命中先生效） | 决策 |
| --- | --- | --- |
| R1 | 服务器已不存在该实体（refetch `404`） | 丢弃 Outbox 行 |
| R2 | 待传动作是**显式** `MARK_READ` / `MARK_UNREAD` | **无条件上传**。显式表态压过任何远端被动进度（无论远端多新） |
| R3 | 服务器当前 `(page, completed)` 已等于本地意图 | 幂等：不发包，按成功清理 |
| R4 | `server.lastModified > local_updated_at`（远端在我们动作之后又变了） | **远端赢**，丢包不覆盖；本地行随后被镜像扫描收敛到远端值 |
| R5 | 其余（远端自我们上次镜像以来没动，或远端更旧） | **本地赢**，上传 |

R4 是「最新用户动作赢」，不是「服务器赢」：它只在远端**确实更晚**时生效，比较的是时间戳，
跟页码大小无关。R2/R5 是它不被允许吞掉用户动作的两条保底。

`fixtures/outbox/conflict.json` 逐条给出 R1–R5 的输入与期望，其中必须有
「本地页码小但动作更晚 → 本地赢」和「远端页码大但时间更早 → 本地赢」两个反例，
用来证明没有偷偷用 `max(page)`。

## 与镜像扫描的关系（Stage 5 已落地，本阶段不回归）

- `sync_write_for`：有未上传动作时，扫描不得改写 `read_progress`；显式 mark 完全屏蔽远端值。
- 远端删除推断（sweep 没扫到）**不删** Outbox 行；只有上传阶段的 `404/410`/refetch-404 才删。

## Shared Fixtures

| 文件 | 钉住什么 |
| --- | --- |
| `fixtures/outbox/coalescing.json` | 入队合并：谁顶掉谁、跨实体不合并、failed 被顶掉 |
| `fixtures/outbox/backoff.json` | 退避序列、`MAX_ATTEMPTS`、`failed` 入口、重启不重置 |
| `fixtures/outbox/conflict.json` | R1–R5 全分支 + 两个「反 max(page)」例 |

Rust：`sync::upload` 的 `#[cfg(test)]` 用例加载同一批 JSON。
Swift：`OutboxContractTests` 加载同一批 JSON。任何行为变更必须先改 Fixture，再同步两端。
