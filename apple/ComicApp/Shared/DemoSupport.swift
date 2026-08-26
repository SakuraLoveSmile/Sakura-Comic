import Foundation
import KomgaAPI
import KomgaSync
import KomgaReader
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Inline fixture so the demo runs without a server or a bundled resource.
/// Shape mirrors `specs/contracts/fixtures/initial-sync/series-page.json`.
private let demoFixtureJSON = """
{
  "content": [
    {"id":"s-berserk","libraryId":"lib-1","name":"Berserk","metadata":{"title":"Berserk","status":"ONGOING","publishers":[]}},
    {"id":"s-onepiece","libraryId":"lib-1","name":"One Piece","metadata":{"title":"One Piece","status":"ONGOING","publishers":[]}},
    {"id":"s-solo","libraryId":"lib-1","name":"Solo Leveling","metadata":{"title":"Solo Leveling","status":"ENDED","publishers":[]}}
  ],
  "totalElements":3,"totalPages":1,"number":0,"size":10,"first":true,"last":true
}
"""

/// Fake series endpoint returning the shared fixture.
struct DemoPageFetcher: SeriesPageFetching {
    func fetchSeriesPage(_ request: PageRequest) async throws -> SeriesPageDTO {
        let data = Data(demoFixtureJSON.utf8)
        return try JSONDecoder().decode(SeriesPageDTO.self, from: data)
    }
}

/// Generates a deterministic colored cover so the wall is visible offline.
struct DemoCoverFetcher: CoverFetching {
    func fetchCoverData(_ url: URL) async throws -> Data {
        makeCoverPNG(seed: url.absoluteString)
    }
}

private func makeCoverPNG(seed: String) -> Data {
    let width = 200
    let height = 300
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: bitmapInfo
    ) else { return Data() }

    let hash = abs(seed.hashValue)
    let hue = CGFloat(hash % 360) / 360.0
    let (r, g, b) = hsbToRgb(hue, s: 0.55, v: 0.85)
    if let fill = CGColor(colorSpace: colorSpace, components: [r, g, b, 1.0]) {
        context.setFillColor(fill)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    guard let cgImage = context.makeImage(),
          let data = pngData(from: cgImage) else { return Data() }
    return data
}

private func hsbToRgb(_ h: CGFloat, s: CGFloat, v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    let i = Int(h * 6)
    let f = h * 6 - CGFloat(i)
    let p = v * (1 - s)
    let q = v * (1 - f * s)
    let t = v * (1 - (1 - f) * s)
    switch i % 6 {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

private func pngData(from cgImage: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

// MARK: - Full media library demo (Stage 4)

/// Serves the shared library fixtures (specs/contracts/fixtures/library/)
/// when the repo is present, so the demo shows the WHOLE media library
/// offline: 2 libraries, 3 series, 7 books, 2 collections, 2 readlists,
/// 1 on-deck book. Falls back to an empty page for anything unknown.
struct DemoLibraryFetcher: LibraryFetching {
    func fetchSeriesPage(_ request: PageRequest) async throws -> SeriesPageDTO {
        if request.page == 0 {
            return try DemoFixtures.load("series-page.json")
        }
        return emptySeriesPage()
    }

    func fetchBooksPage(seriesID: String, request: PageRequest) async throws -> BookPageDTO {
        guard request.page == 0 else { return emptyBookPage() }
        let bySeries: [String: BookPageDTO] = try DemoFixtures.load("books-by-series.json")
        return bySeries[seriesID] ?? emptyBookPage()
    }

    func fetchOnDeckPage(request _: PageRequest) async throws -> BookPageDTO {
        try DemoFixtures.load("ondeck-page.json")
    }

    func fetchCollectionsPage(request _: PageRequest) async throws -> CollectionPageDTO {
        try DemoFixtures.load("collections-page.json")
    }

    func fetchReadlistsPage(request _: PageRequest) async throws -> ReadListPageDTO {
        try DemoFixtures.load("readlists-page.json")
    }

    func fetchLibraries() async throws -> [LibraryDTO] {
        try DemoFixtures.load("libraries.json")
    }

    private func emptySeriesPage() -> SeriesPageDTO {
        SeriesPageDTO(content: [], totalElements: 0, totalPages: 0, number: 0, size: 100, first: false, last: true)
    }

    private func emptyBookPage() -> BookPageDTO {
        BookPageDTO(content: [], totalElements: 0, totalPages: 0, number: 0, size: 100, first: false, last: true)
    }
}

/// Loads one shared fixture from the repo (read-only; missing when the app
/// runs from a bundle, in which case the demo falls back to the inline
/// series fixture via `DemoPageFetcher`-style decoding failures).
enum DemoFixtures {
    static func load<T: Decodable>(_ name: String) throws -> T {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../specs/contracts/fixtures/library/\(name)")
            .standardizedFileURL
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
