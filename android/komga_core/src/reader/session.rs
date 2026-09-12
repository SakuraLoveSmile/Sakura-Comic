//! Reading session: the durable half of Stage 7's progress pipeline.
//!
//! ```text
//! UI gesture -> ReaderSession::turn_to
//!                -> reader_position   (display state, never uploaded)
//!                -> read_progress     (the value that syncs)
//!                -> pending_mutations (coalesced outbox row, same call)
//!                -> Upload::Now | Upload::Idle
//! ```
//!
//! When a request happens is decided by [`ProgressThrottle`], which is pure and
//! contract-tested; what the request contains is decided by `store::outbox`.
//! This type only glues them to SQLite and to the layout. It never sends
//! anything itself: on `Upload::Now` the caller runs
//! `sync::upload::upload_outbox`, so retry/backoff/conflict handling stays in
//! the one place Stage 6 put it.

use super::paging::{layout, Direction, Layout, ReadMode};
use super::settings::ReaderSettings;
use super::throttle::{
    Config as ThrottleConfig, Event, EventKind, PendingIntent, ProgressThrottle,
};

/// How long a page-turn burst may sit locally before the outbox is drained.
/// 5 s is a starting point, not a law: it is one number to retune in the
/// performance phase, and the contract in `reader/throttle.json` pins the
/// behaviour that depends on it.
pub const UPLOAD_INTERVAL_MS: i64 = 5000;
use crate::store::{outbox, position, read_progress};
use rusqlite::Connection;

/// Whether the caller should drain the outbox right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Upload {
    Now,
    Idle,
}

/// One instant in both clocks the pipeline needs: RFC 3339 for the rows,
/// milliseconds for the throttle. Taken as an argument so a test (and the
/// acceptance script) can advance time deterministically.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Clock {
    pub rfc3339: String,
    pub ms: i64,
}

impl Clock {
    pub fn now() -> Self {
        Clock {
            rfc3339: crate::store::thumbnails::now_rfc3339(),
            ms: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|since| since.as_millis() as i64)
                .unwrap_or(0),
        }
    }

    pub fn at_ms(ms: i64) -> Self {
        Clock {
            rfc3339: format!("{ms}"),
            ms,
        }
    }
}

/// Where the reader is standing, and what it owes the server.
pub struct ReaderSession {
    server_id: String,
    book_id: String,
    page_count: u32,
    /// Stage 6 rule R8: only an image-paged manifest may report page numbers.
    writes_progress: bool,
    mode: ReadMode,
    direction: Direction,
    first_page_single: bool,
    layout: Layout,
    current: u32,
    spread: usize,
    throttle: ProgressThrottle,
    /// How far into the current page a webtoon reader is, 0..1. `None` in the
    /// paged modes and for a book that has never been scrolled — the two are the
    /// same fact to a paged reader, and neither is `0.0`.
    page_offset_ratio: Option<f64>,
}

impl ReaderSession {
    /// Restore-or-start. A saved position supplies both the page and the layout
    /// it was displayed with, but only when the user wants positions restored;
    /// with `restore_position` off, every book starts at page 1.
    pub fn open(
        conn: &Connection,
        server_id: &str,
        book_id: &str,
        page_count: u32,
        writes_progress: bool,
        settings: &ReaderSettings,
        clock: &Clock,
    ) -> rusqlite::Result<Self> {
        let saved = if settings.restore_position {
            position::get(conn, server_id, book_id)?
        } else {
            None
        };

        let mode = saved
            .as_ref()
            .map(|saved| ReadMode::parse(&saved.mode))
            .unwrap_or(settings.mode);
        let direction = saved
            .as_ref()
            .map(|saved| Direction::parse(&saved.direction))
            .unwrap_or(settings.direction);
        let layout = layout(
            page_count,
            mode,
            direction,
            settings.first_page_single,
            &std::collections::HashSet::new(),
        );

        // A manifest can shrink between two reads; never restore past its end.
        let wanted = saved
            .as_ref()
            .and_then(|saved| u32::try_from(saved.page).ok())
            .filter(|page| *page > 0)
            .unwrap_or(1);
        let start = if page_count == 0 {
            1
        } else {
            wanted.clamp(1, page_count)
        };
        let spread = layout.index_for_page(start).unwrap_or(0);
        let current = layout.entry_page(spread).unwrap_or(start);

        let restored = restored_pending(conn, server_id, book_id)?;
        // `last_upload_at` stays unknown on purpose: a row a crash left behind
        // is owed immediately rather than after another full interval.
        let throttle = ProgressThrottle::open(
            ThrottleConfig {
                book_id: book_id.to_string(),
                page_count,
                interval_ms: UPLOAD_INTERVAL_MS,
            },
            Some(current),
            None,
            restored,
        );

        // Restored from the same row the page came from, and only when the page
        // itself was restored: landing on page 1 because the user turned position
        // restore off must not also scroll halfway down it.
        let page_offset_ratio = if current == start {
            saved.as_ref().and_then(|saved| saved.page_offset_ratio)
        } else {
            None
        };

        let session = ReaderSession {
            server_id: server_id.to_string(),
            book_id: book_id.to_string(),
            page_count,
            writes_progress,
            mode,
            direction,
            first_page_single: settings.first_page_single,
            layout,
            current,
            spread,
            throttle,
            page_offset_ratio,
        };
        // A restore can legally move the page: the stored page may be the second
        // half of a pair, or past the end of a manifest that shrank. Stamp the
        // corrected page so the row always describes what is on screen.
        let corrected = saved
            .as_ref()
            .is_some_and(|saved| i64::from(current) != saved.page);
        if corrected {
            session.persist(conn, clock)?;
        }
        Ok(session)
    }

    pub fn page(&self) -> u32 {
        self.current
    }

    pub fn spread(&self) -> usize {
        self.spread
    }

    pub fn page_count(&self) -> u32 {
        self.page_count
    }

    pub fn mode(&self) -> ReadMode {
        self.mode
    }

    pub fn direction(&self) -> Direction {
        self.direction
    }

    /// How far into the current page the reader is, 0..1.
    pub fn page_offset_ratio(&self) -> Option<f64> {
        self.page_offset_ratio
    }

    /// Record the scroll offset without writing to the database.
    ///
    /// A scroll reports continuously, and a write per report would put the whole
    /// position row through SQLite on every frame; the offset rides along with
    /// the next persist, which a turn or a close always triggers.
    pub fn set_page_offset_ratio(&mut self, ratio: Option<f64>) {
        self.page_offset_ratio = ratio.map(|r| r.clamp(0.0, 1.0));
    }

    pub fn layout(&self) -> &Layout {
        &self.layout
    }

    /// Pages on screen, left-to-right / top-to-bottom.
    pub fn visible(&self) -> Vec<u32> {
        self.layout.visual(self.spread).unwrap_or_default()
    }

    /// Turn to a canonical page. Clamped, idempotent, and durable before it is
    /// visible: the position row and the outbox row are written in the same
    /// call, so a crash cannot show a page the server will never hear about.
    pub fn turn_to(
        &mut self,
        conn: &Connection,
        page: u32,
        clock: &Clock,
    ) -> rusqlite::Result<Upload> {
        if self.page_count == 0 {
            return Ok(Upload::Idle);
        }
        let page = page.clamp(1, self.page_count);
        if page == self.current {
            return Ok(Upload::Idle);
        }
        let Some(spread) = self.layout.index_for_page(page) else {
            return Ok(Upload::Idle);
        };
        self.current = page;
        self.spread = spread;
        // A scroll offset is a statement about *one* page: "62% down page 1" says
        // nothing about page 3, and carrying it over would drop the reader into
        // the middle of a page they have never seen. Cleared here rather than by
        // the caller so it cannot be forgotten by a caller in another language.
        self.page_offset_ratio = None;
        self.persist(conn, clock)?;
        // T9: a book the image reader cannot drive (EPUB/PDF) must never enter
        // the page-progress stream, not even as a queued row.
        if !self.writes_progress {
            return Ok(Upload::Idle);
        }
        let calls = self.throttle.apply(Event::page(clock.ms, page));
        Ok(Upload::flag(!calls.is_empty()))
    }

    /// Advance one spread in the current reading direction.
    pub fn next(&mut self, conn: &Connection, clock: &Clock) -> rusqlite::Result<Upload> {
        self.step(conn, 1, clock)
    }

    pub fn previous(&mut self, conn: &Connection, clock: &Clock) -> rusqlite::Result<Upload> {
        self.step(conn, -1, clock)
    }

    fn step(&mut self, conn: &Connection, delta: isize, clock: &Clock) -> rusqlite::Result<Upload> {
        if self.layout.spread_count() == 0 {
            return Ok(Upload::Idle);
        }
        let moved = (self.spread as isize + delta).clamp(0, self.layout.spread_count() as isize - 1)
            as usize;
        let entry = self.layout.entry_page(moved).unwrap_or(self.current);
        self.turn_to(conn, entry, clock)
    }

    /// Re-pair the book after a mode/direction change without losing the place.
    pub fn relayout(
        &mut self,
        conn: &Connection,
        mode: ReadMode,
        direction: Direction,
        clock: &Clock,
    ) -> rusqlite::Result<()> {
        self.mode = mode;
        self.direction = direction;
        self.layout = layout(
            self.page_count,
            mode,
            direction,
            self.first_page_single,
            &std::collections::HashSet::new(),
        );
        self.spread = self.layout.index_for_page(self.current).unwrap_or(0);
        self.current = self.layout.entry_page(self.spread).unwrap_or(self.current);
        self.persist(conn, clock)
    }

    /// Explicit user statement — never throttled (rule T4).
    pub fn mark_read(&mut self, conn: &Connection, clock: &Clock) -> rusqlite::Result<Upload> {
        if self.writes_progress {
            read_progress::mark_read(conn, &self.server_id, &self.book_id)?;
        }
        Ok(Upload::flag(
            !self
                .throttle
                .apply(Event::of(clock.ms, EventKind::MarkRead))
                .is_empty(),
        ))
    }

    pub fn mark_unread(&mut self, conn: &Connection, clock: &Clock) -> rusqlite::Result<Upload> {
        if self.writes_progress {
            read_progress::mark_unread(conn, &self.server_id, &self.book_id)?;
        }
        self.current = 0;
        self.spread = 0;
        Ok(Upload::flag(
            !self
                .throttle
                .apply(Event::of(clock.ms, EventKind::MarkUnread))
                .is_empty(),
        ))
    }

    /// The UI's periodic timer.
    pub fn tick(&mut self, clock: &Clock) -> Upload {
        Upload::flag(
            !self
                .throttle
                .apply(Event::of(clock.ms, EventKind::Tick))
                .is_empty(),
        )
    }

    /// Leaving the reader: persist once more and give the outbox its chance.
    pub fn close(&mut self, conn: &Connection, clock: &Clock) -> rusqlite::Result<Upload> {
        if self.current > 0 {
            self.persist(conn, clock)?;
        }
        Ok(Upload::flag(
            !self
                .throttle
                .apply(Event::of(clock.ms, EventKind::Exit))
                .is_empty(),
        ))
    }

    /// Backgrounding is the last reliable moment to get a request out.
    pub fn background(&mut self, clock: &Clock) -> Upload {
        Upload::flag(
            !self
                .throttle
                .apply(Event::of(clock.ms, EventKind::Background))
                .is_empty(),
        )
    }

    /// Which statement, if any, this book currently owes the server.
    pub fn outbox_state(&self, conn: &Connection) -> rusqlite::Result<Option<&'static str>> {
        let queued = outbox::queued_for_book(conn, &self.server_id, &self.book_id)?;
        Ok(
            match queued.as_ref().map(|entry| entry.mutation_type.as_str()) {
                Some("READ_PROGRESS") => Some("READ_PROGRESS"),
                Some("MARK_READ") => Some("MARK_READ"),
                Some("MARK_UNREAD") => Some("MARK_UNREAD"),
                _ => None,
            },
        )
    }

    fn persist(&self, conn: &Connection, clock: &Clock) -> rusqlite::Result<()> {
        position::save_with_offset(
            conn,
            &self.server_id,
            &self.book_id,
            self.current,
            self.mode.as_str(),
            self.direction.as_str(),
            self.page_offset_ratio,
            &clock.rfc3339,
        )?;
        if self.writes_progress && self.current > 0 {
            read_progress::upsert_local_read_progress(
                conn,
                &self.server_id,
                &self.book_id,
                self.current as i64,
                self.current >= self.page_count,
            )?;
        }
        Ok(())
    }
}

impl Upload {
    fn flag(now: bool) -> Self {
        if now {
            Upload::Now
        } else {
            Upload::Idle
        }
    }
}

/// The row a previous session left unpaid, if any.
pub fn restored_pending(
    conn: &Connection,
    server_id: &str,
    book_id: &str,
) -> rusqlite::Result<Option<PendingIntent>> {
    Ok(outbox::queued_for_book(conn, server_id, book_id)?
        .as_ref()
        .and_then(|entry| outbox::intent_of(&entry.mutation_type, &entry.payload))
        .map(|intent| match intent {
            outbox::Intent::Progress { page, completed } => PendingIntent::Progress {
                page: page.unwrap_or(1).max(1) as u32,
                completed,
            },
            outbox::Intent::MarkRead => PendingIntent::MarkRead,
            outbox::Intent::MarkUnread => PendingIntent::MarkUnread,
        }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::open_in_memory;
    use crate::store::read_progress;

    const BOOK: &str = "book";
    const SERVER: &str = "srv";

    fn settings() -> ReaderSettings {
        ReaderSettings::default()
    }

    fn open(
        conn: &Connection,
        page_count: u32,
        settings: &ReaderSettings,
        ms: i64,
    ) -> ReaderSession {
        ReaderSession::open(
            conn,
            SERVER,
            BOOK,
            page_count,
            true,
            settings,
            &Clock::at_ms(ms),
        )
        .unwrap()
    }

    /// -1 means "no row at all", which is different from a stored page 0.
    fn stored_page(conn: &Connection) -> i64 {
        read_progress::stored_progress(conn, SERVER, BOOK)
            .unwrap()
            .map(|row| row.page)
            .unwrap_or(-1)
    }

    #[test]
    fn a_new_book_starts_at_page_one_and_owes_nothing() {
        let conn = open_in_memory().unwrap();
        let session = open(&conn, 30, &settings(), 0);
        assert_eq!(session.page(), 1);
        assert_eq!(session.spread(), 0);
        assert_eq!(session.visible(), vec![1]);
        assert_eq!(session.outbox_state(&conn).unwrap(), None);
        assert_eq!(stored_page(&conn), -1, "opening must not write progress");
    }

    /// The offset belongs to one page. Moving on has to drop it, and the place
    /// that enforces this is the session rather than the UI: a page change from
    /// any caller in any language must not carry "62% down page 1" onto page 3,
    /// because that would open the reader in the middle of a page nobody has seen.
    #[test]
    fn a_page_change_drops_the_scroll_offset_it_was_standing_on() {
        let conn = open_in_memory().unwrap();
        let mut session = open(&conn, 30, &settings(), 0);
        session.set_page_offset_ratio(Some(0.62));

        session.turn_to(&conn, 3, &Clock::at_ms(1_000)).unwrap();

        assert_eq!(session.page(), 3);
        assert_eq!(session.page_offset_ratio(), None);
        let stored = position::get(&conn, SERVER, BOOK).unwrap().unwrap();
        assert_eq!(stored.page, 3i64);
        assert_eq!(stored.page_offset_ratio, None);
    }

    #[test]
    fn turning_a_page_writes_position_progress_and_one_outbox_row() {
        let conn = open_in_memory().unwrap();
        let mut session = open(&conn, 30, &settings(), 0);
        // 0 ms since "opened" and a null last-upload stamp: the first turn is
        // still throttled, because a burst must not start a request per page.
        assert_eq!(
            session.turn_to(&conn, 2, &Clock::at_ms(100)).unwrap(),
            Upload::Idle
        );
        assert_eq!(session.page(), 2);
        assert_eq!(stored_page(&conn), 2);
        assert_eq!(session.outbox_state(&conn).unwrap(), Some("READ_PROGRESS"));
        let saved = position::get(&conn, SERVER, BOOK).unwrap().unwrap();
        assert_eq!(
            (saved.page, saved.mode.as_str(), saved.direction.as_str()),
            (2, "single", "ltr")
        );

        assert_eq!(
            session.turn_to(&conn, 2, &Clock::at_ms(200)).unwrap(),
            Upload::Idle,
            "a repeat turn is not a write at all"
        );
    }

    #[test]
    fn a_thirty_page_burst_costs_one_row_and_one_upload_window() {
        let conn = open_in_memory().unwrap();
        let mut session = open(&conn, 100, &settings(), 0);
        let mut uploads = 0;
        for (index, page) in (2..=31).enumerate() {
            let clock = Clock::at_ms((index as i64) * 90);
            if session.turn_to(&conn, page, &clock).unwrap() == Upload::Now {
                uploads += 1;
                // The caller drains the outbox; mirror what it would do.
                crate::store::outbox::forget(&conn, SERVER, BOOK).unwrap();
            }
        }
        assert_eq!(
            uploads, 0,
            "interval 5000ms vs a 2700ms burst -> no traffic"
        );
        assert_eq!(
            stored_page(&conn),
            31,
            "the durable page is the last one read"
        );
        let queued = outbox::queued_for_book(&conn, SERVER, BOOK)
            .unwrap()
            .unwrap();
        assert_eq!(queued.mutation_type, "READ_PROGRESS");
        // Key order is whatever serde_json emits, so compare the document.
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&queued.payload).unwrap(),
            serde_json::json!({"bookId": "book", "page": 31, "completed": false}),
        );
    }

    #[test]
    fn close_flushes_what_the_burst_left_behind() {
        let conn = open_in_memory().unwrap();
        let mut session = open(&conn, 100, &settings(), 0);
        session.turn_to(&conn, 12, &Clock::at_ms(100)).unwrap();
        assert_eq!(
            session.close(&conn, &Clock::at_ms(900)).unwrap(),
            Upload::Now
        );
    }

    #[test]
    fn an_explicit_mark_is_never_held_by_the_throttle() {
        let conn = open_in_memory().unwrap();
        let mut session = open(&conn, 100, &settings(), 0);
        session.turn_to(&conn, 12, &Clock::at_ms(100)).unwrap();
        assert_eq!(
            session.mark_read(&conn, &Clock::at_ms(200)).unwrap(),
            Upload::Now
        );
        assert_eq!(session.outbox_state(&conn).unwrap(), Some("MARK_READ"));
        assert_eq!(
            stored_page(&conn),
            12,
            "marking read must not move the page"
        );
        let queued = outbox::queued_for_book(&conn, SERVER, BOOK)
            .unwrap()
            .unwrap();
        assert_eq!(
            outbox::intent_of(&queued.mutation_type, &queued.payload),
            Some(outbox::Intent::MarkRead),
            "the pending READ_PROGRESS was coalesced away, not queued alongside"
        );

        assert_eq!(
            session.mark_unread(&conn, &Clock::at_ms(300)).unwrap(),
            Upload::Now
        );
        assert_eq!(session.outbox_state(&conn).unwrap(), Some("MARK_UNREAD"));
        assert_eq!(
            stored_page(&conn),
            0,
            "mark unread resets the local progress"
        );
    }

    #[test]
    fn restart_restores_the_page_the_spread_and_the_debt() {
        let conn = open_in_memory().unwrap();
        let double = ReaderSettings {
            mode: ReadMode::Double,
            direction: Direction::Rtl,
            ..Default::default()
        };
        {
            let mut session = open(&conn, 30, &double, 0);
            session.turn_to(&conn, 10, &Clock::at_ms(100)).unwrap();
            session.close(&conn, &Clock::at_ms(200)).unwrap();
            crate::store::outbox::forget(&conn, SERVER, BOOK).unwrap();
        }

        // A brand new session on the same database: the layout comes back too,
        // so page 10 lands on the same spread rather than on a bare page.
        let session = open(&conn, 30, &ReaderSettings::default(), 5000);
        assert_eq!(session.page(), 10);
        assert_eq!(session.spread(), 5, "[1] [2,3] [4,5] [6,7] [8,9] [10,11]");
        assert_eq!(
            session.mode(),
            ReadMode::Double,
            "the layout comes back too"
        );
        assert_eq!(session.direction(), Direction::Rtl);
        assert_eq!(
            session.visible(),
            vec![11, 10],
            "RTL puts the reading-first page of the pair on the right"
        );
    }

    #[test]
    fn a_debt_survives_a_kill_and_is_offered_again_on_the_next_open() {
        let conn = open_in_memory().unwrap();
        {
            let mut session = open(&conn, 50, &settings(), 0);
            for page in 2..6 {
                session
                    .turn_to(&conn, page, &Clock::at_ms(page as i64 * 10))
                    .unwrap();
            }
            // No close, no flush: the process just ends.
        }
        assert_eq!(stored_page(&conn), 5);
        assert!(outbox::queued_for_book(&conn, SERVER, BOOK)
            .unwrap()
            .is_some());

        let mut reopened = open(&conn, 50, &settings(), 60_000);
        assert_eq!(reopened.page(), 5);
        assert_eq!(
            reopened.tick(&Clock::at_ms(60_001)),
            Upload::Now,
            "the first timer after a restart must be allowed to pay the old debt"
        );
    }

    #[test]
    fn restore_can_be_switched_off_and_the_layout_change_keeps_the_place() {
        let conn = open_in_memory().unwrap();
        {
            let mut session = open(&conn, 30, &settings(), 0);
            session.turn_to(&conn, 20, &Clock::at_ms(100)).unwrap();
        }
        let mut off = settings();
        off.restore_position = false;
        let fresh = open(&conn, 30, &off, 200);
        assert_eq!(fresh.page(), 1, "the user asked not to resume");

        let mut session = open(&conn, 30, &settings(), 300);
        assert_eq!(session.page(), 20);
        session
            .relayout(&conn, ReadMode::Double, Direction::Rtl, &Clock::at_ms(400))
            .unwrap();
        // firstPageSingle: [1] [2,3] [4,5] ... [2k,2k+1] -> page 20 is in [20,21].
        assert_eq!(session.spread(), 10);
        assert_eq!(
            session.page(),
            20,
            "the page that was on screen stays the current page"
        );
        assert_eq!(
            session.visible(),
            vec![21, 20],
            "reading order 20 then 21, RTL on screen reversed"
        );
        assert_eq!(
            position::get(&conn, SERVER, BOOK).unwrap().unwrap().mode,
            "double"
        );
    }

    #[test]
    fn a_non_paged_book_keeps_position_but_never_owes_a_progress_write() {
        let conn = open_in_memory().unwrap();
        let mut session = ReaderSession::open(
            &conn,
            SERVER,
            BOOK,
            25,
            false,
            &settings(),
            &Clock::at_ms(0),
        )
        .unwrap();
        session.turn_to(&conn, 4, &Clock::at_ms(100)).unwrap();
        assert_eq!(session.page(), 4);
        assert_eq!(position::get(&conn, SERVER, BOOK).unwrap().unwrap().page, 4);
        assert_eq!(
            stored_page(&conn),
            -1,
            "EPUB/PDF must not write read-progress pages"
        );
        assert_eq!(session.outbox_state(&conn).unwrap(), None);
        assert_eq!(
            session.close(&conn, &Clock::at_ms(9000)).unwrap(),
            Upload::Idle
        );
    }

    #[test]
    fn shrinking_manifest_cannot_restore_past_the_end() {
        let conn = open_in_memory().unwrap();
        {
            let mut session = open(&conn, 30, &settings(), 0);
            session.turn_to(&conn, 30, &Clock::at_ms(100)).unwrap();
        }
        // Same database, but the book now reports 12 pages.
        let session = open(&conn, 12, &settings(), 200);
        assert_eq!(session.page(), 12);
        assert_eq!(session.layout().spread_count(), 12);
    }

    #[test]
    fn empty_book_has_no_layout_and_owes_nothing() {
        let conn = open_in_memory().unwrap();
        let mut session = open(&conn, 0, &settings(), 0);
        assert_eq!(
            session.turn_to(&conn, 1, &Clock::at_ms(10)).unwrap(),
            Upload::Idle
        );
        assert_eq!(
            session.next(&conn, &Clock::at_ms(20)).unwrap(),
            Upload::Idle
        );
        assert!(session.visible().is_empty());
        assert_eq!(stored_page(&conn), -1);
    }
}
