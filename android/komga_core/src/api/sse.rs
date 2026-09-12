//! SSE transport (Stage 6): `GET /sse/v1/events` + a WHATWG frame parser.
//!
//! The parser is pure and byte-driven on purpose: a network read can split a
//! frame — or a single UTF-8 character — anywhere, and `text/event-stream`
//! allows LF, CRLF *and* CR terminators. Every case in
//! `specs/contracts/fixtures/sse/parse.json` is asserted below, and the Swift
//! side asserts the same file.
//!
//! What this module does *not* do: treat events as a queue, deduplicate them,
//! or trust their payloads. See `specs/contracts/reconnect/README.md`.

use std::collections::VecDeque;
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderValue, ACCEPT, CONTENT_TYPE};
use reqwest::Client;

use super::auth::AuthMethod;
use super::error::{ApiError, Result};

/// The path the objective specifies. **Unverified against a real server** —
/// it is absent from the exported OpenAPI of 1.26.3 and cannot be probed
/// without a credential (every `/api/*` and `/sse/*` path answers 401).
/// `SseClient::connect` therefore proves the route from the response itself.
pub const EVENTS_PATH: &str = "/sse/v1/events";

/// How long a live stream may stay silent before we call it dead.
pub const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(15);

pub fn events_url(base_url: &str) -> String {
    format!("{}{}", base_url.trim_end_matches('/'), EVENTS_PATH)
}

/// One dispatched `text/event-stream` event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SseEvent {
    /// The `event:` field, or `message` when absent (spec default).
    pub kind: String,
    pub data: String,
    /// The last-event-ID buffer at dispatch time — it persists across events.
    pub id: Option<String>,
    /// `retry:` in milliseconds, when this frame carried a valid one.
    pub retry_ms: Option<u64>,
}

impl SseEvent {
    /// The `data:` payload decoded, when it is JSON. Never required to succeed:
    /// an event we cannot read is just an unrecognised hint.
    pub fn json<T: serde::de::DeserializeOwned>(&self) -> Option<T> {
        serde_json::from_str(&self.data).ok()
    }
}

/// Incremental frame parser. Feed it whatever bytes arrive.
#[derive(Debug, Default)]
pub struct SseParser {
    line: Vec<u8>,
    /// A CR terminator already emitted; a following LF belongs to it.
    saw_cr: bool,
    event_type: Vec<u8>,
    data: Vec<u8>,
    last_id: Option<String>,
    retry_ms: Option<u64>,
    retry_this_frame: Option<u64>,
    /// Completed frames, including comment-only ones — the liveness signal.
    pub frames: usize,
}

impl SseParser {
    pub fn new() -> Self {
        Self::default()
    }

    /// The server's suggested reconnect delay, once it has sent one.
    pub fn retry_ms(&self) -> Option<u64> {
        self.retry_ms
    }

    /// The resume token to send as `Last-Event-ID`. Holding it does not make
    /// the stream reliable — a reconnect still reconciles.
    pub fn last_event_id(&self) -> Option<&str> {
        self.last_id.as_deref()
    }

    /// True when bytes are buffered mid-frame (a cut-off stream tail that must
    /// be discarded, not dispatched).
    pub fn has_partial_frame(&self) -> bool {
        !self.line.is_empty()
            || !self.data.is_empty()
            || !self.event_type.is_empty()
            || self.retry_this_frame.is_some()
    }

    pub fn push(&mut self, bytes: &[u8]) -> Vec<SseEvent> {
        let mut out = Vec::new();
        for &byte in bytes {
            match byte {
                b'\n' => {
                    if self.saw_cr {
                        // Part of a CRLF pair we already emitted.
                        self.saw_cr = false;
                        continue;
                    }
                    let line = std::mem::take(&mut self.line);
                    self.consume_line(&line, &mut out);
                }
                b'\r' => {
                    let line = std::mem::take(&mut self.line);
                    self.consume_line(&line, &mut out);
                    self.saw_cr = true;
                }
                other => {
                    self.saw_cr = false;
                    self.line.push(other);
                }
            }
        }
        out
    }

    fn consume_line(&mut self, line: &[u8], out: &mut Vec<SseEvent>) {
        if line.is_empty() {
            self.frames += 1;
            self.dispatch(out);
            self.retry_this_frame = None;
            return;
        }
        if line[0] == b':' {
            // Comment / heartbeat: keeps the connection alive, carries no event.
            return;
        }
        let text = String::from_utf8_lossy(line);
        let (field, value) = match text.split_once(':') {
            Some((field, value)) => (field, value.strip_prefix(' ').unwrap_or(value)),
            // A line with no colon is a field with an empty value.
            None => (text.as_ref(), ""),
        };
        match field {
            "event" => self.event_type.extend_from_slice(value.as_bytes()),
            "data" => {
                self.data.extend_from_slice(value.as_bytes());
                self.data.push(b'\n');
            }
            "id" => {
                if !value.contains('\0') {
                    self.last_id = Some(value.to_string());
                }
            }
            "retry" => match value.parse::<u64>() {
                Ok(ms) if !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()) => {
                    self.retry_ms = Some(ms);
                    self.retry_this_frame = Some(ms);
                }
                _ => {}
            },
            // Unknown fields are ignored: a server adding one must not break us.
            _ => {}
        }
    }

    fn dispatch(&mut self, out: &mut Vec<SseEvent>) {
        if self.data.is_empty() {
            self.event_type.clear();
            return;
        }
        let mut data = std::mem::take(&mut self.data);
        if data.last() == Some(&b'\n') {
            data.pop();
        }
        let kind = if self.event_type.is_empty() {
            "message".to_string()
        } else {
            String::from_utf8_lossy(&std::mem::take(&mut self.event_type)).into_owned()
        };
        out.push(SseEvent {
            kind,
            data: String::from_utf8_lossy(&data).into_owned(),
            id: self.last_id.clone(),
            retry_ms: self.retry_this_frame,
        });
    }
}

/// A live stream: handshake already validated, frames read on demand.
pub struct SseStream {
    response: reqwest::Response,
    parser: SseParser,
    ready: VecDeque<SseEvent>,
}

impl SseStream {
    /// The next dispatched event. `Ok(None)` means the server closed the
    /// stream cleanly; `Err` means it broke — both lead to the reconnect path.
    pub async fn next_event(&mut self) -> Result<Option<SseEvent>> {
        loop {
            if let Some(event) = self.ready.pop_front() {
                return Ok(Some(event));
            }
            match self.response.chunk().await {
                Ok(Some(bytes)) => {
                    for event in self.parser.push(&bytes) {
                        self.ready.push_back(event);
                    }
                }
                // Connection closed: a half frame still buffered is discarded.
                Ok(None) => return Ok(None),
                Err(_) => return Err(ApiError::Network),
            }
        }
    }

    pub fn frames_seen(&self) -> usize {
        self.parser.frames
    }

    pub fn last_event_id(&self) -> Option<String> {
        self.parser.last_event_id().map(str::to_string)
    }

    pub fn retry_ms(&self) -> Option<u64> {
        self.parser.retry_ms()
    }
}

/// Connects to the event stream. Kept separate from `KomgaClient` because it
/// must not inherit a 30s total-request timeout — an idle stream is normal.
pub struct SseClient {
    base_url: String,
    auth: AuthMethod,
    http: Client,
}

impl SseClient {
    pub fn new(base_url: String, auth: AuthMethod) -> Result<Self> {
        let http = Client::builder()
            .redirect(super::url::strict_redirect_policy())
            .build()
            .map_err(|_| ApiError::Network)?;
        Ok(Self {
            base_url,
            auth,
            http,
        })
    }

    pub fn events_url(&self) -> String {
        events_url(&self.base_url)
    }

    /// Open the stream and prove it is one (contract: `fixtures/sse/handshake.json`).
    /// Anything that is not a `text/event-stream` 200 becomes
    /// `ApiError::ApiCompatibility`, which the caller turns into reconcile-only
    /// mode rather than a retry loop.
    pub async fn connect(&self, last_event_id: Option<&str>) -> Result<SseStream> {
        let mut headers = HeaderMap::new();
        self.auth.apply_headers(&mut headers);
        headers.insert(ACCEPT, HeaderValue::from_static("text/event-stream"));
        if let Some(id) = last_event_id {
            headers.insert(
                "last-event-id",
                HeaderValue::from_str(id).map_err(|_| ApiError::Network)?,
            );
        }
        let response = self
            .http
            .get(self.events_url())
            .headers(headers)
            .send()
            .await
            .map_err(|_| ApiError::Network)?;
        let status = response.status().as_u16();
        match status {
            401 | 403 => return Err(ApiError::Authentication),
            200 => {}
            code => return Err(ApiError::Server { status_code: code }),
        }
        let content_type = response
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or_default()
            .to_ascii_lowercase();
        if !content_type.starts_with("text/event-stream") {
            return Err(ApiError::ApiCompatibility {
                message: format!(
                    "{EVENTS_PATH} answered {status} with '{content_type}', not an event stream"
                ),
            });
        }
        Ok(SseStream {
            response,
            parser: SseParser::new(),
            ready: VecDeque::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    struct Fixture {
        cases: Vec<Case>,
    }

    use serde::Deserialize;

    #[derive(Deserialize)]
    struct Case {
        name: String,
        chunks: Vec<String>,
        events: Vec<ExpectedEvent>,
        #[serde(default)]
        ends_open: bool,
    }

    #[derive(Deserialize)]
    struct ExpectedEvent {
        #[serde(rename = "type")]
        kind: String,
        data: String,
        id: Option<String>,
        retry: Option<u64>,
    }

    /// The shared contract: Swift asserts this same file.
    #[test]
    fn parses_the_shared_fixture() {
        let raw = include_str!("../../../../specs/contracts/fixtures/sse/parse.json");
        let fixture: Fixture =
            serde_json::from_str(raw).expect("sse/parse.json must decode into the test shape");
        for case in &fixture.cases {
            let mut parser = SseParser::new();
            let mut got = Vec::new();
            for chunk in &case.chunks {
                got.extend(parser.push(chunk.as_bytes()));
            }
            assert_eq!(
                got.len(),
                case.events.len(),
                "case {:?} dispatched the wrong number of events",
                case.name
            );
            for (event, expected) in got.iter().zip(&case.events) {
                assert_eq!(event.kind, expected.kind, "case {:?}", case.name);
                assert_eq!(event.data, expected.data, "case {:?}", case.name);
                assert_eq!(event.id, expected.id, "case {:?}", case.name);
                assert_eq!(event.retry_ms, expected.retry, "case {:?}", case.name);
            }
            assert_eq!(
                parser.has_partial_frame(),
                case.ends_open,
                "case {:?}: half-frame state wrong at end of stream",
                case.name
            );
        }
    }

    #[test]
    fn heartbeats_count_as_frames_without_dispatching() {
        let mut parser = SseParser::new();
        let events = parser.push(b":hb\n\n");
        assert!(events.is_empty());
        assert_eq!(
            parser.frames, 1,
            "a comment frame must prove the stream alive"
        );
    }

    #[test]
    fn retry_raises_the_reconnect_floor_once_seen() {
        let mut parser = SseParser::new();
        parser.push(b"retry: 1500\ndata: x\n\n");
        assert_eq!(parser.retry_ms(), Some(1500));
        // Later frames inherit it, per the spec's connection-level state.
        let events = parser.push(b"data: y\n\n");
        assert_eq!(events[0].retry_ms, None);
        assert_eq!(parser.retry_ms(), Some(1500));
    }

    #[test]
    fn a_split_multibyte_character_survives_the_chunk_boundary() {
        let bytes = "data: 进度\n\n".as_bytes();
        let split = 8; // lands inside the UTF-8 encoding of 进
        let mut parser = SseParser::new();
        let mut events = parser.push(&bytes[..split]);
        assert!(events.is_empty());
        events.extend(parser.push(&bytes[split..]));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].data, "进度");
    }

    #[test]
    fn events_url_matches_the_spec_path() {
        assert_eq!(
            events_url("http://192.168.0.69:25600/"),
            "http://192.168.0.69:25600/sse/v1/events"
        );
    }
}
