//! komga_core — the local-first Rust core for the Android client.
//!
//! Layering rule: only the `ffi` module may expose flutter_rust_bridge types;
//! every other module is plain Rust. Core → Application Facade → FFI Adapter.

pub mod api;
pub mod cache;
pub mod diagnostics;
pub mod downloads;
pub mod ffi;
pub mod model;
pub mod reader;
pub mod store;
pub mod sync;
