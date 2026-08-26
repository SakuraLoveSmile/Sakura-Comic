import Foundation

/// Komga readlist page response (Spring Data Page shape).
/// Contract: specs/openapi; shared fixture:
/// specs/contracts/fixtures/library/readlists-page.json
public struct ReadListPageDTO: Decodable, Sendable, Equatable {
    public let content: [ReadListDTO]
    public let totalElements: Int
    public let totalPages: Int
    public let number: Int
    public let size: Int
    public let first: Bool
    public let last: Bool

    public init(
        content: [ReadListDTO], totalElements: Int, totalPages: Int,
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

public struct ReadListDTO: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let summary: String?
    public let ordered: Bool?
    public let filtered: Bool?
    public let bookIds: [String]?
    public let createdDate: String?
    public let lastModifiedDate: String?
}
