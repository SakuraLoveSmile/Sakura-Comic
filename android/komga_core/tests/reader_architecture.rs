//! Stage 8 architecture gate.
//!
//! The objective states two rules about the image pipeline that are easy to
//! break by accident six months from now, and impossible to notice in review:
//!
//! 1. Large image bytes must never cross the FFI. The pipeline is
//!    Komga -> Rust download -> disk cache -> Flutter local file -> decode, and
//!    a `Vec<u8>` in a page or cover signature is the shortcut that looks
//!    harmless until a 500-page 4K book turns every page turn into a 24 MB
//!    marshalling copy.
//! 2. `flutter_rust_bridge` may only be used inside `src/ffi/`. Everywhere else
//!    the core must be plain Rust, or the crate cannot be built for a platform
//!    that has no Flutter (the fixture server, the smoke binaries, tests).
//!
//! These are source-level assertions on purpose: the compile already proves the
//! types, but only a text scan catches someone *adding* a byte-returning entry
//! point, and it fails with a message that says what to do instead.

use std::collections::BTreeSet;
use std::path::PathBuf;

fn core_root() -> PathBuf {
    // tests/ -> crate root
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn read(relative: &str) -> String {
    let path = core_root().join(relative);
    std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("cannot read {path:?}: {error}"))
}

/// Strip line comments and doc comments so a mention inside prose cannot pass or
/// fail a rule about code.
fn code_only(source: &str) -> String {
    source
        .lines()
        .filter(|line| {
            let trimmed = line.trim_start();
            !(trimmed.starts_with("//") || trimmed.starts_with("///") || trimmed.starts_with("//!"))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Every `pub fn` / `pub async fn` signature in the FFI surface, with its return
/// type. Multi-line signatures are joined, which is what `cargo fmt` produces.
fn signatures(source: &str) -> Vec<(String, String)> {
    let flat = source.replace('\n', " ");
    let mut out = Vec::new();
    for chunk in flat.split("pub async fn ").skip(1).chain(
        flat.split("pub fn ")
            .skip(1)
            .map(|rest| rest.trim_start_matches("async ")),
    ) {
        let name: String = chunk
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        // The return type runs from `->` to the first `{` that opens the body.
        let head = match chunk.split_once("->") {
            Some((_, rest)) => rest.split_once('{').map(|(head, _)| head).unwrap_or(rest),
            None => "",
        };
        out.push((name, head.trim().to_string()));
    }
    out
}

#[test]
fn no_ffi_entry_point_carries_image_bytes() {
    let source = read("src/ffi/bridge.rs");
    let code = code_only(&source);
    assert!(
        !code.contains("Vec<u8>"),
        "flutter_rust_bridge::ffi's page/cover surface must not mention Vec<u8>: \
         hand back a file path instead (see reader_page_path)"
    );
    let offenders: Vec<String> = signatures(&code)
        .into_iter()
        .filter(|(name, returns)| {
            let image_shaped = name.contains("page")
                || name.contains("cover")
                || name.contains("thumbnail")
                || name.contains("reader")
                || name.contains("bytes");
            image_shaped && (returns.contains("u8") || returns.contains("Uint8List"))
        })
        .map(|(name, returns)| format!("{name} -> {returns}"))
        .collect();
    assert!(
        offenders.is_empty(),
        "these FFI functions return collections or bytes where a path belongs: {offenders:?}"
    );
}

/// The rule that keeps the crate portable: the frb dependency may only be
/// reachable from the `ffi` module.
#[test]
fn flutter_rust_bridge_stays_inside_the_ffi_layer() {
    let mut offenders = BTreeSet::new();
    let mut entries = vec![core_root().join("src")];
    while let Some(dir) = entries.pop() {
        for entry in std::fs::read_dir(&dir).expect("src tree readable") {
            let path = entry.expect("entry").path();
            if path.is_dir() {
                entries.push(path);
                continue;
            }
            if path.extension().and_then(|e| e.to_str()) != Some("rs") {
                continue;
            }
            let text = std::fs::read_to_string(&path).expect("rust file readable");
            if code_only(&text).contains("flutter_rust_bridge") {
                let relative = path.strip_prefix(core_root()).unwrap_or(&path);
                if !relative.starts_with("src/ffi") {
                    offenders.insert(relative.to_string_lossy().into_owned());
                }
            }
        }
    }
    // The one file that does use frb heavily — the generated glue — lives under
    // src/ffi/generated, which is inside the allowed layer.
    assert!(
        offenders.is_empty(),
        "flutter_rust_bridge leaked outside src/ffi/: {offenders:?}"
    );
}

/// The UI is never allowed to hold image bytes: it is handed a path and decodes
/// the file itself, so the pipeline cannot be short-circuited from Dart.
#[test]
fn the_core_hands_paths_and_the_reader_cache_tiers_exist_on_disk() {
    let source = read("src/ffi/application.rs");
    assert!(
        source.contains("location.path.to_string_lossy()"),
        "reader_page_path must hand back a path, as it always has"
    );
    let cache = read("src/cache/mod.rs");
    for tier in ["thumbnails", "pages", "prefetch"] {
        assert!(
            cache.contains(&format!(
                "pub const {}_DIR: &str = \"{tier}\";",
                tier.to_uppercase()
            )),
            "the cache layout names {tier}/ as a tier"
        );
    }
    // The Stage 7 rule that Stage 8 must not quietly lose: prefetch never blocks
    // a render, and the reader core issues no HTTP.
    let reader = read("src/reader/mod.rs");
    assert!(reader.contains("`reader` never issues HTTP"));
    let loader = read("src/reader/loader.rs");
    assert!(
        !code_only(&loader).contains("reqwest"),
        "the reader pipeline must not grow its own transport"
    );
}
