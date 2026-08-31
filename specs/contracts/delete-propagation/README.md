# Delete Propagation Contract

- 服务端删除由 Reconcile 的 id 扫描发现（事件尚未接入；两者语义一致）→ 本地级联删除
- 每种实体的删除范围（`store/prune.rs` / `KomgaStore` 等价实现）：
  - **Series**：`series` + `series_metadata` + `series_tags/genres/authors` +
    `series_fts` 行 + `collection_series` 成员 + 其全部 Books（递归走 Book 规则）
  - **Book**：`books` + `book_metadata` + `book_tags/authors` + `book_fts` 行 +
    `read_progress` + `readlist_books` 成员。
    **`downloads` / `download_pages` 不在级联范围内**（Stage 9）：见下条同一推理——
    离线下载是用户主动留在设备上的字节，比一条待上传的写更不可恢复（写能重放，
    文件在下一次断网时就再也拿不回来）。书行消失只让本地副本变成
    `stale`（"已失效"），仍然可读、仍然只有用户能删
  - **Collection**：`collections` + `collection_series`
  - **Readlist**：`readlists` + `readlist_books`
- 封面 / 缓存条目同步失效：删 `thumbnails` 行并由 facade 删除磁盘文件；
  墓碑 `cause` 区分 `reconcile`（本实体直接消失）与 `cascade`（随父实体一起消失）
- 离线下载：**随镜像一起保留**（Stage 9）。理由与下一条完全相同，且更强——
  「这一轮扫描里没看到」是推断，而下载文件是**唯一**一份本地才有的东西。
  `prune::delete_book` 与 `delete_server_mirror` 都不再触碰这两张表；
  断开一台服务器同样保留下载行与文件（行是唯一能把文件说回 `(serverId, bookId)`
  的索引，目录名是 sanitised 的），要清掉它们请走 `download_delete_all`。
  契约测试 `a_download_survives_every_automatic_cleanup_and_dies_only_by_a_user_gesture`
  逐条攻击钉住这条（变异检查：把两条 DELETE 放回 `prune::delete_book` 必须变红）
- 未上传的 Outbox 条目：**随镜像一起保留**。远端删除是「这一轮扫描里没看到这个 id」
  的推断，而 offset 分页在并发增删下可能整体错位、漏掉某个 id；镜像行删错了下一轮
  还能重新拉回来，用户动作丢了就再也回不来。所以只有上传阶段（拿到服务器对 404/410
  的确认）才有权丢弃 `pending_mutations`；Book 与其所属 Series 的级联同理
- 墓碑：`deleted_entities(server_id, entity_type, remote_id, deleted_at, cause)`；
  同一 id 重新出现在远端时清除墓碑
- 固化位置：`fixtures/sync/scenario-reconcile.json` 第 3/5 步断言墓碑集合与
  「镜像 == 快照」；`ffi::application` 测试额外断言封面文件从磁盘消失
