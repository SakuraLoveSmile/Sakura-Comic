//! Server profile persistence (multi-server safe).

use crate::model::server_profile::{AuthType, ServerProfile};
use rusqlite::{params, Connection, Row};

fn auth_type_to_str(auth_type: AuthType) -> &'static str {
    match auth_type {
        AuthType::ApiKey => "api_key",
        AuthType::Basic => "basic",
    }
}

fn auth_type_from_str(s: &str) -> AuthType {
    match s {
        "basic" => AuthType::Basic,
        _ => AuthType::ApiKey,
    }
}

fn row_to_profile(row: &Row) -> rusqlite::Result<ServerProfile> {
    let capabilities_json: String = row.get("capabilities")?;
    let capabilities = serde_json::from_str(&capabilities_json).unwrap_or_default();
    Ok(ServerProfile {
        id: row.get("id")?,
        display_name: row.get("display_name")?,
        base_url: row.get("base_url")?,
        auth_type: auth_type_from_str(&row.get::<_, String>("auth_type")?),
        credential_ref: row.get("credential_ref")?,
        capabilities,
        last_successful_connection: row.get("last_successful_connection")?,
    })
}

/// Insert or update a server profile.
pub fn save_server(conn: &Connection, profile: &ServerProfile) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT INTO servers (id, display_name, base_url, auth_type, credential_ref, capabilities, last_successful_connection)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(id) DO UPDATE SET
           display_name = excluded.display_name,
           base_url = excluded.base_url,
           auth_type = excluded.auth_type,
           credential_ref = excluded.credential_ref,
           capabilities = excluded.capabilities,
           last_successful_connection = excluded.last_successful_connection",
        params![
            profile.id,
            profile.display_name,
            profile.base_url,
            auth_type_to_str(profile.auth_type),
            profile.credential_ref,
            serde_json::to_string(&profile.capabilities).unwrap_or_else(|_| "[]".into()),
            profile.last_successful_connection,
        ],
    )?;
    Ok(())
}

/// All server profiles, ordered by display name.
pub fn list_servers(conn: &Connection) -> rusqlite::Result<Vec<ServerProfile>> {
    let mut stmt = conn.prepare("SELECT * FROM servers ORDER BY display_name")?;
    let rows = stmt.query_map([], row_to_profile)?;
    rows.collect()
}

pub fn get_server(conn: &Connection, id: &str) -> rusqlite::Result<Option<ServerProfile>> {
    let mut stmt = conn.prepare("SELECT * FROM servers WHERE id = ?1")?;
    let mut rows = stmt.query_map(params![id], row_to_profile)?;
    rows.next().transpose()
}

/// Returns true if a row was deleted.
pub fn delete_server(conn: &Connection, id: &str) -> rusqlite::Result<bool> {
    let changed = conn.execute("DELETE FROM servers WHERE id = ?1", params![id])?;
    Ok(changed > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    #[test]
    fn server_crud() {
        let conn = open_in_memory().unwrap();
        let mut profile = ServerProfile::new("Home", "https://komga.example.com", AuthType::ApiKey);
        profile.credential_ref = Some("keychain://home".into());
        profile.capabilities = vec!["sse".into()];

        save_server(&conn, &profile).unwrap();
        assert_eq!(list_servers(&conn).unwrap().len(), 1);

        let fetched = get_server(&conn, &profile.id).unwrap().unwrap();
        assert_eq!(fetched, profile);

        profile.display_name = "Home 2".into();
        save_server(&conn, &profile).unwrap();
        let updated = get_server(&conn, &profile.id).unwrap().unwrap();
        assert_eq!(updated.display_name, "Home 2");

        assert!(delete_server(&conn, &profile.id).unwrap());
        assert!(get_server(&conn, &profile.id).unwrap().is_none());
        assert!(!delete_server(&conn, &profile.id).unwrap());
    }
}
