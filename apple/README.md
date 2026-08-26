# apple — Apple 平台

- **ComicApp**：iOS / macOS / tvOS / visionOS 应用壳（XcodeGen 描述：`apple/ComicApp/project.yml`）
- **KomgaKit**：共享 Swift Package
  - `KomgaAPI`（传输层：认证 / HTTP / 分页 / SSE）
  - `KomgaStore`（GRDB 本地库）
  - `KomgaSync`（同步引擎）
  - `KomgaReader`（阅读器）
  - `KomgaFeatures`（Feature 模型）

依赖方向：`KomgaStore → KomgaAPI`，`KomgaSync → KomgaAPI + KomgaStore`，
`KomgaFeatures → 全部核心模块`。UI / Navigation / Interaction Adapter 在各平台 App 壳内。
