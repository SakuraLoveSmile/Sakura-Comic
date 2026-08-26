# Initial Sync Contract

- 顺序：Libraries → Series → Books → Collections → Readlists → Read Progress
- 同步过程中 UI 直接读取已写入的数据，不等待全部完成
- 每个实体以 (serverId, remoteId) 落库；写入使用事务

共享 Fixture：
- `series-page.json` — Series 分页响应样例（200 OK 单页、3 条记录），Swift 与 Rust 解码测试共同加载

Stage 4 的完整媒体库镜像（FullSync）：
- Series / Books / Collections / Readlists 均以 size=100 分页拉取至 `last=true`，
  每页写库一次（事务）；Books 的 readProgress 内嵌在 BookDto 中随书入库；
  On-Deck（`/api/v1/books/ondeck`）作为阅读进度提示再次回填
- 完整媒体库 Fixture 见 `fixtures/library/`（README 同上）
