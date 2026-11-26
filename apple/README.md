# Apple 平台（已冻结）

这个目录里的 SwiftUI 外壳与 `KomgaKit` Swift Package 在 2026-11-26 之后不再维护：

- **不构建**：`.xcodeproj` 由 `project.yml` 生成，但已经不在 CI / Release 里跑；
- **不测试**：`scripts/verify.sh` 不再执行 `swift build` / `swift test` / `xcodebuild`；
- **不发布**：Release 流水线只产出 Android APK 与 AAB；
- **不排期**：`docs/roadmap.md` 里的 iOS / macOS 主题随平台范围一起暂停。

保留它的原因只有一个：它是这个项目做过的真实实现，包含与 Rust 核心同构的同步、下载、阅读器代码，
恢复 Apple 支持时可以当参考。要恢复，需要把 CI 与 Release 里对应的任务、签名身份和 `MARKETING_VERSION`
一起接回来，并重新走一遍真机验收——不是改一个开关。

当前范围见根 [README](../README.md) 的「平台范围」。

## 冻结时的模块（留作参考）

- **ComicApp**：iOS / macOS / tvOS / visionOS 应用壳（XcodeGen 描述：`apple/ComicApp/project.yml`）
- **KomgaKit**：共享 Swift Package
  - `KomgaAPI`（传输层：认证 / HTTP / 分页 / SSE）
  - `KomgaStore`（GRDB 本地库）
  - `KomgaSync`（同步引擎）
  - `KomgaReader`（阅读器）
  - `KomgaFeatures`（Feature 模型）

依赖方向：`KomgaStore → KomgaAPI`，`KomgaSync → KomgaAPI + KomgaStore`，
`KomgaFeatures → 全部核心模块`。UI / Navigation / Interaction Adapter 在各平台 App 壳内。
