//! OpenAPI conformance — what the API layer may assume about a Komga server.
//!
//! The sync engine is built on five list endpoints. Komga's own OpenAPI
//! document (exported from a running server, `specs/openapi`) says which of
//! them exist and which are deprecated, and "deprecated" in Komga means
//! *removed in the next major version*. Discovering that at runtime on the
//! user's library would be a bad day, so it is checked here instead:
//!
//! * every path the client builds must exist in the snapshot
//! * a path that is deprecated must be pinned in `KNOWN_DEPRECATED_ENDPOINTS`,
//!   so newly deprecated endpoints we start calling fail the test
//! * every page-envelope property Komga says it returns must be a field the
//!   client actually decodes (a rename would otherwise be silently ignored)

use serde_json::Value;

/// The exported Komga OpenAPI document. JSON content, `.yaml` extension, as
/// published by Komga itself.
pub const SPEC: &str = include_str!("../../../../specs/openapi/komga-openapi.yaml");

/// What the snapshot says about one endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub path: String,
    pub method: String,
    pub deprecated: bool,
    pub summary: String,
}

fn spec() -> &'static Value {
    // Parsed once: the helpers below are called per field per fixture entity,
    // and re-reading a 180 KB document each time made the gate take ~19 seconds.
    static DOCUMENT: std::sync::OnceLock<Value> = std::sync::OnceLock::new();
    DOCUMENT.get_or_init(|| serde_json::from_str(SPEC).expect("the OpenAPI snapshot must parse"))
}

/// Look up `GET path` in the snapshot; `None` when the server has no such route.
pub fn endpoint(path: &str, method: &str) -> Option<Endpoint> {
    let operation = spec()["paths"].get(path)?.get(method)?;
    Some(Endpoint {
        path: path.to_string(),
        method: method.to_string(),
        deprecated: operation["deprecated"].as_bool().unwrap_or(false),
        summary: operation["summary"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
    })
}

/// Find the documented path a concrete URL maps onto, matching `{param}`
/// segments against the actual values.
pub fn documented_path(concrete_path: &str) -> Option<String> {
    let paths = spec()["paths"].as_object()?;
    let wanted: Vec<&str> = concrete_path
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect();
    for key in paths.keys() {
        let segments: Vec<&str> = key
            .split('/')
            .filter(|segment| !segment.is_empty())
            .collect();
        if segments.len() != wanted.len() {
            continue;
        }
        if segments
            .iter()
            .zip(wanted.iter())
            .all(|(documented, actual)| documented.starts_with('{') || documented == actual)
        {
            return Some(key.clone());
        }
    }
    None
}

/// The `$ref`ed schema name of a `200 application/json` response.
pub fn response_schema(path: &str, method: &str) -> Option<String> {
    let node = spec()["paths"].get(path)?;
    let schema = node[method]["responses"]["200"]["content"]["application/json"]["schema"].clone();
    let reference = schema["$ref"].as_str()?;
    Some(reference.rsplit('/').next()?.to_string())
}

/// Property names of a `components/schemas` entry.
pub fn schema_properties(name: &str) -> Vec<String> {
    spec()["components"]["schemas"]
        .get(name)
        .and_then(|schema| schema["properties"].as_object())
        .map(|properties| properties.keys().cloned().collect())
        .unwrap_or_default()
}

/// Is this property documented as non-nullable by the server?
pub fn field_is_nullable(schema: &str, field: &str) -> Option<bool> {
    let property = spec()["components"]["schemas"]
        .get(schema)?
        .get("properties")?
        .get(field)?
        .clone();
    match &property["type"] {
        Value::Array(types) => Some(types.iter().any(|t| t.as_str() == Some("null"))),
        Value::String(_) => Some(false),
        _ => None,
    }
}

pub fn field_is_required(schema: &str, field: &str) -> Option<bool> {
    let node = spec()["components"]["schemas"].get(schema)?;
    Some(
        node["required"]
            .as_array()?
            .iter()
            .any(|item| item.as_str() == Some(field)),
    )
}

pub fn schema_has_field(schema: &str, field: &str) -> bool {
    spec()["components"]["schemas"]
        .get(schema)
        .map(|node| node["properties"].get(field).is_some())
        .unwrap_or(false)
}

#[cfg(test)]
mod decode_tests {
    use super::*;

    /// The properties a client struct decodes as **mandatory** (no `Option`, no
    /// `#[serde(default)]`). If Komga ever makes one of these absent or nullable,
    /// decoding fails and the sweep dies halfway through — so the server's own
    /// document must keep saying `required` and non-nullable.
    const MANDATORY_FIELDS: &[(&str, &[&str])] = &[
        ("SeriesDto", &["id", "libraryId", "name"]),
        ("SeriesMetadataDto", &["title"]),
        ("BookDto", &["id", "seriesId", "name"]),
        ("BookMetadataDto", &["title"]),
        ("CollectionDto", &["id", "name"]),
        ("ReadListDto", &["id", "name"]),
        ("LibraryDto", &["id", "name", "root"]),
    ];

    /// Every property the client reads from each schema, mandatory or optional.
    /// Anything here that the server does not document would silently decode to
    /// `None`/default forever, so the mismatch has to be a deliberate exception.
    const DECODED_FIELDS: &[(&str, &[&str])] = &[
        (
            "SeriesDto",
            &[
                "id",
                "libraryId",
                "name",
                "created",
                "lastModified",
                "booksCount",
                "booksReadCount",
                "booksUnreadCount",
                "booksInProgressCount",
                "booksMetadata",
                "metadata",
            ],
        ),
        (
            "SeriesMetadataDto",
            &[
                "title",
                "status",
                "summary",
                "publisher",
                "genres",
                "tags",
                "readingDirection",
                "language",
                "ageRating",
                // authors is deliberately NOT here: see
                // `series_authors_come_from_the_aggregation`.
            ],
        ),
        (
            "BookDto",
            &[
                "id",
                "seriesId",
                "seriesTitle",
                "name",
                "number",
                "oneshot",
                "created",
                "lastModified",
                "sizeBytes",
                "media",
                "metadata",
                "readProgress",
            ],
        ),
        ("MediaDto", &["mediaType", "pagesCount"]),
        (
            "BookMetadataDto",
            &[
                "title",
                "number",
                "numberSort",
                "summary",
                "isbn",
                "releaseDate",
                "authors",
                "tags",
            ],
        ),
        ("ReadProgressDto", &["page", "completed", "lastModified"]),
        (
            "CollectionDto",
            &[
                "id",
                "name",
                "ordered",
                "filtered",
                "seriesIds",
                "createdDate",
                "lastModifiedDate",
            ],
        ),
        (
            "ReadListDto",
            &[
                "id",
                "name",
                "summary",
                "ordered",
                "filtered",
                "bookIds",
                "createdDate",
                "lastModifiedDate",
            ],
        ),
        ("LibraryDto", &["id", "name", "root", "unavailable"]),
        ("BookMetadataAggregationDto", &["authors", "tags"]),
        ("AuthorDto", &["name", "role"]),
    ];

    #[test]
    fn fields_we_require_are_required_by_the_server() {
        for (schema, fields) in MANDATORY_FIELDS {
            for field in *fields {
                assert_eq!(
                    field_is_required(schema, field),
                    Some(true),
                    "{schema}.{field} is decoded as mandatory but the server does not \
                     document it as required — a response without it would abort a sweep"
                );
                assert_eq!(
                    field_is_nullable(schema, field),
                    Some(false),
                    "{schema}.{field} can be null according to the server, but the client \
                     decodes it as a non-optional value"
                );
            }
        }
    }

    #[test]
    fn fields_we_read_exist_on_the_server() {
        for (schema, fields) in DECODED_FIELDS {
            for field in *fields {
                assert!(
                    schema_has_field(schema, field),
                    "the client reads {schema}.{field}, but the server documents no such \
                     property — it would silently decode to None/default"
                );
            }
        }
    }

    /// Walk a "list of pages" and audit every entity inside it.
    fn audit_pages(
        pages: Option<&Vec<Value>>,
        schema: &str,
        label: &str,
        snapshot: &str,
        problems: &mut Vec<String>,
    ) {
        for page in pages.cloned().unwrap_or_default() {
            for item in page.as_array().cloned().unwrap_or_default() {
                audit_object(schema, label, snapshot, &item, problems);
            }
        }
    }

    /// Assert every Komga-required property the client reads is present in one
    /// fixture entity, then descend into nested objects it models too.
    fn audit_object(
        schema: &str,
        label: &str,
        snapshot: &str,
        item: &Value,
        problems: &mut Vec<String>,
    ) {
        let Some(object) = item.as_object() else {
            return;
        };
        let Some(fields) = DECODED_FIELDS
            .iter()
            .find(|(modelled, _)| *modelled == schema)
            .map(|(_, fields)| *fields)
        else {
            return;
        };
        let name = object
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("(no id)");
        for field in fields {
            if !field_is_required(schema, field).unwrap_or(false) {
                continue;
            }
            if !object.contains_key(*field) {
                problems.push(format!(
                    "{label} {snapshot}/{name}: {schema}.{field} is required by Komga and \
                     read by the client, but the fixture omits it"
                ));
            }
        }
        let children: &[(&str, &str)] = match schema {
            "SeriesDto" => &[
                ("metadata", "SeriesMetadataDto"),
                ("booksMetadata", "BookMetadataAggregationDto"),
            ],
            "BookDto" => &[
                ("metadata", "BookMetadataDto"),
                ("media", "MediaDto"),
                ("readProgress", "ReadProgressDto"),
            ],
            _ => &[],
        };
        for (key, child_schema) in children {
            let Some(child) = object.get(*key) else {
                continue;
            };
            let nested = format!("{label}.{key}");
            if child.is_object() {
                audit_object(child_schema, &nested, snapshot, child, problems);
            } else if let Some(list) = child.as_array() {
                for entry in list {
                    audit_object(child_schema, &nested, snapshot, entry, problems);
                }
            }
        }
    }

    /// The shared scenario fixtures must not be looser than a real response,
    /// otherwise the contract battery can pass on data the server never sends.
    #[test]
    fn fixtures_are_as_strict_as_the_real_server() {
        for file in [
            include_str!("../../../../specs/contracts/fixtures/sync/scenario-reconcile.json"),
            include_str!("../../../../specs/contracts/fixtures/sync/scenario-interrupt.json"),
        ] {
            let scenario: Value = serde_json::from_str(file).unwrap();
            let mut problems: Vec<String> = Vec::new();
            for snap in scenario["snapshots"].as_array().unwrap() {
                let id = snap["id"].as_str().unwrap_or("?").to_string();
                audit_pages(
                    snap["series"].as_array(),
                    "SeriesDto",
                    "series",
                    &id,
                    &mut problems,
                );
                audit_pages(
                    snap["collections"].as_array(),
                    "CollectionDto",
                    "collection",
                    &id,
                    &mut problems,
                );
                audit_pages(
                    snap["readlists"].as_array(),
                    "ReadListDto",
                    "readlist",
                    &id,
                    &mut problems,
                );
                audit_pages(
                    snap["onDeck"].as_array(),
                    "BookDto",
                    "on-deck book",
                    &id,
                    &mut problems,
                );
                for library in snap["libraries"].as_array().cloned().unwrap_or_default() {
                    audit_object("LibraryDto", "library", &id, &library, &mut problems);
                }
                if let Some(map) = snap["books"].as_object() {
                    for pages in map.values() {
                        audit_pages(pages.as_array(), "BookDto", "book", &id, &mut problems);
                    }
                }
            }
            assert!(
                problems.is_empty(),
                "{}: the fixtures are looser than a real Komga response:\n{}",
                scenario["name"].as_str().unwrap_or("?"),
                problems.join("\n")
            );
        }
    }

    /// Series-level authors are read from `booksMetadata` (the aggregation),
    /// because `SeriesMetadataDto` has no `authors` field. If Komga ever adds
    /// one, this test says so instead of us reading the wrong source forever.
    #[test]
    fn series_authors_come_from_the_aggregation() {
        assert!(
            !schema_has_field("SeriesMetadataDto", "authors"),
            "SeriesMetadataDto now has authors — check whether the mirror should read \
             series authors from there instead of booksMetadata"
        );
        assert!(schema_has_field("BookMetadataAggregationDto", "authors"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::{book, collection, readlist, series, server};

    /// Endpoints the sync engine depends on. If Komga drops one, the sweep
    /// cannot run at all, so this list is the durability contract.
    const SYNC_ENDPOINTS: &[(&str, &str)] = &[
        ("/api/v1/libraries", "get"),
        ("/api/v1/series", "get"),
        ("/api/v1/series/{seriesId}/books", "get"),
        ("/api/v1/books/ondeck", "get"),
        ("/api/v1/collections", "get"),
        ("/api/v1/readlists", "get"),
    ];

    /// Deprecated upstream, knowingly. Each has a documented successor; moving
    /// to it is a transport change that must be verified against a real server.
    const KNOWN_DEPRECATED_ENDPOINTS: &[&str] =
        &["/api/v1/series", "/api/v1/series/{seriesId}/books"];

    #[test]
    fn every_sync_endpoint_exists_on_the_server() {
        for (path, method) in SYNC_ENDPOINTS {
            let found = endpoint(path, method);
            assert!(
                found.is_some(),
                "GET {path} is not in Komga's OpenAPI document — the sync engine would be \
                 calling a route that does not exist",
            );
        }
    }

    #[test]
    fn deprecation_is_pinned_and_explained() {
        let mut seen = Vec::new();
        for (path, method) in SYNC_ENDPOINTS {
            let found = endpoint(path, method).unwrap();
            if found.deprecated {
                seen.push(found.path.clone());
            }
        }
        seen.sort();
        let mut expected = KNOWN_DEPRECATED_ENDPOINTS.to_vec();
        expected.sort();
        assert_eq!(
            seen, expected,
            "the sync engine's use of deprecated endpoints changed; either adopt the \
             successor (POST /api/v1/series/list, POST /api/v1/books/list) or pin the \
             new state here with a reason"
        );
    }

    /// The client's page DTOs must cover every property Komga documents, so a
    /// rename shows up as a test failure rather than a silently missing field.
    #[test]
    fn page_envelope_fields_are_understood() {
        let ours = [
            "content",
            "totalElements",
            "totalPages",
            "number",
            "size",
            "first",
            "last",
        ];
        for path in [
            "/api/v1/series",
            "/api/v1/books/ondeck",
            "/api/v1/collections",
            "/api/v1/readlists",
        ] {
            let schema = response_schema(path, "get")
                .unwrap_or_else(|| panic!("{path} has no JSON response schema"));
            let properties = schema_properties(&schema);
            assert!(!properties.is_empty(), "{schema} lists no properties");
            for field in properties.iter().filter(|field| !is_hateoas(field)) {
                assert!(
                    ours.contains(&field.as_str()) || is_derived(field),
                    "{schema}.{field} is returned by Komga but not modelled by the client"
                );
            }
            for field in ours {
                assert!(
                    properties.contains(&field.to_string()),
                    "the client decodes {field}, but {schema} no longer documents it"
                );
            }
        }
    }

    /// HATEOAS/pagination metadata the client derives instead of decoding.
    fn is_hateoas(field: &str) -> bool {
        matches!(field, "pageable" | "sort")
    }

    /// `empty` and `numberOfElements` are computable from the fields the client
    /// does decode, so ignoring them cannot lose information.
    fn is_derived(field: &str) -> bool {
        matches!(field, "empty" | "numberOfElements")
    }

    /// The paths the client builds must be the paths the spec documents — a
    /// typo in a URL builder would otherwise only show up against a real server.
    #[test]
    fn built_urls_match_documented_paths() {
        let base = "https://komga.example.com";
        let request = series::PageRequest::new(0, 100);
        let cases = [
            (series::series_page_url(base, &request), "/api/v1/series"),
            (
                book::books_page_url(base, "series-1", &request),
                "/api/v1/series/{seriesId}/books",
            ),
            (book::on_deck_url(base, &request), "/api/v1/books/ondeck"),
            (
                collection::collections_page_url(base, &request, None),
                "/api/v1/collections",
            ),
            (
                readlist::readlists_page_url(base, &request),
                "/api/v1/readlists",
            ),
            (server::libraries_url(base), "/api/v1/libraries"),
        ];
        for (built, documented) in cases {
            let path = built
                .trim_start_matches(base)
                .split('?')
                .next()
                .unwrap()
                .to_string();
            assert_eq!(
                documented_path(&path).as_deref(),
                Some(documented),
                "{built} builds a path the server does not document"
            );
        }
    }
}
