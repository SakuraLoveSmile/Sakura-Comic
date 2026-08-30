//! Page manifest: normalize what Komga reports into the canonical page list the
//! reader lays out, caches and restores against.
//!
//! Contract: `specs/contracts/fixtures/reader/manifest.json`, loaded identically
//! by the Swift mirror (`KomgaReader.Manifest`).
//!
//! This module deliberately knows nothing about HTTP: the wire `PageDto` is
//! converted into [`RawPage`] at the API boundary, so the normalization rules
//! below are testable without a transport.

use crate::cache::safe_key;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// One entry of `GET /api/v1/books/{id}/pages` before normalization.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RawPage {
    pub file_name: String,
    pub media_type: String,
    pub number: i64,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub size_bytes: Option<i64>,
}

/// A page after normalization. `number` is canonical (1-based, positional).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PageDescriptor {
    pub number: u32,
    pub file_name: String,
    pub media_type: String,
    pub width: u32,
    pub height: u32,
    pub size_bytes: i64,
}

impl PageDescriptor {
    /// Unknown aspect ratio: the page cannot be proven to be a spread half.
    pub fn dimensions_unknown(&self) -> bool {
        self.width == 0 || self.height == 0
    }

    pub fn is_image(&self) -> bool {
        self.media_type.starts_with("image/")
    }

    /// Persistence boundary: `store` owns the row shape, the reader owns this
    /// one, and only these two functions translate between them.
    pub fn to_row(&self) -> crate::store::pages::PageRow {
        crate::store::pages::PageRow {
            number: self.number as i64,
            file_name: self.file_name.clone(),
            media_type: self.media_type.clone(),
            width: self.width as i64,
            height: self.height as i64,
            size_bytes: self.size_bytes,
        }
    }

    pub fn from_row(row: &crate::store::pages::PageRow) -> Self {
        PageDescriptor {
            number: row.number.max(0) as u32,
            file_name: row.file_name.clone(),
            media_type: row.media_type.clone(),
            width: row.width.max(0) as u32,
            height: row.height.max(0) as u32,
            size_bytes: row.size_bytes,
        }
    }
}

/// Formats that are paged by a viewer other than the image reader.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Fallback {
    Epub,
    Pdf,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PageManifest {
    pub server_id: String,
    pub book_id: String,
    pub pages: Vec<PageDescriptor>,
    /// Entries whose reported `number` disagrees with their position.
    pub drift: u32,
    pub looks_zero_based: bool,
    pub reflowable: bool,
    pub fallback: Option<Fallback>,
}

impl PageManifest {
    /// Position is the only ordering authority: `number` never reorders,
    /// dedupes or drops a page (see the `drift` / `duplicates` rules).
    pub fn from_raw(
        server_id: &str,
        book_id: &str,
        book_media_type: Option<&str>,
        raw: &[RawPage],
    ) -> Self {
        let mut pages = Vec::with_capacity(raw.len());
        let mut drift = 0u32;
        for (index, page) in raw.iter().enumerate() {
            let canonical = index as i64 + 1;
            if page.number != canonical {
                drift += 1;
            }
            pages.push(PageDescriptor {
                number: canonical as u32,
                file_name: page.file_name.clone(),
                media_type: page.media_type.clone(),
                width: page.width.unwrap_or(0).max(0) as u32,
                height: page.height.unwrap_or(0).max(0) as u32,
                // `size` is a display string and is intentionally not parsed;
                // the on-disk size is what the cache accounts with.
                size_bytes: page.size_bytes.unwrap_or(0).max(0),
            });
        }

        let book_type = book_media_type.unwrap_or("");
        let reflowable = book_type.contains("epub")
            || book_type.contains("xhtml")
            || pages
                .iter()
                .any(|page| page.media_type.contains("epub") || page.media_type.contains("xhtml"));
        let all_pdf = !pages.is_empty()
            && pages
                .iter()
                .all(|page| page.media_type == "application/pdf");
        let pdf = !reflowable && (book_type.contains("pdf") || all_pdf);

        PageManifest {
            server_id: server_id.to_string(),
            book_id: book_id.to_string(),
            looks_zero_based: raw.first().is_some_and(|page| page.number == 0),
            drift,
            reflowable,
            fallback: if reflowable {
                Some(Fallback::Epub)
            } else if pdf {
                Some(Fallback::Pdf)
            } else {
                None
            },
            pages,
        }
    }

    /// Rebuild from the SQLite mirror.
    ///
    /// Delegates to `from_raw` on purpose: the mirrored path and the network
    /// path must not grow two normalization rules, or an offline open could
    /// disagree with what was cached.
    pub fn from_rows(
        server_id: &str,
        book_id: &str,
        book_media_type: Option<&str>,
        rows: &[crate::store::pages::PageRow],
    ) -> Self {
        let raw: Vec<RawPage> = rows
            .iter()
            .map(|row| RawPage {
                file_name: row.file_name.clone(),
                media_type: row.media_type.clone(),
                number: row.number,
                width: Some(row.width),
                height: Some(row.height),
                size_bytes: Some(row.size_bytes),
            })
            .collect();
        Self::from_raw(server_id, book_id, book_media_type, &raw)
    }

    pub fn page_count(&self) -> u32 {
        self.pages.len() as u32
    }

    /// The image reader may only drive an all-image, non-empty manifest.
    pub fn is_paged(&self) -> bool {
        !self.pages.is_empty()
            && self.fallback.is_none()
            && self.pages.iter().all(PageDescriptor::is_image)
    }

    /// Stage 6 rule R8: only an image-paged book may report 1-based page
    /// numbers through `read-progress`. EPUB goes to the progression API and
    /// PDF goes to a file viewer, so neither may enqueue a page write.
    pub fn writes_page_progress(&self) -> bool {
        self.is_paged()
    }

    /// Empty manifests are a hard error state, never a silent page 1.
    pub fn empty_error(&self) -> bool {
        self.pages.is_empty()
    }

    /// Reflowable books report position through the progression API.
    pub fn progression_api(&self) -> bool {
        self.reflowable
    }

    /// Canonical numbers, which are also the numbers sent to the 1-based
    /// `?zero_based=false` image endpoint.
    pub fn canonical(&self) -> Vec<u32> {
        self.pages.iter().map(|page| page.number).collect()
    }

    pub fn unknown_dimensions(&self) -> Vec<u32> {
        self.pages
            .iter()
            .filter(|page| page.dimensions_unknown())
            .map(|page| page.number)
            .collect()
    }

    pub fn unpairable(&self) -> HashSet<u32> {
        self.unknown_dimensions().into_iter().collect()
    }

    pub fn get(&self, number: u32) -> Option<&PageDescriptor> {
        self.pages.get(number.checked_sub(1)? as usize)
    }

    pub fn cache_keys(&self) -> Vec<String> {
        self.pages
            .iter()
            .map(|page| self.cache_key(page.number))
            .collect()
    }

    pub fn cache_key(&self, number: u32) -> String {
        page_cache_key(&self.server_id, &self.book_id, number)
    }
}

/// Multi-server safe page key, sharing the cover key's sanitizer so one cache
/// directory and one LRU pool can account for both.
pub fn page_cache_key(server_id: &str, book_id: &str, number: u32) -> String {
    safe_key(&format!("{server_id}-{book_id}-p{number}"))
}

/// The stored extension follows the RESPONSE content type, because the server
/// may transcode (`?convert=jpeg`) or content-negotiate.
pub fn extension_for_content_type(content_type: &str) -> &'static str {
    let head = content_type.split(';').next().unwrap_or("").trim();
    match head {
        "image/jpeg" | "image/jpg" => ".jpg",
        "image/png" => ".png",
        "image/webp" => ".webp",
        "image/gif" => ".gif",
        "image/avif" => ".avif",
        _ => ".img",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(number: i64, name: &str) -> RawPage {
        RawPage {
            file_name: name.to_string(),
            media_type: "image/jpeg".to_string(),
            number,
            width: Some(1000),
            height: Some(1500),
            size_bytes: Some(1024),
        }
    }

    #[test]
    fn ordering_survives_junk_numbering() {
        let raw = vec![image(7, "a"), image(7, "b"), image(99, "c")];
        let manifest = PageManifest::from_raw("srv", "book", None, &raw);
        assert_eq!(manifest.canonical(), vec![1, 2, 3]);
        assert_eq!(manifest.drift, 3);
        assert!(manifest.is_paged());
    }

    #[test]
    fn cache_keys_are_multi_server_safe_and_sanitized() {
        assert_eq!(page_cache_key("srv 1", "book/2", 3), "srv_1-book_2-p3");
        let manifest = PageManifest::from_raw("srv", "book", None, &[image(1, "a")]);
        assert_eq!(manifest.cache_keys(), vec!["srv-book-p1".to_string()]);
    }

    #[test]
    fn content_type_falls_back_to_opaque_extension() {
        assert_eq!(extension_for_content_type("image/png"), ".png");
        assert_eq!(extension_for_content_type("image/jpeg;q=0.8"), ".jpg");
        assert_eq!(
            extension_for_content_type("application/octet-stream"),
            ".img"
        );
        assert_eq!(extension_for_content_type(""), ".img");
    }
}

#[cfg(test)]
mod contract_tests {
    use super::*;
    use serde::de::DeserializeOwned;
    use std::collections::BTreeMap;

    fn fixture<T: DeserializeOwned>(name: &str) -> T {
        let path = format!(
            "{}/../../specs/contracts/fixtures/reader/{name}",
            env!("CARGO_MANIFEST_DIR")
        );
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("cannot read {path}: {error}"));
        serde_json::from_str(&text).unwrap_or_else(|error| panic!("cannot decode {path}: {error}"))
    }

    #[derive(Deserialize)]
    struct Fixture {
        cases: Vec<Case>,
        #[serde(rename = "contentTypes")]
        content_types: BTreeMap<String, String>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Raw {
        #[serde(default)]
        file_name: String,
        #[serde(default)]
        media_type: String,
        #[serde(default)]
        number: i64,
        #[serde(default)]
        width: Option<i64>,
        #[serde(default)]
        height: Option<i64>,
        #[serde(default)]
        size_bytes: Option<i64>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Input {
        server_id: String,
        book_id: String,
        #[serde(default)]
        media_type: Option<String>,
        pages: Vec<Raw>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Expect {
        page_count: u32,
        #[serde(default)]
        canonical: Vec<u32>,
        #[serde(default)]
        requested_numbers: Vec<u32>,
        drift: u32,
        looks_zero_based: bool,
        paged: bool,
        #[serde(default)]
        reflowable: bool,
        #[serde(default)]
        progression_api: bool,
        #[serde(default)]
        fallback: Option<String>,
        #[serde(default)]
        empty_error: bool,
        #[serde(default)]
        widths: Vec<u32>,
        #[serde(default)]
        heights: Vec<u32>,
        #[serde(default)]
        size_bytes: Vec<i64>,
        #[serde(default)]
        unknown_dimensions: Vec<u32>,
        #[serde(default)]
        unpairable: Vec<u32>,
        #[serde(default)]
        cache_keys: Vec<String>,
        #[serde(default)]
        manifest_media_types: Vec<String>,
    }

    #[derive(Deserialize)]
    struct Case {
        name: String,
        input: Input,
        expect: Expect,
    }

    #[test]
    fn manifest_matches_the_shared_contract() {
        let fixture: Fixture = fixture("manifest.json");
        assert!(fixture.cases.len() >= 8);
        for case in &fixture.cases {
            let raw: Vec<RawPage> = case
                .input
                .pages
                .iter()
                .map(|page| RawPage {
                    file_name: page.file_name.clone(),
                    media_type: page.media_type.clone(),
                    number: page.number,
                    width: page.width,
                    height: page.height,
                    size_bytes: page.size_bytes,
                })
                .collect();
            let manifest = PageManifest::from_raw(
                &case.input.server_id,
                &case.input.book_id,
                case.input.media_type.as_deref(),
                &raw,
            );
            let name = &case.name;
            let expect = &case.expect;
            assert_eq!(
                manifest.page_count(),
                expect.page_count,
                "{name}: pageCount"
            );
            assert_eq!(manifest.drift, expect.drift, "{name}: drift");
            assert_eq!(
                manifest.looks_zero_based, expect.looks_zero_based,
                "{name}: looksZeroBased"
            );
            assert_eq!(manifest.is_paged(), expect.paged, "{name}: paged");
            assert_eq!(manifest.reflowable, expect.reflowable, "{name}: reflowable");
            assert_eq!(
                manifest.progression_api(),
                expect.progression_api,
                "{name}: progressionApi"
            );
            assert_eq!(
                manifest.empty_error(),
                expect.empty_error,
                "{name}: emptyError"
            );
            let fallback = expect.fallback.as_ref().map(|value| match value.as_str() {
                "epub" => Fallback::Epub,
                "pdf" => Fallback::Pdf,
                other => panic!("{name}: unknown fallback {other}"),
            });
            assert_eq!(manifest.fallback, fallback, "{name}: fallback");
            if !expect.canonical.is_empty() {
                assert_eq!(manifest.canonical(), expect.canonical, "{name}: canonical");
            }
            let requested: Vec<u32> = manifest.canonical();
            if !expect.requested_numbers.is_empty() {
                assert_eq!(
                    requested, expect.requested_numbers,
                    "{name}: requestedNumbers"
                );
            }
            if !expect.widths.is_empty() {
                let widths: Vec<u32> = manifest.pages.iter().map(|p| p.width).collect();
                assert_eq!(widths, expect.widths, "{name}: widths");
            }
            if !expect.heights.is_empty() {
                let heights: Vec<u32> = manifest.pages.iter().map(|p| p.height).collect();
                assert_eq!(heights, expect.heights, "{name}: heights");
            }
            if !expect.size_bytes.is_empty() {
                let sizes: Vec<i64> = manifest.pages.iter().map(|p| p.size_bytes).collect();
                assert_eq!(sizes, expect.size_bytes, "{name}: sizeBytes");
            }
            if !expect.unknown_dimensions.is_empty() {
                assert_eq!(
                    manifest.unknown_dimensions(),
                    expect.unknown_dimensions,
                    "{name}: unknownDimensions"
                );
            }
            if !expect.unpairable.is_empty() {
                let got: Vec<u32> = {
                    let set = manifest.unpairable();
                    let mut got: Vec<u32> = set.into_iter().collect();
                    got.sort_unstable();
                    got
                };
                assert_eq!(got, expect.unpairable, "{name}: unpairable");
            }
            if !expect.cache_keys.is_empty() {
                assert_eq!(
                    manifest.cache_keys(),
                    expect.cache_keys,
                    "{name}: cacheKeys"
                );
            }
            if !expect.manifest_media_types.is_empty() {
                let got: Vec<String> = manifest
                    .pages
                    .iter()
                    .map(|page| page.media_type.clone())
                    .collect();
                assert_eq!(
                    got, expect.manifest_media_types,
                    "{name}: manifestMediaTypes"
                );
            }
        }

        // The content-type table is data in the fixture; the implementation must
        // agree with every row of it.
        for (content_type, extension) in &fixture.content_types {
            if content_type == "other" {
                assert_eq!(extension_for_content_type("text/plain"), extension, "other");
                continue;
            }
            assert_eq!(
                extension_for_content_type(content_type),
                extension.as_str(),
                "{content_type}"
            );
        }
    }

    /// Anti-vacuity: two cases whose inputs are identical would let a wrong
    /// normalization pass unnoticed.
    #[test]
    fn manifest_cases_are_distinct() {
        let fixture: Fixture = fixture("manifest.json");
        let mut seen = std::collections::BTreeSet::new();
        for case in &fixture.cases {
            let key = format!(
                "{:?}|{:?}|{:?}",
                case.input.media_type,
                case.input
                    .pages
                    .iter()
                    .map(|page| (
                        page.number,
                        page.media_type.clone(),
                        page.width,
                        page.height,
                        page.size_bytes
                    ))
                    .collect::<Vec<_>>(),
                case.input.pages.len()
            );
            assert!(seen.insert(key), "duplicate manifest case: {}", case.name);
        }
    }
}
