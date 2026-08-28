import XCTest
@testable import KomgaAPI

/// Mirror of the Rust `api/openapi.rs` gate, aimed at the Apple DTOs.
///
/// The probe is general instead of hand-listed: for every property present in a
/// fixture entity, we remove it and try to decode. If decoding then fails, the
/// Swift DTO treats that property as mandatory — which is only safe when Komga
/// documents it as `required`. Anything else is a real-server decode bomb that
/// would abort a sweep halfway.
///
/// Page envelopes are the pinned exception: springdoc declares no `required`
/// for any `Page*Dto`, so the entity rule cannot apply there. The sync
/// algorithm depends on the whole envelope (`last` terminates paging,
/// `number`/`size` drive the cursor), so the client decodes all seven fields
/// as mandatory on purpose and a response without one fails loudly into the
/// unified error model instead of guessing — defaulting `last` to false would
/// page forever.
final class OpenAPIConformanceTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/KomgaKitTests
            .appendingPathComponent("../../../..")   // repo root
            .standardizedFileURL
    }

    private var spec: [String: Any] {
        let data = try! Data(contentsOf: root.appendingPathComponent("specs/openapi/komga-openapi.yaml"))
        return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    private func required(_ schema: String) -> Set<String> {
        let schemas = spec["components"] as? [String: Any] ?? [:]
        let all = schemas["schemas"] as? [String: Any] ?? [:]
        let node = all[schema] as? [String: Any] ?? [:]
        return Set((node["required"] as? [String]) ?? [])
    }

    private func hasProperty(_ schema: String, _ field: String) -> Bool {
        let schemas = spec["components"] as? [String: Any] ?? [:]
        let all = schemas["schemas"] as? [String: Any] ?? [:]
        let node = all[schema] as? [String: Any] ?? [:]
        let props = node["properties"] as? [String: Any] ?? [:]
        return props[field] != nil
    }

    private func properties(_ schema: String) -> Set<String> {
        let schemas = spec["components"] as? [String: Any] ?? [:]
        let all = schemas["schemas"] as? [String: Any] ?? [:]
        let node = all[schema] as? [String: Any] ?? [:]
        guard let props = node["properties"] as? [String: Any] else { return [] }
        return Set(props.keys)
    }

    /// Remove `path` from a copied JSON tree.
    private func removing(_ object: [String: Any], _ path: [String]) -> [String: Any] {
        guard let head = path.first else { return object }
        var copy = object
        if path.count == 1 {
            copy.removeValue(forKey: head)
            return copy
        }
        if let child = copy[head] as? [String: Any] {
            copy[head] = removing(child, Array(path.dropFirst()))
        }
        return copy
    }

    private func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// One probe round: remove every property of `entity` in turn and decode,
    /// flagging any field the DTO makes mandatory that the spec does not.
    /// Nested objects are probed against their own DTO on the child object
    /// itself — decoding the whole entity with a child decoder would fail on
    /// every key and report phantom violations.
    private func probe(
        entity: [String: Any],
        schema: String,
        label: String,
        decode: (Data) throws -> Void,
        children: [String: (schema: String, decode: (Data) throws -> Void, arrays: [String: String])] = [:],
        arrayChildren: [String: String] = [:],
        problems: inout [String]
    ) {
        for key in entity.keys {
            let mutated = removing(entity, [key])
            do {
                try decode(data(mutated))
            } catch {
                if !required(schema).contains(key) {
                    problems.append(
                        "\(label): \(schema).\(key) is decoded as mandatory by KomgaKit, but "
                        + "the server does not document it as required"
                    )
                }
            }
        }
        for (key, child) in children {
            guard let childObject = entity[key] as? [String: Any] else { continue }
            probe(
                entity: childObject,
                schema: child.schema,
                label: "\(label).\(key)",
                decode: child.decode,
                arrayChildren: child.arrays,
                problems: &problems
            )
        }
        // Arrays of objects (authors) — remove a field from the first element.
        for (key, childSchema) in arrayChildren {
            guard var list = entity[key] as? [[String: Any]], !list.isEmpty else { continue }
            for field in list[0].keys {
                var mutated = entity
                list[0] = removing(list[0], [field])
                mutated[key] = list
                do {
                    try decode(data(mutated))
                } catch {
                    if !required(childSchema).contains(field) {
                        problems.append(
                            "\(label).\(key): \(childSchema).\(field) is decoded as mandatory by "
                            + "KomgaKit, but the server does not document it as required"
                        )
                    }
                }
            }
        }
    }

    private func seriesEntities() -> [(snapshot: String, entity: [String: Any])] {
        collect(entitySchemas: [
            ("series", "SeriesDto"),
            ("collections", "CollectionDto"),
            ("readlists", "ReadListDto"),
            ("onDeck", "BookDto"),
        ])
    }

    /// Flatten a scenario file's snapshots into (snapshot, entity) pairs.
    private func collect(entitySchemas: [(key: String, schema: String)])
        -> [(snapshot: String, entity: [String: Any])] {
        var out: [(String, [String: Any])] = []
        for name in ["scenario-reconcile.json", "scenario-interrupt.json"] {
            let url = root.appendingPathComponent("specs/contracts/fixtures/sync/\(name)")
            let json = (try! JSONSerialization.jsonObject(with: Data(contentsOf: url))) as! [String: Any]
            for case let snap as [String: Any] in json["snapshots"] as? [[String: Any]] ?? [] {
                let id = (snap["id"] as? String) ?? "?"
                for (key, schema) in entitySchemas {
                    _ = schema
                    for case let page as [Any] in snap[key] as? [[Any]] ?? [] {
                        for case let entity as [String: Any] in page {
                            out.append((id, entity))
                        }
                    }
                }
                if let books = snap["books"] as? [String: Any] {
                    for pages in books.values {
                        for case let page as [Any] in pages as? [[Any]] ?? [] {
                            for case let entity as [String: Any] in page {
                                out.append((id, entity))
                            }
                        }
                    }
                }
                for case let library as [String: Any] in snap["libraries"] as? [[String: Any]] ?? [] {
                    out.append((id, library))
                }
            }
        }
        return out
    }

    func test_swift_dtos_do_not_require_what_the_server_may_omit() throws {
        let decoder = JSONDecoder()
        var problems: [String] = []

        for (_, entity) in collect(entitySchemas: [("series", "SeriesDto")]) where entity["libraryId"] != nil {
            probe(
                entity: entity,
                schema: "SeriesDto",
                label: "series \(entity["id"] ?? "?")",
                decode: { _ = try decoder.decode(SeriesDTO.self, from: $0) },
                children: [
                    "metadata": (
                        "SeriesMetadataDto",
                        { _ = try decoder.decode(SeriesMetadataDTO.self, from: $0) },
                        [:]
                    ),
                    "booksMetadata": (
                        "BookMetadataAggregationDto",
                        { _ = try decoder.decode(BookMetadataAggregationDTO.self, from: $0) },
                        ["authors": "AuthorDto"]
                    ),
                ],
                problems: &problems
            )
        }

        for (_, entity) in collect(entitySchemas: [("onDeck", "BookDto")]) where entity["seriesId"] != nil {
            probe(
                entity: entity,
                schema: "BookDto",
                label: "book \(entity["id"] ?? "?")",
                decode: { _ = try decoder.decode(BookDTO.self, from: $0) },
                children: [
                    "metadata": (
                        "BookMetadataDto",
                        { _ = try decoder.decode(BookMetadataDTO.self, from: $0) },
                        ["authors": "AuthorDto"]
                    ),
                    "media": (
                        "MediaDto",
                        { _ = try decoder.decode(MediaDTO.self, from: $0) },
                        [:]
                    ),
                    "readProgress": (
                        "ReadProgressDto",
                        { _ = try decoder.decode(ReadProgressDTO.self, from: $0) },
                        [:]
                    ),
                ],
                problems: &problems
            )
        }

        for (_, entity) in collect(entitySchemas: [("collections", "CollectionDto")]) where entity["ordered"] != nil {
            probe(
                entity: entity,
                schema: "CollectionDto",
                label: "collection \(entity["id"] ?? "?")",
                decode: { _ = try decoder.decode(CollectionDTO.self, from: $0) },
                problems: &problems
            )
        }

        for (_, entity) in collect(entitySchemas: [("readlists", "ReadListDto")]) where entity["ordered"] != nil {
            probe(
                entity: entity,
                schema: "ReadListDto",
                label: "readlist \(entity["id"] ?? "?")",
                decode: { _ = try decoder.decode(ReadListDTO.self, from: $0) },
                problems: &problems
            )
        }

        for (_, entity) in collect(entitySchemas: [("libraries", "LibraryDto")]) where entity["root"] != nil {
            probe(
                entity: entity,
                schema: "LibraryDto",
                label: "library \(entity["id"] ?? "?")",
                decode: { _ = try decoder.decode(LibraryDTO.self, from: $0) },
                problems: &problems
            )
        }

        XCTAssertTrue(problems.isEmpty, "Swift decode assumptions exceed what Komga guarantees:\n" + problems.joined(separator: "\n"))
    }

    /// Spring Data pages: springdoc populates no `required` for any `Page*Dto`,
    /// so the entity rule does not apply. Field coverage is checked in both
    /// directions like the Rust gate, and the envelope is pinned mandatory on
    /// purpose — see the class comment for why guessing would be worse.
    func test_page_envelopes_decode_mandatory_on_purpose() throws {
        let decoder = JSONDecoder()
        let envelopeFields: Set<String> = [
            "content", "totalElements", "totalPages", "number", "size", "first", "last",
        ]
        // Fields the client derives or ignores by design, as in the Rust gate.
        let derivedOrHateoas: Set<String> = ["pageable", "sort", "empty", "numberOfElements"]

        let pages: [(schema: String, decode: (Data) throws -> Void)] = [
            ("PageSeriesDto", { _ = try decoder.decode(SeriesPageDTO.self, from: $0) }),
            ("PageBookDto", { _ = try decoder.decode(BookPageDTO.self, from: $0) }),
            ("PageCollectionDto", { _ = try decoder.decode(CollectionPageDTO.self, from: $0) }),
            ("PageReadListDto", { _ = try decoder.decode(ReadListPageDTO.self, from: $0) }),
        ]
        for (schema, decode) in pages {
            XCTAssertTrue(
                required(schema).isEmpty,
                "\(schema) now documents `required` — re-examine the envelope pin: the "
                    + "entity rule (mandatory ⇔ required) could apply again"
            )
            let documented = properties(schema)
            XCTAssertFalse(documented.isEmpty, "\(schema) lists no properties")
            for field in documented where !derivedOrHateoas.contains(field) {
                XCTAssertTrue(
                    envelopeFields.contains(field),
                    "\(schema).\(field) is returned by Komga but not modelled by the client"
                )
            }
            for field in envelopeFields {
                XCTAssertTrue(
                    documented.contains(field),
                    "the client decodes \(field), but \(schema) no longer documents it"
                )
            }
            let envelope: [String: Any] = [
                "content": [], "totalElements": 0, "totalPages": 0,
                "number": 0, "size": 100, "first": true, "last": true,
            ]
            for field in envelopeFields {
                var mutated = envelope
                mutated.removeValue(forKey: field)
                XCTAssertThrowsError(
                    try decode(data(mutated)),
                    "\(schema).\(field) became optional — the sync algorithm depends on the "
                        + "envelope; a missing field must fail loudly, not guess (defaulting "
                        + "`last` to false would page forever)"
                )
            }
        }
    }

    /// The transport must build paths the server actually documents.
    func test_transport_paths_are_documented() throws {
        let documented = Set((spec["paths"] as? [String: Any] ?? [:]).keys)
        let base = "https://komga.example.com"
        let request = PageRequest(page: 0, size: 100)
        let built: [(URL?, String)] = [
            (try? KomgaTransport.seriesPageURL(baseURL: base, request: request), "/api/v1/series"),
            (try? KomgaTransport.booksPageURL(baseURL: base, seriesID: "series-1", request: request),
             "/api/v1/series/{seriesId}/books"),
            (try? KomgaTransport.onDeckPageURL(baseURL: base, request: request), "/api/v1/books/ondeck"),
            (try? KomgaTransport.collectionsPageURL(baseURL: base, request: request), "/api/v1/collections"),
            (try? KomgaTransport.readlistsPageURL(baseURL: base, request: request), "/api/v1/readlists"),
            (try? KomgaTransport.librariesURL(baseURL: base), "/api/v1/libraries"),
        ]
        for (url, documentedPath) in built {
            XCTAssertNotNil(url, "no URL builder produced a path for \(documentedPath)")
            XCTAssertTrue(
                documented.contains(documentedPath),
                "\(documentedPath) is called by the client but absent from Komga's OpenAPI document"
            )
            XCTAssertEqual(
                url?.path, documentedPath.replacingOccurrences(of: "{seriesId}", with: "series-1"),
                "the built URL must map onto the documented path"
            )
        }
        // Two endpoints we depend on are deprecated upstream; that must stay a
        // conscious decision, not an accident.
        for path in ["/api/v1/series", "/api/v1/series/{seriesId}/books"] {
            let get = (spec["paths"] as? [String: Any])?[path] as? [String: Any]
            XCTAssertTrue(
                (get?["get"] as? [String: Any])?["deprecated"] as? Bool == true,
                "\(path) is no longer deprecated in the snapshot — revisit the transport"
            )
        }
        XCTAssertFalse(hasProperty("SeriesMetadataDto", "authors"), "series authors should come from booksMetadata")
    }
}
