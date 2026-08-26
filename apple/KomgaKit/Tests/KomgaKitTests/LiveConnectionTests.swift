import XCTest
import KomgaAPI
import KomgaStore

/// Live acceptance for the Apple side of Stage 2, env-gated:
/// `KOMGA_BASE_URL` + `KOMGA_API_KEY` must be set (e.g. the LAN Komga at
/// 192.168.0.69:25600). Without them the test is skipped so CI stays green.
///
/// Chain: 添加服务器(URL 规范化) → 登录(API Key) → 验证 Komga/GET /actuator/info
/// → 获取服务器信息(版本策略) → 保存 ServerProfile(Keychain + SQLite + active)。
@MainActor
final class LiveConnectionTests: XCTestCase {
    private var liveURL: String? { ProcessInfo.processInfo.environment["KOMGA_BASE_URL"] }
    private var liveKey: String? { ProcessInfo.processInfo.environment["KOMGA_API_KEY"] }

    func testLiveAcceptanceChain() async throws {
        guard let baseURL = liveURL, let apiKey = liveKey, !baseURL.isEmpty, !apiKey.isEmpty else {
            throw XCTSkip("set KOMGA_BASE_URL and KOMGA_API_KEY to run the live acceptance chain")
        }

        // 添加服务器：URL 规范化（非法输入直接拒绝）。
        let normalized = try ServerURL.normalized(baseURL)

        // 登录 + 验证 Komga + 获取服务器信息 + 版本兼容校验。
        let transport = KomgaTransport(baseURL: normalized, auth: .apiKey(apiKey))
        let result = try await ServerConnection.connect(fetching: transport)
        XCTAssertNotNil(result.serverVersion, "server build.version should be present")
        XCTAssertFalse(result.capabilities.contains("unknown-version"))
        print("LIVE: connected to \(normalized) · Komga \(result.serverVersion ?? "?") · \(result.libraries.count) libraries")

        // 保存 ServerProfile：secret → Keychain，profile+caps → SQLite，
        // libraries 镜像 (server_id, remote_id)，切换 active server。
        let store = try KomgaStore()
        let profileID = "live-\(UUID().uuidString)"
        let ref = KeychainStore.credentialRef(serverID: profileID)
        let keychain = KeychainStore()
        try keychain.save(secret: apiKey, for: ref)
        defer { try? keychain.delete(ref: ref) }

        // RFC 3339 serialization is millisecond-precision; truncate so the
        // stored value round-trips exactly (store contract, see store tests).
        let now = Date()
        let lastConnected = Date(
            timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded() / 1000
        )
        let profile = ServerProfile(
            id: profileID,
            displayName: "Live",
            baseURL: normalized,
            authType: .apiKey,
            credentialRef: ref,
            capabilities: result.capabilities,
            lastSuccessfulConnection: lastConnected
        )
        try store.upsertServer(profile)
        defer { try? store.deleteServer(id: profileID) }
        _ = try store.upsertLibraries(serverID: profileID, libraries: result.libraries)
        try store.setActiveServer(id: profileID)

        // Read back + isolation checks.
        XCTAssertEqual(try store.activeServerProfile(), profile)
        XCTAssertEqual(try store.fetchLibraries(serverID: profileID).count, result.libraries.count)

        // Cleanup.
        _ = try store.deleteServer(id: profileID)
        XCTAssertNil(try store.activeServerProfile())
        print("LIVE: acceptance chain OK (server info + libraries + profile + switch)")
    }
}