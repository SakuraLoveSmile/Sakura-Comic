# Read Progress Contract

- **Passive Progress**：普通翻页进度，可结合本地更新时间、Mutation 是否上传、服务端更新时间合并
- **Explicit Mark Read**：用户明确行为，优先级高于普通进度
- **Explicit Mark Unread**：不能被 max(page) 类规则覆盖
- 上传：Optimistic UI → Mutation Outbox → 节流 PATCH；强杀前未上传进度保留在 Outbox

规则由 `fixtures/read-progress/` 下的共享 Fixture 固化。
