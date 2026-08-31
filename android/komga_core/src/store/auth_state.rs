//! What the last credentialed contact with a server proved about its credential.
//!
//! The distinction this table exists to keep is between three sentences that
//! look alike from a phone: "the server rejected your key", "the server was
//! unreachable", and "we have not spoken to it yet". Only the first one means
//! the user has to do something, and only the first one may say so — which is
//! why callers pass a verdict rather than an error, and why a network failure
//! must not reach this module at all.
//!
//! It lives in `app_state` rather than a new table on purpose: one keyed value
//! per server, no schema version to negotiate, and nothing to migrate.

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

/// Prefix for the per-server key. Scoped by server because every credential is
/// per-server, and one dead key must not grey out the shelf of a second one.
pub const KEY_PREFIX: &str = "auth_state:";

/// What a caller observed about a credential. Deliberately narrower than `ApiError`: only the two
/// outcomes that carry information about *the credential*.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CredentialVerdict {
    /// A request that carried the credential was accepted.
    Accepted,
    /// The server answered 401 or 403 to a request that carried it.
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthState {
    /// Never observed, or the stored note could not be read.
    Unknown,
    Valid,
    Expired,
}

impl AuthState {
    pub fn as_str(&self) -> &'static str {
        match self {
            AuthState::Unknown => "unknown",
            AuthState::Valid => "valid",
            AuthState::Expired => "expired",
        }
    }
}

/// The stored form: the verdict plus when it was earned, so the UI can say
/// "since 12:04" instead of asserting that a key is bad right now.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct StoredNote {
    state: String,
    at: String,
}

fn key(server_id: &str) -> String {
    format!("{KEY_PREFIX}{server_id}")
}

/// Read one server's credential state, and when it was last proved.
///
/// An unreadable value reads as `Unknown`: the row is written by this module,
/// so the only way to get here is a build from another era — and a client that
/// cannot read the note must fall back to "ask the server", not to "the user's
/// key is bad".
pub fn get(conn: &Connection, server_id: &str) -> rusqlite::Result<(AuthState, Option<String>)> {
    let raw: Option<String> = conn
        .query_row(
            "SELECT value FROM app_state WHERE key = ?1",
            params![key(server_id)],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let Some(raw) = raw else {
        return Ok((AuthState::Unknown, None));
    };
    match serde_json::from_str::<StoredNote>(&raw) {
        Ok(note) => {
            let state = match note.state.as_str() {
                "valid" => AuthState::Valid,
                "expired" => AuthState::Expired,
                _ => AuthState::Unknown,
            };
            Ok((state, Some(note.at)))
        }
        Err(_) => Ok((AuthState::Unknown, None)),
    }
}

/// Record what just happened and return the state it leaves behind.
pub fn note(
    conn: &Connection,
    server_id: &str,
    verdict: CredentialVerdict,
    at: &str,
) -> rusqlite::Result<AuthState> {
    let state = match verdict {
        CredentialVerdict::Accepted => AuthState::Valid,
        CredentialVerdict::Rejected => AuthState::Expired,
    };
    let payload = serde_json::to_string(&StoredNote {
        state: state.as_str().to_string(),
        at: at.to_string(),
    })
    .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    conn.execute(
        "INSERT INTO app_state (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key(server_id), payload],
    )?;
    Ok(state)
}

/// Forget one server's note (used when the server is deleted, and when the user
/// replaces a credential and the next answer is the only honest evidence).
pub fn clear(conn: &Connection, server_id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM app_state WHERE key = ?1",
        params![key(server_id)],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store;

    #[test]
    fn a_server_never_spoken_to_is_unknown_rather_than_expired() {
        let conn = store::open_in_memory().unwrap();
        let (state, at) = get(&conn, "s1").unwrap();
        assert_eq!(state, AuthState::Unknown);
        assert_eq!(at, None);
    }

    #[test]
    fn a_rejection_says_expired_and_keeps_the_moment_it_happened() {
        let conn = store::open_in_memory().unwrap();
        assert_eq!(
            note(
                &conn,
                "s1",
                CredentialVerdict::Rejected,
                "2026-08-31T12:04:00Z"
            )
            .unwrap(),
            AuthState::Expired
        );
        let (state, at) = get(&conn, "s1").unwrap();
        assert_eq!(state, AuthState::Expired);
        assert_eq!(at.as_deref(), Some("2026-08-31T12:04:00Z"));
    }

    #[test]
    fn a_later_acceptance_is_what_clears_an_expiration() {
        let conn = store::open_in_memory().unwrap();
        note(&conn, "s1", CredentialVerdict::Rejected, "t1").unwrap();
        assert_eq!(
            note(&conn, "s1", CredentialVerdict::Accepted, "t2").unwrap(),
            AuthState::Valid
        );
        let (state, at) = get(&conn, "s1").unwrap();
        assert_eq!(state, AuthState::Valid);
        // The timestamp moves with the verdict: a stale "expired at t1" beside
        // a valid state would make the banner impossible to reason about.
        assert_eq!(at.as_deref(), Some("t2"));
    }

    #[test]
    fn two_servers_hold_two_independent_verdicts() {
        let conn = store::open_in_memory().unwrap();
        note(&conn, "s1", CredentialVerdict::Rejected, "t1").unwrap();
        note(&conn, "s2", CredentialVerdict::Accepted, "t1").unwrap();
        assert_eq!(get(&conn, "s1").unwrap().0, AuthState::Expired);
        assert_eq!(get(&conn, "s2").unwrap().0, AuthState::Valid);
        // A dead key on one server must not grey out the other's shelf, and
        // must not even leave a row behind for it.
        clear(&conn, "s1").unwrap();
        assert_eq!(get(&conn, "s1").unwrap().0, AuthState::Unknown);
        assert_eq!(get(&conn, "s2").unwrap().0, AuthState::Valid);
    }

    #[test]
    fn a_note_this_build_cannot_read_reads_as_unknown_not_as_expired() {
        let conn = store::open_in_memory().unwrap();
        // Only this module writes the key, so arriving here means a different
        // era's build left it: fall back to "ask the server".
        crate::store::app_state::put_value(&conn, &key("s1"), "not json").unwrap();
        assert_eq!(get(&conn, "s1").unwrap().0, AuthState::Unknown);
        crate::store::app_state::put_value(
            &conn,
            &key("s2"),
            "{\"state\":\"revoked\",\"at\":\"t\"}",
        )
        .unwrap();
        assert_eq!(get(&conn, "s2").unwrap().0, AuthState::Unknown);
    }

    #[test]
    fn clearing_one_server_leaves_the_active_server_pick_alone() {
        let conn = store::open_in_memory().unwrap();
        crate::store::app_state::set_active_server(&conn, "s1").unwrap();
        note(&conn, "s1", CredentialVerdict::Rejected, "t1").unwrap();
        clear(&conn, "s1").unwrap();
        assert_eq!(
            crate::store::app_state::get_active_server(&conn)
                .unwrap()
                .as_deref(),
            Some("s1")
        );
    }

    #[test]
    fn the_note_is_a_single_row_per_server_and_survives_a_second_write() {
        let conn = store::open_in_memory().unwrap();
        note(&conn, "s1", CredentialVerdict::Rejected, "t1").unwrap();
        note(&conn, "s1", CredentialVerdict::Accepted, "t2").unwrap();
        let rows: i64 = conn
            .query_row(
                "SELECT count(*) FROM app_state WHERE key = ?1",
                params![key("s1")],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(rows, 1);
    }
}
