//! Collection DTOs — subset of the Komga CollectionDto (contract:
//! specs/openapi, shared fixture:
//! specs/contracts/fixtures/library/collections-page.json).
//! Membership is embedded (`seriesIds`), so a single list call mirrors
//! both the collection rows and the `collection_series` join table.

use serde::{Deserialize, Serialize};

/// Page response of the Komga collections endpoint (Spring Data Page shape).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectionPage {
    pub content: Vec<Collection>,
    pub total_elements: i64,
    pub total_pages: i64,
    pub number: i64,
    pub size: i64,
    pub first: bool,
    pub last: bool,
}

/// CollectionDto.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Collection {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub ordered: bool,
    #[serde(default)]
    pub filtered: bool,
    #[serde(default)]
    pub series_ids: Vec<String>,
    #[serde(default)]
    pub created_date: Option<String>,
    #[serde(default)]
    pub last_modified_date: Option<String>,
}
