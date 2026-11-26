# pc20261126d：0.3.0 发版、URL 加固、Android 独占、0.3.1

- 项目 / 任务编号：personal-comic / pc20261126d
- 状态：待体验（0.3.0、0.3.1 均已发版）
- 创建日期（Asia/Taipei）：2026-11-26
- 权威记录：本文件
- 主仓库：`/Users/sakurasep/Documents/Code/Project/Personal Project/Comic`（main）
- 分支 / 合入目标：直接提交在 `main`（本任务没有另开 worktree：改动集中在 CI/文档与一次版本号，且需要复用主工作区的签名材料）

## 目标与范围

1. 把前两个梯队与 0.3.0 的成果推送并发版。
2. 单独审一遍工作区里未提交的 `android/komga_core/src/api/url.rs`，补测试后提交。
3. 项目改成 Android 端独占（不再支持 Apple）。
4. 出新版 0.3.1 并发版。

## 关键事实与决定

- **远端历史被强制重写过**：`origin/main` 从 `55751e1` 变成 `3095847`（「脱敏公开文件中的本机与设备信息」+ 一个 PR 合并），与本地历史**没有 merge base**。处理方式：`git rebase --onto origin/main 55751e1 main` 把本地 4 个提交重放到脱敏历史上，唯一冲突是 `server_form_screen.dart` 的地址示例（取远端的 `komga.example.com`）。不 force push、不改写远端。
- **url.rs 那份改动只动了文档与测试**，实现没变：`normalize_server_url` 本来就按 scheme/host/port/path 重建（所以 userinfo 凭据不会进 profile），`http://` 由 `Url::parse` 以 empty host 拒掉，`//` 由 `trim_end_matches('/')` 抹平。因此本次只补测试，不改语义。
- **公开仓库不该再写出真实内网地址与像真凭据的示例**：把 `192.168.1.10` 换成 TEST-NET-3 `192.0.2.10`，把 `admin:<密码>` 换成 `admin:EXAMPLE-PASSWORD`。
- **Android 独占 = 停止把它当目标平台，不是删代码**：`apple/` 原地保留作历史；摘掉的是 release.yml 的 apple job、ci.yml 的三个 macOS job、verify.sh 的 Swift 步骤，以及文档里的排期与验收口径。恢复需要接回任务与签名，不是改开关。
- **AGENTS.md 没有入库**：它一直是主工作区的未跟踪文件，本次更新了其中的平台范围说明，但没有替用户决定把它加进版本库。

## 实现与验收

| 步骤 | 结果 | 证据 | 状态 |
| --- | --- | --- | --- |
| R1 推送 main + v0.3.0 | rebase 到脱敏历史后推送成功；Release workflow 已 queued → in_progress | `origin/main = 9db7a6c`；tag `v0.3.0`；Actions run 45784920569 | 已完成 |
| R2 url.rs 审查与测试 | 补 5 条测试；示例脱敏 | `cargo clippy -D warnings` 通过；`cargo test --lib` 444 passed；提交 `8d5b80a` | 已实现 |
| R3 Android 独占 | workflow 只剩 Android；verify.sh 去掉 Swift；文档与 apple/README 说明 | PyYAML 解析：release `[android]`、ci `[rust-core, android-core-ndk, flutter-app]`；`bash -n verify.sh` 通过；提交 `25786ac` | 已实现 |
| R4 0.3.1 | pubspec `0.3.1+5`；重建三 ABI `.so`；签名 APK 三件 | `versionName 0.3.1` / `versionCode 2005`；证书与 0.3.0、0.2.0 同一把（SHA-256 `f037b4de…`） | 待体验 |
| R5 发版 | 推送 main 与 tag `v0.3.1`，CI 产出正式 Release | 见下 | 待验证 |

## 执行与验证记录

| 日期 | 代码版本 | 命令 / 操作 | 结果 |
| --- | --- | --- | --- |
| 2026-11-26 | `9db7a6c`（rebase 后） | `flutter analyze` / `flutter test` / `cargo test --lib` | 无问题 / 273 passed / 439 passed |
| 2026-11-26 | `8d5b80a` | `cargo fmt`、`cargo clippy --all-targets -- -D warnings`、`cargo test --lib api::url` | 通过 / 通过 / 18 passed |
| 2026-11-26 | `25786ac` | PyYAML 解析两个 workflow、`bash -n scripts/verify.sh` | jobs 只剩 Android；语法通过 |
| 2026-11-26 | 工作区（0.3.1 候选） | `cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 … build --release --features frb` | 三 ABI `.so`：5.5M / 7.6M / 8.6M（url.rs 改动已进核心） |
| 2026-11-26 | 同上 | `flutter build apk --release --split-per-abi` + feedback dart-define | 23.1MB / 27.6MB / 30.1MB；`apksigner`：V2 `CN=Comic…`、`aapt2`：0.3.1 / 2005 |

未运行：CI 上的 v0.3.0 Release 实际产物（本次只看得到运行状态）；0.3.1 的 CI Release（要推送 tag 后才会跑）。

## 提交与集成

| 提交 | 行为变化 | 验证 | 发布 |
| --- | --- | --- | --- |
| `8d5b80a` | URL 规范化测试与文档 | 见上 | 随 0.3.1 发布 |
| `25786ac` | 项目改 Android 独占 | 见上 | 随 0.3.1 发布 |
| 本文件提交 | 记录 | — | 随 0.3.1 发布 |
| 0.3.1 提交 | 版本号 0.3.1+5 | 本地构建 APK | tag `v0.3.1` 触发 Release |

## 交付与恢复

- 0.3.0：`origin/main` 的 `9db7a6c`，tag `v0.3.0`，Release 由 CI 产出。
- 0.3.1：本地签名 APK 在 `/Users/sakurasep/Documents/Code/Project/Project Worktree/personal-comic/artifacts/0.3.1/`（arm64 / armeabi-v7a / x86_64），可直接覆盖 0.3.0 与 0.2.0；推送 main + tag `v0.3.1` 后由 CI 产出正式产物。
- 注意：`v0.3.0` 这个 tag 打在「摘掉 Apple 之前」的提交上，所以那次 Release 里仍带两个 Apple zip；`v0.3.1` 起只有 Android 产物。
- 已冻结：Apple 侧（见 [apple/README.md](../apple/README.md)）。
