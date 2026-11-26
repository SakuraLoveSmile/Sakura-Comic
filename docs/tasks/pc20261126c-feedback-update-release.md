# pc20261126c：反馈组件 0.17.0 + 应用内检查更新 + 0.3.0 发布

- 项目 / 任务编号：personal-comic / pc20261126c
- 状态：待体验（代码、自动化检查与本地签名构建完成；未推送、未发版）
- 创建日期（Asia/Taipei）：2026-11-26
- 权威记录：本文件
- 主仓库：`/Users/sakurasep/Documents/Code/Project/Personal Project/Comic`（main）
- 工作树：`/Users/sakurasep/Documents/Code/Project/Project Worktree/personal-comic/20261126-feat-pc20261126c-feedback-update-release`
- 基线 / 分支 / 合入目标：`a14a7d4`（第二梯队，本任务叠在 a→b 之上） / `feat/20261126-pc20261126c-feedback-update-release` / `main`
- 当前 HEAD / 未提交差异：`a14a7d4` + 本次改动

## 目标与范围

1. feedback_widget 从固定在 0.5.2 的提交升到 v0.17.0，并按上游 0.14.0 起的接入要求在宿主侧托管五项反馈外观。
2. 加应用内「检查更新」：正式版 / 预览版两条渠道，读 GitHub Releases，与真实安装版本比较，给出下载入口。
3. 版本号升到 0.3.0+4，合入 main，本地构建签名 APK。

明确排除：Apple 侧（MARKETING_VERSION 同步）、应用内静默下载安装 APK（需要 REQUEST_INSTALL_PACKAGES 与未知来源授权，本次不做）、自动检查（只在用户点的时候联网）。

## 已确认决定

- **更新只做「告诉你去哪拿」**：检查 → 展示版本与说明 → 打开 APK 直链或 Release 页（浏览器下载）。不申请安装权限，不做静默安装。
- **渠道语义**：`UpdateChannel.release` 只认 GitHub `prerelease == false`；`UpdateChannel.preview` 也认预发布，但按版本取最新——预览版之后出了更新的正式版，预览渠道会推荐正式版。
- **版本比较**：点分数列优先；`0.3.0` 高于 `0.3.0-preview.1`；`+N` 构建号不参与比较（每个发布都不同，正式性已由 tag 表达）。
- **预览版发布必须真的被标成 prerelease**，否则正式渠道会把预览包当成正式更新推给人：`release.yml` 里 tag 含 `-` 时 `prerelease: true`，且版本校验按核心版本比较（`v0.3.0-preview.1` 对 `0.3.0`）。
- **反馈外观五项由宿主托管**（上游 0.14.0 起是接入要求）：入口样式、灵感球待机样式、唤醒方式、入场动画、光束动效；存进 `AppSettings`，设置页「反馈外观」小节改，面板 `hideSettings: true` 只留服务器设置；面板改选也回传保存。
- **反馈组件挂在 MaterialApp 外侧**（上游 v12 推荐）：push/pop 不重建它，安卓返回先到组件，「放弃这次反馈？」由组件先弹。

## 实现与验收

| 步骤 | 用户效果 / 实现范围 | 验收情形与预期 | 当前结果及证据 | 状态 |
| --- | --- | --- | --- | --- |
| T1 组件升级 | 反馈面板换成 0.17.0：圈选引导、关闭前确认、边缘反射开关等 | `flutter analyze` 干净；`feedback_test.dart` / `feedback_appearance_test.dart` 全绿 | 见「执行与验证记录」 | 已实现 |
| T2 托管五项 | 设置页「反馈外观」能改五项并持久化；面板里不再出现这五项 | `feedback_appearance_test.dart`：改选 → 保存 → 重进读回；`feedback_test.dart`：五项原样传给组件、面板只剩服务器设置 | 同上 | 已实现 |
| T3 检查更新 | 设置页「更新」：当前版本（真实）、正式/预览渠道、检查、结果、下载 | `app_update_test.dart` 14 条（解析/比较/渠道/网络错误）+ `update_section_test.dart` 5 条（新版本卡片、已最新、失败可重试、切渠道清结果、无 APK 打开发布页）+ `settings_and_diagnostics_test.dart` 1 条（渠道写盘、重进读回） | 同上 | 已实现 |
| T4 版本号 | 0.3.0+4 | `pubspec.yaml` | — | 已实现 |
| T5 预览版可发布 | `-preview` tag 会被标 prerelease，且不会被版本校验拒掉 | `release.yml` 两处 publish 加 `prerelease:`，两处版本校验按核心版本比较 | 未在 CI 实跑（需要 push 才生效） | 待验证 |
| T6 合入 main | main 从 `55751e1` 快进到 `58c3d71`（a→b→c 三个提交） | `git log` 见下；主工作区未提交的 `url.rs` 保持原样 | 已完成 | 已实现 |
| T7 本地构建 | 0.3.0 签名 APK 三 ABI | 签名 `CN=Comic…`、与 v0.2.0 证书 SHA-256 一致（可覆盖升级）、versionCode 2003→2004 | 见「执行与验证记录」 | 已实现 |

## 执行与验证记录

| 日期 | 代码版本 / 候选差异 | 环境 | 命令 | 结果 |
| --- | --- | --- | --- | --- |
| 2026-11-26 | 本次改动 | macOS arm64 / Flutter 3.41.3 | `flutter pub get` | feedback_widget 0.5.2 → 0.17.0；`flutter_secure_storage` 仍 9.2.4（override 未动）；新增直接依赖 `url_launcher`（本就在依赖树里） |
| 2026-11-26 | 同上 | 同上 | `flutter analyze` | No issues found |
| 2026-11-26 | 同上 | 同上 | `flutter test` | 273 passed |
| 2026-11-26 | 变异检验 | 同上 | 去掉渠道过滤 / 渠道改动不落盘 | 对应用例分别失败，恢复后全绿 |
| 2026-11-26 | `58c3d71`（干净树） | macOS arm64 / rustc 1.85.0（pinned） | `cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -o jniLibs build --release --features frb` | 三个 ABI 的 `libkomga_core.so`：5.5M / 7.6M / 8.6M；先给 1.85.0 补装 Android target（脚本里那句 `rustup target add` 只作用于默认工具链） |
| 2026-11-26 | 同上 | Flutter 3.41.3 / JDK17 | `flutter build apk --release --split-per-abi --dart-define=FEEDBACK_API_BASE=… --dart-define=FEEDBACK_APP_ID=comic` | 三个 APK：23.1MB / 27.6MB / 30.1MB；`libapp.so` 里含 feedback 服务地址，确认 dart-define 已编入 |
| 2026-11-26 | 同上 | build-tools 37.0.0 | `apksigner verify --print-certs`、`aapt2 dump badging` | V2 签名 `CN=Comic, OU=Personal, O=Comic`；SHA-256 `f037b4de…`；与 v0.2.0 的证书完全相同；versionCode 2004 > v0.2.0 的 2003，versionName 0.3.0 |

未运行：真机上的反馈面板与手势（0.17.0 的圈选引导、关闭确认层、边缘反射）、真实 GitHub Releases 检查更新（测试全部用注入的 fetch）、`release.yml` 的预览版发布路径（需要 push 一个 `-preview` tag）。

## 提交与集成

| 提交 | 行为变化与原因 | 验证 | 合并 / 发布 |
| --- | --- | --- | --- |
| `58c3d71` 反馈组件 0.17.0 + 应用内检查更新 + 0.3.0 | 三项交付 | 见上表 | 已快进合入 main；未推送 |
| 本文件随后的一次记录提交 | 构建与校验结果 | — | 同样快进合入 main |

## 交付与恢复

- 体验入口：设置 → 反馈外观（五项）；设置 → 更新（渠道 + 检查更新）；反馈灵感球/面板。
- 安装包（0.3.0，自签，可直接覆盖 v0.2.0）：
  - `artifacts/0.3.0/app-arm64-v8a-release.apk`（主流手机）
  - `artifacts/0.3.0/app-armeabi-v7a-release.apk`（老设备）
  - `artifacts/0.3.0/app-x86_64-release.apk`（模拟器/少数设备）
  目录：`/Users/sakurasep/Documents/Code/Project/Project Worktree/personal-comic/artifacts/0.3.0/`
- 尚未完成 / 尚未验证：真机体验；Apple 端未跟进（MARKETING_VERSION 仍是 0.2.0，bundle id 仍是 com.example.comic）；预览版发布链路只在本地改好，未在 CI 跑过；未打 tag、未推送，因此 GitHub Release 与 CI 产物尚未产生。
- 这次 APK 由 `58c3d71` 的干净树构建；主工作区里那份未提交的 `android/komga_core/src/api/url.rs` 加固改动**没有**进入这个包。
