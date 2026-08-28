# Read Progress Contract

三类写动作，两个方向（镜像扫描侧 + 上传侧）。**合并判据是动作时间，不是页码大小。**

- **Passive Progress（被动翻页）**：本地动作时间 `local_updated_at` 与服务器进度自身的
  `readProgress.lastModified` 比较，**谁的更晚谁赢**。两侧都必须有戳时才可能判给远端；
  缺任一侧时保留用户动作（丢了的用户动作无法重新推导出来）。
- **Explicit Mark Read**：用户明确行为，优先级高于任何远端被动进度 —— 远端更晚也照传。
- **Explicit Mark Unread**：不能被 max(page) 类规则覆盖。远端还留着 page 50 / completed
  时，Mark Unread 必须把两端都归零，否则 `max(page)` 会「复活」用户刚清掉的进度。

两个方向各有一条实现，且都必须遵守同一份 fixture：

| 方向 | 规则 | 实现 |
| --- | --- | --- |
| 镜像扫描写入前 | 有未上传的本地意图就不许覆盖（显式 mark 完全屏蔽远端值；被动进度只被**更晚**的远端戳替换，且队列条目保留） | Rust `store/read_progress.rs::sync_write_for` ↔ Swift `syncWriteAllows` |
| 上传前（Outbox） | R1-R6 决策，见下 | Rust `store/outbox.rs::decide` ↔ Swift `OutboxUpload.decide` |

**明确禁止**：`Server Always Wins`（会吞掉断网期间的动作）与统一 `max(page)`
（页码不携带「谁更新」的信息）。反例用例见
[`../fixtures/outbox/conflict.json`](../offline-mutation/README.md)（本地 page 3 更晚 →
本地赢；远端 page 3 更晚 → 远端赢）。上传侧完整规则在
[offline-mutation/](../offline-mutation/README.md)，重连与事件流在
[reconnect/](../reconnect/README.md)。

## Shared Fixtures

| 文件 | 钉住什么 |
| --- | --- |
| `fixtures/read-progress/offline-priority.json` | 扫描侧：断网翻页 + Mark Read/Unread 不被镜像覆盖 |
| `fixtures/library/books-by-series.json` | 远端进度随 BookDto 内联下来的解码形状 |
| `fixtures/outbox/conflict.json` | 上传侧 R1-R6（含两条反 `max(page)` 用例） |

两端各自加载同一批文件断言（Rust `store::read_progress::tests` /
`store::outbox::contract_tests`，Swift `ReadProgressSyncTests` / `OutboxContractTests`）。
任何行为变更必须先改 Fixture，再同步修改两端实现。
