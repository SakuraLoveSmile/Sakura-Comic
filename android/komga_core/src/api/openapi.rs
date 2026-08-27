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

fn spec() -> Value {
    serde_json::from_str(SPEC).expect("the OpenAPI snapshot must parse")
}

/// Look up `GET path` in the snapshot; `None` when the server has no such route.
pub fn endpoint(path: &str, method: &str) -> Option<Endpoint> {
    let document = spec();
    let operation = document["paths"].get(path)?.get(method)?;
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
    let document = spec();
    let paths = document["paths"].as_object()?;
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
    let document = spec();
    let node = document["paths"].get(path)?;
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
