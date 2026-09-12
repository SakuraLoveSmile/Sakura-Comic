import Foundation
import SwiftUI

public struct AppSettings: Codable, Equatable, Sendable {
    public static let stateKey = "app_settings"
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int = 1
    public var autoSyncMetadata: Bool = true
    public var cacheLimitMiB: Int = 512
    public var appearance: String = "system" // "system", "light", "dark"
    public var gridDensity: String = "comfortable" // "compact", "comfortable", "spacious"

    public init(
        schemaVersion: Int = currentSchemaVersion,
        autoSyncMetadata: Bool = true,
        cacheLimitMiB: Int = 512,
        appearance: String = "system",
        gridDensity: String = "comfortable"
    ) {
        self.schemaVersion = schemaVersion
        self.autoSyncMetadata = autoSyncMetadata
        self.cacheLimitMiB = cacheLimitMiB
        self.appearance = appearance
        self.gridDensity = gridDensity
    }

    public static func decode(from jsonString: String?) -> AppSettings {
        guard let jsonString,
              let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded
    }

    public func encode() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
