# 架构

## Local First

```text
Komga Server
     ↓ REST + SSE
Remote Gateway
     ↓
Sync Engine (Reconcile | Mutation Outbox)
     ↓
SQLite (local mirror)
     ↓
Query Layer (Library / Progress / Downloads)
     ↓
UI
```

UI 的唯一主要数据源为本地数据库；网络请求不直接驱动 UI 页面。收益：页面秒开、
弱网可用、离线可浏览、搜索与筛选无网络延迟、后台更新时 UI 自动刷新。

## 多服务器模型

所有 Komga 远端 ID 都不能单独作为数据库主键，统一使用 `(serverId, remoteId)`。
涉及：libraries / series / books / collections / readlists / read_progress /
downloads / pending_mutations（read_progress 为 `(server_id, book_id)`）。
避免 ID 冲突、缓存污染、进度串库、封面串库。

## 平台分层

- **Android**：Flutter(UI) → Application API → flutter_rust_bridge → Rust Core
  （HTTP / SSE / SQLite / Sync / Cache / Downloads）
- **Apple**：SwiftUI → Feature Model → KomgaKit
  （KomgaAPI / KomgaStore / KomgaSync / KomgaReader）

## 错误模型

统一错误类型：AuthenticationError / NetworkError / ServerError /
ApiCompatibilityError / DatabaseError / StorageError / DecodeError。
UI 不接触 reqwest / SQLite / URLSession 底层错误，由 Core 映射为用户可理解状态。

## 日志

分类：API / SYNC / DATABASE / CACHE / DOWNLOAD / READER / SSE。
Debug 可记录详细日志；Release 禁止输出 API Key、Basic 密码、Authorization Header。
