# Delete Propagation Contract

- 服务端删除由 Reconcile 的 id 扫描发现（事件尚未接入；两者语义一致）→ 本地级联删除
- 每种实体的删除范围（`store/prune.rs` / `KomgaStore` 等价实现）：
  - **Series**：`series` + `series_metadata` + `series_tags/genres/authors` +
    `series_fts` 行 + `collection_series` 成员 + 其全部 Books（递归走 Book 规则）
  - **Book**：`books` + `book_metadata` + `book_tags/authors` + `book_fts` 行 +
    `read_progress` + `readlist_books` 成员 + `downloads` / `download_pages`
  - **Collection**：`collections` + `collection_series`
  - **Readlist**：`readlists` + `readlist_books`
- 封面 / 缓存条目同步失效：删 `thumbnails` 行并由 facade 删除磁盘文件；
  墓碑 `cause` 区分 `reconcile`（本实体直接消失）与 `cascade`（随父实体一起消失）
- 未上传的 Outbox 条目：实体被删即丢弃其 `pending_mutations`（给一本服务器上已不
  存在的书上传进度没有意义）。级联删除的 Book 同样适用
- 墓碑：`deleted_entities(server_id, entity_type, remote_id, deleted_at, cause)`；
  同一 id 重新出现在远端时清除墓碑
- 固化位置：`fixtures/sync/scenario-reconcile.json` 第 3/5 步断言墓碑集合与
  「镜像 == 快照」；`ffi::application` 测试额外断言封面文件从磁盘消失
