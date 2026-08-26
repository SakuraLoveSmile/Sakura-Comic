# Comic App (Flutter shell)

- `lib/`：纯 UI（列表、动画、导航、图片渲染）。不直接访问 Komga API。
- `android/`：Android 宿主工程（由 `flutter create . --platforms android` 补齐后接入 Rust 库）。
- Rust Core 位于 `../komga_core`；FFI 绑定由 flutter_rust_bridge_codegen 生成到 `lib/src/rust/`（Phase 0 step 02）。

用 `flutter test` 运行 Widget 测试。
