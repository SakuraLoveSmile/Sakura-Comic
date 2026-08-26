//! AuthorDto — shared by series and book metadata.
//! Komga: `{ "name": "...", "role": "STORY_ART" }` (role optional).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Author {
    pub name: String,
    #[serde(default)]
    pub role: Option<String>,
}
