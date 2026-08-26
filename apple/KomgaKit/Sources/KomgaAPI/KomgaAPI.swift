/// KomgaAPI — transport layer for the Komga REST API and SSE stream.
///
/// Responsibilities (Phase 0+):
/// - Authentication: API Key (X-API-Key), Basic as compatibility fallback
/// - Request / pagination / retry / error mapping
/// - SSE connection to `/sse/v1/events`
/// - OpenAPI-driven models — contract source: `specs/openapi/komga-openapi.yaml`
public enum KomgaAPI {
    /// Bumped when the transport contract snapshot changes.
    public static let contractVersion = "0.0.1"
}
