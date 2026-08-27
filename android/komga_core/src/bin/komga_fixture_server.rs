//! komga_fixture_server — a Komga-shaped HTTP server over loopback.
//!
//! The sync engine is normally exercised through injected fetchers, which
//! bypasses `KomgaClient` entirely: URL building, auth headers, `page`/`size`
//! slicing, Spring Data page envelopes and HTTP error mapping. This binary
//! serves the Stage 5 scenario snapshots over real TCP so the acceptance chain
//! (`stage5_smoke`) runs end-to-end against an actual HTTP server.
//!
//! What it serves is chosen by a *file holding a snapshot name*, re-read on
//! every request, so a test script can change "the library on the server"
//! while the client is running — exactly what a real Komga does when someone
//! adds, edits or deletes a series:
//!
//!   echo s1 > /tmp/komga_fixture/snapshot     # the server just changed
//!
//! Authentication follows Komga's own rule: an API key in `X-API-Key` (which
//! is what `KomgaClient` sends) or a `Basic` `Authorization` header; anything
//! else gets a 401. The key value is checked, which is what proves the client
//! really transmits the credential it was configured with.
//!
//! Usage:
//!   komga_fixture_server --scenario specs/contracts/fixtures/sync/scenario-reconcile.json \
//!       --snapshot-file /tmp/komga_fixture/snapshot --expect-key KEY [--port 0]
//!
//! Prints `LISTENING <port>` once bound, then serves until killed. Port 0 lets
//! the OS pick a free port, so parallel runs never collide.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::thread;

use serde_json::{json, Value};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut config = Config::default();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--scenario" => {
                i += 1;
                config.scenario = PathBuf::from(&args[i]);
            }
            "--snapshot-file" => {
                i += 1;
                config.snapshot_file = PathBuf::from(&args[i]);
            }
            "--expect-key" => {
                i += 1;
                config.expect_key = args[i].clone();
            }
            "--port" => {
                i += 1;
                config.port = args[i].parse().expect("--port takes a number");
            }
            "--help" | "-h" => {
                println!(
                    "usage: komga_fixture_server --scenario PATH --snapshot-file PATH [--expect-key KEY] [--port N]"
                );
                return;
            }
            other => panic!("unknown arg: {other}"),
        }
        i += 1;
    }

    let listener = TcpListener::bind(("127.0.0.1", config.port)).expect("bind");
    println!(
        "LISTENING {}",
        listener.local_addr().expect("local addr").port()
    );
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let config = config.clone();
                thread::spawn(move || {
                    let _ = serve(stream, &config);
                });
            }
            Err(_) => continue,
        }
    }
}

#[derive(Clone, Default)]
struct Config {
    scenario: PathBuf,
    snapshot_file: PathBuf,
    expect_key: String,
    port: u16,
}

/// The snapshot named in `snapshot_file`, looked up in the scenario JSON.
fn current_snapshot(config: &Config) -> Option<Value> {
    let wanted = std::fs::read_to_string(&config.snapshot_file).ok()?;
    let wanted = wanted.trim();
    let text = std::fs::read_to_string(&config.scenario).ok()?;
    let scenario: Value = serde_json::from_str(&text).ok()?;
    scenario
        .get("snapshots")?
        .as_array()?
        .iter()
        .find(|snap| snap.get("id").and_then(Value::as_str) == Some(wanted))
        .cloned()
}

fn serve(stream: TcpStream, config: &Config) -> std::io::Result<()> {
    let mut stream = stream;
    // Read the request headers only: GETs carry no body, and waiting for EOF
    // would hang on a keep-alive client until it times out.
    let reader = stream.try_clone()?;
    let mut lines = BufReader::new(reader).lines();
    let request_line = lines.next().transpose()?.unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let _method = parts.next().unwrap_or("GET");
    let target = parts.next().unwrap_or("/");
    let mut authorized = false;
    while let Some(line) = lines.next().transpose()? {
        let line = line.trim_end().to_ascii_lowercase();
        if line.is_empty() {
            break;
        }
        // Komga accepts an API key header or HTTP Basic; both are honoured,
        // and an API key must match what the runner configured.
        if let Some(value) = line.strip_prefix("x-api-key:") {
            authorized = !config.expect_key.is_empty() && value.trim() == config.expect_key;
        } else if line.starts_with("authorization: basic") {
            authorized = true;
        }
    }
    if !authorized {
        return respond(&mut stream, 401, r#"{"message":"missing credentials"}"#);
    }

    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p, q),
        None => (target, ""),
    };
    let page = query_param(query, "page").unwrap_or(0);
    let size = query_param(query, "size").unwrap_or(20);

    let Some(state) = current_snapshot(config) else {
        return respond(
            &mut stream,
            500,
            r#"{"message":"fixture snapshot unavailable"}"#,
        );
    };

    if path == "/actuator/info" {
        return respond(
            &mut stream,
            200,
            &json!({ "build": { "version": "1.26.3-fixture" } }).to_string(),
        );
    }
    // `/api/v1/series/{id}/books` — the id comes from the path, like Komga.
    if let Some(rest) = path.strip_prefix("/api/v1/series/") {
        if let Some(series_id) = rest.strip_suffix("/books") {
            let items = page_items(&state, &["books", series_id]);
            return page_response(&mut stream, &items, page, size);
        }
    }
    let items = match path {
        // Komga answers /api/v1/libraries with a plain array, not a page.
        "/api/v1/libraries" => {
            let libraries = state["libraries"].as_array().cloned().unwrap_or_default();
            return respond(
                &mut stream,
                200,
                &serde_json::to_string(&libraries).unwrap_or_else(|_| "[]".into()),
            );
        }
        "/api/v1/series" => page_items(&state, &["series"]),
        "/api/v1/books/ondeck" => page_items(&state, &["onDeck"]),
        "/api/v1/collections" => page_items(&state, &["collections"]),
        "/api/v1/readlists" => page_items(&state, &["readlists"]),
        _ => return respond(&mut stream, 404, r#"{"message":"not found"}"#),
    };
    page_response(&mut stream, &items, page, size)
}

/// Concatenate a "list of pages" (or a map of series -> list of pages) into
/// one ordered list, so the client's own `page`/`size` decides what it sees.
fn page_items(state: &Value, keys: &[&str]) -> Vec<Value> {
    let mut cursor: &Value = state;
    for key in keys {
        cursor = &cursor[key];
    }
    let pages: Vec<&Vec<Value>> = match cursor.as_array() {
        Some(list) => list.iter().filter_map(Value::as_array).collect(),
        None => cursor
            .as_object()
            .map(|map| {
                map.values()
                    .flat_map(|nested| nested.as_array().into_iter().flatten())
                    .filter_map(Value::as_array)
                    .collect()
            })
            .unwrap_or_default(),
    };
    pages.into_iter().flatten().cloned().collect()
}

fn page_response(
    stream: &mut TcpStream,
    items: &[Value],
    page: usize,
    size: usize,
) -> std::io::Result<()> {
    let size = size.max(1);
    let start = page.saturating_mul(size);
    let content: Vec<Value> = items.iter().skip(start).take(size).cloned().collect();
    let total_pages = items.len().div_ceil(size) as i64;
    let body = json!({
        "content": content,
        "totalElements": items.len() as i64,
        "totalPages": total_pages,
        "number": page as i64,
        "size": size as i64,
        "first": page == 0,
        "last": start + content.len() >= items.len(),
    });
    respond(stream, 200, &body.to_string())
}

fn query_param(query: &str, key: &str) -> Option<usize> {
    query.split('&').find_map(|pair| {
        let (k, v) = pair.split_once('=')?;
        (k == key).then(|| v.parse().ok()).flatten()
    })
}

fn respond(stream: &mut TcpStream, status: u16, body: &str) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        401 => "Unauthorized",
        404 => "Not Found",
        _ => "Internal Server Error",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}
