//! API contract version policy — mirrors specs/openapi/compatibility.md.
//!
//! The OpenAPI snapshot (specs/openapi/komga-openapi.yaml) is the single
//! source of truth for both clients. Bump `CONTRACT_VERSION` whenever the
//! snapshot or the policy changes; Swift `KomgaAPI.contractVersion` must
//! match it exactly.

use super::error::{ApiError, Result};

/// Client contract version — must equal Swift `KomgaAPI.contractVersion`.
pub const CONTRACT_VERSION: &str = "0.2.0";

/// Snapshot pin (info.version of the OpenAPI file).
pub const SNAPSHOT_VERSION: &str = "1.26.3";

/// Lowest server version this contract accepts.
pub const MIN_SERVER_VERSION: (u64, u64, u64) = (1, 26, 0);

/// Outcome of checking a server's `build.version` against the policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VersionCheck {
    /// Within the snapshot line (1.26.x).
    Accepted,
    /// Higher minor on the same major — accepted, capability recorded.
    NewerMinor { version: String },
    /// Version missing or unparseable — accepted, capability recorded.
    UnknownVersion,
}

/// Policy decision for a server version (see compatibility.md table).
pub fn check_server_version(version: Option<&str>) -> Result<VersionCheck> {
    let Some(version) = version else {
        return Ok(VersionCheck::UnknownVersion);
    };
    let Some((major, minor, _patch)) = parse_version(version) else {
        return Ok(VersionCheck::UnknownVersion);
    };
    let (min_major, min_minor, _min_patch) = MIN_SERVER_VERSION;

    // Komga's deprecation policy: endpoints marked deprecated are removed in
    // the next major, so a higher major is the hard compatibility boundary.
    if major > min_major {
        return Err(ApiError::ApiCompatibility {
            message: format!(
                "server version {version} has a newer major than the contract (snapshot {SNAPSHOT_VERSION})"
            ),
        });
    }
    if major < min_major || (major == min_major && minor < min_minor) {
        return Err(ApiError::ApiCompatibility {
            message: format!(
                "server version {version} is below the contract minimum (snapshot {SNAPSHOT_VERSION})"
            ),
        });
    }
    if major == min_major && minor > min_minor {
        return Ok(VersionCheck::NewerMinor {
            version: version.to_string(),
        });
    }
    Ok(VersionCheck::Accepted)
}

/// Parse `major.minor.patch`-style versions; tolerates a leading `v`,
/// extra numeric segments and suffixes ("1.26.3-SNAPSHOT").
fn parse_version(raw: &str) -> Option<(u64, u64, u64)> {
    let trimmed = raw.trim();
    let trimmed = trimmed.strip_prefix('v').unwrap_or(trimmed);
    let mut parts = trimmed
        .split(['.', '-'])
        .filter_map(|part| part.parse::<u64>().ok());
    Some((
        parts.next()?,
        parts.next().unwrap_or(0),
        parts.next().unwrap_or(0),
    ))
}

/// Capabilities contributed by the version check (see compatibility.md).
pub fn version_capabilities(check: &VersionCheck) -> Vec<String> {
    match check {
        VersionCheck::Accepted => Vec::new(),
        VersionCheck::NewerMinor { version } => {
            vec![format!("newer-than-snapshot:{version}")]
        }
        VersionCheck::UnknownVersion => vec!["unknown-version".into()],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_snapshot_line() {
        assert_eq!(
            check_server_version(Some("1.26.3")).unwrap(),
            VersionCheck::Accepted
        );
        assert_eq!(
            check_server_version(Some("1.26.0")).unwrap(),
            VersionCheck::Accepted
        );
        // Patch-level differences inside the snapshot line are compatible.
        assert_eq!(
            check_server_version(Some("1.26.99")).unwrap(),
            VersionCheck::Accepted
        );
    }

    #[test]
    fn accepts_newer_minor_same_major() {
        assert_eq!(
            check_server_version(Some("1.27.0")).unwrap(),
            VersionCheck::NewerMinor {
                version: "1.27.0".into()
            }
        );
    }

    #[test]
    fn rejects_below_minimum() {
        let err = check_server_version(Some("1.25.9")).unwrap_err();
        assert!(matches!(err, ApiError::ApiCompatibility { .. }));
    }

    #[test]
    fn rejects_newer_major() {
        let err = check_server_version(Some("2.0.0")).unwrap_err();
        assert!(matches!(err, ApiError::ApiCompatibility { .. }));
    }

    #[test]
    fn missing_or_garbage_is_unknown() {
        assert_eq!(
            check_server_version(None).unwrap(),
            VersionCheck::UnknownVersion
        );
        assert_eq!(
            check_server_version(Some("not-a-version")).unwrap(),
            VersionCheck::UnknownVersion
        );
    }

    #[test]
    fn parses_messy_versions() {
        assert_eq!(parse_version("v1.26.3"), Some((1, 26, 3)));
        assert_eq!(parse_version("1.26.3-SNAPSHOT"), Some((1, 26, 3)));
        assert_eq!(parse_version("1.26"), Some((1, 26, 0)));
        assert_eq!(parse_version("1.26.3.7"), Some((1, 26, 3)));
        assert_eq!(parse_version("x.y.z"), None);
    }

    #[test]
    fn capabilities() {
        assert_eq!(
            version_capabilities(&VersionCheck::Accepted),
            Vec::<String>::new()
        );
        assert_eq!(
            version_capabilities(&VersionCheck::NewerMinor {
                version: "1.27.0".into()
            }),
            vec!["newer-than-snapshot:1.27.0"]
        );
        assert_eq!(
            version_capabilities(&VersionCheck::UnknownVersion),
            vec!["unknown-version"]
        );
    }
}
