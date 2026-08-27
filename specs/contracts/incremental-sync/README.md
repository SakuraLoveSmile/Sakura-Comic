# Incremental Sync Contract（Reconcile Sync）

- 触发：启动 `app_launch` / 回前台 `did_become_active` / SSE 重连 `sse_reconnected` /
  网络恢复 `network_recovered` / 手动刷新 `manual_refresh`。
  前两个受 `MIN_RECONCILE_INTERVAL_SECS = 60` 节流，其余立即执行；
  **所有触发的执行路径完全相同**（正确性不依赖触发来源）
- 流程：每种实体做远端**全量 id 扫描**（分页 → 事务写入 → 记游标）→
  扫描完成后与本地 id 集合求差 → 差集即远端删除
- 处理：Added（本地无此 id）/ Changed（`lastModified` 变了）/ Deleted（本地多余 id →
  级联删除 + 墓碑）/ ReadProgress（书的内嵌进度 + On-Deck 回填）
- 安全规则：**prune 只在扫描到达 `last = true` 后执行**；游标续跑时已提交页的 id
  用本地行播种进 seen 集合。失败的同步最多推迟一个删除，绝不删远端还在的数据
- 状态记录在 `sync_state`：一行一个 `(serverId, entityType)`，字段
  `lastSyncAt` / `syncCursor` / `syncStatus`(`idle|syncing|error`) / `lastError`；
  `entity_type = 'full'` 行承载服务器级 `lastFullSync` / `lastSuccessfulSync`
- 目标：**不依赖 SSE 的完整性也能最终恢复正确状态**（场景 fixtures 全部以
  `"sse": "disabled"` 运行）
