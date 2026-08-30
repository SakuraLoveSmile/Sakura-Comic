import Foundation

/// Disk image cache with the three tiers the reader needs (mirror of
/// `cache/mod.rs`), local-first.
///
/// Layout:
///   cache/
///   ├── thumbnails/   covers, keyed per entity
///   ├── pages/        bytes the reader actually displayed, plus offline downloads
///   └── prefetch/     bytes pulled ahead of the reader and not yet looked at
///
/// The split between `pages/` and `prefetch/` is what makes eviction honest:
/// unseen bytes are worth less than seen bytes, so they are always the first
/// victims (`PageCache.evictToBudget`). LRU accounting lives in the
/// `cache_entries` ledger, not on the filesystem; these are the primitives.
public struct DiskImageCache: Sendable {
    public let rootURL: URL

    public static let thumbnailsTier = "thumbnails"
    public static let pagesTier = "pages"
    public static let prefetchTier = "prefetch"

    /// Every tier, in the order a sweep should walk them.
    public static let tiers: [String] = [thumbnailsTier, pagesTier, prefetchTier]

    /// Suffix a partially written file carries. It is never a cache candidate,
    /// so anything found with it during a sweep is debris from an interrupted
    /// write.
    public static let partSuffix = ".part"

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        for tier in Self.tiers {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent(tier),
                withIntermediateDirectories: true
            )
        }
    }

    public func thumbnailURL(for key: String) -> URL {
        url(inTier: Self.thumbnailsTier, named: Self.safeKey(key))
    }

    public func pageURL(for key: String) -> URL {
        url(inTier: Self.pagesTier, named: Self.safeKey(key))
    }

    public func prefetchURL(for key: String) -> URL {
        url(inTier: Self.prefetchTier, named: Self.safeKey(key))
    }

    public func url(inTier tier: String, named name: String) -> URL {
        rootURL.appendingPathComponent(tier).appendingPathComponent(name)
    }

    public func directoryURL(forTier tier: String) -> URL {
        rootURL.appendingPathComponent(tier)
    }

    /// The pages directory, for callers that build a path themselves (the page
    /// cache appends the response-content-type extension).
    public func pagesDirectoryURL() -> URL {
        directoryURL(forTier: Self.pagesTier)
    }

    public func prefetchDirectoryURL() -> URL {
        directoryURL(forTier: Self.prefetchTier)
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Bytes actually on disk, or nil when the file is gone. The cache accounts
    /// with this rather than with a manifest guess.
    public func size(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let bytes = values.fileSize else { return nil }
        return Int64(bytes)
    }

    /// Write bytes under thumbnails/ and return the file URL.
    @discardableResult
    public func storeThumbnail(_ data: Data, for key: String) throws -> URL {
        let url = thumbnailURL(for: key)
        try data.write(to: url)
        return url
    }

    /// Commit page bytes atomically: write to a `.part` sibling, then rename.
    /// A crash mid-download therefore leaves no candidate for a cache hit.
    @discardableResult
    public func storePage(_ data: Data, at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staging = Self.stagingURL(for: url)
        do {
            try data.write(to: staging)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: staging, to: url)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return url
    }

    /// The `.part` path one committed URL stages through. A sweep that finds a
    /// name with this suffix knows the write that produced it never finished.
    public static func stagingURL(for url: URL) -> URL {
        url.appendingPathExtension("part")
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

    /// File names present in one tier directory. Empty when the directory is
    /// gone, which is a legitimate state for a sweep (nothing to reconcile).
    /// Ascending so a sweep is reproducible.
    public func files(inTier tier: String) throws -> [String] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL(forTier: tier),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        guard let contents else { return [] }
        return contents
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile ?? false
            }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Delete every `*.part` staging file. A download that was interrupted
    /// leaves one behind, and nothing ever reads it, so it is pure waste.
    /// Returns how many files were removed.
    @discardableResult
    public func removeStaleParts() throws -> Int {
        var removed = 0
        for tier in Self.tiers {
            for name in try files(inTier: tier) where name.hasSuffix(Self.partSuffix) {
                try remove(directoryURL(forTier: tier).appendingPathComponent(name))
                removed += 1
            }
        }
        return removed
    }

    /// Move a file from one tier's directory to another's, keeping its name.
    /// This is the prefetch-to-page promotion, and it must stay a rename:
    /// copying a 24 MB page to promote it would cost the reader a frame.
    public func relocate(_ url: URL, toTier tier: String) throws -> URL {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != "." else {
            throw DiskImageCacheError.cachePathHasNoFileName(url.path)
        }
        let target = directoryURL(forTier: tier).appendingPathComponent(name)
        if target.path == url.path { return target }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            // Same filesystem by construction, so this is the rare
            // cross-device/exfat case; a copy is slow but correct.
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: url, to: target)
            try FileManager.default.removeItem(at: url)
            return target
        }
    }

    /// Total bytes currently stored in all three tiers.
    public func bytesUsed() throws -> Int64 {
        var total: Int64 = 0
        for dir in Self.tiers {
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

/// The one filesystem condition `DiskImageCache` has to name rather than wrap:
/// a path with no leaf cannot be relocated between tiers, because relocation
/// keeps the name.
public enum DiskImageCacheError: Error, Sendable, Equatable, CustomStringConvertible {
    case cachePathHasNoFileName(String)

    public var description: String {
        switch self {
        case .cachePathHasNoFileName(let path): return "cache path has no file name: \(path)"
        }
    }
}
