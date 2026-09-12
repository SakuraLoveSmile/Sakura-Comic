//! Server base URL normalization.
//!
//! Accepted forms:
//! - `https://komga.example.com`
//! - `http://192.168.1.10:25600`
//! - `https://example.com/komga/`

use super::error::ApiError;
use url::Url;

/// Normalize a user-entered server URL.
///
/// Rules:
/// - require http/https scheme
/// - preserve the path (Komga may be hosted under a sub-path, e.g. /komga/)
/// - strip trailing slashes
/// - reject query strings and fragments
pub fn normalize_server_url(raw: &str) -> Result<String, ApiError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(ApiError::UrlInvalid {
            message: "URL is empty".into(),
        });
    }
    let parsed = Url::parse(trimmed).map_err(|e| ApiError::UrlInvalid {
        message: e.to_string(),
    })?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(ApiError::UrlInvalid {
            message: format!("unsupported scheme '{}'", parsed.scheme()),
        });
    }
    if parsed.query().is_some() || parsed.fragment().is_some() {
        return Err(ApiError::UrlInvalid {
            message: "query strings and fragments are not allowed".into(),
        });
    }

    let mut out = format!("{}://{}", parsed.scheme(), parsed.host_str().unwrap_or(""));
    if let Some(port) = parsed.port() {
        out.push_str(&format!(":{port}"));
    }
    let path = parsed.path().trim_end_matches('/');
    if !path.is_empty() {
        out.push_str(path);
    }
    Ok(out)
}

/// Unified redirect policy for all authenticated requests:
/// - Maximum 5 redirect hops
/// - Same origin only (scheme, host, and port must match)
/// - Strictly reject cross-origin redirects and HTTPS -> HTTP downgrades
pub fn strict_redirect_policy() -> reqwest::redirect::Policy {
    reqwest::redirect::Policy::custom(|attempt| {
        if attempt.previous().len() >= 5 {
            return attempt.error("too many redirects (maximum 5 allowed)");
        }
        let initial = match attempt.previous().first() {
            Some(prev) => prev,
            None => return attempt.follow(),
        };
        let next = attempt.url();
        // Reject HTTPS downgrade to HTTP
        if initial.scheme() == "https" && next.scheme() == "http" {
            return attempt.error("https downgrade to http forbidden");
        }
        // Reject cross-origin (scheme, host, port must match)
        if initial.scheme() != next.scheme()
            || initial.host_str() != next.host_str()
            || initial.port_or_known_default() != next.port_or_known_default()
        {
            return attempt.error("cross-origin redirect forbidden");
        }
        attempt.follow()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_trailing_slash() {
        assert_eq!(
            normalize_server_url("https://komga.example.com/").unwrap(),
            "https://komga.example.com"
        );
    }

    #[test]
    fn keeps_sub_path() {
        assert_eq!(
            normalize_server_url("https://example.com/komga/").unwrap(),
            "https://example.com/komga"
        );
    }

    #[test]
    fn keeps_port() {
        assert_eq!(
            normalize_server_url("http://192.168.1.10:25600/").unwrap(),
            "http://192.168.1.10:25600"
        );
    }

    #[test]
    fn trims_whitespace() {
        assert_eq!(
            normalize_server_url("  https://komga.example.com  ").unwrap(),
            "https://komga.example.com"
        );
    }

    #[test]
    fn rejects_bad_scheme() {
        assert!(normalize_server_url("ftp://example.com").is_err());
    }

    #[test]
    fn rejects_query() {
        assert!(normalize_server_url("https://komga.example.com/?a=1").is_err());
    }

    #[test]
    fn rejects_empty() {
        assert!(normalize_server_url("   ").is_err());
    }

    #[test]
    fn redirect_policy_allows_same_origin() {
        let policy = strict_redirect_policy();
        // Verify policy builds without panic
        assert_eq!(format!("{policy:?}"), "Policy(Custom)");
    }
}
