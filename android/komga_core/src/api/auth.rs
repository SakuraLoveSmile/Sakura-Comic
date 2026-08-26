//! Authentication helpers.
//!
//! Primary: API Key (`X-API-Key`). Compatibility: Basic auth.
//! Secrets live in platform credential storage; the API layer only receives
//! them at request time and never logs them.

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use reqwest::header::{HeaderMap, HeaderName, HeaderValue, AUTHORIZATION};

/// How a request authenticates to Komga.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthMethod {
    ApiKey { key: String },
    Basic { username: String, password: String },
}

impl AuthMethod {
    /// Apply authentication headers to an outgoing request.
    pub fn apply_headers(&self, headers: &mut HeaderMap) {
        match self {
            AuthMethod::ApiKey { key } => {
                if let Ok(value) = HeaderValue::from_str(key) {
                    let name = HeaderName::from_static("x-api-key");
                    headers.insert(name, value);
                }
            }
            AuthMethod::Basic { username, password } => {
                let encoded = STANDARD.encode(format!("{username}:{password}"));
                if let Ok(value) = HeaderValue::from_str(&format!("Basic {encoded}")) {
                    headers.insert(AUTHORIZATION, value);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_key_header() {
        let mut headers = HeaderMap::new();
        AuthMethod::ApiKey {
            key: "secret".into(),
        }
        .apply_headers(&mut headers);
        assert_eq!(headers.get("x-api-key").unwrap(), "secret");
    }

    #[test]
    fn basic_auth_header() {
        let mut headers = HeaderMap::new();
        AuthMethod::Basic {
            username: "alice".into(),
            password: "s3cret".into(),
        }
        .apply_headers(&mut headers);
        assert_eq!(
            headers.get(AUTHORIZATION).unwrap(),
            "Basic YWxpY2U6czNjcmV0"
        );
    }
}
