//! FFI boundary — Application Facade (plain Rust) + optional FRB adapter.
//!
//! Core → Application Facade → FFI Adapter → Flutter.
//!
//! `bridge` is plain Rust (adapter functions + domain types), compiled always
//! so the default (non-FRB) build and CI still cover it. Only the generated
//! `generated` module depends on flutter_rust_bridge, so it is gated behind
//! the `frb` feature — `cargo build --features frb` for Android, plain
//! `cargo build` everywhere else.

pub mod application;
pub mod bridge;
pub mod error;

#[cfg(feature = "frb")]
#[path = "generated/frb_generated.rs"]
pub mod generated;
