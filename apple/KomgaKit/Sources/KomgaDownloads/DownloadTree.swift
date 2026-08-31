import Foundation

// MARK: - The download tree (mirror of Rust `downloads/manifest.rs`)
//
// File names are the entire interop between the two implementations: a Swift
// side writing `%03d`, or keying a page by the reader's cache key instead of its
// number, produces a tree the other platform cannot read and no test catches
// until a user re-downloads a book. So every rule here is derived from
// `specs/contracts/fixtures/downloads/layout.json`, and
// `DownloadsTreeContractTests` runs that file's own `cases` against it.

public enum DownloadTreeError: Error, Equatable, CustomStringConvertible {
    /// The root resolved inside the cache directory.
    case rootInsideCacheRoot(String)
    /// The document is there but is not the document it claims to be.
    case unreadable(String)

    public var description: String {
        switch self {
        case let .rootInsideCacheRoot(path):
            return "a download root may not live under the cache; refused \(path)"
        case let .unreadable(reason):
            return "download manifest unreadable: \(reason)"
        }
    }
}

/// Where downloads live. A sibling of `cache/`, both derived from the directory
/// holding the database file — and that sibling relationship is the mechanism
/// that makes "no cache cleanup can delete a download" true without a single `if`
/// in an eviction path.
public struct DownloadRoot: Sendable, Equatable {
    public static let directoryName = "downloads"
    public static let cacheDirectoryName = "cache"
    public static let manifestFileName = "manifest.json"
    /// Written-then-renamed, so a half-finished page is never a hit. The
    /// `.part` file is the *only* evidence of an interrupted write; there is no
    /// in-flight page state to keep in sync with it.
    public static let partSuffix = ".part"
    public static let zeroPadWidth = 4
    /// When nothing can be sniffed from the bytes.
    public static let fallbackExtension = "img"

    public var url: URL

    /// Resolve the tree for a database. Refuses a root that lands inside the
    /// cache directory: not as a style rule, but because the cache's own
    /// eviction paths take their authority from being the only thing rooted at
    /// `cache/`.
    public static func forDatabase(_ database: URL) throws -> DownloadRoot {
        let parent = database.deletingLastPathComponent()
        let root = parent.appendingPathComponent(directoryName)
        let cache = parent.appendingPathComponent(cacheDirectoryName)
        try rejectIfUnderCache(root, cache: cache)
        return DownloadRoot(url: root)
    }

    /// An explicitly-named root, for a device that keeps its files somewhere
    /// other than beside the database.
    public static func at(_ url: URL, cacheRoot: URL) throws -> DownloadRoot {
        try rejectIfUnderCache(url, cache: cacheRoot)
        return DownloadRoot(url: url)
    }

    private static func rejectIfUnderCache(_ root: URL, cache: URL) throws {
        let candidate = root.standardizedFileURL.path
        let forbidden = cache.standardizedFileURL.path
        if candidate == forbidden || candidate.hasPrefix(forbidden + "/") {
            throw DownloadTreeError.rootInsideCacheRoot(candidate)
        }
    }

    public func bookDirectory(serverId: String, bookId: String) -> URL {
        url
            .appendingPathComponent(DownloadTree.safeKey(serverId))
            .appendingPathComponent(DownloadTree.safeKey(bookId))
    }

    public var manifestName: String { Self.manifestFileName }
}

public enum DownloadTree {
    /// Keep `[A-Za-z0-9._-]`, map everything else to `_`. Komga ids are
    /// alphanumeric, so this is about the server id a user typed, not about the
    /// book id.
    public static func safeKey(_ value: String) -> String {
        String(value.map { character in
            let isAllowed = character.isLetter || character.isNumber
                || character == "." || character == "_" || character == "-"
            return isAllowed ? character : "_"
        })
    }

    /// `width = max(4, digits(number))`, so page 100000 is `100000.png` rather
    /// than a name that collides with `0000.png`. Four digits covers any book a
    /// person would read; the growth rule is what keeps the mapping injective.
    /// `extension:` is spelled `fileExtension:` here because `extension` is a
    /// keyword in Swift and cannot be interpolated from its own parameter list.
    public static func pageFileName(number: Int, fileExtension: String) -> String {
        let digits = String(number).count
        let width = max(zeroPadWidth, digits)
        let padded = String(repeating: "0", count: max(0, width - digits)) + String(number)
        return "\(padded).\(fileExtension)"
    }

    public static let zeroPadWidth = DownloadRoot.zeroPadWidth

    /// The inverse, for a sweep that has the file and needs the page. A name
    /// that does not parse is not evidence of anything, so it reads as `nil`
    /// rather than as page 0.
    public static func pageNumber(ofFile fileName: String) -> Int? {
        let stem = (fileName as NSString).deletingPathExtension
        guard !stem.isEmpty, stem.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(stem)
    }

    /// The extension comes from the container the bytes actually are, falling
    /// back to `img` when nothing can be sniffed. A declared `Content-Type` is
    /// only a claim; the file is what the decoder will get.
    public static func extensionFor(sniffed: String) -> String {
        let normalised = sniffed.lowercased()
        let known: [String: String] = [
            "png": "png", "jpg": "jpg", "jpeg": "jpg", "gif": "gif", "webp": "webp",
        ]
        return known[normalised] ?? DownloadRoot.fallbackExtension
    }

    /// A page's final path: `downloads/{server}/{book}/0007.png`.
    public static func pagePath(root: DownloadRoot, serverId: String, bookId: String, fileName: String) -> URL {
        root.bookDirectory(serverId: serverId, bookId: bookId).appendingPathComponent(fileName)
    }

    /// Where a page is written before it is renamed into place.
    public static func stagingPath(for page: URL) -> URL {
        page.appendingPathExtension("part")
    }
}

/// One page as the manifest records it.
public struct ManifestPage: Sendable, Equatable, Codable {
    public var number: Int
    public var fileName: String
    /// `image/png`, the server's own wording — not `png`.
    public var mediaType: String
    public var sizeBytes: Int64
    public var width: Int?
    public var height: Int?

    public init(
        number: Int,
        fileName: String,
        mediaType: String,
        sizeBytes: Int64,
        width: Int?,
        height: Int?
    ) {
        self.number = number
        self.fileName = fileName
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.width = width
        self.height = height
    }
}

/// `manifest.json`, the document that makes a directory of files a book.
///
/// `serverId` / `bookId` are the **raw** ids, not the sanitised directory names:
/// a `safeKey` collision between two servers would otherwise be invisible, and
/// this is the only document that can say which book a directory really is.
public struct DownloadManifest: Sendable, Equatable, Codable {
    public var serverId: String
    public var bookId: String
    public var pagesCount: Int
    /// When the job was created. Rewritten only then, never when a page lands:
    /// a 292-page book has one creation time, and 292 page times would make the
    /// field useless for the freshness comparison.
    public var downloadedAt: String
    /// The book's `lastModified` as the server reported it when the job was
    /// created. `nil` when the job was created offline and never saw an answer.
    public var remoteLastModified: String?
    /// Ascending by `number`, and holding only pages that are on disk.
    public var pages: [ManifestPage]

    private enum CodingKeys: String, CodingKey {
        case serverId, bookId, pagesCount, downloadedAt, remoteLastModified, pages
    }

    public init(
        serverId: String,
        bookId: String,
        pagesCount: Int,
        downloadedAt: String,
        remoteLastModified: String?,
        pages: [ManifestPage]
    ) {
        self.serverId = serverId
        self.bookId = bookId
        self.pagesCount = pagesCount
        self.downloadedAt = downloadedAt
        self.remoteLastModified = remoteLastModified
        self.pages = pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverId = try container.decode(String.self, forKey: .serverId)
        bookId = try container.decode(String.self, forKey: .bookId)
        pagesCount = try container.decode(Int.self, forKey: .pagesCount)
        downloadedAt = try container.decode(String.self, forKey: .downloadedAt)
        remoteLastModified = try container.decodeIfPresent(String.self, forKey: .remoteLastModified)
        pages = try container.decode([ManifestPage].self, forKey: .pages)
    }

    /// A missing manifest is not an error: it means the directory was never
    /// finished, or belongs to a build that has not written one yet. Anything
    /// else — present but not decodable — is reported, because a half-written
    /// JSON file is exactly what a process killed mid-rename leaves behind.
    public static func read(at url: URL) throws -> DownloadManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(DownloadManifest.self, from: data)
        } catch {
            throw DownloadTreeError.unreadable(String(describing: error))
        }
    }

    /// Whole-file write, atomically: the manifest is rewritten on page landings
    /// rather than appended per page, so a crash cannot leave a document whose
    /// page list half-agrees with the directory.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The document's own claim about which pages are present, used by the
    /// recovery sweep to tell "not downloaded yet" from "gone".
    public var pageNumbers: Set<Int> { Set(pages.map(\.number)) }
}
