# Behavior Contracts

| 目录 | 内容 |
| --- | --- |
| initial-sync/ | 首次同步顺序（Libraries → Series → Books → Collections → Readlists → Progress）与分批规则 |
| incremental-sync/ | 分页拉取变化、事务合并、Added/Changed/Deleted |
| delete-propagation/ | 服务端删除的本地传播与级联 |
| read-progress/ | 进度合并、冲突规则（Mark Read / Mark Unread 语义） |
| offline-mutation/ | Outbox 状态机：重试 / 退避 / failed / 同族合并 / 重启恢复 / 上传前冲突判定 R1–R6 |
| reconnect/ | SSE 解析、重连与生命周期：事件只是提示，重连后必须先 Reconcile |
| fixtures/ | Swift / Rust 共享测试数据 |

每个目录内的 `README.md` 描述该契约；最终规则以 fixtures + 两端测试为验收依据。
