# OpenAPI 兼容性记录与版本策略

## 当前快照

| 字段 | 值 |
| --- | --- |
| Komga 版本 | 1.26.3 |
| API 版本（info.version） | 1.26.3 |
| 导出日期 | 2026-08-25 |
| OpenAPI 文件 | specs/openapi/komga-openapi.yaml |
| 来源端点 | GET /v3/api-docs（Springdoc；/api/v1/openapi.json 在此版本不存在） |
| 格式 | OpenAPI 3.1.0，JSON 序列化（YAML 1.2 超集，可直接作 yaml 使用） |
| 路径数 | 139 |
| 认证 | Basic Authentication 或 X-API-Key 头（真实服务器 401 实测确认） |
| 合同版本（client contractVersion） | Swift `KomgaAPI.contractVersion` = Rust `ApiContract::VERSION` = "0.2.0" |

快照与上游一致：`https://raw.githubusercontent.com/gotson/komga/master/komga/docs/openapi.json`（2026-08-26 下载对比，逐路径一致）。

## 实测记录（真实验收，2026-08-25/26）

- GET /api/v1/series?page=0&size=10 → 200；分页字段（content/totalElements/totalPages/number/size/first/last）与 Swift/Rust DTO 一致
- GET /api/v1/libraries → 200（纯数组，非分页包装）
- GET /api/v1/series/{id}/thumbnail → 200 image/jpeg
- GET /actuator/info 未认证 → 401（快照摘要 "Get server information"；作连接探测端点在契约内）
- 无凭证请求 → 401 Unauthorized（映射为 Authentication 错误）
- 注意：/sse/v1/events 未出现在本版本 OpenAPI 中（SSE 契约仍按 specs/events/komga-sse-events.md 维护，若服务端实际暴露则以行为测试为准）
- 注意：SeriesMetadata 实际字段为 publisher（字符串）与 genres（数组），而非 publishers；当前 DTO 以 Option/默认值容忍，生成代码前按 OpenAPI 快照对齐
- 注意：本版本 OpenAPI 不含 /api/v1/about 与 /api/v1/server；“获取服务器信息”统一走 /actuator/info（页面路径信息按 /api/v1/settings 另行取用）

## API 版本兼容策略

`komga-openapi.yaml` 是 Swift / Rust API Model 的唯一事实来源。客户端在连接阶段
用 `/actuator/info` 取回 `build.version` 并按下表决策：

| 服务器版本 | 客户端行为 |
| --- | --- |
| < 1.26.0（合约下限） | 拒绝：`ApiCompatibility` 错误，不保存 Profile |
| 1.26.x（当前线） | 接受 |
| 1.x 且 1.27 ≤ minor（高于快照的 minor/patch） | 接受，capabilities 追加 `newer-than-snapshot`，UI 可提示“服务器较新” |
| major > 1 | 拒绝：`ApiCompatibility`（Komga 官方策略：deprecated 端点在下个大版本移除） |
| 版本缺失/解析失败 | 接受但 capabilitity 记录 `unknown-version`（不做唯一依赖） |

规则：

- **新增字段永远兼容**：Swift/Rust DTO 对未知字段静默忽略（serde / JSONDecoder），
  服务端 minor 升级只增字段时无需客户端改动。
- **禁止**为“适配客户端”手改快照；兼容性差异写在本文档与 Behavior 契约。
- 破坏性变更只随 major 发布（Komga 官方 deprecation 策略），因此 major 是硬边界。
- 快照升级流程：重新导出 → `python3 -c` diff 路径/字段 → 更新上表版本列 → 跑两端
  “fixture 解码测试” → bump 两端 contractVersion 并在本文件记录变更摘要。
- 认证：API Key（X-API-Key）为主，Basic 为兼容方案；认证信息只存
  Keychain（Apple）/ Android Keystore（Android），本地数据库仅保存 Credential Reference。

## Capabilities 约定

连接成功后探测到的服务器能力写入 `ServerProfile.capabilities`（自由字符串数组）：

| capability | 含义 |
| --- | --- |
| `sse` | /sse/v1/events 可用（Phase 2 使用） |
| `newer-than-snapshot` | 服务器 minor 高于快照线 |
| `unknown-version` | build.version 缺失或无法解析 |
| `libraries:N` | 连接时探测到的库数量（N 为整数） |