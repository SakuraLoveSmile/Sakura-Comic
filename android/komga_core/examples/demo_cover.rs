//! Write a demo cover PNG so cover bytes can be inspected on the host:
//!
//! ```text
//! cargo run --example demo_cover -- /tmp/demo-cover.png
//! ```

fn main() {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "/tmp/demo-cover.png".into());
    let bytes = komga_core::cache::demo_png::demo_cover_bytes("demo-seed");
    std::fs::write(&path, &bytes).expect("write png");
    println!("wrote {} bytes -> {}", bytes.len(), path);
}
