# 同步引擎

四部分：**BootstrapSync / ReconciliationSync / EventDrivenSync / MutationUploadSync**。

## Bootstrap Sync

首次连接：Libraries → Series → Books → Collections → Readlists → Read Progress → SQLite。
同步过程中 UI 直接读取已写入的数据，不等待全部完成即可进入书架。

## Reconciliation Sync

触发：App 启动 / 回前台 / SSE 重连 / 网络恢复 / 手动刷新。
流程：分页拉取变化 → Transaction → Local Store；处理 Added / Changed / Deleted / ReadProgress。

## Event Driven Sync

SSE 端点：`/sse/v1/events`。
流程：SSE Event → Mark Entity Dirty → Targeted Reconcile → SQLite Update → UI Observe。

## SSE 重连

断开 → 重连 → ReconciliationSync → 恢复 EventDrivenSync。
禁止假设连接期间不漏事件。

## Mutation Outbox

本地先更新 → 写 pending_mutations → 后台上传 → 成功后删除。
支持：READ_PROGRESS / MARK_READ / MARK_UNREAD（未来可扩展）。
字段：id / server_id / entity_id / mutation_type / payload / created_at / retry_count / last_error。

## 阅读进度冲突

- **Passive Progress**：可结合本地更新时间、Mutation 是否上传、服务端更新时间合并
- **Explicit Mark Read**：优先级高于普通进度
- **Explicit Mark Unread**：不能被 max(page) 类规则覆盖

最终规则见 `specs/contracts/read-progress/`，由 Shared Fixture 验证两端行为一致。

## 上传节流

阅读中禁止每翻一页就请求：Page → Local DB → debounce/throttle → PATCH。
App 被强杀前未上传的进度仍在 Outbox，下次启动继续上传。
