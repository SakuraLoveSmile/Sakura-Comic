import Foundation
import XCTest
@testable import KomgaDownloads
@testable import KomgaReader
@testable import KomgaStore

/// Swift twin of `komga_core::cache::demo_png`: deterministic RGB PNG bytes,
/// built with no image library so both platforms can measure the same page.
///
/// The encoder writes non-interlaced RGB8 PNGs whose IDAT uses deflate *stored*
/// blocks, so a page's byte size is a function of its pixel size rather than of
/// whatever a compression library felt like that day. That is what makes the
/// cache tests able to reason about budgets: "room for two pages" means two
/// pages here, not two pages plus an unknown.
///
/// One deliberate difference from the Rust encoder: the ancillary `tEXt` padding
/// chunk goes *after* `IHDR`, not before. PNG requires IHDR first, and the
/// integrity walker (on both platforms) rejects a chunk that precedes it, so
/// padding ahead of the header would make every padded page a refusal.
enum DemoPNG {
    /// Width encodes the page number, so a reader can prove from the decoded
    /// bytes that page N is the page it asked for — the same reason Rust does it.
    static func pageDimensions(_ number: UInt32) -> (UInt32, UInt32) {
        (64 + number, 96 + (number % 5))
    }

    /// Fixture page image (RGB PNG) for one canonical 1-based page number.
    static func page(_ number: UInt32) -> Data {
        let (width, height) = pageDimensions(number)
        return png(width: Int(width), height: Int(height), rgb: color(for: number))
    }

    static func pageBytes(_ number: UInt32) -> [UInt8] {
        [UInt8](page(number))
    }

    /// A page padded with a legal ancillary `tEXt` chunk to at least `minBytes`.
    static func paddedPage(_ number: UInt32, minBytes: Int) -> Data {
        let (width, height) = pageDimensions(number)
        let bare = png(width: Int(width), height: Int(height), rgb: color(for: number)).count
        return png(
            width: Int(width), height: Int(height), rgb: color(for: number),
            pad: max(minBytes - bare - 16, 0)
        )
    }

    static func color(for number: UInt32) -> (UInt8, UInt8, UInt8) {
        // Stable per page, and different between pages.
        let hue = Int((UInt64(number) &* 47) % 360)
        return hsvToRgb(Double(hue) / 360.0, 0.55, 0.85)
    }

    static func png(
        width: Int,
        height: Int,
        rgb: (UInt8, UInt8, UInt8),
        pad: Int = 0
    ) -> Data {
        var out: [UInt8] = Array(ImageIntegrity.pngSignature)
        var ihdr: [UInt8] = []
        ihdr.append(contentsOf: be32(UInt32(truncatingIfNeeded: width)))
        ihdr.append(contentsOf: be32(UInt32(truncatingIfNeeded: height)))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // bit depth 8, colour type 2 (RGB)
        pushChunk(&out, bytes("IHDR"), ihdr)
        if pad > 0 {
            // Ancillary, and after IHDR where the spec puts it.
            pushChunk(&out, bytes("tEXt"), bytes("pad ") + [UInt8](repeating: 0x78, count: pad))
        }
        var raw: [UInt8] = []
        raw.reserveCapacity((1 + width * 3) * height)
        for _ in 0..<height {
            raw.append(0) // filter byte: None
            for _ in 0..<width { raw.append(contentsOf: [rgb.0, rgb.1, rgb.2]) }
        }
        pushChunk(&out, bytes("IDAT"), zlibStored(raw))
        pushChunk(&out, bytes("IEND"), [])
        return Data(out)
    }

    // MARK: - Encoder plumbing

    static func zlibStored(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01] // CMF/FLG: deflate, 32K window, no dict
        var pos = 0
        while true {
            let len = min(data.count - pos, 0xFFFF)
            let isFinal = (pos + len) == data.count
            out.append(isFinal ? 1 : 0) // BFINAL | BTYPE=00 (stored)
            out.append(contentsOf: le16(UInt16(truncatingIfNeeded: len)))
            out.append(contentsOf: le16(~UInt16(truncatingIfNeeded: len)))
            out.append(contentsOf: data[pos..<(pos + len)])
            pos += len
            if isFinal { break }
        }
        out.append(contentsOf: be32(adler32(data)))
        return out
    }

    static func pushChunk(_ out: inout [UInt8], _ kind: [UInt8], _ data: [UInt8]) {
        out.append(contentsOf: be32(UInt32(truncatingIfNeeded: data.count)))
        out.append(contentsOf: kind)
        out.append(contentsOf: data)
        out.append(contentsOf: be32(ImageIntegrity.crc32(kind + data)))
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    static func byte(_ value: UInt32, _ shift: Int) -> UInt8 {
        UInt8((value >> UInt32(shift)) & 0xFF)
    }

    static func be32(_ value: UInt32) -> [UInt8] {
        [byte(value, 24), byte(value, 16), byte(value, 8), byte(value, 0)]
    }

    static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    static func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> (UInt8, UInt8, UInt8) {
        let i = Int((h * 6.0).rounded(.down))
        let f = h * 6.0 - Double(i)
        let p = v * (1.0 - s)
        let q = v * (1.0 - f * s)
        let t = v * (1.0 - (1.0 - f) * s)
        let triple: (Double, Double, Double)
        switch ((i % 6) + 6) % 6 {
        case 0: triple = (v, t, p)
        case 1: triple = (q, v, p)
        case 2: triple = (p, v, t)
        case 3: triple = (p, q, v)
        case 4: triple = (t, p, v)
        default: triple = (v, p, q)
        }
        return (
            UInt8(min(max(triple.0 * 255.0, 0), 255).rounded(.down)),
            UInt8(min(max(triple.1 * 255.0, 0), 255).rounded(.down)),
            UInt8(min(max(triple.2 * 255.0, 0), 255).rounded(.down))
        )
    }
}

/// Shared temp-dir + store scaffolding for the cache suites, so a test names the
/// thing it is checking rather than the plumbing it needs.
final class CacheHarness: @unchecked Sendable {
    let directory: URL
    let store: KomgaStore
    let cache: PageCache

    init(budgetBytes: Int64 = 0, memoryBytes: Int? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageCacheTests-\(UUID().uuidString)")
        store = try KomgaStore()
        cache = try PageCache(store: store, rootURL: directory)
        // Ledger-level tests opt out of automatic trimming the same way Rust's
        // harness does: a budget of 0 disables it, and the tests that care set a
        // real number.
        cache.budgetBytes = budgetBytes
        if let memoryBytes { cache.setMemoryBudget(memoryBytes) }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `(pages/, prefetch/)` file names.
    func tiers() throws -> (pages: [String], prefetch: [String]) {
        (
            try cache.disk.files(inTier: DiskImageCache.pagesTier),
            try cache.disk.files(inTier: DiskImageCache.prefetchTier)
        )
    }

    /// A manifest of `pages` entries for one book, built through the production
    /// normalizer so the fixture cannot disagree with the real thing.
    func manifest(
        serverID: String = "srv",
        bookID: String = "book",
        pages: Int
    ) -> PageManifest {
        let indexes = pages > 0 ? Array(1...pages) : [Int]()
        let raw = indexes.map { index -> RawPage in
            let number = UInt32(index)
            let (width, height) = DemoPNG.pageDimensions(number)
            return RawPage(
                fileName: String(format: "%03d.png", index),
                mediaType: "image/png",
                number: Int64(index),
                width: Int64(width),
                height: Int64(height),
                sizeBytes: Int64(DemoPNG.page(number).count)
            )
        }
        return PageManifest.fromRaw(
            serverID: serverID, bookID: bookID, bookMediaType: nil, raw: raw
        )
    }

    func page(_ number: UInt32) -> Data { DemoPNG.page(number) }
}
