//! Unified API error model.
//!
//! UI never touches reqwest / SQLite / URLSession errors; the core maps them
//! into these user-comprehensible states (see docs/architecture.md).

use std::fmt;

/// API-layer error taxonomy.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum ApiError {
    Authentication,
    Network,
    Server {
        status_code: u16,
    },
    ApiCompatibility {
        message: String,
    },
    UrlInvalid {
        message: String,
    },
    Database {
        message: String,
    },
    Storage {
        message: String,
    },
    Decode {
        message: String,
    },
    InvalidInput {
        message: String,
    },
    /// A bounded event-stream read saw no frame: normal for a live connection,
    /// and never a reason to reschedule a reconnect.
    Idle,
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApiError::Authentication => write!(f, "authentication failed"),
            ApiError::Network => write!(f, "network error"),
            ApiError::Server { status_code } => write!(f, "server error (HTTP {status_code})"),
            ApiError::ApiCompatibility { message } => {
                write!(f, "api compatibility error: {message}")
            }
            ApiError::UrlInvalid { message } => write!(f, "invalid url: {message}"),
            ApiError::Database { message } => write!(f, "database error: {message}"),
            ApiError::Storage { message } => write!(f, "storage error: {message}"),
            ApiError::Decode { message } => write!(f, "decode error: {message}"),
            ApiError::InvalidInput { message } => write!(f, "invalid input: {message}"),
            ApiError::Idle => write!(f, "event stream idle"),
        }
    }
}

impl std::error::Error for ApiError {}

/// Convenience alias used across the API layer.
pub type Result<T> = std::result::Result<T, ApiError>;
