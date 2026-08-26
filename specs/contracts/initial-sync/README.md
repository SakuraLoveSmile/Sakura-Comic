# Initial Sync Contract

- 顺序：Libraries → Series → Books → Collections → Readlists → Read Progress
- 同步过程中 UI 直接读取已写入的数据，不等待全部完成
- 每个实体以 (serverId, remoteId) 落库；写入使用事务

共享 Fixture：
- `series-page.json` — Series 分页响应样例（200 OK 单页、3 条记录），Swift 与 Rust 解码测试共同加载
