//! Series DTO — Komga SeriesDto (contract: specs/openapi, shared fixtures:
//! specs/contracts/fixtures/initial-sync/series-page.json and
//! specs/contracts/fixtures/library/series-page.json).

use serde::{Deserialize, Serialize};

use crate::model::author::Author;

/// Page response of the Komga series list endpoint (Spring Data Page shape).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeriesPage {
    pub content: Vec<Series>,
    pub total_elements: i64,
    pub total_pages: i64,
    pub number: i64,
    pub size: i64,
    pub first: bool,
    pub last: bool,
}

/// SeriesDto (unknown fields are ignored by serde).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Series {
    pub id: String,
    pub library_id: String,
    pub name: String,
    #[serde(default)]
    pub created: Option<String>,
    #[serde(default)]
    pub last_modified: Option<String>,
    #[serde(default)]
    pub books_count: Option<i64>,
    #[serde(default)]
    pub books_read_count: Option<i64>,
    #[serde(default)]
    pub books_unread_count: Option<i64>,
    #[serde(default)]
    pub books_in_progress_count: Option<i64>,
    /// `booksMetadata` aggregation — series-level authors/tags (the list
    /// endpoint carries series authors here, not inside `metadata`).
    #[serde(default)]
    pub books_metadata: Option<BookMetadataAggregation>,
    #[serde(default)]
    pub metadata: Option<SeriesMetadata>,
}

/// BookMetadataAggregationDto (subset: series authors/tags aggregation).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookMetadataAggregation {
    #[serde(default)]
    pub authors: Vec<Author>,
    #[serde(default)]
    pub tags: Vec<String>,
}

/// SeriesMetadataDto — the fields the media library needs; unknown fields
/// (links, alternateTitles, sharingLabels, ...) are ignored by serde.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeriesMetadata {
    pub title: String,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub publisher: Option<String>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub authors: Vec<Author>,
    #[serde(default)]
    pub reading_direction: Option<String>,
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default)]
    pub age_rating: Option<String>,
    #[serde(default)]
    pub title_sort: Option<String>,
    #[serde(default)]
    pub total_book_count: Option<i64>,
}
