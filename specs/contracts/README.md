# Behavior Contracts

| 目录 | 内容 |
| --- | --- |
| initial-sync/ | 首次同步顺序（Libraries → Series → Books → Collections → Readlists → Progress）与分批规则 |
| incremental-sync/ | 分页拉取变化、事务合并、Added/Changed/Deleted |
| delete-propagation/ | 服务端删除的本地传播与级联 |
| read-progress/ | 进度合并、冲突规则（Mark Read / Mark Unread 语义） |
| fixtures/ | Swift / Rust 共享测试数据 |

每个目录内的 `README.md` 描述该契约；最终规则以 fixtures + 两端测试为验收依据。
