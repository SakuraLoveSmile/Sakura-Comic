# Shared Fixtures

- JSON 文件，命名 snake_case，按契约目录组织
- 常用字段：`remote`（服务端状态）、`localPending`（本地未上传状态）、`expected`（期望合并结果）
- Swift XCTest 与 Rust cargo test 必须加载同一文件并断言同一 `expected`
- 只允许由 Behavior 变更驱动修改；两端实现同步更新
