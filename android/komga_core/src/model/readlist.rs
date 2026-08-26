//! ReadList DTOs — subset of the Komga ReadListDto (contract:
//! specs/openapi, shared fixture:
//! specs/contracts/fixtures/library/readlists-page.json).
//! Membership is embedded (`bookIds`, ordered), so a single list call
//! mirrors both the readlist rows and the `readlist_books` join table.

use serde::{Deserialize, Serialize};

/// Page response of the Komga readlists endpoint (Spring Data Page shape).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadListPage {
    pub content: Vec<ReadList>,
    pub total_elements: i64,
    pub total_pages: i64,
    pub number: i64,
    pub size: i64,
    pub first: bool,
    pub last: bool,
}

/// ReadListDto.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadList {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub ordered: bool,
    #[serde(default)]
    pub filtered: bool,
    #[serde(default)]
    pub book_ids: Vec<String>,
    #[serde(default)]
    pub created_date: Option<String>,
    #[serde(default)]
    pub last_modified_date: Option<String>,
}
