import Foundation

/// A book row in the local store with its read progress joined in
/// (mirror of the Rust `store::books::BookRow`).
public struct BookRecord: Sendable, Equatable, Identifiable {

    public init(serverID: String, remoteID: String, seriesID: String, seriesTitle: String?, title: String, number: String?, numberSort: Double?, fileSize: Int64?, mediaType: String?, pagesCount: Int64?, createdAt: String?, lastModified: String?, progressPage: Int64?, progressCompleted: Bool) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle
        self.title = title
        self.number = number
        self.numberSort = numberSort
        self.fileSize = fileSize
        self.mediaType = mediaType
        self.pagesCount = pagesCount
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.progressPage = progressPage
        self.progressCompleted = progressCompleted
    }
    public let serverID: String
    public let remoteID: String
    public let seriesID: String
    public let seriesTitle: String?
    public let title: String
    public let number: String?
    public let numberSort: Double?
    public let fileSize: Int64?
    public let mediaType: String?
    public let pagesCount: Int64?
    public let createdAt: String?
    public let lastModified: String?
    public let progressPage: Int64?
    public let progressCompleted: Bool

    public var id: String { remoteID }
}

/// Full book detail (row + metadata + tags + authors + progress).
public struct BookDetailRecord: Sendable, Equatable {

    public init(serverID: String, remoteID: String, seriesID: String, seriesTitle: String?, title: String, number: String?, numberSort: Double?, summary: String?, isbn: String?, releaseDate: String?, mediaType: String?, pagesCount: Int64?, fileSize: Int64?, createdAt: String?, lastModified: String?, tags: [String], authors: [AuthorRow], progressPage: Int64?, progressCompleted: Bool) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.seriesID = seriesID
        self.seriesTitle = seriesTitle
        self.title = title
        self.number = number
        self.numberSort = numberSort
        self.summary = summary
        self.isbn = isbn
        self.releaseDate = releaseDate
        self.mediaType = mediaType
        self.pagesCount = pagesCount
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.tags = tags
        self.authors = authors
        self.progressPage = progressPage
        self.progressCompleted = progressCompleted
    }
    public let serverID: String
    public let remoteID: String
    public let seriesID: String
    public let seriesTitle: String?
    public let title: String
    public let number: String?
    public let numberSort: Double?
    public let summary: String?
    public let isbn: String?
    public let releaseDate: String?
    public let mediaType: String?
    public let pagesCount: Int64?
    public let fileSize: Int64?
    public let createdAt: String?
    public let lastModified: String?
    public let tags: [String]
    public let authors: [AuthorRow]
    public let progressPage: Int64?
    public let progressCompleted: Bool
}

/// One row of the continue-reading shelf (derived from read_progress).
public struct ContinueReadingRecord: Sendable, Equatable, Identifiable {

    public init(bookID: String, bookTitle: String, number: String?, seriesID: String, seriesName: String, page: Int64?, totalPages: Int64?, progressPercent: Int64?, localUpdatedAt: String?) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.number = number
        self.seriesID = seriesID
        self.seriesName = seriesName
        self.page = page
        self.totalPages = totalPages
        self.progressPercent = progressPercent
        self.localUpdatedAt = localUpdatedAt
    }
    public let bookID: String
    public let bookTitle: String
    public let number: String?
    public let seriesID: String
    public let seriesName: String
    public let page: Int64?
    public let totalPages: Int64?
    public let progressPercent: Int64?
    public let localUpdatedAt: String?

    public var id: String { bookID }
}