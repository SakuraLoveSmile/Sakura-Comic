# docs

- [roadmap.md](roadmap.md) — **路线图**：主题式排期，取代 Phase / Stage 体系

## 设计文档

- [architecture.md](architecture.md) — 整体架构、多服务器模型、错误模型、日志
- [sync-engine.md](sync-engine.md) — 同步引擎四管线、SSE 重连、Outbox、进度冲突
- [database-schema.md](database-schema.md) — SQLite Schema 与 FTS5 搜索
- [reader.md](reader.md) — 阅读器模式、缓存策略、进度节流
- [offline-storage.md](offline-storage.md) — 缓存与离线下载分离

## 验收存档

历史阶段验收记录，仅存档，不再驱动排期：

- [stage2-checklist.md](stage2-checklist.md) — API 契约与服务器管理
- [stage4-checklist.md](stage4-checklist.md) — 完整媒体库
- [stage5-checklist.md](stage5-checklist.md) — 同步引擎（Bootstrap + Reconcile + 删除传播）
- [stage6-checklist.md](stage6-checklist.md) — SSE 事件流 + Mutation Outbox（断网 / 强杀 / 重启后自动上传）
- [stage7-checklist.md](stage7-checklist.md) — 阅读器基础版
- [stage8-checklist.md](stage8-checklist.md) — 阅读器性能与缓存
- [stage9-checklist.md](stage9-checklist.md) — 离线下载（Download Manager / 断网整本可读 / 复网自动上传）
- [phase0-checklist.md](phase0-checklist.md) — 垂直切片
