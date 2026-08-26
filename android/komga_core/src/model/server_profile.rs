//! Server Profile — multi-server connection metadata.
//!
//! Compatibility targets:
//! - `https://komga.example.com`
//! - `http://192.168.1.10:25600`
//! - `https://example.com/komga/`

use serde::{Deserialize, Serialize};

/// How authentication credentials are presented to Komga.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthType {
    ApiKey,
    Basic,
}

/// A saved Komga server profile.
///
/// Credentials are never stored here — only `credential_ref` referencing
/// platform credential storage (Keychain / Android Keystore).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerProfile {
    pub id: String,
    pub display_name: String,
    pub base_url: String,
    pub auth_type: AuthType,
    /// Reference into Keychain / Android Keystore; never the secret itself.
    pub credential_ref: Option<String>,
    /// Capabilities discovered during connection test, e.g. "sse".
    pub capabilities: Vec<String>,
    /// RFC 3339 timestamp of the last successful connection.
    pub last_successful_connection: Option<String>,
}

impl ServerProfile {
    pub fn new(
        display_name: impl Into<String>,
        base_url: impl Into<String>,
        auth_type: AuthType,
    ) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            display_name: display_name.into(),
            base_url: base_url.into(),
            auth_type,
            credential_ref: None,
            capabilities: Vec::new(),
            last_successful_connection: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serde_roundtrip() {
        let profile = ServerProfile::new("Home", "https://komga.example.com", AuthType::ApiKey);
        let json = serde_json::to_string(&profile).unwrap();
        let back: ServerProfile = serde_json::from_str(&json).unwrap();
        assert_eq!(profile, back);
    }

    #[test]
    fn generates_unique_ids() {
        let a = ServerProfile::new("A", "http://192.168.1.10:25600", AuthType::Basic);
        let b = ServerProfile::new("B", "http://192.168.1.11:25600", AuthType::Basic);
        assert_ne!(a.id, b.id);
    }
}
