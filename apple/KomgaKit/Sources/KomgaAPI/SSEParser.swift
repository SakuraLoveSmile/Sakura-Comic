import Foundation

// MARK: - SSE transport (Stage 6): `GET /sse/v1/events` + a WHATWG frame parser
//
// Mirror of Rust `api/sse.rs`. The parser is pure and byte-driven on purpose: a
// network read can split a frame — or a single UTF-8 character — anywhere, and
// `text/event-stream` allows LF, CRLF *and* CR terminators. Every case in
// `specs/contracts/fixtures/sse/parse.json` is asserted on both sides.
//
// What this does *not* do: treat events as a queue, deduplicate them, or trust
// their payloads. See `specs/contracts/reconnect/README.md`.

/// The path the objective specifies. **Unverified against a real server** — it
/// is absent from the exported OpenAPI of 1.26.3 and cannot be probed without a
/// credential (every `/api/*` and `/sse/*` path answers 401), so `connect`
/// proves the route from the response itself.
public let sseEventsPath = "/sse/v1/events"

/// How long a live stream may stay silent before we call it dead
/// (`fixtures/sse/handshake.json#first_frame_timeout_ms`).
public let sseFirstFrameTimeout: TimeInterval = 15

/// LF / CR / ':' as bytes, so the parser reads like the spec it mirrors.
private let sseLF: UInt8 = 0x0A
private let sseCR: UInt8 = 0x0D
private let sseColon: UInt8 = 0x3A

public func sseEventsURL(baseURL: String) -> String {
    let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    return "\(base)\(sseEventsPath)"
}

/// One dispatched `text/event-stream` event.
public struct SseEvent: Sendable, Equatable {
    /// The `event:` field, or `message` when absent (spec default).
    public var kind: String
    public var data: String
    /// The last-event-ID buffer at dispatch time — it persists across events.
    public var id: String?
    /// `retry:` in milliseconds, when this frame carried a valid one.
    public var retryMS: UInt64?

    public init(kind: String, data: String, id: String?, retryMS: UInt64?) {
        self.kind = kind
        self.data = data
        self.id = id
        self.retryMS = retryMS
    }

    /// The `data:` payload decoded, when it is JSON. Never required to succeed:
    /// an event we cannot read is just an unrecognised hint.
    public func decoded<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(data.utf8))
    }
}

/// Incremental frame parser. Feed it whatever bytes arrive.
public struct SseParser: Sendable {
    private var line: [UInt8] = []
    /// A CR terminator already emitted; a following LF belongs to it.
    private var sawCR = false
    private var eventType: [UInt8] = []
    private var data: [UInt8] = []
    private var lastID: String?
    private var retryMS: UInt64?
    private var retryThisFrame: UInt64?
    /// Completed frames, including comment-only ones — the liveness signal.
    public private(set) var frames = 0

    public init() {}

    /// The server's suggested reconnect delay, once it has sent one.
    public var retryMilliseconds: UInt64? { retryMS }

    /// The resume token to send as `Last-Event-ID`. Holding it does not make
    /// the stream reliable — a reconnect still reconciles.
    public var lastEventID: String? { lastID }

    /// True when bytes are buffered mid-frame (a cut-off stream tail that must
    /// be discarded, not dispatched).
    public var hasPartialFrame: Bool {
        !line.isEmpty || !data.isEmpty || !eventType.isEmpty || retryThisFrame != nil
    }

    /// Convenience for text input (the shared fixture spells chunks as strings).
    public mutating func push(_ text: String) -> [SseEvent] {
        push(Array(text.utf8))
    }

    public mutating func push(_ bytes: [UInt8]) -> [SseEvent] {
        var out: [SseEvent] = []
        for byte in bytes {
            switch byte {
            case sseLF:
                if sawCR {
                    // Part of a CRLF pair we already emitted.
                    sawCR = false
                    continue
                }
                consumeLine(line, into: &out)
                line = []
            case sseCR:
                consumeLine(line, into: &out)
                line = []
                sawCR = true
            default:
                sawCR = false
                line.append(byte)
            }
        }
        return out
    }

    private mutating func consumeLine(_ complete: [UInt8], into out: inout [SseEvent]) {
        if complete.isEmpty {
            frames += 1
            dispatch(into: &out)
            retryThisFrame = nil
            return
        }
        if complete[0] == sseColon {
            // Comment / heartbeat: keeps the connection alive, carries no event.
            return
        }
        let text = String(decoding: complete, as: UTF8.self)
        let field: String
        let value: String
        if let colon = text.firstIndex(of: ":") {
            field = String(text[..<colon])
            var start = text.index(after: colon)
            // Exactly one leading space is part of the terminator, not the value.
            if start < text.endIndex, text[start] == " " {
                start = text.index(after: start)
            }
            value = String(text[start...])
        } else {
            // A line with no colon is a field with an empty value.
            field = text
            value = ""
        }
        switch field {
        case "event":
            eventType.append(contentsOf: value.utf8)
        case "data":
            data.append(contentsOf: value.utf8)
            data.append(sseLF)
        case "id":
            if !value.contains("\0") {
                lastID = value
            }
        case "retry":
            // Integer milliseconds only; anything else leaves the schedule ours.
            if !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
               let ms = UInt64(value) {
                retryMS = ms
                retryThisFrame = ms
            }
        // Unknown fields are ignored: a server adding one must not break us.
        default:
            break
        }
    }

    private mutating func dispatch(into out: inout [SseEvent]) {
        if data.isEmpty {
            eventType = []
            return
        }
        if data.last == sseLF {
            data.removeLast()
        }
        let kind: String
        if eventType.isEmpty {
            kind = "message"
        } else {
            kind = String(decoding: eventType, as: UTF8.self)
        }
        eventType = []
        out.append(
            SseEvent(
                kind: kind,
                data: String(decoding: data, as: UTF8.self),
                id: lastID,
                retryMS: retryThisFrame
            )
        )
        data = []
    }
}
