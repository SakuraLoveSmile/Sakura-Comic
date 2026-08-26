# Stage 2 Checklist — API 契约与服务器管理

验收标准（双端必须完成）：

```text
添加服务器 → 登录 → 验证 Komga → 获取服务器信息 → 保存 Server Profile
```

## API 契约

| 项 | 位置 |
| --- | --- |
| Komga OpenAPI Snapshot | `specs/openapi/komga-openapi.yaml`（1.26.3，139 路径，与上游 master 逐路径一致） |
| API Model（Swift） | `KomgaKit/Sources/KomgaAPI/`：SeriesPageDTO / ServerInfoDTO / LibraryDTO / PageRequest |
| API Model（Rust） | `komga_core/src/model/`：SeriesPage / ServerInfo / Library |
| 统一错误模型 | Swift `KomgaAPIError`（`KomgaTransport.swift`）↔ Rust `ApiError`（`api/error.rs`），7 类一一对应 |
| 分页请求 | `PageRequest`（Swift）/ `PageRequest` + `series_page_url`（Rust），共享 fixture 验证 |
| Authentication | `AuthMethod`（apiKey / basic）：Swift `Auth.swift` ↔ Rust `api/auth.rs`；真实服务器 401 实测 |
| API 版本兼容策略 | `specs/openapi/compatibility.md`（版本决策表 + 快照升级流程 + capabilities 约定） |
| 连接端点契约 | `specs/contracts/connection/README.md` + fixtures（actuator-info / libraries） |

## Server Profile（双端）

| 能力 | Apple | Android |
| --- | --- | --- |
| 添加服务器 | `AddServerView` → `LibraryViewModel.addServer` | `ServerFormScreen` → `ServerManager.add` |
| 删除服务器 | `ServersView` swipe/menu → `deleteServer` | `ServersScreen` menu → `ServerManager.delete` |
| 编辑服务器 | `AddServerView(existing:)` → `updateServer` | `ServerFormScreen(existing:)` → `ServerManager.update` |
| 测试连接 | “测试连接”按钮 → `testConnection`（/actuator/info + /api/v1/libraries + 版本策略） | 同上（Rust facade `test_connection`） |
| 保存认证信息 | Keychain（`KeychainStore`，credentialRef=`keychain:<serverId>`） | Android Keystore（`MainActivity.kt` 通道，ref=`keystore:<serverId>`） |
| 切换服务器 | Library 工具栏 Menu + `ServersView` → `app_state.active_server_id` | `ServersScreen` → Rust `set_active_server` |
| 远端实体隔离 | 所有表主键 `(server_id, remote_id)`（libraries/series/books/...） | 同构（rusqlite schema 一致） |

## 本地验收

```bash
bash scripts/verify.sh                     # cargo fmt/clippy/test + swift build/test + flutter analyze/test
cd android/komga_core && cargo run --bin stage2_smoke -- --fixture --db /tmp/comic-stage2.sqlite   # Android 侧离线验收链
```

## 真实服务器验收（可选，需 API Key）

```bash
bash scripts/e2e_stage2.sh   # = stage2_smoke live + Apple LiveConnectionTests（环境变量 KOMGA_BASE_URL/KOMGA_API_KEY）
```

```text
cargo run -p komga_core --bin stage2_smoke -- --db /tmp/comic-stage2.sqlite \
  --base-url "$KOMGA_BASE_URL" --api-key "$KOMGA_API_KEY"
```

Apple 侧 live 测试：`KomgaKitTests/LiveConnectionTests`（无环境变量时跳过）。