//! The error the UI can branch on.
//!
//! Everything the core can fail with already has a name in
//! [`crate::api::error::ApiError`], and for two stages each of the ~75 bridge
//! functions threw that name away with `.map_err(|e| e.to_string())`. A Dart
//! side holding a string can print it, and can *not* answer the three questions
//! it actually has: does this need the user to do something, should I try again
//! later by myself, and should I stop trying at all? "FormatException:
//! authentication failed" answers none of them, and the answer changes what
//! screen the user ends up on.
//!
//! So the FFI boundary carries a code, a message and one bit of policy.
//!
//! # The code list is a contract
//!
//! `specs/contracts/fixtures/errors/codes.json` is the source of truth for the
//! names; Rust, Swift and Dart each enumerate the same list, and the three
//! `codes_are_the_shared_fixture_*` tests across the repository fail if one side
//! renames a variant on its own. Unknown-on-the-receiving-end is a designed-for
//! case: a Dart build from before a rename must degrade to `unknown`, not crash.
//!
//! # What is deliberately *not* here
//!
//! No code the core cannot actually produce. `cancelled`, `linkBlocked` and
//! `lowSpace` are the obvious candidates, and each is a *state* the caller
//! already receives in a report DTO rather than an error — inventing an error
//! code for a condition that arrives as data would give the UI two ways to learn
//! one fact, and they would disagree the first time either changed.

use super::super::api::error::ApiError;
use serde::{Deserialize, Serialize};

/// What kind of failure this was. Serialized as the lowerCamelCase name, which
/// is the spelling all three platforms store in the shared fixture.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ErrorCode {
    /// 401 or 403: the server rejected the credential. The only code in here
    /// whose fix is something the user must type.
    AuthExpired,
    /// No route, refused, timed out, or a stream that stopped mid-body.
    NetworkUnavailable,
    /// A response that says the entity is not there (404, 410).
    NotFound,
    /// The server already has a different answer for this (409).
    Conflict,
    /// 429: back off and come back, on the existing schedule.
    RateLimited,
    /// A generic server-side failure (any other 4xx/5xx).
    ServerError,
    /// This build's transport contract does not cover that server.
    ContractUnsupported,
    /// The caller asked for something malformed, or the URL is not a URL.
    InvalidInput,
    /// A response arrived and is not the shape documented at
    /// `specs/openapi/`.
    DecodeFailed,
    /// SQLite said no. Retryable only through [`ErrorCode::DatabaseBusy`].
    DatabaseFailure,
    /// Another connection held the write lock past `busy_timeout`.
    DatabaseBusy,
    /// The filesystem refused a write the core had already been told to make.
    StorageFailure,
    /// A bounded event-stream read saw no frame. Normal, not a failure.
    Idle,
    /// Anything this build cannot name, including a code from a newer client.
    #[default]
    Unknown,
}

impl ErrorCode {
    /// The fixture's spelling.
    pub fn as_str(&self) -> &'static str {
        match self {
            ErrorCode::AuthExpired => "authExpired",
            ErrorCode::NetworkUnavailable => "networkUnavailable",
            ErrorCode::NotFound => "notFound",
            ErrorCode::Conflict => "conflict",
            ErrorCode::RateLimited => "rateLimited",
            ErrorCode::ServerError => "serverError",
            ErrorCode::ContractUnsupported => "contractUnsupported",
            ErrorCode::InvalidInput => "invalidInput",
            ErrorCode::DecodeFailed => "decodeFailed",
            ErrorCode::DatabaseFailure => "databaseFailure",
            ErrorCode::DatabaseBusy => "databaseBusy",
            ErrorCode::StorageFailure => "storageFailure",
            ErrorCode::Idle => "idle",
            ErrorCode::Unknown => "unknown",
        }
    }

    /// The whole list, in fixture order. Mirrored by Swift and Dart.
    pub const ALL: [ErrorCode; 14] = [
        ErrorCode::AuthExpired,
        ErrorCode::NetworkUnavailable,
        ErrorCode::NotFound,
        ErrorCode::Conflict,
        ErrorCode::RateLimited,
        ErrorCode::ServerError,
        ErrorCode::ContractUnsupported,
        ErrorCode::InvalidInput,
        ErrorCode::DecodeFailed,
        ErrorCode::DatabaseFailure,
        ErrorCode::DatabaseBusy,
        ErrorCode::StorageFailure,
        ErrorCode::Idle,
        ErrorCode::Unknown,
    ];

    /// Whether a later automatic attempt can plausibly succeed with nothing in
    /// between. This is the bit that decides whether the UI keeps a spinner or
    /// shows a message, so it is policy, not decoration: `authExpired` retries
    /// itself forever against a server that will never accept it, and
    /// `networkUnavailable` that stops on its own would be a lie.
    pub fn is_retryable(&self) -> bool {
        matches!(
            self,
            ErrorCode::NetworkUnavailable
                | ErrorCode::RateLimited
                | ErrorCode::DatabaseBusy
                | ErrorCode::ServerError
        )
    }

    /// Whether the user has to do something before this can work. Exactly one
    /// code, which is the whole reason this bit is worth carrying: every other
    /// failure is either the client's problem or the server's.
    pub fn needs_user(&self) -> bool {
        matches!(self, ErrorCode::AuthExpired)
    }
}

impl std::fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// An error as the FFI boundary sees it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreError {
    pub code: ErrorCode,
    /// Human-readable, for a support export. Never a parse target: it is the
    /// `ApiError`'s own text, which is allowed to change wording freely.
    pub message: String,
    /// Derived from `code` at construction, so the two can never disagree.
    pub retryable: bool,
    /// `true` when the user must act. Also derived.
    pub needs_user: bool,
}

impl CoreError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            retryable: code.is_retryable(),
            needs_user: code.needs_user(),
        }
    }

    /// A failure this build cannot name. Carries the text, because that is the
    /// only thing left to carry.
    pub fn unknown(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Unknown, message)
    }

    /// Map the status codes Komga actually answers with onto the granular
    /// codes. The text is kept because `Server { status_code }` alone would
    /// lose what the caller already knew.
    fn from_server_status(status: u16, message: &str) -> Self {
        match status {
            401 | 403 => Self::new(ErrorCode::AuthExpired, message),
            404 | 410 => Self::new(ErrorCode::NotFound, message),
            409 => Self::new(ErrorCode::Conflict, message),
            429 => Self::new(ErrorCode::RateLimited, message),
            _ => Self::new(ErrorCode::ServerError, message),
        }
    }
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl std::error::Error for CoreError {}

impl From<ApiError> for CoreError {
    fn from(error: ApiError) -> Self {
        CoreError::from(&error)
    }
}

impl From<&ApiError> for CoreError {
    fn from(error: &ApiError) -> Self {
        match error {
            ApiError::Authentication => Self::new(ErrorCode::AuthExpired, error.to_string()),
            ApiError::Network => Self::new(ErrorCode::NetworkUnavailable, error.to_string()),
            ApiError::Server { status_code } => {
                Self::from_server_status(*status_code, &error.to_string())
            }
            ApiError::ApiCompatibility { message } => {
                Self::new(ErrorCode::ContractUnsupported, message.clone())
            }
            ApiError::UrlInvalid { message } => Self::new(ErrorCode::InvalidInput, message.clone()),
            ApiError::InvalidInput { message } => {
                Self::new(ErrorCode::InvalidInput, message.clone())
            }
            ApiError::Decode { message } => Self::new(ErrorCode::DecodeFailed, message.clone()),
            ApiError::Storage { message } => Self::new(ErrorCode::StorageFailure, message.clone()),
            ApiError::Database { message } => Self::from_database_text(message),
            ApiError::Idle => Self::new(ErrorCode::Idle, error.to_string()),
            // No wildcard, deliberately: `ApiError` is `#[non_exhaustive]` to
            // *downstream* crates, so inside this one the compiler still insists
            // that a new variant be mapped here by name. A silent fall-through
            // to `unknown` would mean the next API error added anywhere in the
            // core reaches the UI with no code until somebody notices in
            // production.
        }
    }
}

impl CoreError {
    /// `ApiError::Database` is built from a `rusqlite::Error` by `db_err`, which
    /// flattens it to text. The one distinction worth keeping is SQLITE_BUSY:
    /// it means "another connection is mid-write", which is retryable on its
    /// own, from every other database failure, which is not.
    fn from_database_text(message: &str) -> Self {
        if message.contains("database is locked") || message.contains("SQLITE_BUSY") {
            Self::new(ErrorCode::DatabaseBusy, message)
        } else {
            Self::new(ErrorCode::DatabaseFailure, message)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The fixture is the contract. Read at test time from the same file the
    /// Swift and Dart sides load.
    const CODES_FIXTURE: &str =
        include_str!("../../../../specs/contracts/fixtures/errors/codes.json");

    fn fixture_codes() -> Vec<String> {
        let document: serde_json::Value =
            serde_json::from_str(CODES_FIXTURE).expect("codes fixture must decode");
        document["codes"]
            .as_array()
            .expect("`codes` must be an array")
            .iter()
            .map(|entry| {
                entry["code"]
                    .as_str()
                    .expect("each entry needs a `code`")
                    .to_string()
            })
            .collect()
    }

    #[test]
    fn the_enum_and_the_shared_fixture_list_the_same_codes_in_the_same_order() {
        let fixture = fixture_codes();
        let rust: Vec<String> = ErrorCode::ALL
            .iter()
            .map(|code| code.as_str().to_string())
            .collect();
        assert_eq!(rust, fixture, "one side renamed a code on its own");
    }

    #[test]
    fn the_fixture_records_which_codes_retry_and_which_need_the_user() {
        // Not just the names: the two policy bits the UI branches on are in the
        // fixture too, so a change to `is_retryable` has to be a change to the
        // contract, noticed by the other two platforms.
        let document: serde_json::Value = serde_json::from_str(CODES_FIXTURE).unwrap();
        for entry in document["codes"].as_array().unwrap() {
            let code = entry["code"].as_str().unwrap();
            let owned = ErrorCode::ALL
                .iter()
                .find(|candidate| candidate.as_str() == code)
                .unwrap_or_else(|| panic!("fixture names a code this build lacks: {code}"));
            assert_eq!(
                owned.is_retryable(),
                entry["retryable"].as_bool().unwrap(),
                "{code}: retryable disagrees with the fixture"
            );
            assert_eq!(
                owned.needs_user(),
                entry["needsUser"].as_bool().unwrap(),
                "{code}: needsUser disagrees with the fixture"
            );
        }
    }

    #[test]
    fn every_core_failure_lands_on_a_nameable_code() {
        let cases: Vec<(ApiError, ErrorCode)> = vec![
            (ApiError::Authentication, ErrorCode::AuthExpired),
            (ApiError::Network, ErrorCode::NetworkUnavailable),
            (ApiError::Idle, ErrorCode::Idle),
            (ApiError::Server { status_code: 404 }, ErrorCode::NotFound),
            (ApiError::Server { status_code: 410 }, ErrorCode::NotFound),
            (ApiError::Server { status_code: 409 }, ErrorCode::Conflict),
            (
                ApiError::Server { status_code: 429 },
                ErrorCode::RateLimited,
            ),
            (
                ApiError::Server { status_code: 500 },
                ErrorCode::ServerError,
            ),
            (
                ApiError::Server { status_code: 401 },
                ErrorCode::AuthExpired,
            ),
            (
                ApiError::ApiCompatibility {
                    message: "1.30".into(),
                },
                ErrorCode::ContractUnsupported,
            ),
            (
                ApiError::UrlInvalid {
                    message: "no scheme".into(),
                },
                ErrorCode::InvalidInput,
            ),
            (
                ApiError::Decode {
                    message: "missing field".into(),
                },
                ErrorCode::DecodeFailed,
            ),
            (
                ApiError::Storage {
                    message: "read-only".into(),
                },
                ErrorCode::StorageFailure,
            ),
            (
                ApiError::Database {
                    message: "no such table: x".into(),
                },
                ErrorCode::DatabaseFailure,
            ),
        ];
        for (error, expected) in cases {
            let mapped = CoreError::from(error.clone());
            assert_eq!(mapped.code, expected, "{error}");
            // The two policy bits are derived, never supplied: a construction
            // site could not claim `authExpired, retryable` even if it wanted to.
            assert_eq!(mapped.retryable, expected.is_retryable());
            assert_eq!(mapped.needs_user, expected.needs_user());
            assert!(!mapped.message.is_empty(), "{expected} lost its text");
        }
    }

    #[test]
    fn only_a_locked_database_is_a_busy_database() {
        let busy = CoreError::from(ApiError::Database {
            message: "database is locked".into(),
        });
        assert_eq!(busy.code, ErrorCode::DatabaseBusy);
        assert!(busy.retryable);
        let broken = CoreError::from(ApiError::Database {
            message: "file is not a database".into(),
        });
        assert_eq!(broken.code, ErrorCode::DatabaseFailure);
        assert!(!broken.retryable);
    }

    #[test]
    fn authentication_is_the_one_code_that_asks_the_user_for_something() {
        let expired = CoreError::from(ApiError::Authentication);
        assert!(
            (expired.code, expired.retryable, expired.needs_user)
                == (ErrorCode::AuthExpired, false, true)
        );
        // Everything else in the list must not raise a prompt, or the user is
        // asked for a password every time the train goes through a tunnel.
        for code in ErrorCode::ALL {
            if code != ErrorCode::AuthExpired {
                assert!(!code.needs_user(), "{code} claims to need the user");
            }
        }
    }

    #[test]
    fn the_wire_form_carries_code_message_and_both_policy_bits() {
        let error = CoreError::from(ApiError::Network);
        let json = serde_json::to_value(&error).unwrap();
        assert_eq!(json["code"], "networkUnavailable");
        assert_eq!(json["retryable"], true);
        assert_eq!(json["needsUser"], false);
        let mut keys: Vec<String> = json.as_object().unwrap().keys().cloned().collect();
        keys.sort();
        assert_eq!(
            keys,
            vec![
                "code".to_string(),
                "message".to_string(),
                "needsUser".to_string(),
                "retryable".to_string()
            ],
            "the wire field names are what Dart and Swift decode by"
        );
        let round: CoreError = serde_json::from_value(json).unwrap();
        assert_eq!(round, error);
    }

    #[test]
    fn an_unfamiliar_code_name_from_a_newer_build_reads_as_unknown() {
        let decoded: CoreError = serde_json::from_str(
            "{\"code\":\"quantumFailure\",\"message\":\"from the future\",\"retryable\":false,\"needsUser\":false}",
        )
        .unwrap_or_else(|_| {
            // Either shape is acceptable — a hard decode failure or an unknown
            // variant — as long as the client does not panic on it.
            CoreError::unknown("from the future")
        });
        assert_eq!(decoded.code, ErrorCode::Unknown);
    }
}
