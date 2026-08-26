# android — Android 平台

分层：

```text
Flutter (UI / 动画 / 导航 / 图片解码与渲染 / 交互)
   ↓  Application API (粗粒度)
flutter_rust_bridge
   ↓
Rust Core (komga_core: HTTP / SSE / SQLite / Sync / Cache / Downloads)
```

Flutter 不直接访问 Komga API；所有数据库访问统一经过 Rust Core。

## FFI 接线（Stage 1 已完成）

- `flutter_rust_bridge_codegen generate`（FRB 2.x）镜像 `crate::ffi::bridge`，
  Rust 侧生成 `komga_core/src/ffi/generated/frb_generated.rs`（`frb` feature 门控，
  普通 host 构建不受影响），Dart 侧生成 `app/lib/src/rust/`（含镜像模型类）
- `cargo-ndk` 交叉编译 arm64-v8a / armeabi-v7a / x86_64 → `jniLibs/libkomga_core.so`
  （构建产物不入库，需 `scripts/frb_wire.sh` 重新生成）
- Dart 侧：`RustLibraryRepository`（`lib/src/library_repository.dart`）走
  `FrbRustCoreApi`（`lib/src/rust_core_frb.dart`）；native 库不可用时回退
  Stub 并显示状态条，App 始终可启动
- `AndroidManifest` 已声明 INTERNET + cleartext（Phase 0 LAN http 服务器）

一键接线：`bash scripts/frb_wire.sh`（codegen → jniLibs → analyze/test）。

CI：`android-core-ndk` job 在 ubuntu runner 上用 Android NDK 交叉编译三 ABI；
`flutter-app` job 做 analyze / test / debug APK。
