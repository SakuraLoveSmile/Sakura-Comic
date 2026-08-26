import Foundation

/// AuthorDto — shared by series and book metadata.
/// Komga: `{ "name": "...", "role": "STORY_ART" }` (role optional).
public struct AuthorDTO: Decodable, Sendable, Equatable {
    public let name: String
    public let role: String?

    public init(name: String, role: String? = nil) {
        self.name = name
        self.role = role
    }
}