# pc20261126a：Android 第一梯队修复（分页翻页 / 未读书下载 / 清除筛选 / 书籍详情弹层）

- 项目 / 任务编号：personal-comic / pc20261126a（项目内首个任务编号，沿用日期+序号）
- 状态：实现中（代码与自动化检查完成，待真机体验）
- 创建日期（Asia/Taipei）：2026-11-26
- 权威记录：本文件
- 主仓库：`/Users/sakurasep/Documents/Code/Project/Personal Project/Comic`（main，含用户未提交的 `android/komga_core/src/api/url.rs`，本次未触碰）
- 工作树：`/Users/sakurasep/Documents/Code/Project/Project Worktree/personal-comic/20261126-fix-pc20261126a-android-first-tier`
- 基线 / 分支 / 合入目标：`55751e1` / `fix/20261126-pc20261126a-android-first-tier` / `main`
- 当前 HEAD / 未提交差异：`55751e1` + 本次改动（未提交）

## 目标与范围

来源：上一轮「用户视角体验盘点」的第一梯队。四条都会让用户直接认为功能坏了，本次只做 Android（Flutter UI + Rust core）。

覆盖：

1. 分页阅读里点按屏幕、底栏箭头、进度滑块只改页码，画面不跟随（`reader_screen.dart`）。
2. 从未打开过的书点「下载」必定失败，并弹出英文内部文案（Rust `download_enqueue` 依赖已镜像的页清单）。
3. 书架筛选点「全部状态 / 全部标签 / 全部题材」把字面量 `全部` 当筛选值，书架立刻变 0 且回不来（`series_grid.dart`）。
4. 书籍详情弹层四个带文字按钮挤在一行 `Row`，必然横向溢出，且弹层不可滚动（`series_detail.dart`）。

明确排除：iOS/macOS 侧（含 iOS 条漫不记进度）、阅读器沉浸模式/工具栏隐藏、搜索交互、下载队列状态文案、诊断页——属第二、三梯队，另行立任务。

## 已确认决定

- **下载**：新增 FFI `download_prepare`（`server_id, book_id, base_url, api_key`），镜像缺页清单时用 `PageStreaming` 取一次并落库，然后走原有 `download_enqueue`。`download_enqueue` 的离线语义不变（已镜像的书零请求），因此「离线状态下下载已镜像的书」仍然可用。
- **翻页**：以 core 的 layout（`ReaderController.spread`）为唯一事实来源；视图跟随跳转放在帧后回调里执行，避免在滚动回调里移动正在被解析的视图；滑动方向仍由 `onPageChanged → turnTo` 驱动，两者不会互相打架。
- **模式切换**：单页↔双页、条漫↔分页时重建 `PageController`（旧索引在新布局下不代表同一页）。
- **筛选**：菜单里的「全部 X」是 `null`（清除），字面量不再进入查询。
- **弹层**：`Wrap` + `SingleChildScrollView`，四个动作在手机上折行而不是被裁掉。

## 实现与验收

| 步骤 | 用户效果 / 实现范围 | 验收情形与预期 | 当前结果及证据 | 状态 |
| --- | --- | --- | --- | --- |
| T1 | 点按左右半屏、点底栏 ←/→、拖滑块，画面与页码一致 | 点按右半屏后画面换页；箭头再翻一页；点滑块末端跳到末页且画面一致 | `test/reader_test.dart`「分页模式：点按、底栏箭头、滑块都让画面跟着页码走」通过；删掉 `_followSpread()` 调用后该测试失败 | 已实现 |
| T2 | 没读过的书也能直接下载 | 未镜像 + 在线：入队成功、页清单落库、只发一次页清单请求；已镜像 + 离线：零请求入队 | `cargo test --lib` 434 passed，含 `a_book_never_opened_online_can_still_be_queued` | 已实现 |
| T2b | 下载失败说人话 | 断网且未镜像时提示「这本书还没同步过页数，联网后再点一次下载」 | 代码路径 `FailurePresentation.from` + `ErrorCode.networkUnavailable`；无自动化（需真机/断网） | 待体验 |
| T3 | 「全部状态」是清除筛选，不是筛选 | 选 ONGOING 后书架只剩连载；再选「全部状态」恢复全部 | `test/media_library_test.dart`「全部状态 clears the filter instead of filtering by the word」；恢复字面量传参后测试失败 | 已实现 |
| T4 | 书籍详情四个动作在手机上都能看到 | 360dp 宽下四动作齐全、无溢出异常，简介可滚动 | 同文件「书籍详情弹层在小屏上四动作齐全且不横向溢出」；把 `Wrap` 换回 `Row` 后测试失败 | 已实现 |

## 执行与验证记录

| 日期 | 代码版本 / 候选差异 | 环境 | 命令 | 结果 |
| --- | --- | --- | --- | --- |
| 2026-11-26 | 本次改动（未提交） | macOS arm64 / rustc 1.85.0 / Flutter 3.41.3 (Dart 3.11.1) | `cd android/komga_core && cargo test --lib` | 434 passed，0 failed |
| 2026-11-26 | 同上 | 同上 | `cargo clippy --all-targets -- -D warnings` | 通过，无告警 |
| 2026-11-26 | 同上 | 同上 | `cargo fmt --check` | 通过 |
| 2026-11-26 | 同上 | 同上 | `bash scripts/check_frb_drift.sh` | `FRB bindings in sync`（重新生成后仍一致） |
| 2026-11-26 | 同上 | 同上 | `cd android/app && flutter analyze` | No issues found |
| 2026-11-26 | 同上 | 同上 | `cd android/app && flutter test` | 224 passed |
| 2026-11-26 | 变异检验 | 同上 | 依次移除跟随跳转 / 恢复字面量筛选 / `Wrap`→`Row` | 三条新测试分别失败，恢复后全绿 |

未运行（阻塞项）：真机或模拟器上的实际手感（点按/滑块/模式切换）；真实 Komga 服务器上的「未读书目下载」（需要服务器地址与 API Key 授权）。

## 提交与集成

| 提交 | 行为变化与原因 | 验证 | 合并 / 发布 |
| --- | --- | --- | --- |
| 本分支首个提交 `Android 第一梯队修复: 翻页跟随画面 + 未读书目下载 + 清除筛选 + 详情弹层` | 四条第一梯队缺陷修复，含新增 FFI `download_prepare` 与重新生成的绑定 | 见上表 | 未合入、未推送 |

注意：重新生成的 FRB 绑定带有格式化差异（本机 `dart format` 为短风格，仓库既有文件为长风格），漂移脚本按 `dart format` 归一化后判等，已通过。语义差异只有新增的 `download_prepare`。

## 交付与恢复

- 体验入口：书架筛选菜单、书籍详情弹层、阅读器点按/箭头/滑块、书籍详情「下载」。
- 尚未完成 / 尚未验证：真机体验与真实服务器下载；PDF/EPUB 书籍现在也能被排队下载，但阅读器仍只能提示「没有可显示的图像页面」（属既有能力缺口，未在本次处理）。
