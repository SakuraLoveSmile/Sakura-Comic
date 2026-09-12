//! Per-series reader overrides: the first level of the two-level model
//! "series override → global setting".
//!
//! The milestone rule is that mode and direction are decided by exactly two
//! things, in this order: what the user set for *this series*, else the global
//! preference. There is deliberately no third level — a book no longer remembers
//! its own mode or direction, which means two volumes of one series can never
//! disagree, and tapping "双页" in volume 3 does not silently turn volume 9 into a
//! spread.
//!
//! Storage: one `app_state` row per overridden series, so a series the user never
//! touched costs nothing and a corrupted row can only ever lose that one series'
//! override. The key encodes `(serverId, seriesId)` as a JSON array rather than
//! joining them with a delimiter, because both halves are server-supplied text
//! and any delimiter will eventually appear inside an id.

use super::paging::{Direction, ReadMode};
use super::settings::ReaderSettings;
use crate::store::app_state;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

/// Prefix of the `app_state` keys that hold series overrides.
pub const OVERRIDE_KEY_PREFIX: &str = "reader_override:";

/// What a series overrides. Both fields are optional: a series may fix its
/// direction and leave the page mode global, and that is not a half-written row.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SeriesOverride {
    pub mode: Option<ReadMode>,
    pub direction: Option<Direction>,
}

impl SeriesOverride {
    /// True when this override changes nothing, i.e. the series follows global.
    pub fn is_empty(&self) -> bool {
        self.mode.is_none() && self.direction.is_none()
    }
}

/// The `app_state` key for one series' override.
pub fn override_key(server_id: &str, series_id: &str) -> String {
    let pair = serde_json::json!([server_id, series_id]).to_string();
    format!("{OVERRIDE_KEY_PREFIX}{pair}")
}

/// Load one series' override. `None` means "follows global".
///
/// A row that no longer parses is treated as absent rather than as an error: the
/// cost of ignoring a corrupt override is one series falling back to the global
/// preference, while the cost of failing is a reader that will not open.
pub fn load_override(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
) -> rusqlite::Result<Option<SeriesOverride>> {
    let raw: Option<String> = app_state::get_value(conn, &override_key(server_id, series_id))?;
    Ok(raw
        .as_deref()
        .and_then(|text| serde_json::from_str::<SeriesOverride>(text).ok())
        .filter(|parsed| !parsed.is_empty()))
}

/// Write one series' override. An empty override removes the row entirely, so
/// "恢复跟随全局" is a delete rather than a row that says "nothing".
pub fn save_override(
    conn: &Connection,
    server_id: &str,
    series_id: &str,
    value: &SeriesOverride,
) -> rusqlite::Result<()> {
    if value.is_empty() {
        return clear_override(conn, server_id, series_id);
    }
    let text = serde_json::to_string(value)
        .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
    app_state::put_value(conn, &override_key(server_id, series_id), &text)
}

/// Drop one series' override — "恢复跟随全局".
pub fn clear_override(conn: &Connection, server_id: &str, series_id: &str) -> rusqlite::Result<()> {
    conn.execute(
        "DELETE FROM app_state WHERE key = ?1",
        [override_key(server_id, series_id)],
    )?;
    Ok(())
}

/// Every overridden series of one server, for the settings screen's list.
pub fn list_overrides(
    conn: &Connection,
    server_id: &str,
) -> rusqlite::Result<Vec<(String, SeriesOverride)>> {
    let mut stmt = conn.prepare("SELECT key, value FROM app_state WHERE key LIKE ?1")?;
    let rows = stmt.query_map([format!("{OVERRIDE_KEY_PREFIX}%")], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (key, value) = row?;
        let Ok(Some(series_id)) = decode_override_key(&key, server_id) else {
            continue;
        };
        let Ok(parsed) = serde_json::from_str::<SeriesOverride>(&value) else {
            continue;
        };
        if !parsed.is_empty() {
            out.push((series_id, parsed));
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

/// The series id inside an override key, when the key belongs to `server_id`.
fn decode_override_key(key: &str, server_id: &str) -> rusqlite::Result<Option<String>> {
    let Some(json) = key.strip_prefix(OVERRIDE_KEY_PREFIX) else {
        return Ok(None);
    };
    let Ok(pair) = serde_json::from_str::<Vec<String>>(json) else {
        return Ok(None);
    };
    match pair.as_slice() {
        [server, series] if server == server_id => Ok(Some(series.clone())),
        _ => Ok(None),
    }
}

/// Apply a series' override to the global settings — the whole two-level rule,
/// in one pure function so the shelf, the reader and the tests cannot drift.
///
/// The global document is not modified; the returned copy is what one book is
/// opened with. This matters: opening a book must never write to the global
/// preference, which is exactly the bug where tapping "双页" in one book made
/// every book a spread.
pub fn resolve_for_series(
    global: &ReaderSettings,
    series: Option<SeriesOverride>,
) -> ReaderSettings {
    let mut effective = global.clone();
    if let Some(series) = series {
        if let Some(mode) = series.mode {
            effective.mode = mode;
        }
        if let Some(direction) = series.direction {
            effective.direction = direction;
        }
    }
    effective.sanitized()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    const SERVER: &str = "server-1";
    const SERIES: &str = "series-a";

    #[test]
    fn a_series_without_an_override_resolves_to_the_global_settings() {
        let conn = open_in_memory().unwrap();
        let global = ReaderSettings::default();
        assert!(load_override(&conn, SERVER, SERIES).unwrap().is_none());
        assert_eq!(
            resolve_for_series(&global, None),
            global.sanitized(),
            "no override must be indistinguishable from an untouched series"
        );
    }

    #[test]
    fn an_override_is_scoped_to_its_own_series() {
        let conn = open_in_memory().unwrap();
        save_override(
            &conn,
            SERVER,
            SERIES,
            &SeriesOverride {
                mode: Some(ReadMode::Double),
                direction: Some(Direction::Rtl),
            },
        )
        .unwrap();

        let loaded = load_override(&conn, SERVER, SERIES).unwrap().unwrap();
        assert_eq!(loaded.mode, Some(ReadMode::Double));
        assert_eq!(loaded.direction, Some(Direction::Rtl));

        // A different series, a different server: both follow global.
        assert!(load_override(&conn, SERVER, "series-b").unwrap().is_none());
        assert!(load_override(&conn, "server-2", SERIES).unwrap().is_none());
    }

    #[test]
    fn a_partial_override_leaves_the_other_half_global() {
        let conn = open_in_memory().unwrap();
        let global = ReaderSettings {
            mode: ReadMode::Webtoon,
            direction: Direction::Ltr,
            ..ReaderSettings::default()
        };

        save_override(
            &conn,
            SERVER,
            SERIES,
            &SeriesOverride {
                mode: None,
                direction: Some(Direction::Rtl),
            },
        )
        .unwrap();

        let effective = resolve_for_series(&global, load_override(&conn, SERVER, SERIES).unwrap());
        assert_eq!(effective.direction, Direction::Rtl, "the series wins");
        assert_eq!(effective.mode, ReadMode::Webtoon, "the global still wins");
    }

    #[test]
    fn a_webtoon_override_never_keeps_first_page_single() {
        let conn = open_in_memory().unwrap();
        save_override(
            &conn,
            SERVER,
            SERIES,
            &SeriesOverride {
                mode: Some(ReadMode::Webtoon),
                direction: None,
            },
        )
        .unwrap();
        let effective = resolve_for_series(
            &ReaderSettings::default(),
            load_override(&conn, SERVER, SERIES).unwrap(),
        );
        assert_eq!(effective.mode, ReadMode::Webtoon);
        assert!(
            !effective.first_page_single,
            "a webtoon is a single column by definition"
        );
    }

    #[test]
    fn clearing_an_override_removes_the_row_rather_than_storing_an_empty_one() {
        let conn = open_in_memory().unwrap();
        save_override(
            &conn,
            SERVER,
            SERIES,
            &SeriesOverride {
                mode: Some(ReadMode::Double),
                direction: None,
            },
        )
        .unwrap();
        clear_override(&conn, SERVER, SERIES).unwrap();
        assert!(load_override(&conn, SERVER, SERIES).unwrap().is_none());

        // An all-None override is the same thing as clearing.
        save_override(
            &conn,
            SERVER,
            SERIES,
            &SeriesOverride {
                mode: Some(ReadMode::Double),
                direction: None,
            },
        )
        .unwrap();
        save_override(&conn, SERVER, SERIES, &SeriesOverride::default()).unwrap();
        assert!(load_override(&conn, SERVER, SERIES).unwrap().is_none());
        let rows: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM app_state WHERE key LIKE 'reader_override:%'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(rows, 0, "no empty rows are left behind");
    }

    #[test]
    fn a_corrupt_override_falls_back_to_global_instead_of_failing() {
        let conn = open_in_memory().unwrap();
        app_state::put_value(&conn, &override_key(SERVER, SERIES), "{not json").unwrap();
        assert!(load_override(&conn, SERVER, SERIES).unwrap().is_none());
        let global = ReaderSettings::default();
        assert_eq!(resolve_for_series(&global, None), global.sanitized());
    }

    #[test]
    fn ids_with_delimiters_do_not_collide() {
        let conn = open_in_memory().unwrap();
        // The pair ("a", "b|c") and ("a|b", "c") must not share a key — the
        // reason the key is JSON rather than `server|series`.
        save_override(
            &conn,
            "a",
            "b|c",
            &SeriesOverride {
                mode: Some(ReadMode::Double),
                direction: None,
            },
        )
        .unwrap();
        assert!(load_override(&conn, "a|b", "c").unwrap().is_none());
        assert!(load_override(&conn, "a", "b").unwrap().is_none());
        assert_eq!(
            load_override(&conn, "a", "b|c").unwrap().unwrap().mode,
            Some(ReadMode::Double)
        );
    }

    #[test]
    fn listing_overrides_returns_only_this_servers_series() {
        let conn = open_in_memory().unwrap();
        save_override(
            &conn,
            SERVER,
            "series-b",
            &SeriesOverride {
                mode: Some(ReadMode::Single),
                direction: Some(Direction::Rtl),
            },
        )
        .unwrap();
        save_override(
            &conn,
            SERVER,
            "series-a",
            &SeriesOverride {
                mode: Some(ReadMode::Double),
                direction: None,
            },
        )
        .unwrap();
        save_override(
            &conn,
            "server-2",
            "series-c",
            &SeriesOverride {
                mode: Some(ReadMode::Double),
                direction: None,
            },
        )
        .unwrap();

        let listed = list_overrides(&conn, SERVER).unwrap();
        assert_eq!(
            listed.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(),
            vec!["series-a", "series-b"],
            "sorted, and server-2's series is not ours"
        );
    }

    #[test]
    fn opening_a_book_does_not_write_to_the_global_preference() {
        let conn = open_in_memory().unwrap();
        let saved = ReaderSettings::default();
        ReaderSettings::save(&conn, &saved).unwrap();

        let resolved = resolve_for_series(
            &saved,
            Some(SeriesOverride {
                mode: Some(ReadMode::Webtoon),
                direction: Some(Direction::Vertical),
            }),
        );
        assert_eq!(resolved.mode, ReadMode::Webtoon);

        // The stored document is untouched: the next book still sees 单页 · LTR.
        let reloaded = ReaderSettings::load(&conn).unwrap();
        assert_eq!(reloaded.mode, saved.mode);
        assert_eq!(reloaded.direction, saved.direction);
    }
}
