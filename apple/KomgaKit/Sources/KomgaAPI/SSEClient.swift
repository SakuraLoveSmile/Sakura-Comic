import Foundation

// MARK: - SSE client (Stage 6): the live `GET /sse/v1/events` connection
//
// Mirror of Rust `api::sse::SseClient` / `SseStream`. Kept separate from
// `KomgaTransport` because it must not inherit a total-request timeout: an idle
// event stream is normal. What is *not* normal is a silent one, so the session's
// inactivity window is `sseFirstFrameTimeout` — the same 15 s the handshake
// needs to prove the route is really a stream, applied to every later frame too.

/// Connects to the event stream and proves it is one.
public struct SSEClient: Sendable {
    public let baseURL: String
    public let auth: AuthMethod
    private let session: URLSession

    /// `session` is injectable for tests; the default one is tuned for a
    /// long-lived stream (no response caching, inactivity timeout only).
    public init(baseURL: String, auth: AuthMethod, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.auth = auth
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            // Reset on every byte: this is the "a live stream may stay silent for
            // 15 s, then it is dead" rule, not a total-duration budget.
            configuration.timeoutIntervalForRequest = sseFirstFrameTimeout
            self.session = URLSession(configuration: configuration, delegate: StrictRedirectDelegate(), delegateQueue: nil)
        }
    }

    public var eventsURL: URL? {
        URL(string: sseEventsURL(baseURL: baseURL))
    }

    /// The request exactly as it goes on the wire (`fixtures/sse/handshake.json
    /// #endpoint`): GET, `Accept: text/event-stream`, the same auth as REST, and
    /// `Last-Event-ID` when resuming.
    public func makeRequest(lastEventID: String? = nil) throws -> URLRequest {
        guard let url = eventsURL else {
            throw KomgaAPIError.urlInvalid(sseEventsURL(baseURL: baseURL))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        auth.apply(to: &request)
        if let lastEventID {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        return request
    }

    /// Handshake validation: 200 + a `text/event-stream` content type. Anything
    /// else that is not a status/auth answer means "this route is not an event
    /// stream", which the caller turns into reconcile-only mode instead of a
    /// retry loop (contract: `on_failure.mode`).
    public static func classifyHandshake(status: Int, contentType: String?) -> Result<Void, KomgaAPIError> {
        switch status {
        case 401, 403:
            return .failure(.authentication)
        case 200:
            let lowered = (contentType ?? "").lowercased()
            guard lowered.hasPrefix("text/event-stream") else {
                return .failure(
                    .apiCompatibility(
                        "\(sseEventsPath) answered 200 with '\(lowered)', not an event stream"
                    )
                )
            }
            return .success(())
        default:
            return .failure(.server(statusCode: status))
        }
    }

    /// Open the stream, validate the handshake, then yield dispatched events.
    ///
    /// Finishing without an error means the server closed the stream; throwing
    /// means it broke. Both are the normal path and lead the caller to reconnect
    /// (and reconcile first — events missed while disconnected must be assumed
    /// lost).
    public func events(lastEventID: String? = nil) -> AsyncThrowingStream<SseEvent, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(lastEventID: lastEventID)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }
        let session = self.session
        return AsyncThrowingStream { continuation in
            let reader = Task {
                var parser = SseParser()
                var buffer: [UInt8] = []
                buffer.reserveCapacity(4096)
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let http = response as? HTTPURLResponse
                    switch Self.classifyHandshake(
                        status: http?.statusCode ?? 0,
                        contentType: http?.value(forHTTPHeaderField: "Content-Type")
                    ) {
                    case .failure(let error):
                        throw error
                    case .success:
                        break
                    }
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 4096 {
                            for event in parser.push(buffer) {
                                continuation.yield(event)
                            }
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        // A tail without a terminator is never dispatched: a
                        // half frame is discarded and the reconnect reconciles.
                        for event in parser.push(buffer) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as KomgaAPIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: KomgaAPIError.network)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}
