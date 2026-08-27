# Initial Sync Contract

- 顺序：Libraries → Series → Books → Collections → Readlists → Read Progress
- 同步过程中 UI 直接读取已写入的数据，不等待全部完成
- 每个实体以 (serverId, remoteId) 落库；写入使用事务

共享 Fixture：
- `series-page.json` — Series 分页响应样例（200 OK 单页、3 条记录），Swift 与 Rust 解码测试共同加载

Stage 5 起 Bootstrap 是**可中断恢复**的按序步骤引擎（`sync::full` / `FullSync.swift`）：
- 步骤顺序即 `sync_state::BOOTSTRAP_ORDER`；每页一次事务写入，并在同一写入路径里
  把下一页写进 `sync_state.sync_cursor`（`page=N`；Books 为 `series=<id>|page=<n>`）
- 重启后从第一个未完成步骤续跑；已完成步骤跳过（`skipped_steps`），续跑步骤记入
  `resumed_steps`；步骤失败写 `sync_status = error` 且保留游标
- 强制重镜像：`StartAt::Fresh`（清空游标）
- 共享场景：`fixtures/sync/scenario-reconcile.json`、`fixtures/sync/scenario-interrupt.json`
  （由 `scripts/gen_stage5_fixtures.py` 生成；双端读同一份）
- 比对深度：不止 id 集合。每一步都逐字段比对 series 的名称/状态/lastModified/四个阅读计数、
  归一化 genres 与 summary、book 的标题/summary/tags/numberSort/pagesCount/lastModified、
  合集成员、书单保序成员、阅读进度集合、FTS 行数、library 的 root+unavailable，
  以及无孤儿 Book、墓碑集合、`sync_state` 状态与每步请求次数
- 「时间戳不动、内容会变」的场景必须单独覆盖：s5 改书metadata（同时推进 lastModified）、
  s6 只推进 series 的阅读计数而**不**推进 lastModified

Stage 4 的完整媒体库镜像（FullSync）：
- Series / Books / Collections / Readlists 均以 size=100 分页拉取至 `last=true`，
  每页写库一次（事务）；Books 的 readProgress 内嵌在 BookDto 中随书入库；
  On-Deck（`/api/v1/books/ondeck`）作为阅读进度提示再次回填
- 完整媒体库 Fixture 见 `fixtures/library/`（README 同上）
