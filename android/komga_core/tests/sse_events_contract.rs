//! The shared event-name table, asserted from the same JSON the Swift side
//! reads (`Tests/KomgaKitTests/SSEEventContractTests.swift`).
//!
//! This is the cross-platform half of `specs/contracts/reconnect/README.md`:
//! Rust's `classify` and Swift's `EventClassifying.classify` must agree on every
//! name Komga puts on the wire, because a mismatch is a silently different
//! refresh behaviour on the two platforms.

use std::fs;

use komga_core::api::sse::SseEvent;
use komga_core::sync::sse::{classify, DirtySet, Hint, Target};
use serde::Deserialize;

#[derive(Deserialize)]
struct Fixture {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    event: String,
    data: String,
    expect: Expect,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Expect {
    #[serde(default)]
    books: Vec<String>,
    #[serde(default)]
    deleted_books: Vec<String>,
    #[serde(default)]
    needs_sweep: bool,
    #[serde(default)]
    ignore: bool,
}

fn path() -> String {
    format!(
        "{}/../../specs/contracts/fixtures/sse/events.json",
        env!("CARGO_MANIFEST_DIR")
    )
}

#[test]
fn the_event_table_matches_the_shared_fixture() {
    let raw = fs::read_to_string(path()).expect("shared event fixture must be readable");
    let fixture: Fixture =
        serde_json::from_str(&raw).expect("events.json must decode into the test shape");
    assert!(
        fixture.cases.len() >= 20,
        "the event fixture lost cases: {}",
        fixture.cases.len()
    );
    for case in &fixture.cases {
        let hint = classify(&SseEvent {
            kind: case.event.clone(),
            data: case.data.clone(),
            id: None,
            retry_ms: None,
        });
        // Fold the hint the way a session would, then compare observable state.
        let mut dirty = DirtySet::default();
        dirty.merge(&hint);
        let books: Vec<String> = dirty.books.iter().cloned().collect();
        let deleted: Vec<String> = dirty.deleted_books.iter().cloned().collect();
        assert_eq!(books, case.expect.books, "{} books", case.event);
        assert_eq!(deleted, case.expect.deleted_books, "{} deleted", case.event);
        assert_eq!(
            dirty.needs_sweep(),
            case.expect.needs_sweep,
            "{} needsSweep",
            case.event
        );
        if case.expect.ignore {
            assert!(
                books.is_empty() && deleted.is_empty() && !dirty.global,
                "{} must produce no work at all",
                case.event
            );
        }
    }
}

/// The two cases that break a name-keyword matcher, named explicitly so a
/// regression reports itself.
#[test]
fn keyword_heuristics_are_not_good_enough() {
    // No "book" in the name, but it is a book's progress that changed.
    let progress = classify(&SseEvent {
        kind: "ReadProgressChanged".into(),
        data: r#"{"bookId":"b1","userId":"u1"}"#.into(),
        id: None,
        retry_ms: None,
    });
    assert_eq!(progress.targets, vec![Target::Book("b1".into())]);
    assert!(
        !progress.global,
        "a remote read must not force a full sweep"
    );

    // "Deleted" in the name, but the entity is not deleted.
    let thumbnail = classify(&SseEvent {
        kind: "ThumbnailBookDeleted".into(),
        data: r#"{"bookId":"b1","seriesId":"s1","selected":false}"#.into(),
        id: None,
        retry_ms: None,
    });
    assert!(!thumbnail.deleted, "losing a poster is not losing a book");
    assert_eq!(thumbnail.targets, vec![Target::Book("b1".into())]);
    assert_eq!(
        thumbnail,
        Hint {
            targets: vec![Target::Book("b1".into())],
            global: false,
            deleted: false,
        }
    );
}
