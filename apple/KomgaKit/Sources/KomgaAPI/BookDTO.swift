import Foundation

/// Komga book page response (Spring Data Page shape).
/// Contract: specs/openapi; shared fixture:
/// specs/contracts/fixtures/library/books-by-series.json (keyed by series id).
public struct BookPageDTO: Decodable, Sendable, Equatable {
    public let content: [BookDTO]
    public let totalElements: Int
    public let totalPages: Int
    public let number: Int
    public let size: Int
    public let first: Bool
    public let last: Bool

    public init(
        content: [BookDTO], totalElements: Int, totalPages: Int,
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

public struct BookDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let seriesId: String
    public let seriesTitle: String?
    public let name: String
    public let number: Int?
    public let oneshot: Bool?
    public let media: MediaDTO?
    public let metadata: BookMetadataDTO?
    public let readProgress: ReadProgressDTO?
    public let created: String?
    public let lastModified: String?
    public let sizeBytes: Int64?
}

public struct MediaDTO: Decodable, Sendable, Equatable {
    public let mediaType: String?
    public let pagesCount: Int?

    public init(mediaType: String? = nil, pagesCount: Int? = nil) {
        self.mediaType = mediaType
        self.pagesCount = pagesCount
    }
}

public struct BookMetadataDTO: Decodable, Sendable, Equatable {
    public let title: String
    public let number: String?
    public let numberSort: Double?
    public let summary: String?
    public let isbn: String?
    public let releaseDate: String?
    public let authors: [AuthorDTO]?
    public let tags: [String]?
}

/// ReadProgressDto — inline on BookDto.
public struct ReadProgressDTO: Decodable, Sendable, Equatable {
    public let page: Int?
    public let completed: Bool?
    public let lastModified: String?
}
