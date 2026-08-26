/// KomgaAPI — transport layer for the Komga REST API and SSE stream.
///
/// Responsibilities (Phase 0+):
/// - Authentication: API Key (X-API-Key), Basic as compatibility fallback
/// - Request / pagination / retry / error mapping
/// - SSE connection to `/sse/v1/events`
/// - OpenAPI-driven models — contract source: `specs/openapi/komga-openapi.yaml`
public enum KomgaAPI {
    /// Bumped when the transport contract snapshot changes.
    /// Must equal Rust `ApiContract::CONTRACT_VERSION` ("0.2.0").
    public static let contractVersion = KomgaContract.contractVersion
}
