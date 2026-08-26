# 阅读器

## 模式

- **Paged**：单页翻页，支持左→右 / 右→左
- **Double Page**：双页（Page 1 | Page 2），支持 Manga RTL、First Page Single、Landscape 优化
- **Webtoon**：连续垂直滚动，需要 Virtualization / 图片 Prefetch / Decode Queue / Memory Limit

## Pipeline

```text
Page Descriptor → Cache Lookup → Download → Disk → Decode → Memory Cache → Render
```

## 缓存策略

阅读当前页 N 时优先预加载 N+1、N+2，可视情况缓存 N-1。
**禁止一次加载整本漫画到内存。**

## 性能目标

- 500+ 页 / 4K 大图 / 快速连续翻页 / 长时间 Webtoon 滚动可用
- 60 FPS（高刷设备尽可能 120 FPS）
- 避免大图 Decode 阻塞 UI 线程、避免 FFI 大块 Byte Copy、避免一次加载过多图片

## 进度

Reader → Local Progress → Optimistic UI → Mutation Outbox → 节流 PATCH（禁止每页一请求）。
