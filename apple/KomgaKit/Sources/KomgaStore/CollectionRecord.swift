import Foundation

/// Author row shared by series/book detail reads (role defaults to "").
public struct AuthorRow: Sendable, Equatable {

    public init(name: String, role: String) {
        self.name = name
        self.role = role
    }
    public let name: String
    public let role: String
}

/// A collection row in the local store (mirror of CollectionRow).
public struct CollectionRecord: Sendable, Equatable, Identifiable {

    public init(serverID: String, remoteID: String, name: String, ordered: Bool, filtered: Bool, createdDate: String?, lastModifiedDate: String?) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.name = name
        self.ordered = ordered
        self.filtered = filtered
        self.createdDate = createdDate
        self.lastModifiedDate = lastModifiedDate
    }
    public let serverID: String
    public let remoteID: String
    public let name: String
    public let ordered: Bool
    public let filtered: Bool
    public let createdDate: String?
    public let lastModifiedDate: String?

    public var id: String { remoteID }
}

/// Collection detail: row + its member series (paged).
public struct CollectionDetailRecord: Sendable, Equatable {

    public init(remoteID: String, name: String, ordered: Bool, filtered: Bool, createdDate: String?, lastModifiedDate: String?, members: PagedSeries) {
        self.remoteID = remoteID
        self.name = name
        self.ordered = ordered
        self.filtered = filtered
        self.createdDate = createdDate
        self.lastModifiedDate = lastModifiedDate
        self.members = members
    }
    public let remoteID: String
    public let name: String
    public let ordered: Bool
    public let filtered: Bool
    public let createdDate: String?
    public let lastModifiedDate: String?
    public let members: PagedSeries
}

/// A readlist row in the local store (mirror of ReadlistRow).
public struct ReadlistRecord: Sendable, Equatable, Identifiable {

    public init(serverID: String, remoteID: String, name: String, summary: String?, ordered: Bool, filtered: Bool, createdDate: String?, lastModifiedDate: String?) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.name = name
        self.summary = summary
        self.ordered = ordered
        self.filtered = filtered
        self.createdDate = createdDate
        self.lastModifiedDate = lastModifiedDate
    }
    public let serverID: String
    public let remoteID: String
    public let name: String
    public let summary: String?
    public let ordered: Bool
    public let filtered: Bool
    public let createdDate: String?
    public let lastModifiedDate: String?

    public var id: String { remoteID }
}

/// Readlist detail: row + its ordered books (paged).
public struct ReadlistDetailRecord: Sendable, Equatable {

    public init(remoteID: String, name: String, summary: String?, ordered: Bool, filtered: Bool, createdDate: String?, lastModifiedDate: String?, books: PagedBooks) {
        self.remoteID = remoteID
        self.name = name
        self.summary = summary
        self.ordered = ordered
        self.filtered = filtered
        self.createdDate = createdDate
        self.lastModifiedDate = lastModifiedDate
        self.books = books
    }
    public let remoteID: String
    public let name: String
    public let summary: String?
    public let ordered: Bool
    public let filtered: Bool
    public let createdDate: String?
    public let lastModifiedDate: String?
    public let books: PagedBooks
}

/// Paged series rows + total (本地查询).
public struct PagedSeries: Sendable, Equatable {

    public init(items: [SeriesRecord], total: Int) {
        self.items = items
        self.total = total
    }
    public let items: [SeriesRecord]
    public let total: Int
}

/// Paged book rows + total (本地查询).
public struct PagedBooks: Sendable, Equatable {

    public init(items: [BookRecord], total: Int) {
        self.items = items
        self.total = total
    }
    public let items: [BookRecord]
    public let total: Int
}

/// Paged collection rows + total.
public struct PagedCollections: Sendable, Equatable {

    public init(items: [CollectionRecord], total: Int) {
        self.items = items
        self.total = total
    }
    public let items: [CollectionRecord]
    public let total: Int
}

/// Paged readlist rows + total.
public struct PagedReadlists: Sendable, Equatable {

    public init(items: [ReadlistRecord], total: Int) {
        self.items = items
        self.total = total
    }
    public let items: [ReadlistRecord]
    public let total: Int
}

/// Full series detail (row + metadata + tags/genres/authors + memberships).
public struct SeriesDetailRecord: Sendable, Equatable {

    public init(serverID: String, remoteID: String, libraryID: String, name: String, sortName: String?, status: String?, createdAt: String?, lastModified: String?, booksCount: Int?, booksReadCount: Int?, booksUnreadCount: Int?, booksInProgressCount: Int?, summary: String?, publisher: String?, readingDirection: String?, language: String?, ageRating: String?, totalBookCount: Int?, genres: [String], tags: [String], authors: [AuthorRow], collections: [CollectionRef]) {
        self.serverID = serverID
        self.remoteID = remoteID
        self.libraryID = libraryID
        self.name = name
        self.sortName = sortName
        self.status = status
        self.createdAt = createdAt
        self.lastModified = lastModified
        self.booksCount = booksCount
        self.booksReadCount = booksReadCount
        self.booksUnreadCount = booksUnreadCount
        self.booksInProgressCount = booksInProgressCount
        self.summary = summary
        self.publisher = publisher
        self.readingDirection = readingDirection
        self.language = language
        self.ageRating = ageRating
        self.totalBookCount = totalBookCount
        self.genres = genres
        self.tags = tags
        self.authors = authors
        self.collections = collections
    }
    public let serverID: String
    public let remoteID: String
    public let libraryID: String
    public let name: String
    public let sortName: String?
    public let status: String?
    public let createdAt: String?
    public let lastModified: String?
    public let booksCount: Int?
    public let booksReadCount: Int?
    public let booksUnreadCount: Int?
    public let booksInProgressCount: Int?
    public let summary: String?
    public let publisher: String?
    public let readingDirection: String?
    public let language: String?
    public let ageRating: String?
    public let totalBookCount: Int?
    public let genres: [String]
    public let tags: [String]
    public let authors: [AuthorRow]
    /// Collections that include this series (membership chips).
    public let collections: [CollectionRef]
}

/// A collection that contains a series.
public struct CollectionRef: Sendable, Equatable {

    public init(remoteID: String, name: String) {
        self.remoteID = remoteID
        self.name = name
    }
    public let remoteID: String
    public let name: String
}

/// Distinct filter-chip options derived from the local mirror.
public struct FilterOptions: Sendable, Equatable {

    public init(tags: [String], genres: [String], statuses: [String]) {
        self.tags = tags
        self.genres = genres
        self.statuses = statuses
    }
    public let tags: [String]
    public let genres: [String]
    public let statuses: [String]
}

/// Library rows with their local series counts.
public struct LibraryCountRecord: Sendable, Equatable {

    public init(remoteID: String, name: String, seriesCount: Int) {
        self.remoteID = remoteID
        self.name = name
        self.seriesCount = seriesCount
    }
    public let remoteID: String
    public let name: String
    public let seriesCount: Int
}