import XCTest
import KomgaAPI

/// The shared SSE contract: `specs/contracts/fixtures/sse/parse.json` and
/// `handshake.json` drive both platforms, so a frame parser that only works on
/// tidy LF-terminated input cannot pass here. Mirror of Rust `api::sse::tests`.
final class SSEParserTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/sse")
            .standardizedFileURL
    }

    private func load<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: fixtureURL.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - parse.json

    private struct ParseFixture: Decodable {
        var cases: [ParseCase]
    }

    private struct ParseCase: Decodable {
        var name: String
        var chunks: [String]
        var events: [ExpectedEvent]
        var endsOpen: Bool?

        enum CodingKeys: String, CodingKey {
            case name, chunks, events
            case endsOpen = "ends_open"
        }
    }

    private struct ExpectedEvent: Decodable {
        var type: String
        var data: String
        var id: String?
        var retry: UInt64?
    }

    /// The shared contract: chunk-for-chunk, event-for-event.
    func testParsesTheSharedFixture() throws {
        let fixture: ParseFixture = try load("parse.json")
        XCTAssertFalse(fixture.cases.isEmpty, "the parse fixture lost its cases")
        for testCase in fixture.cases {
            var parser = SseParser()
            var got: [SseEvent] = []
            for chunk in testCase.chunks {
                got.append(contentsOf: parser.push(chunk))
            }
            XCTAssertEqual(
                got.count, testCase.events.count,
                "case \(testCase.name) dispatched the wrong number of events"
            )
            for (event, expected) in zip(got, testCase.events) {
                XCTAssertEqual(event.kind, expected.type, "case \(testCase.name)")
                XCTAssertEqual(event.data, expected.data, "case \(testCase.name)")
                XCTAssertEqual(event.id, expected.id, "case \(testCase.name)")
                XCTAssertEqual(event.retryMS, expected.retry, "case \(testCase.name)")
            }
            XCTAssertEqual(
                parser.hasPartialFrame, testCase.endsOpen ?? false,
                "case \(testCase.name): half-frame state wrong at end of stream"
            )
        }
    }

    /// A cut-off stream tail is discarded, not dispatched — the reconnect's
    /// Reconcile is what makes up for it.
    func testAHalfFrameIsNeverDispatched() {
        var parser = SseParser()
        var events = parser.push("data: complete\n\ndata: part")
        XCTAssertEqual(events.map(\.data), ["complete"])
        XCTAssertTrue(parser.hasPartialFrame)
        // The same stream may keep writing the line; only its terminator dispatches.
        events = parser.push("ial\n\n")
        XCTAssertEqual(events.map(\.data), ["partial"])
        XCTAssertFalse(parser.hasPartialFrame)
    }

    /// A comment frame carries no event but does prove the connection is alive.
    func testHeartbeatsCountAsFramesWithoutDispatching() {
        var parser = SseParser()
        let events = parser.push(Array(":hb\n\n".utf8))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(parser.frames, 1, "a comment frame must prove the stream alive")
    }

    /// `retry:` is connection state: later frames inherit the floor it set, but
    /// only the frame that carried it reports it.
    func testRetryRaisesTheReconnectFloorOnceSeen() {
        var parser = SseParser()
        _ = parser.push("retry: 1500\ndata: x\n\n")
        XCTAssertEqual(parser.retryMilliseconds, 1500)
        let events = parser.push("data: y\n\n")
        XCTAssertEqual(events.first?.retryMS, nil)
        XCTAssertEqual(parser.retryMilliseconds, 1500)
    }

    func testASplitMultibyteCharacterSurvivesTheChunkBoundary() {
        let bytes = Array("data: 进度\n\n".utf8)
        let split = 8 // lands inside the UTF-8 encoding of 进
        var parser = SseParser()
        var events = parser.push(Array(bytes[..<split]))
        XCTAssertTrue(events.isEmpty)
        events.append(contentsOf: parser.push(Array(bytes[split...])))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "进度")
    }

    /// The `id:` buffer persists across frames and is what `Last-Event-ID`
    /// resumes from — but an id with a NUL is ignored, per the spec.
    func testLastEventIDPersistsAcrossFramesAndRejectsNUL() {
        var parser = SseParser()
        _ = parser.push("id: 7\ndata: {}\n\n")
        XCTAssertEqual(parser.lastEventID, "7")
        _ = parser.push("id: a\0b\ndata: {}\n\n")
        XCTAssertEqual(parser.lastEventID, "7", "an id containing NUL must be ignored")
        let events = parser.push("data: {}\n\n")
        XCTAssertEqual(events.last?.id, "7")
    }

    // MARK: - handshake.json

    private struct HandshakeFixture: Decodable {
        var endpoint: Endpoint
        var successCriteria: [String]
        var firstFrameTimeoutMS: Int
        var outcomeClasses: [OutcomeClass]
        var reconnect: Reconnect

        enum CodingKeys: String, CodingKey {
            case endpoint
            case successCriteria = "success_criteria"
            case firstFrameTimeoutMS = "first_frame_timeout_ms"
            case outcomeClasses = "outcome_classes"
            case reconnect
        }
    }

    private struct Endpoint: Decodable {
        var method: String
        var path: String
        var accept: String
        var resumeHeader: String

        enum CodingKeys: String, CodingKey {
            case method, path, accept
            case resumeHeader = "resume_header"
        }
    }

    private struct OutcomeClass: Decodable {
        var observed: Observed
        var classification: String
        var action: String?
    }

    private struct Observed: Decodable {
        var status: Int
        var contentType: String?
        var firstFrame: String?

        enum CodingKeys: String, CodingKey {
            case status
            case contentType = "content_type"
            case firstFrame = "first_frame"
        }
    }

    private struct Reconnect: Decodable {
        var retryField: String
        var mandatoryAfterEachSuccessfulReconnect: [String]

        enum CodingKeys: String, CodingKey {
            case retryField = "retry_field"
            case mandatoryAfterEachSuccessfulReconnect = "mandatory_after_each_successful_reconnect"
        }
    }

    /// The endpoint we speak is the one the contract names, header for header.
    func testRequestCarriesTheContractedEndpointAndHeaders() throws {
        let fixture: HandshakeFixture = try load("handshake.json")
        XCTAssertEqual(sseEventsPath, fixture.endpoint.path)
        let client = SSEClient(baseURL: "http://192.168.0.69:25600/", auth: .apiKey("secret"))
        XCTAssertEqual(
            client.eventsURL?.absoluteString,
            "http://192.168.0.69:25600" + fixture.endpoint.path
        )
        let request = try client.makeRequest()
        XCTAssertEqual(request.httpMethod, fixture.endpoint.method)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), fixture.endpoint.accept)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Last-Event-ID"), "first connect has no token")

        let resumed = try client.makeRequest(lastEventID: "42")
        XCTAssertEqual(
            resumed.value(forHTTPHeaderField: fixture.endpoint.resumeHeader), "42"
        )
    }

    /// Every documented observation maps to the classification the caller acts on.
    func testHandshakeOutcomeClassesMatchTheFixture() throws {
        let fixture: HandshakeFixture = try load("handshake.json")
        XCTAssertEqual(
            Double(fixture.firstFrameTimeoutMS) / 1000, sseFirstFrameTimeout,
            "the liveness window is pinned by the fixture"
        )
        XCTAssertFalse(fixture.successCriteria.isEmpty)
        for outcome in fixture.outcomeClasses {
            let result = SSEClient.classifyHandshake(
                status: outcome.observed.status,
                contentType: outcome.observed.contentType
            )
            XCTAssertEqual(
                Self.classification(of: result), outcome.classification,
                "observed \(outcome.observed.status) / \(outcome.observed.contentType ?? "nil")"
            )
        }
    }

    /// The fixture's spelling of what a connection attempt proved. A 404 is
    /// deliberately still a plain server error — Rust keeps backing off rather
    /// than concluding the route is absent, which is the behaviour asserted here.
    private static func classification(of result: Result<Void, KomgaAPIError>) -> String {
        switch result {
        case .success: return "connected"
        case .failure(.authentication): return "unverified_credentials"
        case .failure(.apiCompatibility): return "not_an_event_stream"
        case .failure(.server): return "route_absent"
        case .failure: return "unclassified"
        }
    }

    /// A stream that is not text/event-stream is the one failure mode that must
    /// not be retried: the caller degrades to reconcile-only instead.
    func testAJsonAnswerIsNotRetriedAsAStream() throws {
        let result = SSEClient.classifyHandshake(status: 200, contentType: "application/json")
        guard case .failure(.apiCompatibility(let message)) = result else {
            return XCTFail("a JSON answer must be reported as a non-stream, got \(result)")
        }
        XCTAssertTrue(message.contains("application/json"), message)
        XCTAssertTrue(message.contains("/sse/v1/events"), message)
        // Case-insensitive and parameter-tolerant, the way HTTP says so.
        XCTAssertNoThrow(
            try SSEClient.classifyHandshake(
                status: 200, contentType: "Text/Event-Stream; charset=utf-8"
            ).get()
        )
    }

    /// The reconnect ordering the contract forbids skipping.
    func testReconnectRequiresAReconcileBeforeEventsAreConsumed() throws {
        let fixture: HandshakeFixture = try load("handshake.json")
        let mandatory = fixture.reconnect.mandatoryAfterEachSuccessfulReconnect.joined()
        XCTAssertTrue(mandatory.contains("Reconcile"), mandatory)
        XCTAssertTrue(mandatory.contains("only then resume consuming events"), mandatory)
        XCTAssertTrue(
            fixture.reconnect.retryField.contains("max(backoff_seconds, retry_ms / 1000)"),
            "the retry floor is a floor, not a replacement"
        )
    }
}
