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

    public init(
        content: [SeriesDTO], totalElements: Int, totalPages: Int,
        number: Int, size: Int, first: Bool, last: Bool
    ) {
        self.content = content
        self.totalElements = totalElements
        self.totalPages = totalPages
        self.number = number
        self.size = size
        self.first = first
        self.last = last
    }
}

public struct SeriesDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let libraryId: String
    public let name: String
    public let created: String?
    public let lastModified: String?
    public let booksCount: Int?
    public let booksReadCount: Int?
    public let booksUnreadCount: Int?
    public let booksInProgressCount: Int?
    /// Stage 4: the list endpoint aggregates series authors/tags here
    /// (SeriesMetadataDto itself has no authors field).
    public let booksMetadata: BookMetadataAggregationDTO?
    public let metadata: SeriesMetadataDTO?
}

public struct SeriesMetadataDTO: Decodable, Sendable, Equatable {
    public let title: String
    public let status: String?
    public let summary: String?
    public let publisher: String?
    public let genres: [String]?
    public let tags: [String]?
    public let authors: [AuthorDTO]?
    public let readingDirection: String?
    public let language: String?
    public let ageRating: String?
    public let titleSort: String?
    public let totalBookCount: Int?
}

/// BookMetadataAggregationDto (subset: authors / tags aggregation).
public struct BookMetadataAggregationDTO: Decodable, Sendable, Equatable {
    public let authors: [AuthorDTO]?
    public let tags: [String]?
}