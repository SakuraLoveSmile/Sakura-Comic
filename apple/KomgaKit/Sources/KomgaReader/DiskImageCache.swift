import Foundation

/// Disk image cache (thumbnails / pages), local-first.
///
/// Layout:
///   cache/thumbnails/
///   cache/pages/
///
/// Phase 0 ships filesystem primitives; LRU eviction and size limits land
/// with cache_entries bookkeeping (docs/offline-storage.md). LRU must never
/// evict offline downloads.
public struct DiskImageCache: Sendable {
    public let rootURL: URL

    /// Creates .../cache/thumbnails and .../cache/pages under rootURL.
    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("thumbnails"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("pages"),
            withIntermediateDirectories: true
        )
    }

    public func thumbnailURL(for key: String) -> URL {
        rootURL
            .appendingPathComponent("thumbnails")
            .appendingPathComponent(Self.safeKey(key))
    }

    public func pageURL(for key: String) -> URL {
        rootURL
            .appendingPathComponent("pages")
            .appendingPathComponent(Self.safeKey(key))
    }

    /// Write bytes under thumbnails/ and return the file URL.
    @discardableResult
    public func storeThumbnail(_ data: Data, for key: String) throws -> URL {
        let url = thumbnailURL(for: key)
        try data.write(to: url)
        return url
    }

    public func load(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Remove a cached file; missing files are treated as success.
    public func remove(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Total bytes currently stored in thumbnails/ and pages/.
    public func bytesUsed() throws -> Int64 {
        var total: Int64 = 0
        for dir in ["thumbnails", "pages"] {
            let dirURL = rootURL.appendingPathComponent(dir)
            let items = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.fileSizeKey]
            )
            for item in items {
                let values = try item.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Cache key for a series cover (multi-server safe).
    public static func coverKey(serverID: String, seriesID: String) -> String {
        safeKey("\(serverID)-\(seriesID)")
    }

    /// Keys become filenames: keep only [A-Za-z0-9._-], everything else -> '_'.
    public static func safeKey(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let underscore = UnicodeScalar(0x5F)!
        let scalars = key.unicodeScalars.map { allowed.contains($0) ? $0 : underscore }
        return String(String.UnicodeScalarView(scalars))
    }
}
