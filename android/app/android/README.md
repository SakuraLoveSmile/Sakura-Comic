# Android 宿主工程（占位）

Phase 0 step 02 在此接入：
- Gradle 通过 cargo-ndk 构建 `komga_core`（armeabi-v7a / arm64-v8a / x86_64）
- flutter_rust_bridge 生成的 `rust_lib_komga_core` 依赖
- 注意：Rust 侧 HTTP / SQLite / Sync 全部在 Core 内，Flutter 仅持粗粒度 Application API
