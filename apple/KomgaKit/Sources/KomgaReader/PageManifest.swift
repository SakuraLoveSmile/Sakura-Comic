import Foundation
import KomgaStore

// MARK: - Page manifest normalization (mirror of `reader/manifest.rs`)
//
// Contract: `specs/contracts/fixtures/reader/manifest.json`, loaded identically by
// the Rust core.
//
// This module deliberately knows nothing about HTTP: the wire `PageDto` is
// converted into `RawPage` at the API boundary, so the normalization rules below
// are testable without a transport.

/// One entry of `GET /api/v1/books/{id}/pages` before normalization.
public struct RawPage: Sendable, Equatable {
    public var fileName: String
    public var mediaType: String
    public var number: Int64
    public var width: Int64?
    public var height: Int64?
    public var sizeBytes: Int64?

    public init(
        fileName: String = "",
        mediaType: String = "",
        number: Int64 = 0,
        width: Int64? = nil,
        height: Int64? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.fileName = fileName
        self.mediaType = mediaType
        self.number = number
        self.width = width
        self.height = height
        self.sizeBytes = sizeBytes
    }
}

/// A page after normalization. `number` is canonical (1-based, positional).
public struct PageDescriptor: Sendable, Equatable, Codable {
    public var number: UInt32
    public var fileName: String
    public var mediaType: String
    public var width: UInt32
    public var height: UInt32
    public var sizeBytes: Int64

    public init(
        number: UInt32,
        fileName: String,
        mediaType: String,
        width: UInt32,
        height: UInt32,
        sizeBytes: Int64
    ) {
        self.number = number
        self.fileName = fileName
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.sizeBytes = sizeBytes
    }

    /// Unknown aspect ratio: the page cannot be proven to be a spread half.
    public var dimensionsUnknown: Bool { width == 0 || height == 0 }

    public var isImage: Bool { mediaType.hasPrefix("image/") }

    /// Persistence boundary: `store` owns the row shape, the reader owns this
    /// one, and only these two functions translate between them.
    public func toRow() -> BookPageRow {
        BookPageRow(
            number: Int64(number),
            fileName: fileName,
            mediaType: mediaType,
            width: Int64(width),
            height: Int64(height),
            sizeBytes: sizeBytes
        )
    }

    public static func fromRow(_ row: BookPageRow) -> PageDescriptor {
        PageDescriptor(
            number: UInt32(max(row.number, 0)),
            fileName: row.fileName,
            mediaType: row.mediaType,
            width: UInt32(max(row.width, 0)),
            height: UInt32(max(row.height, 0)),
            sizeBytes: row.sizeBytes
        )
    }
}

/// Formats that are paged by a viewer other than the image reader.
public enum Fallback: String, Sendable, Equatable, Codable {
    case epub
    case pdf
}

public struct PageManifest: Sendable, Equatable {
    public var serverID: String
    public var bookID: String
    public var pages: [PageDescriptor]
    /// Entries whose reported `number` disagrees with their position.
    public var drift: UInt32
    public var looksZeroBased: Bool
    public var reflowable: Bool
    public var fallback: Fallback?

    public init(
        serverID: String,
        bookID: String,
        pages: [PageDescriptor],
        drift: UInt32,
        looksZeroBased: Bool,
        reflowable: Bool,
        fallback: Fallback?
    ) {
        self.serverID = serverID
        self.bookID = bookID
        self.pages = pages
        self.drift = drift
        self.looksZeroBased = looksZeroBased
        self.reflowable = reflowable
        self.fallback = fallback
    }

    /// Position is the only ordering authority: `number` never reorders, dedupes
    /// or drops a page (see the `drift` / `duplicates` rules).
    public static func fromRaw(
        serverID: String,
        bookID: String,
        bookMediaType: String?,
        raw: [RawPage]
    ) -> PageManifest {
        var pages: [PageDescriptor] = []
        pages.reserveCapacity(raw.count)
        var drift: UInt32 = 0
        for (index, page) in raw.enumerated() {
            let canonical = Int64(index) + 1
            if page.number != canonical { drift += 1 }
            pages.append(PageDescriptor(
                number: UInt32(max(canonical, 0)),
                fileName: page.fileName,
                mediaType: page.mediaType,
                width: UInt32(max(page.width ?? 0, 0)),
                height: UInt32(max(page.height ?? 0, 0)),
                // `size` is a display string and is intentionally not parsed;
                // the on-disk size is what the cache accounts with.
                sizeBytes: max(page.sizeBytes ?? 0, 0)
            ))
        }

        let bookType = bookMediaType ?? ""
        let reflowable = bookType.contains("epub") || bookType.contains("xhtml")
            || pages.contains { $0.mediaType.contains("epub") || $0.mediaType.contains("xhtml") }
        let allPdf = !pages.isEmpty && pages.allSatisfy { $0.mediaType == "application/pdf" }
        let pdf = !reflowable && (bookType.contains("pdf") || allPdf)

        return PageManifest(
            serverID: serverID,
            bookID: bookID,
            pages: pages,
            drift: drift,
            looksZeroBased: raw.first?.number == 0,
            reflowable: reflowable,
            fallback: reflowable ? .epub : (pdf ? .pdf : nil)
        )
    }

    public var pageCount: UInt32 { UInt32(pages.count) }

    /// Rebuild from the SQLite mirror.
    ///
    /// Delegates to `fromRaw` on purpose: the mirrored path and the network path
    /// must not grow two normalization rules, or an offline open could disagree
    /// with what was cached.
    public static func fromRows(
        serverID: String,
        bookID: String,
        bookMediaType: String?,
        rows: [BookPageRow]
    ) -> PageManifest {
        let raw = rows.map { row in
            RawPage(
                fileName: row.fileName,
                mediaType: row.mediaType,
                number: row.number,
                width: row.width,
                height: row.height,
                sizeBytes: row.sizeBytes
            )
        }
        return fromRaw(
            serverID: serverID, bookID: bookID,
            bookMediaType: bookMediaType, raw: raw
        )
    }

    /// The image reader may only drive an all-image, non-empty manifest.
    public var isPaged: Bool {
        !pages.isEmpty && fallback == nil && pages.allSatisfy(\.isImage)
    }

    /// Stage 6 rule R8: only an image-paged book may report 1-based page numbers
    /// through `read-progress`. EPUB goes to the progression API and PDF goes to
    /// a file viewer, so neither may enqueue a page write.
    public var writesPageProgress: Bool { isPaged }

    /// Empty manifests are a hard error state, never a silent page 1.
    public var emptyError: Bool { pages.isEmpty }

    /// Reflowable books report position through the progression API.
    public var progressionApi: Bool { reflowable }

    /// Canonical numbers, which are also the numbers sent to the 1-based
    /// `?zero_based=false` image endpoint.
    public func canonical() -> [UInt32] { pages.map(\.number) }

    public func unknownDimensions() -> [UInt32] {
        pages.filter(\.dimensionsUnknown).map(\.number)
    }

    public func unpairable() -> Set<UInt32> { Set(unknownDimensions()) }

    public func get(_ number: UInt32) -> PageDescriptor? {
        guard number > 0 else { return nil }
        return pages[Int(number - 1)]
    }

    public func cacheKeys() -> [String] { pages.map { cacheKey($0.number) } }

    public func cacheKey(_ number: UInt32) -> String {
        pageCacheKey(serverID: serverID, bookID: bookID, number: number)
    }
}

/// Multi-server safe page key, sharing the cover key's sanitizer so one cache
/// directory and one LRU pool can account for both.
public func pageCacheKey(serverID: String, bookID: String, number: UInt32) -> String {
    DiskImageCache.safeKey("\(serverID)-\(bookID)-p\(number)")
}

/// The stored extension follows the RESPONSE content type, because the server may
/// transcode (`?convert=jpeg`) or content-negotiate.
public func pageExtension(forContentType contentType: String) -> String {
    let head = contentType
        .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        .first
        .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    switch head {
    case "image/jpeg", "image/jpg": return ".jpg"
    case "image/png": return ".png"
    case "image/webp": return ".webp"
    case "image/gif": return ".gif"
    case "image/avif": return ".avif"
    default: return ".img"
    }
}
