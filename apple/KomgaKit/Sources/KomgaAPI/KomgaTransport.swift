import Foundation

/// Page-based series query (behavior contract with Rust).
public struct PageRequest: Sendable, Equatable {
    public var page: Int
    public var size: Int
    public var sort: String?

    public init(page: Int, size: Int, sort: String? = nil) {
        self.page = page
        self.size = size
        self.sort = sort
    }

    public func queryItems() -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(size)),
        ]
        if let sort {
            items.append(URLQueryItem(name: "sort", value: sort))
        }
        return items
    }
}

/// Unified API error mapping (mirrors Rust `ApiError`).
public enum KomgaAPIError: Error, Sendable, Equatable {
    case authentication
    case network
    case server(statusCode: Int)
    case apiCompatibility(String)
    case urlInvalid(String)
    case decode(String)
}

/// URLSession-based transport. One instance per server profile; the auth
/// method is attached at request time — never persist secrets here.
public struct KomgaTransport: Sendable {
    public let baseURL: String
    public let auth: AuthMethod
    private let session: URLSession

    public init(baseURL: String, auth: AuthMethod, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session
    }

    public func fetchSeriesPage(_ request: PageRequest) async throws -> SeriesPageDTO {
        let url = try Self.seriesPageURL(baseURL: baseURL, request: request)
        return try await fetch(SeriesPageDTO.self, url: url)
    }

    /// `GET /actuator/info` — server identity + version (connection probe).
    public func fetchServerInfo() async throws -> ServerInfoDTO {
        let url = try Self.serverInfoURL(baseURL: baseURL)
        return try await fetch(ServerInfoDTO.self, url: url)
    }

    /// `GET /api/v1/libraries` — plain array (no pagination wrapper).
    public func fetchLibraries() async throws -> [LibraryDTO] {
        let url = try Self.librariesURL(baseURL: baseURL)
        return try await fetch([LibraryDTO].self, url: url)
    }

    /// Authenticated GET with unified error mapping.
    public func fetch<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        var urlRequest = URLRequest(url: url)
        auth.apply(to: &urlRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw KomgaAPIError.network
        }
        return try Self.decode(type, data: data, response: response)
    }

    /// Stable URL builder (public for tests and Swift/Rust parity checks).
    public static func seriesPageURL(baseURL: String, request: PageRequest) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: "\(base)/api/v1/series") else {
            throw KomgaAPIError.network
        }
        components.queryItems = request.queryItems()
        guard let url = components.url else {
            throw KomgaAPIError.network
        }
        return url
    }

    /// Komga series thumbnail endpoint (used by the cover cache).
    public static func seriesThumbnailURL(baseURL: String, seriesID: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/api/v1/series/\(seriesID)/thumbnail") else {
            throw KomgaAPIError.network
        }
        return url
    }

    /// Server-info endpoint (connection probe; see specs/openapi).
    public static func serverInfoURL(baseURL: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/actuator/info") else {
            throw KomgaAPIError.network
        }
        return url
    }

    /// Libraries endpoint (connection probe).
    public static func librariesURL(baseURL: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/api/v1/libraries") else {
            throw KomgaAPIError.network
        }
        return url
    }

    public static func decode<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw KomgaAPIError.network
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw KomgaAPIError.decode(error.localizedDescription)
            }
        case 401, 403:
            throw KomgaAPIError.authentication
        default:
            throw KomgaAPIError.server(statusCode: http.statusCode)
        }
    }
}
