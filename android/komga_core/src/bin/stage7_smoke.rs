//! stage7_smoke — the reader's acceptance run over real loopback HTTP.
//!
//! Each phase is a separate process so the driving script can create the exact
//! conditions the stage names — including a genuinely unreachable server and a
//! database another process already wrote. Checks are assertions that panic: the
//! evidence is this binary's exit code plus its `ok:` lines, and the page/write
//! journals the fixture server fills in are what prove *how many* requests the
//! reader made, not merely that the data ended up right.
//!
//!   --phase open      正常打开漫画: manifest -> SQLite mirror -> page bytes.
//!                     Also proves page N's image really is page N (the fixture
//!                     encodes the number in the PNG width) and that the
//!                     mirrored pages_count agrees with the manifest.
//!   --phase modes     单页 / 双页 / 条漫 x LTR / RTL / Vertical from the live
//!                     page count, plus the settings that drive them.
//!   --phase flip      快速翻页: a 30-turn burst costs 30 local writes, ONE
//!                     outbox row, and zero requests until the throttle says so.
//!   --phase reopen    重启后恢复位置: a new process on the same files restores
//!                     the page AND the layout, and reads the manifest and every
//!                     warm page out of local storage with no network at all.
//!   --phase offline   断网后继续阅读已缓存页面: unreachable server, cached
//!                     pages keep loading, an uncached page fails as a network
//!                     error, and reading still reaches SQLite.
//!   --phase prefetch  相邻页预取: the window ahead lands on disk, a warm
//!                     window costs nothing.
//!   --phase sync      阅读状态最终同步 Komga: READ_PROGRESS, MARK_READ and
//!                     MARK_UNREAD each reach the server as themselves.
//!   --phase live-reader
//!                     the same open/read/sync round-trip against a REAL Komga:
//!                     the manifest's reported dimensions must match the pixels
//!                     it actually serves, and the book's own progress is put
//!                     back exactly as it was found.
//!
//! Usage (the script owns these; --server-id defaults to A):
//!   cargo run --bin stage7_smoke -- --phase open \
//!     --db /tmp/s7.sqlite --cache /tmp/s7-cache \
//!     --base-url http://127.0.0.1:PORT --key fixture-key --book book-3-3

use std::time::{Duration, SystemTime};

use komga_core::api::auth::AuthMethod;
use komga_core::api::error::ApiError;
use komga_core::api::mutation::ProgressWriter;
use komga_core::api::page::PageStreaming;
use komga_core::api::series::KomgaClient;
use komga_core::cache::demo_png::page_dimensions;
use komga_core::model::book::Book;
use komga_core::reader::cache::PageCache;
use komga_core::reader::loader::{LoaderError, PageSource, ReaderLoader, Source};
use komga_core::reader::manifest::{PageManifest, RawPage};
use komga_core::reader::paging::{Direction, ReadMode};
use komga_core::reader::prefetch::Window;
use komga_core::reader::session::{Clock, ReaderSession, Upload};
use komga_core::reader::settings::{Background, ReaderSettings};
use komga_core::store::{self, books, outbox, position, read_progress};

use komga_core::store::outbox::Refetch;
use rusqlite::Connection;

#[derive(Default)]
struct Args {
    db: String,
    cache: String,
    base_url: String,
    offline_url: String,
    key: String,
    phase: String,
    book: String,
    server: String,
}

type Smoke = Result<(), Box<dyn std::error::Error>>;

fn main() {
    let args = parse();
    let outcome: Smoke = match args.phase.as_str() {
        "open" => phase_open(&args),
        "modes" => phase_modes(&args),
        "flip" => phase_flip(&args),
        "reopen" => phase_reopen(&args),
        "offline" => phase_offline(&args),
        "prefetch" => phase_prefetch(&args),
        "sync" => phase_sync(&args),
        "live-reader" => phase_live_reader(&args),
        other => panic!("unknown --phase {other}"),
    };
    match outcome {
        Ok(()) => println!("ok: phase {} passed", args.phase),
        Err(error) => panic!("phase {} failed: {error}", args.phase),
    }
}

fn parse() -> Args {
    let argv: Vec<String> = std::env::args().collect();
    let mut args = Args {
        book: "book-3-3".to_string(),
        server: "A".to_string(),
        ..Default::default()
    };
    let mut i = 1;
    while i + 1 < argv.len() {
        match argv[i].as_str() {
            "--db" => args.db = argv[i + 1].clone(),
            "--cache" => args.cache = argv[i + 1].clone(),
            "--base-url" => args.base_url = argv[i + 1].clone(),
            "--offline-url" => args.offline_url = argv[i + 1].clone(),
            "--key" => args.key = argv[i + 1].clone(),
            "--phase" => args.phase = argv[i + 1].clone(),
            "--book" => args.book = argv[i + 1].clone(),
            "--server-id" => args.server = argv[i + 1].clone(),
            other => panic!("unknown arg {other}"),
        }
        i += 2;
    }
    assert!(!args.db.is_empty(), "--db is required");
    assert!(!args.cache.is_empty(), "--cache is required");
    assert!(!args.key.is_empty(), "--key is required");
    args
}

fn block_on<F: std::future::Future>(future: F) -> F::Output {
    static RT: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_all()
            .build()
            .expect("runtime")
    })
    .block_on(future)
}

fn open_store(args: &Args) -> Connection {
    store::open(&args.db).expect("open store")
}

fn client(args: &Args, base_url: &str) -> KomgaClient {
    KomgaClient::new(
        base_url.to_string(),
        AuthMethod::ApiKey {
            key: args.key.to_string(),
        },
    )
    .expect("client")
}

fn page_cache(args: &Args) -> PageCache {
    PageCache::new(&args.cache).expect("page cache")
}

/// The transport adapter. The reader core never sees a client: this is the one
/// place the two meet, and it is deliberately in the harness rather than in
/// `reader`, which is what keeps the "no network in the UI" rule checkable.
struct HttpPages {
    client: KomgaClient,
}

impl PageSource for HttpPages {
    fn fetch_pages(&mut self, book_id: &str) -> Result<Vec<RawPage>, LoaderError> {
        let pages = block_on(self.client.pages(book_id)).map_err(to_loader)?;
        Ok(pages
            .iter()
            .map(|page| RawPage {
                file_name: page.file_name.clone(),
                media_type: page.media_type.clone(),
                number: i64::from(page.number),
                width: page.width.map(i64::from),
                height: page.height.map(i64::from),
                size_bytes: page.size_bytes,
            })
            .collect())
    }

    fn fetch_page(&mut self, book_id: &str, number: u32) -> Result<(Vec<u8>, String), LoaderError> {
        block_on(self.client.page_bytes(book_id, number)).map_err(to_loader)
    }
}

fn to_loader(error: ApiError) -> LoaderError {
    LoaderError::Network(error.to_string())
}

/// Mirror one book so the reader has the same rows the UI would show it from.
fn seed_book(args: &Args, conn: &Connection) -> Result<Book, Box<dyn std::error::Error>> {
    if let Some(existing) = block_on(client(args, &args.base_url).book(&args.book))? {
        books::save_books_batch(conn, &args.server, std::slice::from_ref(&existing))?;
        return Ok(existing);
    }
    panic!("book {} is not in the fixture snapshot", args.book);
}

fn mirrored_media_type(conn: &Connection, args: &Args) -> Option<String> {
    conn.query_row(
        "SELECT media_type FROM books WHERE server_id = ?1 AND remote_id = ?2",
        rusqlite::params![args.server, args.book],
        |row| row.get(0),
    )
    .ok()
    .flatten()
}

/// Rebuild the manifest from its mirror and normalize it the same way the
/// loader does. Whether a book may report page numbers is a property of its
/// PAGES, not of its container: a cbz is `application/vnd.comicbook+zip` and is
/// entirely image-paged, while an epub is not.
fn mirrored_manifest(conn: &Connection, args: &Args) -> PageManifest {
    PageManifest::from_rows(
        &args.server,
        &args.book,
        mirrored_media_type(conn, args).as_deref(),
        &store::pages::list(conn, &args.server, &args.book).unwrap_or_default(),
    )
}

/// PNG width as the file on disk actually declares it.
fn decoded_width(path: &std::path::Path) -> Result<u32, Box<dyn std::error::Error>> {
    let bytes = std::fs::read(path)?;
    if bytes.len() < 24
        || &bytes[0..8] != [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A].as_slice()
    {
        return Err("cached page is not a PNG".into());
    }
    Ok(u32::from_be_bytes([
        bytes[16], bytes[17], bytes[18], bytes[19],
    ]))
}

fn clock(ms: i64) -> Clock {
    let real = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_millis() as i64;
    Clock {
        rfc3339: format!("{:0>20}", real + ms),
        ms: real + ms,
    }
}

// --------------------------------------------------------------------- open ---
fn phase_open(args: &Args) -> Smoke {
    let conn = open_store(args);
    let book = seed_book(args, &conn)?;
    let mirrored_pages = book.media.as_ref().and_then(|media| media.pages_count);

    let mut loader = ReaderLoader::open(
        &conn,
        &args.server,
        &args.book,
        book.media
            .as_ref()
            .and_then(|media| media.media_type.as_deref()),
        HttpPages {
            client: client(args, &args.base_url),
        },
        page_cache(args),
        &clock(0).rfc3339,
        false,
    )?;
    let count = loader.page_count();
    assert!(count > 0, "a fixture book must have pages");
    assert_eq!(
        mirrored_pages.map(|pages| pages as u32),
        Some(count),
        "the mirrored pages_count and the page manifest must not disagree"
    );
    assert!(
        loader.manifest().is_paged(),
        "{:?} must be image-paged for the reader",
        book.media
            .as_ref()
            .and_then(|media| media.media_type.as_ref())
    );
    assert_eq!(
        loader.manifest().drift,
        0,
        "the fixture numbers 1-based pages"
    );

    // Every descriptor matches the bytes the image endpoint will serve.
    for number in [1u32, 2, count] {
        let descriptor = loader.manifest().get(number).expect("descriptor");
        let (width, height) = page_dimensions(number);
        assert_eq!((descriptor.width, descriptor.height), (width, height));
        let page = loader.page(&conn, number, &clock(0).rfc3339)?;
        assert_eq!(page.source, Source::Network, "cold page {number}");
        assert_eq!(
            decoded_width(&page.path)?,
            width,
            "the file cached as page {number} must BE page {number}"
        );
        // The cached file must be what the manifest promised, byte for byte.
        assert_eq!(page.size, std::fs::metadata(&page.path)?.len() as i64);
    }
    assert_eq!(
        loader.page(&conn, count + 1, &clock(0).rfc3339).err(),
        Some(LoaderError::OutOfRange {
            page: count + 1,
            page_count: count
        }),
        "asking past the end is an error, not a clamped image"
    );
    println!(
        "  manifest mirrored: {count} pages, {} bytes on disk",
        loader.cache().bytes_used(&conn)?
    );
    Ok(())
}

// -------------------------------------------------------------------- modes ---
fn phase_modes(args: &Args) -> Smoke {
    let conn = open_store(args);
    let manifest = mirrored_manifest(&conn, args);
    let pages = manifest.page_count();
    assert!(pages > 0, "run --phase open first");

    // Three modes x three directions, from the contract's own table.
    for mode in [ReadMode::Single, ReadMode::Double, ReadMode::Webtoon] {
        for direction in [Direction::Ltr, Direction::Rtl, Direction::Vertical] {
            let settings = ReaderSettings {
                mode,
                direction,
                ..Default::default()
            };
            let session = ReaderSession::open(
                &conn,
                &args.server,
                &args.book,
                pages,
                manifest.writes_page_progress(),
                &settings,
                &clock(0),
            )?;
            let layout = session.layout();
            let flat: Vec<u32> = layout.spreads.iter().flatten().copied().collect();
            assert_eq!(
                flat,
                (1..=pages).collect::<Vec<u32>>(),
                "{mode:?}/{direction:?}"
            );
            let pairing_pages = match mode {
                ReadMode::Single | ReadMode::Webtoon => pages as usize,
                // firstPageSingle is on by default: [1] then pairs from page 2.
                ReadMode::Double => (pages as usize) / 2 + 1,
            };
            assert_eq!(
                layout.spread_count(),
                pairing_pages,
                "{mode:?} spread count"
            );
            assert_eq!(
                layout.axis.as_str(),
                if mode == ReadMode::Webtoon || direction == Direction::Vertical {
                    "vertical"
                } else {
                    "horizontal"
                }
            );
            assert_eq!(
                layout.reversed,
                direction == Direction::Rtl && mode != ReadMode::Webtoon
            );
        }
    }

    // Double-page RTL: the pair's reading-first page sits on the right.
    let double_rtl = ReaderSettings {
        mode: ReadMode::Double,
        direction: Direction::Rtl,
        first_page_single: false,
        ..Default::default()
    };
    let session = ReaderSession::open(
        &conn,
        &args.server,
        &args.book,
        pages,
        manifest.writes_page_progress(),
        &double_rtl,
        &clock(0),
    )?;
    assert_eq!(
        session.visible(),
        vec![2, 1],
        "spread 0 is pages 1|2, right-first"
    );
    assert_eq!(session.layout().nav().advance.as_str(), "right");
    assert_eq!(session.layout().nav().tap_next.as_str(), "left");

    // Settings persistence: the six knobs must survive a reopen of the store.
    let wanted = ReaderSettings {
        mode: ReadMode::Webtoon,
        direction: Direction::Vertical,
        // webtoon forces this off on save (see `sanitized`), so ask for off
        first_page_single: false,
        page_gap: 24,
        background: Background::White,
        keep_screen_awake: false,
        brightness: Some(0.35),
        restore_position: true,
        ..Default::default()
    };
    ReaderSettings::save(&conn, &wanted)?;
    assert_eq!(ReaderSettings::load(&conn)?, wanted);
    ReaderSettings::save(&conn, &ReaderSettings::default())?;
    assert_eq!(ReaderSettings::load(&conn)?, ReaderSettings::default());
    println!("  9 mode/direction layouts + settings round-trip");
    Ok(())
}

// --------------------------------------------------------------------- flip ---
fn phase_flip(args: &Args) -> Smoke {
    let conn = open_store(args);
    let manifest = mirrored_manifest(&conn, args);
    let pages = manifest.page_count();
    assert!(pages > 0, "run --phase open first");
    let settings = ReaderSettings::default();
    let mut session = ReaderSession::open(
        &conn,
        &args.server,
        &args.book,
        pages,
        manifest.writes_page_progress(),
        &settings,
        &clock(0),
    )?;

    // 30 turns where the book allows it; a 24-page book gives 23. Either way it
    // is a burst, and the last page is the last one the book has.
    let target = 31u32.min(pages);
    let turns = target - 1;
    let mut uploads = 0;
    for (index, page) in (2..=target).enumerate() {
        if session.turn_to(&conn, page, &clock(index as i64 * 80))? == Upload::Now {
            uploads += 1;
        }
    }
    assert_eq!(session.page(), target);
    assert_eq!(
        uploads, 0,
        "a {turns}-page burst must not start {uploads} requests"
    );
    let queued =
        outbox::queued_for_book(&conn, &args.server, &args.book)?.expect("one coalesced row");
    assert_eq!(queued.mutation_type, "READ_PROGRESS");
    let stored =
        read_progress::stored_progress(&conn, &args.server, &args.book)?.expect("row written");
    assert_eq!(
        stored.page,
        i64::from(target),
        "the durable page is the last read"
    );
    assert!(
        PageCache::new(&args.cache)?.bytes_used(&conn)? > 0,
        "the pages cached by the open phase must still be there"
    );

    // The reader closes: the position goes out, and only then may it be sent.
    assert_eq!(session.close(&conn, &clock(9_000))?, Upload::Now);
    let sent = drain_outbox(args, &conn);
    assert_eq!(sent, 1, "exactly one request carried the whole burst");
    assert!(outbox::queued_for_book(&conn, &args.server, &args.book)?.is_none());
    println!("  {turns} turns -> 1 outbox row -> 1 request (page {target})");
    Ok(())
}

/// Drain the outbox the way the app does, and report how many rows left.
fn drain_outbox(args: &Args, conn: &Connection) -> usize {
    let http = client(args, &args.base_url);
    let now = clock(0).rfc3339;
    block_on(komga_core::sync::upload::upload_outbox(
        conn,
        &args.server,
        &http,
        &now,
    ))
    .map(|summary| summary.uploaded)
    .unwrap_or_else(|error| panic!("upload failed: {error}"))
}

// ------------------------------------------------------------------- reopen ---
fn phase_reopen(args: &Args) -> Smoke {
    let conn = open_store(args);
    let manifest = mirrored_manifest(&conn, args);
    let pages = manifest.page_count();
    let left_off = position::get(&conn, &args.server, &args.book)?.expect("flip saved a position");

    // A new process on the same two files, with the server still reachable:
    // reopening must be a pure local operation. The driver script proves the
    // "no request" half by diffing the server's page journal across this phase.
    let mut loader = ReaderLoader::open(
        &conn,
        &args.server,
        &args.book,
        Some("image/jpeg"),
        HttpPages {
            client: client(args, &args.base_url),
        },
        page_cache(args),
        &clock(0).rfc3339,
        false,
    )?;
    assert_eq!(
        loader.manifest_source(),
        komga_core::reader::loader::ManifestSource::Mirror,
        "the manifest must come from SQLite, not the network"
    );
    assert_eq!(loader.page_count(), pages);
    // The page the reader was left on must be the page it lands on again, and
    // it must come off disk: that is the whole point of "reopen where you were".
    let back_to = left_off.page.max(1) as u32;
    let page = loader.page(&conn, back_to, &clock(0).rfc3339)?;
    assert_eq!(
        page.source,
        Source::Cache,
        "page {back_to} must still be cached"
    );
    assert_eq!(decoded_width(&page.path)?, page_dimensions(back_to).0);

    let session = ReaderSession::open(
        &conn,
        &args.server,
        &args.book,
        pages,
        manifest.writes_page_progress(),
        &ReaderSettings::default(),
        &clock(0),
    )?;
    assert_eq!(
        session.page() as i64,
        left_off.page,
        "the reader must come back to where it was left"
    );
    assert_eq!(session.mode().as_str(), left_off.mode);
    assert_eq!(session.direction().as_str(), left_off.direction);
    println!(
        "  reopened offline at page {} ({}/{}) with no request",
        session.page(),
        session.spread() + 1,
        session.layout().spread_count()
    );
    Ok(())
}

/// PNG / JPEG dimensions straight out of the header, no image crate.
fn sniff_image_size(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.len() > 24 && bytes[0..8] == [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A] {
        return Some((
            u32::from_be_bytes([bytes[16], bytes[17], bytes[18], bytes[19]]),
            u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]),
        ));
    }
    if bytes.len() < 4 || bytes[0..2] != [0xFF, 0xD8] {
        return None;
    }
    // JPEG: walk the marker chain to a start-of-frame (C0..CF, minus the two
    // that carry no frame header).
    let mut index = 2usize;
    while index + 9 < bytes.len() {
        if bytes[index] != 0xFF {
            index += 1;
            continue;
        }
        let marker = bytes[index + 1];
        if matches!(marker, 0xD8 | 0x01 | 0x00) || (0xD0..=0xD7).contains(&marker) {
            index += 2;
            continue;
        }
        let is_sof = (0xC0..=0xCF).contains(&marker) && !matches!(marker, 0xC4 | 0xC8 | 0xCC);
        let height = u32::from(u16::from_be_bytes([bytes[index + 5], bytes[index + 6]]));
        let width = u32::from(u16::from_be_bytes([bytes[index + 7], bytes[index + 8]]));
        if is_sof && width > 0 && height > 0 {
            return Some((width, height));
        }
        let length = usize::from(u16::from_be_bytes([bytes[index + 2], bytes[index + 3]]));
        if length < 2 {
            return None;
        }
        index += 2 + length;
    }
    None
}

/// 真实服务器: open a real book, read a page, sync a page turn, restore it.
fn phase_live_reader(args: &Args) -> Smoke {
    let conn = open_store(args);
    let book = seed_book(args, &conn)?;
    let media_type = book
        .media
        .as_ref()
        .and_then(|media| media.media_type.clone())
        .unwrap_or_default();
    let declared = book
        .media
        .as_ref()
        .and_then(|media| media.pages_count)
        .unwrap_or(0);
    let original = block_on(client(args, &args.base_url).refetch(&args.book));

    let mut loader = ReaderLoader::open(
        &conn,
        &args.server,
        &args.book,
        Some(&media_type),
        HttpPages {
            client: client(args, &args.base_url),
        },
        page_cache(args),
        &clock(0).rfc3339,
        true,
    )?;
    let count = loader.page_count();
    println!(
        "  live book {}: {count} pages, media {media_type}",
        args.book
    );
    if declared > 0 {
        assert_eq!(
            declared as u32, count,
            "media.pagesCount and GET /pages must agree on a real server"
        );
    }

    // The reported page dimensions must be the dimensions actually served.
    let probes = [1u32, (count / 2).max(1), count];
    let mut checked = 0;
    for number in probes {
        let (reported_width, reported_height) = loader
            .manifest()
            .get(number)
            .map(|descriptor| (descriptor.width, descriptor.height))
            .expect("descriptor");
        let page = loader.page(&conn, number, &clock(0).rfc3339)?;
        let bytes = std::fs::read(&page.path)?;
        assert!(!bytes.is_empty(), "page {number} served no bytes");
        if let Some((width, height)) = sniff_image_size(&bytes) {
            assert_eq!(
                (width, height),
                (reported_width, reported_height),
                "page {number}: the manifest promised {reported_width}x{reported_height} but served {width}x{height}"
            );
            checked += 1;
        }
        assert_eq!(
            loader.page(&conn, number, &clock(0).rfc3339)?.source,
            Source::Cache,
            "the second read of page {number} must come off disk"
        );
    }

    // A page turn reaches the real server, then the book is put back.
    let mut session = ReaderSession::open(
        &conn,
        &args.server,
        &args.book,
        count,
        loader.manifest().writes_page_progress(),
        &ReaderSettings::default(),
        &clock(0),
    )?;
    let probe_page = (count / 3).max(1);
    session.turn_to(&conn, probe_page, &clock(100))?;
    session.close(&conn, &clock(200))?;
    assert!(
        drain_outbox(args, &conn) >= 1,
        "the turn must be accepted by the real endpoint"
    );
    match block_on(client(args, &args.base_url).refetch(&args.book)) {
        Refetch::Found(found) => assert_eq!(
            found.page,
            Some(i64::from(probe_page)),
            "the server must hold the page the reader wrote"
        ),
        other => panic!("real refetch failed: {other:?}"),
    }

    // Restore whatever the user had, so the run is data-preserving.
    match original {
        Refetch::Found(found) => {
            read_progress::upsert_synced_read_progress(
                &conn,
                &args.server,
                &args.book,
                found.page,
                found.completed,
                found.last_modified.clone(),
            )?;
            read_progress::upsert_local_read_progress(
                &conn,
                &args.server,
                &args.book,
                found.page.unwrap_or(0),
                found.completed,
            )?;
            drain_outbox(args, &conn);
            let back = block_on(client(args, &args.base_url).refetch(&args.book));
            match back {
                Refetch::Found(restored) => assert_eq!(
                    (restored.page, restored.completed),
                    (found.page, found.completed),
                    "the book must end where it started"
                ),
                other => panic!("restore refetch failed: {other:?}"),
            }
        }
        Refetch::NotFound => {
            read_progress::mark_unread(&conn, &args.server, &args.book)?;
            drain_outbox(args, &conn);
        }
        other => panic!("unreadable starting progress: {other:?}"),
    }
    println!("  live: {checked} page dimension(s) verified against real pixels, progress restored");
    Ok(())
}

fn mirrored_page_count(conn: &Connection, args: &Args) -> u32 {
    conn.query_row(
        "SELECT COUNT(*) FROM book_pages WHERE server_id = ?1 AND book_id = ?2",
        rusqlite::params![args.server, args.book],
        |row| row.get::<_, i64>(0),
    )
    .unwrap_or(0) as u32
}

// ------------------------------------------------------------------ offline ---
fn phase_offline(args: &Args) -> Smoke {
    let conn = open_store(args);
    let manifest = mirrored_manifest(&conn, args);
    let pages = manifest.page_count();
    let mut loader = ReaderLoader::open(
        &conn,
        &args.server,
        &args.book,
        mirrored_media_type(&conn, args).as_deref(),
        HttpPages {
            client: client(args, &args.offline_url),
        },
        page_cache(args),
        &clock(0).rfc3339,
        false,
    )?;
    let cached = loader.cached_pages(&conn);
    assert!(!cached.is_empty(), "earlier phases warmed the cache");

    // Keep reading through the outage: every warm page must render.
    for number in 1..=pages {
        match loader.page(&conn, number, &clock(0).rfc3339) {
            Ok(page) if cached.contains(&number) => {
                assert_eq!(page.source, Source::Cache, "page {number}");
                assert!(page.path.exists());
            }
            Err(LoaderError::Network(_)) => {
                assert!(!cached.contains(&number), "page {number} was cached");
            }
            other => panic!("unexpected outcome for page {number}: {other:?}"),
        }
    }
    // The first cold page is where the outage becomes visible — and it is a
    // per-page network error, never a broken book.
    let first_cold = (1..=pages).find(|number| !cached.contains(number));
    if let Some(number) = first_cold {
        assert!(matches!(
            loader.page(&conn, number, &clock(0).rfc3339),
            Err(LoaderError::Network(_))
        ));
    }

    // Reading while offline is still durable: the position and the outbox row
    // are both local writes.
    let before = position::get(&conn, &args.server, &args.book)?.map(|saved| saved.page);
    let mut session = ReaderSession::open(
        &conn,
        &args.server,
        &args.book,
        pages,
        manifest.writes_page_progress(),
        &ReaderSettings::default(),
        &clock(0),
    )?;
    let target = (pages / 2).max(1);
    session.turn_to(&conn, target, &clock(100))?;
    let after = position::get(&conn, &args.server, &args.book)?.map(|saved| saved.page);
    assert_eq!(after, Some(target as i64), "position moved while offline");
    assert_ne!(after, before, "the test would pass without moving");
    assert_eq!(
        read_progress::stored_progress(&conn, &args.server, &args.book)?
            .unwrap()
            .page,
        target as i64
    );
    assert!(outbox::queued_for_book(&conn, &args.server, &args.book)?.is_some());
    assert_eq!(
        session.close(&conn, &clock(200))?,
        Upload::Now,
        "close offers the queued page even though the server is unreachable"
    );
    println!(
        "  offline: {} cached pages readable, position durable at {target}",
        cached.len()
    );
    Ok(())
}

// ----------------------------------------------------------------- prefetch ---
fn phase_prefetch(args: &Args) -> Smoke {
    let conn = open_store(args);
    let manifest = mirrored_manifest(&conn, args);
    let pages = manifest.page_count();
    let mut loader = ReaderLoader::open(
        &conn,
        &args.server,
        &args.book,
        Some("image/jpeg"),
        HttpPages {
            client: client(args, &args.base_url),
        },
        page_cache(args),
        &clock(0).rfc3339,
        false,
    )?;
    let spreads = loader
        .layout_for(ReadMode::Single, Direction::Ltr, false)
        .spreads;
    let window = Window {
        forward: 2,
        back: 1,
        cap: 12,
    };

    // Walk the book a spread at a time; the visible page is always warm.
    let mut cold_hits = 0;
    for center in 0..spreads.len().min(12) {
        let report = loader.prefetch(&conn, &spreads, center, window, &clock(0).rfc3339)?;
        let visible = spreads[center][0];
        if !report.requested.is_empty()
            && report.requested[0] != visible
            && !loader.cached_pages(&conn).contains(&visible)
        {
            cold_hits += 1;
        }
        assert!(
            report.failed.is_empty(),
            "a live server must not fail the window: {:?}",
            report.failed
        );
    }
    assert_eq!(cold_hits, 0, "the visible page was never left cold");

    // The whole window is warm now: a second pass must issue nothing.
    let idle = loader.prefetch(&conn, &spreads, 6, window, &clock(0).rfc3339)?;
    assert!(
        idle.requested.is_empty(),
        "a warm window still queued {idle:?}"
    );
    assert_eq!(idle.loaded, Vec::<u32>::new());

    // And the next spread over was pulled ahead of the reader getting there.
    let cached = loader.cached_pages(&conn);
    for number in 1..=8u32 {
        assert!(
            cached.contains(&number),
            "page {number} should be prefetched"
        );
    }
    println!(
        "  prefetch: {} of {pages} pages on disk before the reader asked for them",
        cached.len()
    );
    Ok(())
}

// --------------------------------------------------------------------- sync ---
fn phase_sync(args: &Args) -> Smoke {
    let conn = open_store(args);
    let pages = mirrored_page_count(&conn, args);
    let server = args.server.clone();
    let book = args.book.clone();

    // 1. a plain page write
    read_progress::upsert_local_read_progress(&conn, &server, &book, 17, false)?;
    assert_eq!(drain_outbox(args, &conn), 1);
    let remote = block_on(client(args, &args.base_url).refetch(&book));
    assert!(
        matches!(&remote, Refetch::Found(found) if found.page == Some(17)),
        "read-progress page 17 must reach the server: {remote:?}"
    );

    // 2. MARK_READ: an explicit statement, and deliberately no page field, so
    //    the server keeps the page it already has.
    read_progress::mark_read(&conn, &server, &book)?;
    assert_eq!(drain_outbox(args, &conn), 1);
    let remote = block_on(client(args, &args.base_url).refetch(&book));
    match remote {
        Refetch::Found(found) => {
            assert!(found.completed, "the mark must reach the server: {found:?}");
            assert_eq!(
                found.page,
                Some(17),
                "MARK_READ must not rewrite the server's page"
            );
        }
        other => panic!("expected the server to hold the book, got {other:?}"),
    }
    // Marking read kept the local page too.
    assert_eq!(
        read_progress::stored_progress(&conn, &server, &book)?
            .unwrap()
            .page,
        17
    );

    // 3. MARK_UNREAD: a DELETE, which clears the server's progress entirely.
    read_progress::mark_unread(&conn, &server, &book)?;
    assert_eq!(drain_outbox(args, &conn), 1);
    let remote = block_on(client(args, &args.base_url).refetch(&book));
    match remote {
        Refetch::Found(found) => {
            assert!(
                !found.completed,
                "mark unread must clear completed: {found:?}"
            );
        }
        other => panic!("expected the server to hold the book, got {other:?}"),
    }
    assert_eq!(
        read_progress::stored_progress(&conn, &server, &book)?
            .unwrap()
            .page,
        0
    );

    // Three statements, three distinct requests, no residue in the outbox.
    assert!(outbox::queued_for_book(&conn, &server, &book)?.is_none());
    let counts = outbox::counts(&conn, &server, &clock(0).rfc3339)?;
    assert_eq!(counts.pending + counts.waiting + counts.failed, 0);
    println!("  READ_PROGRESS / MARK_READ / MARK_UNREAD each synced over {pages}-page book {book}");
    Ok(())
}
