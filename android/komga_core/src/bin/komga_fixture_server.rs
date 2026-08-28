//! komga_fixture_server — a Komga-shaped HTTP server over loopback.
//!
//! The sync engine is normally exercised through injected fetchers, which
//! bypasses `KomgaClient` entirely: URL building, auth headers, `page`/`size`
//! slicing, Spring Data page envelopes and HTTP error mapping. This binary
//! serves the scenario snapshots over real TCP so the acceptance chain runs
//! end-to-end against an actual HTTP server.
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
//! Stage 6 added the two write verbs and the event stream:
//!
//!   PATCH  /api/v1/books/{id}/read-progress   204, body {page?, completed?}
//!   DELETE /api/v1/books/{id}/read-progress   204            (mark unread)
//!   GET    /sse/v1/events                     text/event-stream
//!
//! Accepted writes are journalled (one JSON object per line) so a script can
//! assert what the client actually put on the wire, and merged into a progress
//! overlay so a later `GET /api/v1/books/{id}` reports them — that is what makes
//! "uploaded, and the server now agrees" checkable rather than assumed.
//!
//! Usage:
//!   komga_fixture_server --scenario PATH --snapshot-file PATH [--expect-key KEY]
//!       [--port N] [--journal PATH] [--progress-file PATH] [--fault-file PATH]
//!       [--sse-file PATH]
//!
//! Prints `LISTENING <port>` once bound, then serves until killed. Port 0 lets
//! the OS pick a free port, so parallel runs never collide.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut config = Config::default();
    let mut i = 1;
    while i < args.len() {
        let flag = args[i].as_str();
        let mut take = |what: &mut dyn FnMut(String)| {
            i += 1;
            if i < args.len() {
                what(args[i].clone());
            }
        };
        match flag {
            "--scenario" => take(&mut |v| config.scenario = PathBuf::from(v)),
            "--snapshot-file" => take(&mut |v| config.snapshot_file = PathBuf::from(v)),
            "--expect-key" => take(&mut |v| config.expect_key = v),
            "--journal" => take(&mut |v| config.journal = PathBuf::from(v)),
            "--progress-file" => take(&mut |v| config.progress_file = PathBuf::from(v)),
            "--fault-file" => take(&mut |v| config.fault_file = PathBuf::from(v)),
            "--sse-file" => take(&mut |v| config.sse_file = PathBuf::from(v)),
            "--port" => take(&mut |v| config.port = v.parse().expect("--port takes a number")),
            "--help" | "-h" => {
                println!(
                    "usage: komga_fixture_server --scenario PATH --snapshot-file PATH \
                     [--expect-key KEY] [--port N] [--journal PATH] [--progress-file PATH] \
                     [--fault-file PATH] [--sse-file PATH]"
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
    progress_file: PathBuf,
    fault_file: PathBuf,
    journal: PathBuf,
    sse_file: PathBuf,
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

struct Request {
    method: String,
    path: String,
    query: String,
    body: String,
    json_content_type: bool,
}

fn serve(stream: TcpStream, config: &Config) -> std::io::Result<()> {
    let mut stream = stream;
    // ONE buffered reader for headers and body: reading headers through a
    // BufReader and the body off the raw socket loses the bytes the buffer
    // already pulled ahead, and the request then blocks forever.
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    if reader.read_line(&mut request_line)? == 0 {
        return Ok(());
    }
    let request_line = request_line.trim_end().to_string();
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("GET").to_ascii_uppercase();
    let target = parts.next().unwrap_or("/");
    let mut authorized = false;
    let mut content_length = 0usize;
    let mut json_content_type = false;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            break;
        }
        let lowered = line.trim_end().to_ascii_lowercase();
        if lowered.is_empty() {
            break;
        }
        // Komga accepts an API key header or HTTP Basic; both are honoured,
        // and an API key must match what the runner configured.
        if let Some(value) = lowered.strip_prefix("x-api-key:") {
            authorized = !config.expect_key.is_empty() && value.trim() == config.expect_key;
        } else if lowered.starts_with("authorization: basic") {
            authorized = true;
        } else if let Some(value) = lowered.strip_prefix("content-length:") {
            content_length = value.trim().parse().unwrap_or(0);
        } else if lowered.starts_with("content-type:") {
            json_content_type = lowered.contains("application/json");
        }
    }
    // Only the write verbs carry a body; reading exactly Content-Length bytes
    // keeps a keep-alive GET from blocking on EOF.
    let mut body = String::new();
    if content_length > 0 {
        let mut buf = vec![0u8; content_length];
        reader.read_exact(&mut buf)?;
        body = String::from_utf8_lossy(&buf).into_owned();
    }
    if !authorized {
        return respond(&mut stream, 401, r#"{"message":"missing credentials"}"#);
    }
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p, q),
        None => (target, ""),
    };
    let request = Request {
        method,
        path: path.to_string(),
        query: query.to_string(),
        body,
        json_content_type,
    };
    route(&mut stream, config, &request)
}

fn route(stream: &mut TcpStream, config: &Config, request: &Request) -> std::io::Result<()> {
    let path = request.path.as_str();

    // ---- Stage 6: the event stream -------------------------------------------
    if path == "/sse/v1/events" {
        return sse_stream(stream, config);
    }
    if request.method != "GET" && path != "/actuator/info" {
        return write_route(stream, config, request);
    }

    let page = query_param(&request.query, "page").unwrap_or(0);
    let size = query_param(&request.query, "size").unwrap_or(20);

    if path == "/actuator/info" {
        return respond(
            stream,
            200,
            &json!({ "build": { "version": "1.26.3-fixture" } }).to_string(),
        );
    }
    let Some(state) = current_snapshot(config) else {
        return respond(stream, 500, r#"{"message":"fixture snapshot unavailable"}"#);
    };

    // `/api/v1/series/{id}/books` — the id comes from the path, like Komga.
    if let Some(rest) = path.strip_prefix("/api/v1/series/") {
        if let Some(series_id) = rest.strip_suffix("/books") {
            let items = page_items(&state, &["books", series_id]);
            return page_response(stream, &items, page, size);
        }
    }
    // `GET /api/v1/books/{id}` — the Targeted Re-fetch the uploader must do
    // before it writes anything.
    if let Some(book_id) = path
        .strip_prefix("/api/v1/books/")
        .filter(|id| !id.contains('/'))
    {
        let found = all_books(&state)
            .into_iter()
            .find(|book| book.get("id").and_then(Value::as_str) == Some(book_id));
        return match found {
            Some(book) => {
                let merged = merge_progress(config, book_id, book);
                respond(stream, 200, &merged.to_string())
            }
            None => respond(stream, 404, r#"{"message":"book not found"}"#),
        };
    }
    let items = match path {
        // Komga answers /api/v1/libraries with a plain array, not a page.
        "/api/v1/libraries" => {
            let libraries = state["libraries"].as_array().cloned().unwrap_or_default();
            return respond(
                stream,
                200,
                &serde_json::to_string(&libraries).unwrap_or_else(|_| "[]".into()),
            );
        }
        "/api/v1/series" => page_items(&state, &["series"]),
        "/api/v1/books/ondeck" => page_items(&state, &["onDeck"]),
        "/api/v1/collections" => page_items(&state, &["collections"]),
        "/api/v1/readlists" => page_items(&state, &["readlists"]),
        _ => return respond(stream, 404, r#"{"message":"not found"}"#),
    };
    page_response(stream, &items, page, size)
}

/// PATCH/DELETE `read-progress`, exactly as Komga documents them: 204 with no
/// body. `--fault-file` lets a script answer 503/401/400/404 instead, which is
/// how the retry / backoff / failed / authentication paths get real HTTP.
fn write_route(stream: &mut TcpStream, config: &Config, request: &Request) -> std::io::Result<()> {
    let book_id = match request
        .path
        .strip_prefix("/api/v1/books/")
        .and_then(|rest| rest.strip_suffix("/read-progress"))
        .filter(|id| !id.is_empty() && !id.contains('/'))
    {
        Some(id) => id.to_string(),
        None => return respond(stream, 404, r#"{"message":"not found"}"#),
    };
    if let Some(fault) = read_trimmed(&config.fault_file).and_then(|v| v.parse::<u16>().ok()) {
        return respond(
            stream,
            fault,
            &json!({"message": format!("injected fault {fault}")}).to_string(),
        );
    }
    if request.method == "PATCH" {
        if !request.json_content_type {
            return respond(stream, 400, r#"{"message":"expected application/json"}"#);
        }
        let body: Value = match serde_json::from_str(&request.body) {
            Ok(value) => value,
            Err(_) => return respond(stream, 400, r#"{"message":"malformed json"}"#),
        };
        // ReadProgressUpdateDto allows only page + completed; anything else is a
        // client bug we want the acceptance run to catch loudly.
        let unknown: Vec<&str> = body
            .as_object()
            .map(|map| {
                map.keys()
                    .filter(|key| !matches!(key.as_str(), "page" | "completed"))
                    .map(String::as_str)
                    .collect()
            })
            .unwrap_or_default();
        if !unknown.is_empty() {
            return respond(
                stream,
                400,
                &json!({"message": format!("unexpected fields: {unknown:?}")}).to_string(),
            );
        }
        if body.get("page").is_some() && body["page"].as_i64().is_none() {
            return respond(stream, 400, r#"{"message":"page must be an int32"}"#);
        }
        if body.get("completed").is_some() && body["completed"].as_bool().is_none() {
            return respond(stream, 400, r#"{"message":"completed must be a boolean"}"#);
        }
        apply_progress(config, &book_id, &body);
    } else if request.method == "DELETE" {
        // Mark unread: the server's own semantics are page 0 + not completed.
        apply_progress(config, &book_id, &json!({"page": 0, "completed": false}));
    } else {
        return respond(stream, 405, r#"{"message":"method not allowed"}"#);
    }
    journal(
        config,
        &json!({
            "method": request.method,
            "bookId": book_id,
            "body": request.body,
        }),
    );
    // 204: no body at all, which is why the client cannot learn the new stamp.
    stream.write_all(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")?;
    stream.flush()
}

/// Stream the raw frames in `--sse-file` as `text/event-stream`, then close.
/// A trailing half frame is delivered as-is on purpose: the client must not
/// dispatch it.
fn sse_stream(stream: &mut TcpStream, config: &Config) -> std::io::Result<()> {
    let frames = std::fs::read(&config.sse_file).unwrap_or_default();
    // Spring's SseEmitter answers with chunked transfer-encoding (the real
    // server does exactly this — observed on a 401 from 192.168.0.69:25600),
    // so the fixture must not lean on "body delimited by connection close":
    // a client that trusts Content-Length/chunking would see an empty body.
    stream.write_all(
        b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream;charset=UTF-8\r\n\
           Transfer-Encoding: chunked\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n",
    )?;
    stream.flush()?;
    // Small chunks on purpose: a parser that assumes one read == one frame has
    // to fail here the same way it would on a real network.
    for piece in frames.chunks(7) {
        write_chunk(stream, piece)?;
        thread::sleep(Duration::from_millis(5));
    }
    stream.write_all(b"0\r\n\r\n")?;
    stream.flush()
}

fn write_chunk(stream: &mut TcpStream, piece: &[u8]) -> std::io::Result<()> {
    stream.write_all(format!("{:x}\r\n", piece.len()).as_bytes())?;
    stream.write_all(piece)?;
    stream.write_all(b"\r\n")?;
    stream.flush()
}

/// The progress overlay: what this server has been *told* since it started,
/// merged onto the snapshot's own readProgress for a single book.
fn merge_progress(config: &Config, book_id: &str, mut book: Value) -> Value {
    let Some(overlay) = read_json_object(&config.progress_file) else {
        return book;
    };
    let Some(entry) = overlay.get(book_id) else {
        return book;
    };
    if let Some(map) = book.as_object_mut() {
        map.insert(
            "readProgress".to_string(),
            json!({
                "page": entry.get("page").and_then(Value::as_i64).unwrap_or(0),
                "completed": entry.get("completed").and_then(Value::as_bool).unwrap_or(false),
                "created": "2026-08-28T00:00:00Z",
                "lastModified": entry.get("lastModified").and_then(Value::as_str),
                "readDate": "2026-08-28T00:00:00Z",
                "deviceId": "fixture",
                "deviceName": "fixture",
            }),
        );
    }
    book
}

fn apply_progress(config: &Config, book_id: &str, body: &Value) {
    if config.progress_file.as_os_str().is_empty() {
        return;
    }
    let mut overlay = read_json_object(&config.progress_file).unwrap_or_else(|| json!({}));
    let entry = overlay
        .as_object_mut()
        .expect("overlay is an object")
        .entry(book_id.to_string())
        .or_insert_with(|| json!({}));
    if let Some(page) = body.get("page") {
        entry["page"] = page.clone();
    }
    if let Some(completed) = body.get("completed") {
        entry["completed"] = completed.clone();
    }
    entry["lastModified"] = json!(now_rfc3339());
    let text = serde_json::to_string_pretty(&overlay).unwrap_or_default();
    let _ = std::fs::write(&config.progress_file, text);
}

fn journal(config: &Config, entry: &Value) {
    if config.journal.as_os_str().is_empty() {
        return;
    }
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&config.journal)
    {
        let _ = writeln!(file, "{entry}");
    }
}

fn read_trimmed(path: &Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .map(|text| text.trim().to_string())
}

fn read_json_object(path: &Path) -> Option<Value> {
    if path.as_os_str().is_empty() {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    match serde_json::from_str::<Value>(&text).ok()? {
        value @ Value::Object(_) => Some(value),
        _ => None,
    }
}

fn now_rfc3339() -> String {
    // Must be RFC 3339: the client parses this stamp to decide conflict rule R4,
    // and an unreadable stamp would make every remote change look old.
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn all_books(state: &Value) -> Vec<Value> {
    // Snapshots store books either as a list of pages or as series -> pages;
    // page_items already understands both.
    page_items(state, &["books"])
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
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        _ => "Server Error",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()
}
