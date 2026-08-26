# Connection Contract — 添加服务器 → 登录 → 验证 → 获取服务器信息 → 保存 Profile

两条客户端（Swift KomgaKit / Rust komga_core + Flutter）必须实现相同的行为序列。
Shared Fixtures：`specs/contracts/fixtures/connection/`。

## 流程

```text
1. URL 规范化        ServerURL.normalized / normalize_server_url
2. 认证构造          AuthMethod: apiKey(X-API-Key) | basic(Authorization: Basic)
3. 登录 + 验证 Komga  GET /actuator/info      (200 = 凭证有效; 401/403 = 认证失败)
4. 获取服务器信息     同上响应的 build.version（Spring Boot build-info; git 可选）
5. 远端实体探测       GET /api/v1/libraries   → LibraryDto[]（写入 libraries 表,
                     主键 (server_id, remote_id)，不得与其它服务器串库）
6. 版本兼容校验       serverVersion 对快照（1.26.3）执行 specs/openapi/compatibility.md 策略
7. 保存 ServerProfile  credential_ref(Keychain/Keystore) + capabilities + last_successful_connection
8. 切换 active server app_state.active_server_id
```

`/actuator/info` 在 OpenAPI 快照中的摘要即 "Get server information"；它是唯一同时
验证「登录」与「服务器身份/版本」的单请求端点（未认证时返回 401，实测确认）。

## 错误映射（Swift ↔ Rust 对齐）

| 状况 | Swift `KomgaAPIError` | Rust `ApiError` |
| --- | --- | --- |
| HTTP 401/403 | `.authentication` | `Authentication` |
| 网络/超时 | `.network` | `Network` |
| 其它 HTTP 状态 | `.server(statusCode:)` | `Server { status_code }` |
| 服务器版本低于策略下限 | `.apiCompatibility(String)` | `ApiCompatibility { message }` |
| URL 非法 | `.urlInvalid(String)` | `UrlInvalid { message }` |
| 响应解码失败 | `.decode(String)` | `Decode { message }` |
| 本地库失败 | KomgaStore 抛 GRDB 错误（应用层包装） | `Database { message }` |

错误响应体（如 400 `ValidationErrorResponse`）不参与类型系统：客户端只消费状态码，
`detail` 仅用于日志（禁止把服务端消息直接展示给用户）。

## Fixture 与测试

- `actuator-info.json` — ServerInfoDTO/ServerInfo 解码测试（Swift/Rust 共用）
- `libraries.json` — LibraryDTO/Library 解码 + 入库 `(server_id, remote_id)` 测试

离线测试用 Fake Fetcher / URLProtocol 返回 fixture；真实连接验收（可选）由环境变量
`KOMGA_BASE_URL` / `KOMGA_API_KEY` 控制，未设置时跳过。