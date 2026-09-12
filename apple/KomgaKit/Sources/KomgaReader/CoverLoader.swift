import Foundation
import KomgaAPI

/// Errors from the cover pipeline.
public enum CoverLoaderError: Error, Sendable, Equatable {
    case network
    case http(statusCode: Int)
}

/// Fetches raw cover bytes; implemented by URLSessionCoverFetcher and fakes.
public protocol CoverFetching: Sendable {
    func fetchCoverData(_ url: URL) async throws -> Data
}

/// Real fetcher: attaches AuthMethod and performs the download.
public struct URLSessionCoverFetcher: CoverFetching {
    public let auth: AuthMethod
    public let session: URLSession

    public init(auth: AuthMethod, session: URLSession = KomgaTransport.makeDefaultSession()) {
        self.auth = auth
        self.session = session
    }

    public func fetchCoverData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        auth.apply(to: &request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CoverLoaderError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw CoverLoaderError.network
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CoverLoaderError.http(statusCode: http.statusCode)
        }
        return data
    }
}

/// Cache-first cover service: load from disk, fetch + store on miss.
public struct CoverLoader: Sendable {
    public let cache: DiskImageCache
    private let fetcher: any CoverFetching

    public init(cache: DiskImageCache, fetcher: any CoverFetching) {
        self.cache = cache
        self.fetcher = fetcher
    }

    public func thumbnailData(serverID: String, seriesID: String, coverURL: URL) async throws -> Data {
        let key = DiskImageCache.coverKey(serverID: serverID, seriesID: seriesID)
        let url = cache.thumbnailURL(for: key)
        if let cached = try? cache.load(url) {
            return cached
        }
        let data = try await fetcher.fetchCoverData(coverURL)
        try cache.storeThumbnail(data, for: key)
        return data
    }
}
