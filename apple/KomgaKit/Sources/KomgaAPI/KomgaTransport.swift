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

/// Strict redirect policy: max 5 hops, same origin only (scheme, host, port),
/// rejecting HTTPS -> HTTP downgrade.
public final class StrictRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public static let maxHops = 5

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let currentURL = task.currentRequest?.url,
              let newURL = request.url else {
            completionHandler(nil)
            return
        }

        let sameScheme = currentURL.scheme?.lowercased() == newURL.scheme?.lowercased()
        let sameHost = currentURL.host?.lowercased() == newURL.host?.lowercased()
        let currentPort = currentURL.port ?? (currentURL.scheme?.lowercased() == "https" ? 443 : 80)
        let newPort = newURL.port ?? (newURL.scheme?.lowercased() == "https" ? 443 : 80)
        let samePort = currentPort == newPort

        let isDowngrade = currentURL.scheme?.lowercased() == "https" && newURL.scheme?.lowercased() == "http"

        if !sameScheme || !sameHost || !samePort || isDowngrade {
            completionHandler(nil)
            return
        }

        let hopCount = (task.taskDescription.flatMap(Int.init) ?? 0) + 1
        if hopCount > Self.maxHops {
            completionHandler(nil)
            return
        }
        task.taskDescription = String(hopCount)

        completionHandler(request)
    }
}

/// URLSession-based transport. One instance per server profile; the auth
/// method is attached at request time — never persist secrets here.
public struct KomgaTransport: Sendable {
    public let baseURL: String
    public let auth: AuthMethod
    private let session: URLSession

    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration, delegate: StrictRedirectDelegate(), delegateQueue: nil)
    }

    public init(baseURL: String, auth: AuthMethod, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.auth = auth
        self.session = session ?? Self.makeDefaultSession()
    }

    public func fetchSeriesPage(_ request: PageRequest) async throws -> SeriesPageDTO {
        let url = try Self.seriesPageURL(baseURL: baseURL, request: request)
        return try await fetch(SeriesPageDTO.self, url: url)
    }

    /// `GET /api/v1/series/{seriesId}/books` — one series' book page.
    public func fetchBooksPage(seriesID: String, request: PageRequest) async throws -> BookPageDTO {
        let url = try Self.booksPageURL(baseURL: baseURL, seriesID: seriesID, request: request)
        return try await fetch(BookPageDTO.self, url: url)
    }

    /// `GET /api/v1/books/ondeck` — continue-reading shelf.
    public func fetchOnDeckPage(request: PageRequest) async throws -> BookPageDTO {
        let url = try Self.onDeckPageURL(baseURL: baseURL, request: request)
        return try await fetch(BookPageDTO.self, url: url)
    }

    /// `GET /api/v1/collections` — collections page.
    public func fetchCollectionsPage(request: PageRequest) async throws -> CollectionPageDTO {
        let url = try Self.collectionsPageURL(baseURL: baseURL, request: request)
        return try await fetch(CollectionPageDTO.self, url: url)
    }

    /// `GET /api/v1/readlists` — readlists page.
    public func fetchReadlistsPage(request: PageRequest) async throws -> ReadListPageDTO {
        let url = try Self.readlistsPageURL(baseURL: baseURL, request: request)
        return try await fetch(ReadListPageDTO.self, url: url)
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

    /// `GET /api/v1/books/{id}` — the Targeted Re-fetch that must precede an
    /// upload, and the read path for an SSE book hint.
    public func fetchBook(id: String) async throws -> BookDTO {
        try await fetch(BookDTO.self, url: Self.bookURL(baseURL: baseURL, bookID: id))
    }

    /// A write that answers `204` with no body: the status code *is* the result,
    /// so it is returned rather than decoded. Transport failures still throw
    /// `.network`; the caller classifies them (contract: 结果分类).
    @discardableResult
    public func performWrite(method: String, path: String, body: String?) async throws -> Int {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)\(path)") else {
            throw KomgaAPIError.urlInvalid("\(base)\(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        auth.apply(to: &request)
        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw KomgaAPIError.network
        }
        guard let http = response as? HTTPURLResponse else {
            throw KomgaAPIError.network
        }
        return http.statusCode
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

    /// Books list URL for one series (stable query order: page, size, sort —
    /// parity with Rust `books_page_url`).
    public static func booksPageURL(baseURL: String, seriesID: String, request: PageRequest) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: "\(base)/api/v1/series/\(seriesID)/books") else {
            throw KomgaAPIError.network
        }
        components.queryItems = request.queryItems()
        guard let url = components.url else {
            throw KomgaAPIError.network
        }
        return url
    }

    /// On-deck (continue reading) URL.
    public static func onDeckPageURL(baseURL: String, request: PageRequest) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: "\(base)/api/v1/books/ondeck") else {
            throw KomgaAPIError.network
        }
        components.queryItems = request.queryItems()
        guard let url = components.url else {
            throw KomgaAPIError.network
        }
        return url
    }

    /// Komga book thumbnail endpoint (used by the cover cache).
    public static func bookThumbnailURL(baseURL: String, bookID: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/api/v1/books/\(bookID)/thumbnail") else {
            throw KomgaAPIError.network
        }
        return url
    }

    /// Collections list URL.
    public static func collectionsPageURL(baseURL: String, request: PageRequest) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: "\(base)/api/v1/collections") else {
            throw KomgaAPIError.network
        }
        components.queryItems = request.queryItems()
        guard let url = components.url else {
            throw KomgaAPIError.network
        }
        return url
    }

    /// Readlists list URL.
    public static func readlistsPageURL(baseURL: String, request: PageRequest) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard var components = URLComponents(string: "\(base)/api/v1/readlists") else {
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

    /// `GET /api/v1/books/{id}` URL (Targeted Re-fetch; parity with Rust
    /// `book_url`).
    public static func bookURL(baseURL: String, bookID: String) throws -> URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/api/v1/books/\(bookID)") else {
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
