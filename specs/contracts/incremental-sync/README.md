# Incremental Sync Contract

- 触发：启动 / 回前台 / SSE 重连 / 网络恢复 / 手动刷新
- 流程：Remote 分页拉取变化 → Transaction → Local Store
- 处理：Added / Changed / Deleted / ReadProgress
- 状态记录在 sync_state（lastFullSync / lastSuccessfulSync / lastError / syncStatus）
