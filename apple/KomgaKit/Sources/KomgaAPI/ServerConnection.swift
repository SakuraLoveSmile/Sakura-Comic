import Foundation

/// Fetching abstraction so the connection flow can be tested offline.
/// `KomgaTransport` conforms via the extension below.
public protocol ConnectionFetching: Sendable {
    func fetchServerInfo() async throws -> ServerInfoDTO
    func fetchLibraries() async throws -> [LibraryDTO]
}

extension KomgaTransport: ConnectionFetching {}

/// Outcome of the connection probe: server identity/version, remote
/// entities (libraries) and policy-derived capabilities.
public struct ConnectionResult: Sendable, Equatable {
    public let serverInfo: ServerInfoDTO
    /// `build.version` of the server (policy input).
    public let serverVersion: String?
    public let libraries: [LibraryDTO]
    /// e.g. `libraries:2`, `unknown-version`, `newer-than-snapshot:1.27.0`.
    public let capabilities: [String]

    public init(
        serverInfo: ServerInfoDTO,
        serverVersion: String?,
        libraries: [LibraryDTO],
        capabilities: [String]
    ) {
        self.serverInfo = serverInfo
        self.serverVersion = serverVersion
        self.libraries = libraries
        self.capabilities = capabilities
    }
}

/// The acceptance chain, transport-agnostic:
/// 登录 → 验证 Komga → 获取服务器信息 → 远端实体探测 → 版本兼容校验.
///
/// Mirrors `App::test_connection_with` on the Rust side; both consume the
/// shared fixtures in specs/contracts/fixtures/connection/.
public enum ServerConnection {
    public static func connect<F: ConnectionFetching>(fetching: F) async throws -> ConnectionResult {
        // 登录 + 验证 Komga + 获取服务器信息 (401/403 → authentication).
        let info = try await fetching.fetchServerInfo()
        let version = info.build?.version
        // 版本兼容校验 (incompatible servers fail fast, before any entity fetch).
        let check = try KomgaContract.check(serverVersion: version)

        // 远端实体探测: libraries (plain array; mirrored with (serverId, remoteId)).
        let libraries = try await fetching.fetchLibraries()

        var capabilities = KomgaContract.capabilities(from: check)
        capabilities.append("libraries:\(libraries.count)")
        if libraries.isEmpty {
            capabilities.append("empty-libraries")
        }

        return ConnectionResult(
            serverInfo: info,
            serverVersion: version,
            libraries: libraries,
            capabilities: capabilities
        )
    }
}