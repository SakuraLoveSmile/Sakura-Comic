# OpenAPI 兼容性记录

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

## 实测记录（2026-08-25，真实验收）

- GET /api/v1/series?page=0&size=10 → 200；分页字段（content/totalElements/totalPages/number/size/first/last）与 Swift/Rust DTO 一致
- GET /api/v1/libraries → 200（纯数组，非分页包装）
- GET /api/v1/series/{id}/thumbnail → 200 image/jpeg
- 无凭证请求 → 401 Unauthorized（映射为 Authentication 错误）
- 注意：/sse/v1/events 未出现在本版本 OpenAPI 中（SSE 契约仍按 specs/events/komga-sse-events.md 维护，若服务端实际暴露则以行为测试为准）
- 注意：SeriesMetadata 实际字段为 publisher（字符串）与 genres（数组），而非 publishers；当前 DTO 以 Option/默认值容忍，Phase 1 生成代码前按 OpenAPI 快照对齐

## 规则
- `komga-openapi.yaml` 是 Swift / Rust API Model 的唯一事实来源
- 服务端升级后重新导出并 diff；breaking change 必须记录到本文件与 Behavior 契约
- 禁止为“适配客户端”手改快照；兼容性差异写在 `compatibility.md` 中
- 认证方式：API Key（X-API-Key）为主，Basic Authentication 为兼容方案
- 认证信息只存 Keychain（Apple）/ Keystore（Android），本地数据库仅保存 Credential Reference
