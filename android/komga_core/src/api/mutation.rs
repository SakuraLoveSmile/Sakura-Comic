//! Komga write endpoints (Stage 6): the Outbox uploader's transport.
//!
//! Both routes come from the OpenAPI document exported by the target server
//! (`specs/openapi/komga-openapi.yaml`, 1.26.3) — see
//! `specs/contracts/offline-mutation/README.md`:
//!
//! - `PATCH  /api/v1/books/{bookId}/read-progress` — body `ReadProgressUpdateDto
//!   {page:int32?, completed:bool?}`, neither field required, success `204` no body
//! - `DELETE /api/v1/books/{bookId}/read-progress` — mark unread, success `204`
//!
//! Because 204 carries no body, a successful write leaves the server's progress
//! stamp unknown; the caller must clear it rather than guess (rule R4 depends on it).

use reqwest::header::{HeaderMap, HeaderValue, CONTENT_TYPE};

use super::error::ApiError;
use super::series::KomgaClient;
use crate::model::book::Book;
use crate::store::outbox::{Attempt, Method, Refetch, RemoteProgress, WireRequest};

/// `GET /api/v1/books/{id}` — the Targeted Re-fetch that must precede an upload.
pub fn book_url(base_url: &str, book_id: &str) -> String {
    format!(
        "{}/api/v1/books/{}",
        base_url.trim_end_matches('/'),
        book_id
    )
}

pub fn read_progress_url(base_url: &str, book_id: &str) -> String {
    format!("{}/read-progress", book_url(base_url, book_id))
}

/// The progress row's own server state. `readProgress.lastModified` is what
/// advances when another device reads — `book.lastModified` does not, which is
/// exactly why using it here would make conflict rule R4 blind.
pub fn remote_of(book: &Book) -> RemoteProgress {
    // The format rides along: which write endpoint is legal depends on it
    // (contract R8), and this is the only place the DTO is read.
    let media_type = book
        .media
        .as_ref()
        .and_then(|media| media.media_type.clone());
    match &book.read_progress {
        Some(progress) => RemoteProgress {
            page: progress.page,
            completed: progress.completed,
            last_modified: progress.last_modified.clone(),
            media_type,
        },
        None => RemoteProgress {
            page: None,
            completed: false,
            // No progress row at all: the server has never been told anything,
            // so there is no stamp to lose against.
            last_modified: None,
            media_type,
        },
    }
}

/// Everything the Outbox uploader needs from the server. A trait so the
/// conflict rules run against a scripted fake (same pattern as `LibraryFetcher`).
#[allow(async_fn_in_trait)]
pub trait ProgressWriter {
    /// Rule R6: never write blind — if this fails, the row is deferred.
    async fn refetch(&self, book_id: &str) -> Refetch;
    async fn apply(&self, request: &WireRequest) -> Attempt;
    /// The full DTO, for an SSE-triggered targeted re-fetch. `Ok(None)` means
    /// the server says this book no longer exists.
    async fn book(&self, book_id: &str) -> super::error::Result<Option<Book>>;
}

impl ProgressWriter for KomgaClient {
    async fn refetch(&self, book_id: &str) -> Refetch {
        let url = book_url(&self.base_url, book_id);
        match self.get_json::<Book>(&url).await {
            Ok(book) => Refetch::Found(remote_of(&book)),
            Err(ApiError::Authentication) => Refetch::Unauthorized,
            Err(ApiError::Server { status_code }) => match Attempt::from_status(status_code) {
                Attempt::Gone => Refetch::NotFound,
                Attempt::BlockedAuthentication => Refetch::Unauthorized,
                _ => Refetch::Unreachable,
            },
            Err(_) => Refetch::Unreachable,
        }
    }

    async fn book(&self, book_id: &str) -> super::error::Result<Option<Book>> {
        match self
            .get_json::<Book>(&book_url(&self.base_url, book_id))
            .await
        {
            Ok(book) => Ok(Some(book)),
            Err(ApiError::Server { status_code })
                if matches!(Attempt::from_status(status_code), Attempt::Gone) =>
            {
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }

    async fn apply(&self, request: &WireRequest) -> Attempt {
        let url = format!("{}{}", self.base_url, request.path);
        let mut headers = HeaderMap::new();
        self.auth.apply_headers(&mut headers);
        let sent = match request.method {
            Method::Patch => {
                headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
                let body = request.body.clone().unwrap_or_default();
                self.http.patch(url).headers(headers).body(body).send()
            }
            Method::Delete => self.http.delete(url).headers(headers).send(),
        }
        .await;
        match sent {
            // 204 is the documented success; 200 is accepted as the same thing.
            Ok(response) => match response.status().as_u16() {
                200 | 204 => Attempt::Succeeded,
                status => Attempt::from_status(status),
            },
            Err(_) => Attempt::Retryable,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::outbox::{request_for, Intent};

    #[test]
    fn urls_match_the_exported_spec() {
        assert_eq!(
            book_url("https://komga.example.com/", "b1"),
            "https://komga.example.com/api/v1/books/b1"
        );
        assert_eq!(
            read_progress_url("http://h:25600", "b1"),
            "http://h:25600/api/v1/books/b1/read-progress"
        );
    }

    #[test]
    fn intents_turn_into_the_documented_bodies() {
        let progress = request_for(
            "b1",
            &Intent::Progress {
                page: Some(12),
                completed: false,
            },
        );
        assert_eq!(progress.method, Method::Patch);
        assert_eq!(progress.path, "/api/v1/books/b1/read-progress");
        assert_eq!(
            progress.body.as_deref(),
            Some(r#"{"page":12,"completed":false}"#)
        );

        let mark_read = request_for("b1", &Intent::MarkRead);
        assert_eq!(mark_read.method, Method::Patch);
        assert_eq!(mark_read.body.as_deref(), Some(r#"{"completed":true}"#));

        let mark_unread = request_for("b1", &Intent::MarkUnread);
        assert_eq!(mark_unread.method, Method::Delete);
        assert_eq!(mark_unread.body, None);
    }

    #[test]
    fn page_is_omitted_when_the_local_row_has_none() {
        let request = request_for(
            "b1",
            &Intent::Progress {
                page: None,
                completed: true,
            },
        );
        assert_eq!(request.body.as_deref(), Some(r#"{"completed":true}"#));
    }

    #[test]
    fn status_classes_follow_the_contract() {
        for (status, expected) in [
            (401u16, Attempt::BlockedAuthentication),
            (403, Attempt::BlockedAuthentication),
            (404, Attempt::Gone),
            (410, Attempt::Gone),
            (400, Attempt::Rejected),
            (408, Attempt::Retryable),
            (429, Attempt::Retryable),
            (500, Attempt::Retryable),
            (503, Attempt::Retryable),
        ] {
            assert_eq!(
                Attempt::from_status(status),
                expected,
                "status {status} must classify as {expected:?}"
            );
        }
    }

    #[test]
    fn transport_and_decode_errors_stay_retryable_but_auth_blocks_the_run() {
        assert_eq!(Attempt::classify(&ApiError::Network), Attempt::Retryable);
        assert_eq!(
            Attempt::classify(&ApiError::Decode {
                message: "x".into()
            }),
            Attempt::Retryable
        );
        assert_eq!(
            Attempt::classify(&ApiError::Authentication),
            Attempt::BlockedAuthentication
        );
        assert_eq!(
            Attempt::classify(&ApiError::Server { status_code: 404 }),
            Attempt::Gone
        );
    }
}
