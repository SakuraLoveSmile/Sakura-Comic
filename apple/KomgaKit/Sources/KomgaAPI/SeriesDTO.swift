import Foundation

/// Komga series page response (Spring Data Page shape).
/// Contract: specs/openapi; shared fixture:
/// specs/contracts/fixtures/initial-sync/series-page.json
public struct SeriesPageDTO: Decodable, Sendable, Equatable {
    public let content: [SeriesDTO]
    public let totalElements: Int
    public let totalPages: Int
    public let number: Int
    public let size: Int
    public let first: Bool
    public let last: Bool
}

public struct SeriesDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let libraryId: String
    public let name: String
    public let created: String?
    public let lastModified: String?
    public let booksCount: Int?
    public let metadata: SeriesMetadataDTO?
}

public struct SeriesMetadataDTO: Decodable, Sendable, Equatable {
    public let title: String
    public let status: String?
    public let summary: String?
    public let publishers: [String]?
}
