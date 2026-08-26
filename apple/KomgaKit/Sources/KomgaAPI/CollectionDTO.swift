import Foundation

/// Komga collection page response (Spring Data Page shape).
/// Contract: specs/openapi; shared fixture:
/// specs/contracts/fixtures/library/collections-page.json
public struct CollectionPageDTO: Decodable, Sendable, Equatable {
    public let content: [CollectionDTO]
    public let totalElements: Int
    public let totalPages: Int
    public let number: Int
    public let size: Int
    public let first: Bool
    public let last: Bool

    public init(
        content: [CollectionDTO], totalElements: Int, totalPages: Int,
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

public struct CollectionDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let ordered: Bool?
    public let filtered: Bool?
    public let seriesIds: [String]?
    public let createdDate: String?
    public let lastModifiedDate: String?
}
