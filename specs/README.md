# specs — 跨端一致性三层契约

1. **Transport Contract** — `specs/openapi/komga-openapi.yaml`
   约束 HTTP Method / URL / Request & Response Schema / Pagination / Filter / Enum / Nullable / 字段名。
   Swift 与 Rust 的 API Model 均以此文件为事实来源。

2. **Event Contract** — `specs/events/komga-sse-events.md`
   记录 SSE（/sse/v1/events）事件语义；SSE 只是变化提示，不是可靠消息队列。

3. **Behavior Contract** — `specs/behavior.md` + `specs/contracts/`
   规范 Swift 与 Rust 两套实现必须具有相同行为，并用 Shared Fixture 测试验证。
