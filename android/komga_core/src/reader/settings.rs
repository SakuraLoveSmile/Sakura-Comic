//! Reader settings: the six knobs Stage 7 owns (direction, page gap,
//! background, keep screen awake, brightness, position restore) plus the
//! prefetch window, persisted in the local database.
//!
//! Settings are stored as one JSON document under `app_state`, so adding a knob
//! is a serde change rather than a migration. Defaults matter: they are what a
//! reader sees on first launch, and what a corrupted row falls back to.

use super::paging::{Direction, ReadMode};
use super::prefetch::Window;
use crate::store::app_state;
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

/// `app_state` key holding the reader settings document.
pub const SETTINGS_KEY: &str = "reader_settings";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Background {
    #[default]
    Black,
    White,
    Gray,
}

impl Background {
    pub fn as_str(self) -> &'static str {
        match self {
            Background::Black => "black",
            Background::White => "white",
            Background::Gray => "gray",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "black" => Some(Background::Black),
            "white" => Some(Background::White),
            "gray" => Some(Background::Gray),
            _ => None,
        }
    }
}

/// Brightness is a multiplier on the system level, in 0.05..=1.0. `None` means
/// "leave the system brightness alone" — the reader must not fight the OS.
pub const MIN_BRIGHTNESS: f32 = 0.05;

pub fn clamp_brightness(value: f32) -> f32 {
    if !(value.is_finite()) {
        return 1.0;
    }
    value.clamp(MIN_BRIGHTNESS, 1.0)
}

/// Gap between pages, in logical pixels; negative gaps would overlap content.
pub const MAX_PAGE_GAP: u32 = 64;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReaderSettings {
    pub mode: ReadMode,
    pub direction: Direction,
    /// Manga convention: the cover/title page stands alone before pairing.
    pub first_page_single: bool,
    pub page_gap: u32,
    pub background: Background,
    pub keep_screen_awake: bool,
    pub brightness: Option<f32>,
    /// When off, every book starts at page 1 and nothing is written back.
    pub restore_position: bool,
    pub prefetch: Window,
    /// Whether the hardware volume keys turn pages.
    ///
    /// Off by default and deliberately so: stealing the volume keys means the
    /// user can no longer change the volume while reading, and that is a trade
    /// each person has to make for themselves — never a default the app picks.
    pub volume_keys_enabled: bool,
}

impl Default for ReaderSettings {
    fn default() -> Self {
        ReaderSettings {
            mode: ReadMode::Single,
            direction: Direction::Ltr,
            first_page_single: true,
            page_gap: 8,
            background: Background::Black,
            keep_screen_awake: true,
            brightness: None,
            restore_position: true,
            prefetch: Window::default(),
            volume_keys_enabled: false,
        }
    }
}

impl ReaderSettings {
    /// Normalizes anything a UI or a stored document could produce into a state
    /// the layout code can rely on.
    pub fn sanitized(mut self) -> Self {
        self.page_gap = self.page_gap.min(MAX_PAGE_GAP);
        self.brightness = self.brightness.map(clamp_brightness);
        // A webtoon is a single column by definition; pairing would be a bug.
        if self.mode == ReadMode::Webtoon {
            self.first_page_single = false;
        }
        self
    }

    pub fn load(conn: &Connection) -> rusqlite::Result<Self> {
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM app_state WHERE key = ?1",
                [SETTINGS_KEY],
                |row| row.get(0),
            )
            .optional()?;
        let settings = raw
            .as_deref()
            .and_then(|text| serde_json::from_str::<ReaderSettings>(text).ok())
            .unwrap_or_default();
        // A partially written or hand-edited row must not brick the reader.
        Ok(settings.sanitized())
    }

    pub fn save(conn: &Connection, settings: &ReaderSettings) -> rusqlite::Result<()> {
        let text = serde_json::to_string(&settings.clone().sanitized())
            .map_err(|error| rusqlite::Error::ToSqlConversionFailure(Box::new(error)))?;
        app_state::put_value(conn, SETTINGS_KEY, &text)
    }
}

/// Direction precedence, which is a real product rule and not a detail:
/// what the user left this book on beats what the series says, which beats the
/// global preference. A manga read once in RTL stays in RTL on the next chapter
/// even if the user's default is LTR.
pub fn resolve_direction(
    per_book: Option<Direction>,
    series_reading_direction: Option<&str>,
    global: Direction,
) -> Direction {
    per_book
        .or_else(|| recommended_direction(series_reading_direction))
        .unwrap_or(global)
}

/// What the server's series metadata implies, if anything.
pub fn recommended_direction(series_reading_direction: Option<&str>) -> Option<Direction> {
    match series_reading_direction?
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "rtl" | "righttoleft" | "right-to-left" | "manga" => Some(Direction::Rtl),
        "ltr" | "lefttoright" | "left-to-right" | "comic" => Some(Direction::Ltr),
        "vertical" | "webtoon" => Some(Direction::Vertical),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;

    #[test]
    fn volume_keys_are_off_by_default_and_a_pre_existing_row_keeps_them_off() {
        let conn = open_in_memory().unwrap();
        assert!(!ReaderSettings::default().volume_keys_enabled);
        assert!(!ReaderSettings::load(&conn).unwrap().volume_keys_enabled);

        // A settings document written before this knob existed must not turn it
        // on, and must not fail to parse: `#[serde(default)]` is the whole
        // reason adding a knob is not a migration.
        app_state::put_value(
            &conn,
            SETTINGS_KEY,
            r#"{"mode":"double","direction":"rtl","firstPageSingle":true,"pageGap":8,
                "background":"gray","keepScreenAwake":true,"brightness":null,
                "restorePosition":true,
                "prefetch":{"forward":4,"back":2,"cap":12}}"#,
        )
        .unwrap();
        let loaded = ReaderSettings::load(&conn).unwrap();
        assert_eq!(loaded.mode, ReadMode::Double);
        assert_eq!(loaded.background, Background::Gray);
        assert!(
            !loaded.volume_keys_enabled,
            "an older document means the user never opted in"
        );
    }

    #[test]
    fn volume_keys_round_trip_through_the_document() {
        let conn = open_in_memory().unwrap();
        let settings = ReaderSettings {
            volume_keys_enabled: true,
            ..ReaderSettings::default()
        };
        ReaderSettings::save(&conn, &settings).unwrap();
        assert!(ReaderSettings::load(&conn).unwrap().volume_keys_enabled);
        // And back off again.
        ReaderSettings::save(
            &conn,
            &ReaderSettings {
                volume_keys_enabled: false,
                ..settings
            },
        )
        .unwrap();
        assert!(!ReaderSettings::load(&conn).unwrap().volume_keys_enabled);
    }

    #[test]
    fn defaults_round_trip_through_sqlite() {
        let conn = open_in_memory().unwrap();
        // Nothing stored yet: the reader still has a usable configuration.
        assert_eq!(
            ReaderSettings::load(&conn).unwrap(),
            ReaderSettings::default()
        );

        let settings = ReaderSettings {
            mode: ReadMode::Double,
            direction: Direction::Rtl,
            page_gap: 20,
            background: Background::White,
            keep_screen_awake: false,
            brightness: Some(0.4),
            prefetch: Window {
                forward: 4,
                back: 2,
                cap: 20,
            },
            ..Default::default()
        };
        ReaderSettings::save(&conn, &settings).unwrap();
        assert_eq!(ReaderSettings::load(&conn).unwrap(), settings);
    }

    #[test]
    fn a_corrupt_row_falls_back_to_defaults_instead_of_failing() {
        let conn = open_in_memory().unwrap();
        app_state::put_value(&conn, SETTINGS_KEY, "{ not json").unwrap();
        assert_eq!(
            ReaderSettings::load(&conn).unwrap(),
            ReaderSettings::default()
        );
    }

    #[test]
    fn impossible_values_are_normalized_on_the_way_in() {
        let conn = open_in_memory().unwrap();
        app_state::put_value(
            &conn,
            SETTINGS_KEY,
            r#"{"mode":"webtoon","firstPageSingle":true,"pageGap":9999,"brightness":0.0}"#,
        )
        .unwrap();
        let loaded = ReaderSettings::load(&conn).unwrap();
        assert_eq!(loaded.page_gap, MAX_PAGE_GAP, "gap is clamped, not trusted");
        assert_eq!(
            loaded.brightness,
            Some(MIN_BRIGHTNESS),
            "0 is below the floor"
        );
        assert!(
            !loaded.first_page_single,
            "webtoon must not carry a pairing flag"
        );
    }

    #[test]
    fn brightness_floor_and_ceiling() {
        assert_eq!(clamp_brightness(0.0), MIN_BRIGHTNESS);
        assert_eq!(clamp_brightness(3.0), 1.0);
        assert_eq!(clamp_brightness(-1.0), MIN_BRIGHTNESS);
        assert_eq!(
            clamp_brightness(f32::NAN),
            1.0,
            "NaN must not reach a UI slider"
        );
        assert_eq!(clamp_brightness(0.5), 0.5);
    }

    #[test]
    fn series_direction_recommends_but_never_overrides_the_user() {
        assert_eq!(
            recommended_direction(Some("Right To Left (rtl)")),
            None,
            "free-form server text is not a guess-the-reader problem"
        );
        assert_eq!(recommended_direction(Some("rtl")), Some(Direction::Rtl));
        assert_eq!(
            recommended_direction(Some("WEBTOON")),
            Some(Direction::Vertical)
        );
        assert_eq!(recommended_direction(Some("unknown")), None);
        assert_eq!(recommended_direction(None), None);

        // Per-book wins over the series, the series wins over the global default.
        assert_eq!(
            resolve_direction(Some(Direction::Ltr), Some("rtl"), Direction::Ltr),
            Direction::Ltr
        );
        assert_eq!(
            resolve_direction(None, Some("rtl"), Direction::Ltr),
            Direction::Rtl,
            "a manga opens right-to-left without the user asking"
        );
        assert_eq!(
            resolve_direction(None, None, Direction::Vertical),
            Direction::Vertical
        );
    }

    #[test]
    fn saving_a_webtoon_setting_does_not_persist_the_stale_flag() {
        let conn = open_in_memory().unwrap();
        let settings = ReaderSettings {
            mode: ReadMode::Webtoon,
            first_page_single: true,
            ..Default::default()
        };
        ReaderSettings::save(&conn, &settings).unwrap();
        let loaded = ReaderSettings::load(&conn).unwrap();
        assert!(!loaded.first_page_single);
        assert_eq!(loaded.mode, ReadMode::Webtoon);
    }
}
