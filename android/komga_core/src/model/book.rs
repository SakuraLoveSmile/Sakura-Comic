//! Book DTOs — subset of the Komga BookDto (contract: specs/openapi,
//! shared fixture: specs/contracts/fixtures/library/books-by-series.json).

use serde::{Deserialize, Serialize};

use crate::model::author::Author;

/// Page response of the Komga books list endpoint (Spring Data Page shape).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookPage {
    pub content: Vec<Book>,
    pub total_elements: i64,
    pub total_pages: i64,
    pub number: i64,
    pub size: i64,
    pub first: bool,
    pub last: bool,
}

/// BookDto — the fields the local mirror needs (unknown fields ignored).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Book {
    pub id: String,
    pub series_id: String,
    #[serde(default)]
    pub series_title: Option<String>,
    pub name: String,
    #[serde(default)]
    pub number: Option<i64>,
    #[serde(default)]
    pub oneshot: bool,
    #[serde(default)]
    pub media: Option<Media>,
    #[serde(default)]
    pub metadata: Option<BookMetadata>,
    #[serde(default)]
    pub read_progress: Option<ReadProgress>,
    #[serde(default)]
    pub created: Option<String>,
    #[serde(default)]
    pub last_modified: Option<String>,
    #[serde(default)]
    pub size_bytes: Option<i64>,
}

/// MediaDto (media type + page count feed the book list UI).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Media {
    #[serde(default)]
    pub media_type: Option<String>,
    #[serde(default)]
    pub pages_count: Option<i64>,
}

/// BookMetadataDto.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookMetadata {
    pub title: String,
    #[serde(default)]
    pub number: Option<String>,
    #[serde(default)]
    pub number_sort: Option<f64>,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub isbn: Option<String>,
    #[serde(default)]
    pub release_date: Option<String>,
    #[serde(default)]
    pub authors: Vec<Author>,
    #[serde(default)]
    pub tags: Vec<String>,
}

/// ReadProgressDto — inline on BookDto; mirrored into `read_progress`
/// during sync (remote truth, `mutation_pending` stays 0).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadProgress {
    #[serde(default)]
    pub page: Option<i64>,
    #[serde(default)]
    pub completed: bool,
    #[serde(default)]
    pub last_modified: Option<String>,
}
