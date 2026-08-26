//! Series DTO — subset of the Komga SeriesDto (contract: specs/openapi,
//! shared fixture: specs/contracts/fixtures/initial-sync/series-page.json).

use serde::{Deserialize, Serialize};

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

/// Minimal SeriesDto (unknown fields are ignored by serde).
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
    pub metadata: Option<SeriesMetadata>,
}

/// Minimal SeriesMetadataDto.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeriesMetadata {
    pub title: String,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub publishers: Vec<String>,
}
