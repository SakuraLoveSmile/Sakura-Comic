import Foundation

/// How a server authenticates.
public enum AuthType: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case apiKey = "api_key"
    case basic

    public var id: String { rawValue }

    /// User-facing label (kept minimal; UI may localize).
    public var label: String {
        switch self {
        case .apiKey: return "API Key"
        case .basic: return "用户名 + 密码"
        }
    }
}

/// A saved Komga server profile.
///
/// Credentials are never stored here — only `credentialRef` pointing into
/// Keychain. All remote IDs elsewhere key on `(serverId, remoteId)`.
public struct ServerProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var authType: AuthType
    public var credentialRef: String?
    public var capabilities: [String]
    public var lastSuccessfulConnection: Date?

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        baseURL: String,
        authType: AuthType,
        credentialRef: String? = nil,
        capabilities: [String] = [],
        lastSuccessfulConnection: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.authType = authType
        self.credentialRef = credentialRef
        self.capabilities = capabilities
        self.lastSuccessfulConnection = lastSuccessfulConnection
    }
}
