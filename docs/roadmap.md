# 路线图

> 本文件取代此前的 Phase / Stage 阶段体系。
> 旧编号（Phase 0–5、Stage 2–10）只作为历史存档，不再作为规划依据；
> `docs/stage*-checklist.md` 保留为验收记录，但不再驱动排期。

## 组织方式

主题式：每个主题用一句话说清交付什么，不与实现阶段绑定，不预设编号。

排序原则：**先把已经付过成本的能力暴露给用户，再谈新能力。**

## 主题序列

| 主题 | 一句话 | 状态 | 交付成果 |
| --- | --- | --- | --- |
| **日常可用** | 出错时知道发生了什么，能自查 | ✅ 已完成 | 同步状态、可行动错误、App级版本化设置、统一脱敏诊断快照与日志 |
| **离线可用** | iPhone / iPad / Android 完整管理离线下载 | ✅ 已完成 | 双端下载中心、原子Manifest、ImageIntegrity结构校验、网络计费/空间注入、下载永久保留 |
| **桌面可用** | macOS 原生体验，多窗口与快捷键焦点隔离 | ✅ 已完成 | 单主窗口、(serverId, bookId) 会话复用、阅读快捷键与输入焦点隔离、GRDB访问收窄 |
| **大库可用** | 大库下书架墙滚动与加载不再随库规模变慢 | ✅ 已完成（Android） | 书架墙视口化构建、封面按瓦片尺寸解码、v11 列表索引、页范围封面查询；数字与未验证项见 [large-library-performance.md](large-library-performance.md) |

**已砍掉**：tvOS、visionOS —— 不进路线图。

## 为什么第一棒是「日常可用」

引擎层已经把状态、错误码、诊断、日志都做完并暴露了 API，但 UI 层几乎完全没接：

| 能力 | 引擎层 | UI 层 |
| --- | --- | --- |
| 同步状态 | `sync_state` 全字段 + 人类可读文案 | Android 有，Apple 只有一个红字 |
| 错误码 | FFI 带 code，401 / 503 真实来源 | Apple 直接抛 `localizedDescription` |
| 诊断快照 | `diagnosticsSnapshot` | 双端零入口 |
| 日志环 | `diagnosticsLogs` + LogRecord | 双端零入口 |
| App 级设置 | — | 双端都没有（只有阅读器设置） |

也就是说：这一棒不是"造新能力"，而是"把已经造好的能力接到界面上"。

---

## 主题一：日常可用

目标：让它成为能每天放心用的 App。判断标准是**出错时用户知道发生了什么、知道该做什么、能自己查**。

### 1.1 同步状态可见

**现状**：Android `src/models.dart:264-305` 已有 `lastSyncAt` / `neverSynced` / `failed` / `interrupted`
与人类可读文案（"同步中断：X"、"未完成，将从 Y 续跑"、"最近同步 Z"、"同步完成：新增 X · 更新 Y · 删除 Z"）；
Apple 只有 `ComicApp/Shared/LibraryView.swift:22` 一处 `syncError` 红字。Outbox 待上传条数双端 UI 均不可见。

**交付**

- 同步状态条：最后同步时间 + 状态（同步中 / 已完成 / 中断 / 失败）
- 失败与中断说人话：Apple 侧补齐 Android 已有的那套文案
- **Outbox 待上传条数可见** —— 核心已可查，缺的只是入口
- 手动刷新入口

**验收**

- 断网后同步 → 界面显示"同步中断：<原因>"，不是静默失败
- 断网状态下标记已读 → 显示"N 条待上传"，而不是假装已保存
- 恢复网络 → 数字归零，状态转为"已完成"

### 1.2 错误可行动

**现状**：Android 有 `src/error_presentation.dart` 映射层；Apple 直接把
`error.localizedDescription` 塞进红色小字（`MediaLibraryViews.swift:622/704/721/736`、
`ReaderModel.swift` 的 banner）。`KomgaAPI/CoreErrorMapping.swift` 已存在，但 UI 层没用起来。

**交付**

- 错误分四类：网络 / 认证 / 服务器 / 本地
- 每类给可执行动作：重试 / 重新登录 / 检查地址 / 清理空间
- Apple 侧建一个与 `error_presentation.dart` 对等的呈现层，接上 `CoreErrorMapping`
- **认证失效单独识别** —— 走重新登录引导，不降级成泛化错误

**验收**

- 错误密钥 → 认证类错误 + 去重新登录（不是"请求失败"）
- 服务器关机 → 网络类 + 重试入口
- 磁盘满 → 本地类 + 清理入口

### 1.3 设置页

**现状**：双端都只有阅读器设置（Apple `ReaderSettingsSheet`、Android `reader_screen.dart:98`
"阅读设置"），没有 App 级设置页。

**交付**

- 服务器（整合现有 `ServersView` / `AddServerView`）
- 同步（触发时机、后台刷新）
- 存储与下载（配额、清理）
- 外观（主题、网格密度）
- 关于：版本号 + **诊断入口**

**验收**：冷启动后能改同步与存储设置，并立即生效。

### 1.4 诊断与日志出口

**现状**：Rust 已暴露 `diagnosticsSnapshot` 与 `diagnosticsLogs`
（`rust_core_api.dart:333/342`），Dart 侧 `DiagnosticsDto` / `LogRecord` 齐全，**双端 UI 零入口**。

**交付**

- 设置页内「诊断」：快照数字（系列数 / 书数 / 页缓存占用 / 下载占用 / Outbox 积压）
- 日志列表（核心日志环，带级别与时间）
- 导出分享（便于报障）

**验收**：沿用 Stage 10 的「不自证」原则 —— 界面上每个数字都要能对照 `sqlite3` 实算或
`find` 实查，不接受"从另一个快照字段取来的数字"。

### 1.5 空状态与加载态

**现状**：Android `libraries_screen.dart:63` 有"尚未同步任何 Library"；
Apple 仅 `ServersView.swift:20` 有 `ContentUnavailableView`，其余列表空数据时的表现未统一。

**交付**

- 五个列表统一空态：服务器 / 媒体库 / 合集 / 书单 / 下载
- 每个空态回答两件事：**为什么空** + **下一步做什么**
- 首屏与翻页的统一加载态

**验收**：五个列表在零数据时不出现白屏或无限转圈，文案指向下一步动作。

---

## 主题二：离线可用（已完成）

Apple 与 Android 端已全面对齐离线下载中心与后台下载调度能力：

- **双端下载入口**：Apple 端 `DownloadsView` 与 Android 端 `DownloadsScreen` 完整拉平，支持分书籍状态进度、暂停/恢复、按书籍清理；
- **防重入与并发锁**：`DownloadEngine` 内部引入原子 Pump Lock，杜绝单 DB 重入并发下载；
- **环境状态感知**：注入真实网络计费（`NWPathMonitor`）与磁盘空间监控（`DiskSpaceProviding`），按书籍蜂窝网络授权控制；
- **图片结构校验**：接入 `ImageIntegrity` 严格校验图片容器完整性，截断/畸变数据自动拦截并重试，不计入完成；
- **原子 Manifest 与安全恢复**：落盘状态通过原子写保障，未知目录保持孤立报告，不破坏用户已有文件；
- **永久离线阅读**：删除服务器或远端书籍同步删除时，本地已下载文件与下载索引绝对保留，可直接离线开书阅读。

---

## 主题三：桌面可用（已完成）

macOS 原生桌面架构与阅读体验全面就绪：

- **单实例主窗口**：采用 SwiftUI `Window` 原生单实例场景，拦截 Cmd+N 多余窗口创建；
- **(serverId, bookId) 会话复用**：阅读窗口身份与会话管理器基于复合键建立，重复打开同一本书自动复用并聚焦现有窗口；
- **键盘导航与输入焦点隔离**：支持左右方向键、空格、翻页键等原生阅读快捷键，自动感知 `NSTextInputClient` / `NSTextView` 焦点并静默绕过，避免搜索输入与翻页冲突；
- **快捷键系统**：支持 `⌘,` 打开偏好设置，`⌘R` 立即同步刷新；
- **架构访问收窄**：`KomgaStore.database` 与 `dbQueue` 访问级别收紧至 `package`，外部完全通过高层封装方法操作。

---

## 沿用不变的原则

- **契约先行** —— 双端共享 fixture 是唯一事实来源，改契约必改两端
- **不自证** —— 验收数字必须与独立来源（`sqlite3` / `find` / 服务器日志）对账
- **真实服务器腿** —— 每个主题至少有一条腿跑真实 Komga，不只有 fixture
- **Local First** —— UI 只读本地库，不直接发网络请求
