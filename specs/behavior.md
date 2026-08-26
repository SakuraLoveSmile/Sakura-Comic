# Behavior Contract

Transport Contract（specs/openapi）只约束 HTTP 层；Event Contract（specs/events）约束事件语义；
Behavior Contract 约束 Swift 与 Rust 两套实现**业务行为一致**。

覆盖场景：

- initial-sync
- incremental-sync
- delete-propagation
- read-progress（含冲突合并）
- offline-mutation（Outbox）
- reconnect（SSE 重连兜底）

## Shared Fixture 约定

`specs/contracts/fixtures/` 下的 JSON 文件是两端测试的唯一数据源：

- Swift XCTest 与 Rust cargo test 加载同一文件
- Fixture 统一表达输入状态与期望输出，例如：

```json
{
  "remote": {
    "bookId": "123",
    "page": 17,
    "completed": false
  },
  "localPending": {
    "page": 23,
    "completed": false
  },
  "expected": {
    "page": 23,
    "uploadRequired": true
  }
}
```

任何行为变更必须先改 Fixture，再同步修改两端实现。
