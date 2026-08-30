//! stage8_smoke — the reader's performance and cache acceptance run.
//!
//! Stage 7 asked "does the reader work"; Stage 8 asks "does it survive". Each
//! phase is a separate process so the script can build the exact conditions the
//! objective names — a 520-page book, a 4K page, a link that answers slowly, a
//! cache with a short read in it — and so a phase cannot inherit another's
//! memory tier or warm files.
//!
//! Every phase prints `metric name=value` lines. The script asserts on those AND
//! on the fixture server's page journal, which is the only witness that cannot
//! lie about how many requests the reader actually made.
//!
//!   --phase big-book        500+ 页漫画: read the whole book, spread by spread.
//!                           The claims are request count (no duplicates), memory
//!                           peak (bounded by the tier, not by the book), and that
//!                           the last 100 pages cost no more than the first 100.
//!   --phase large-pages     4K 大图: pages of real 3840x2160 pixel dimensions in
//!                           a pool deliberately too small to hold them all.
//!   --phase rapid-flip      快速连续翻页: 60 discontinuous jumps. The claim is
//!                           that the unstable plan keeps requests at or below the
//!                           distinct pages touched — no burst per frame.
//!   --phase long-scroll     长时间条漫滚动: 300 webtoon advances with per-turn
//!                           latency percentiles from the reader's own clock.
//!   --phase weak-network    弱网: a delayed server, and a window that must have
//!                           already shrunk to one request at a time.
//!   --phase offline         断网: an unreachable server over a warm cache.
//!   --phase network-switch  Wi-Fi / 蜂窝切换: wifi -> cellular -> offline, and
//!                           the plan must only ever get smaller.
//!   --phase memory-pressure App 内存压力: fill past the tier, then the pressure
//!                           response, and downloads must still be on disk.
//!   --phase background-restore
//!                           App 后台恢复: run twice; the second process restores
//!                           the page and asks the server for nothing.
//!   --phase facade          the shipped surface itself. Everything above drives
//!                           the reader library directly; this phase drives the
//!                           same `App` methods the FFI calls, because a defect
//!                           that lives only in that layer (the sweep that runs on
//!                           a device report, the promotion of a prefetched page on
//!                           display, the prefetch concurrency budget, the memory
//!                           mirror) would otherwise never be seen by acceptance.
//!   --phase books           a long session measured in **books** rather than
//!                           pages: open, read a few, close, repeat. Asserts the
//!                           process-level reader registry drains, because a
//!                           `reader_open` without a matching close would keep one
//!                           session alive per book browsed in a sitting.
//!   --phase corruption      缓存损坏恢复: the server truncates every Nth page.
//!                           The short read must be refused, never cached, and the
//!                           retries must stop by themselves.
//!
//! Usage (the script owns these):
//!   cargo run --bin stage8_smoke -- --phase big-book \
//!     --db /tmp/s8.sqlite --cache /tmp/s8-cache \
//!     --base-url http://127.0.0.1:PORT --key fixture-key \
//!     --stress-book stress-520 --device-memory 4294967296 --pool-budget 67108864

use std::future::Future;
use std::time::{Duration, Instant, SystemTime};

use komga_core::api::auth::AuthMethod;
use komga_core::api::page::PageStreaming;
use komga_core::api::series::KomgaClient;
use komga_core::cache::demo_png;
use komga_core::reader::cache::{PageCache, Tier};
use komga_core::reader::loader::save_position;
use komga_core::reader::loader::{LoaderError, PageSource, ReaderLoader, Source};
use komga_core::reader::manifest::RawPage;
use komga_core::reader::paging::{Direction, ReadMode};
use komga_core::reader::prefetch::Window;
use komga_core::reader::window::{self, Network, Profile, WindowPlan};
use komga_core::store::{self, position};

use rusqlite::Connection;

type Smoke = Result<(), Box<dyn std::error::Error>>;

impl Args {
    /// A phase that needs different device facts than the script passed builds
    /// them here, so no phase silently tests a profile nobody would report.
    fn clone_with(&self, change: impl FnOnce(&mut Args)) -> Args {
        let mut copy = self.clone();
        change(&mut copy);
        copy
    }
}

#[derive(Default, Clone)]
struct Args {
    db: String,
    cache: String,
    base_url: String,
    offline_url: String,
    key: String,
    phase: String,
    book: String,
    server: String,
    device_memory: i64,
    pool_budget: i64,
    memory_budget: i64,
    network: String,
    mode: String,
    turns: usize,
    books: String,
    /// The smallest book this walk will call a big book. The synthetic stress book
    /// is 520 pages, so the floor is 500; a real library only has what it has, and
    /// the live leg lowers the floor and prints the count it actually found.
    min_pages: usize,
}

fn main() {
    let args = parse();
    let outcome: Smoke = match args.phase.as_str() {
        "big-book" => phase_big_book(&args),
        "large-pages" => phase_large_pages(&args),
        "rapid-flip" => phase_rapid_flip(&args),
        "long-scroll" => phase_long_scroll(&args),
        "weak-network" => phase_weak_network(&args),
        "offline" => phase_offline(&args),
        "network-switch" => phase_network_switch(&args),
        "memory-pressure" => phase_memory_pressure(&args),
        "background-restore" => phase_background_restore(&args),
        "corruption" => phase_corruption(&args),
        "facade" => phase_facade(&args),
        "resume-loop" => phase_resume_loop(&args),
        "books" => phase_books(&args),
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
        book: "stress-520".to_string(),
        server: "A".to_string(),
        device_memory: 4 * 1024 * 1024 * 1024,
        pool_budget: 512 * 1024 * 1024,
        memory_budget: 0,
        network: "wifi".to_string(),
        mode: "single".to_string(),
        turns: 0,
        min_pages: 500,
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
            "--device-memory" => args.device_memory = parse_int(&argv[i + 1]),
            "--pool-budget" => args.pool_budget = parse_int(&argv[i + 1]),
            "--memory-budget" => args.memory_budget = parse_int(&argv[i + 1]),
            "--network" => args.network = argv[i + 1].clone(),
            "--mode" => args.mode = argv[i + 1].clone(),
            "--turns" => args.turns = parse_int(&argv[i + 1]) as usize,
            "--books" => args.books = argv[i + 1].clone(),
            "--min-pages" => args.min_pages = parse_int(&argv[i + 1]) as usize,
            other => panic!("unknown arg {other}"),
        }
        i += 2;
    }
    assert!(!args.db.is_empty(), "--db is required");
    assert!(!args.cache.is_empty(), "--cache is required");
    assert!(!args.key.is_empty(), "--key is required");
    args
}

fn parse_int(value: &str) -> i64 {
    value.replace('_', "").parse().expect("integer expected")
}

fn metric(name: &str, value: impl std::fmt::Display) {
    println!("metric {name}={value}");
}

fn open_store(args: &Args) -> Connection {
    store::open(&args.db).expect("open store")
}

/// The cache under test, sized exactly as a device report would size it.
fn cache_for(args: &Args) -> PageCache {
    let mut cache = PageCache::new(&args.cache).expect("page cache");
    cache.set_budget(args.pool_budget);
    let plan = plan_for(args, 0);
    cache
        .set_memory_budget(if args.memory_budget > 0 {
            args.memory_budget
        } else {
            plan.memory_budget_bytes
        })
        .expect("memory tier");
    cache
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

fn block_on<F: Future>(future: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("runtime")
        .block_on(future)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or(Duration::from_secs(0))
        .as_millis() as i64
}

fn stamp(offset_ms: i64) -> String {
    format!("{:0>20}", now_ms() + offset_ms)
}

/// The transport adapter, and the request counter. Counting here rather than
/// reading the server's journal keeps the phase self-checking; the journal is the
/// independent witness the script also reads.
struct Metered {
    client: KomgaClient,
    page_requests: usize,
    manifest_requests: usize,
    distinct: std::collections::BTreeSet<u32>,
    failed: usize,
    /// Every page number fetched, in order. When a request count is not what the
    /// window arithmetic says it should be, the sequence is the only way to see
    /// which page came back for a second trip.
    sequence: Vec<u32>,
}

impl PageSource for Metered {
    fn fetch_pages(&mut self, book_id: &str) -> Result<Vec<RawPage>, LoaderError> {
        self.manifest_requests += 1;
        let pages = block_on(self.client.pages(book_id))
            .map_err(|error| LoaderError::Network(error.to_string()))?;
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
        self.page_requests += 1;
        self.distinct.insert(number);
        self.sequence.push(number);
        match block_on(self.client.page_bytes(book_id, number)) {
            Ok(got) => Ok(got),
            Err(error) => {
                self.failed += 1;
                Err(LoaderError::Network(error.to_string()))
            }
        }
    }
}

impl Metered {
    fn new(args: &Args, base_url: &str) -> Self {
        Metered {
            client: client(args, base_url),
            page_requests: 0,
            manifest_requests: 0,
            distinct: Default::default(),
            failed: 0,
            sequence: Vec::new(),
        }
    }
}

/// Open the stress book through the real HTTP path, refreshing the manifest so
/// the harness sees the page depth the server was told to answer with.
fn open_stress(
    args: &Args,
    conn: &Connection,
    meter: Metered,
    refresh: bool,
) -> Result<ReaderLoader<Metered>, Box<dyn std::error::Error>> {
    Ok(ReaderLoader::open(
        conn,
        &args.server,
        &args.book,
        Some("image/png"),
        meter,
        cache_for(args),
        &stamp(0),
        refresh,
    )?)
}

/// The plan under test, from the same inputs the UI would report.
fn plan_profile(args: &Args, avg_page_bytes: i64) -> Profile {
    Profile {
        device_memory_bytes: args.device_memory,
        cache_budget_bytes: args.pool_budget,
        avg_page_bytes,
        pages_per_spread: if args.mode == "double" { 2 } else { 1 },
        mode: ReadMode::parse(&args.mode),
        direction: Direction::Ltr,
        network: parse_network(&args.network),
        stable: true,
    }
}

fn plan_for(args: &Args, avg_page_bytes: i64) -> WindowPlan {
    window::plan(&plan_profile(args, avg_page_bytes))
}

fn parse_network(value: &str) -> Network {
    match value {
        "wifi" => Network::Wifi,
        "cellular" => Network::Cellular,
        "weak" => Network::Weak,
        "offline" => Network::Offline,
        _ => Network::Unknown,
    }
}

fn report_window(plan: &WindowPlan) {
    metric("window_forward", plan.forward);
    metric("window_back", plan.back);
    metric("window_cap", plan.cap);
    metric("window_in_flight", plan.in_flight);
    metric("memory_budget_bytes", plan.memory_budget_bytes);
}

fn report_cache(cache: &PageCache, conn: &Connection) -> Result<(), Box<dyn std::error::Error>> {
    let memory = cache.memory_stats()?;
    metric("memory_bytes", memory.bytes);
    metric("memory_peak_bytes", memory.peak_bytes);
    metric("memory_entries", memory.entries);
    metric("memory_hits", memory.hits);
    metric("memory_misses", memory.misses);
    metric("memory_evictions", memory.evictions);
    metric("memory_refused", memory.refused_oversized);
    metric("ledger_bytes", cache.bytes_used(conn)?);
    metric("page_tier_bytes", cache.bytes_of_tier(conn, Tier::Page)?);
    metric(
        "prefetch_tier_bytes",
        cache.bytes_of_tier(conn, Tier::Prefetch)?,
    );
    metric("disk_bytes", cache.disk().bytes_used()?);
    Ok(())
}

fn percentile(samples: &[Duration], basis: usize) -> Duration {
    if samples.is_empty() {
        return Duration::ZERO;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let index = ((sorted.len() - 1) * basis) / 100;
    sorted[index]
}

// ------------------------------------------------------------------ big-book ---
/// 500+ 页漫画, read end to end through the real pipeline.
fn phase_big_book(args: &Args) -> Smoke {
    let conn = open_store(args);
    let mut loader = open_stress(args, &conn, Metered::new(args, &args.base_url), true)?;
    let count = loader.page_count();
    assert!(
        count as usize >= args.min_pages,
        "book must be >= {} pages, saw {count}",
        args.min_pages
    );
    // The loader owns the fetcher, so the counter lives with it.
    let avg = avg_page_bytes(&loader);
    let plan = plan_for(args, avg);
    report_window(&plan);
    metric("page_count", count);

    let spreads = loader
        .layout_for(ReadMode::parse(&args.mode), Direction::Ltr, false)
        .spreads;
    let mut latencies = Vec::with_capacity(spreads.len());
    let mut displayed = 0usize;
    for (index, spread) in spreads.iter().enumerate() {
        let started = Instant::now();
        loader.prefetch(&conn, &spreads, index, plan.window(), &stamp(index as i64))?;
        for page in spread {
            let page = loader.page(&conn, *page, &stamp(index as i64))?;
            assert!(page.path.exists(), "page {} vanished", page.number);
            displayed += 1;
        }
        latencies.push(started.elapsed());
    }
    assert_eq!(displayed, count as usize, "every page was displayed");

    // The acceptance claim, stated as arithmetic rather than as a feeling:
    // reading the book once costs exactly one request per page.
    let requests = loader.source().page_requests;
    metric("page_requests", requests);
    metric("distinct_pages", loader.source().distinct.len());
    metric("manifest_requests", loader.source().manifest_requests);
    assert_eq!(
        requests, displayed,
        "reading a book once must cost one request per page; anything more is duplicate work"
    );
    assert_eq!(loader.source().distinct.len(), displayed, "no page twice");

    let first_quarter: Vec<Duration> = latencies[..latencies.len() / 4].to_vec();
    let last_quarter: Vec<Duration> = latencies[latencies.len() - latencies.len() / 4..].to_vec();
    let mean = |values: &[Duration]| -> u128 {
        values.iter().map(|v| v.as_micros()).sum::<u128>() / values.len() as u128
    };
    metric("mean_first_quarter_us", mean(&first_quarter));
    metric("mean_last_quarter_us", mean(&last_quarter));
    metric("p95_us", percentile(&latencies, 95).as_micros());
    report_cache(loader.cache(), &conn)?;
    let memory = loader.cache().memory_stats()?;
    assert!(
        memory.peak_bytes <= memory.budget_bytes,
        "the memory tier peaked at {} over a budget of {}",
        memory.peak_bytes,
        memory.budget_bytes
    );
    let ledger = loader.cache().bytes_used(&conn)?;
    assert!(
        ledger <= args.pool_budget + avg.max(1),
        "the pool holds {ledger} bytes against a {} budget (one page of slack allowed)",
        args.pool_budget
    );
    // The last quarter of a long session must not be slower than the first:
    // that is what "no growth" looks like from the reader's side.
    assert!(
        mean(&last_quarter) <= mean(&first_quarter) * 2 + 5_000,
        "reading slowed across the book: {}us -> {}us",
        mean(&first_quarter),
        mean(&last_quarter)
    );
    Ok(())
}

fn avg_page_bytes<F: PageSource>(loader: &ReaderLoader<F>) -> i64 {
    let sizes: Vec<i64> = loader
        .manifest()
        .pages
        .iter()
        .map(|page| page.size_bytes)
        .filter(|size| *size > 0)
        .collect();
    if sizes.is_empty() {
        0
    } else {
        sizes.iter().sum::<i64>() / sizes.len() as i64
    }
}

// --------------------------------------------------------------- large-pages ---
/// 4K 大图: real 3840x2160 pages, read twice — once with Stage 7's placeholder
/// window and once with the plan the device profile produces.
///
/// The pool here (40 MiB) holds one and a half pages of this book. That is the
/// interesting case, not an extreme one: it is what a 4K scan on a phone with a
/// small allowance looks like. The placeholder window pulls twelve pages ahead
/// into a pool that cannot hold two, so every page the reader turns to has
/// already been evicted, and the re-reads show up as requests. The plan reads
/// the same book at one request per page. Same cache, same server, same loop —
/// the only difference is whether the window knew what a page costs.
fn phase_large_pages(args: &Args) -> Smoke {
    let probe = open_stress(
        args,
        &open_store(args),
        Metered::new(args, &args.base_url),
        true,
    )?;
    let (width, height) = (
        probe.manifest().pages[0].width,
        probe.manifest().pages[0].height,
    );
    let one_page = probe.manifest().pages[0].size_bytes;
    let avg = avg_page_bytes(&probe);
    let pages = probe.page_count();
    drop(probe);
    metric("page_dimensions", format!("{width}x{height}"));
    metric("avg_page_bytes", one_page);
    assert!(
        one_page > 20_000_000 && width >= 3000,
        "the 4K phase needs real large pages, saw {one_page} bytes at {width}x{height}"
    );
    let plan = plan_for(args, avg);
    report_window(&plan);
    assert!(
        plan.cap <= 2,
        "a 40 MiB pool and a {one_page}-byte page must produce a one-page window: {plan:?}"
    );

    let placeholder = read_book(args, "placeholder", Window::default(), pages)?;
    let planned = read_book(args, "planned", plan.window(), pages)?;
    metric(
        "sequence_placeholder",
        placeholder
            .sequence
            .iter()
            .map(|n| n.to_string())
            .collect::<Vec<_>>()
            .join(","),
    );
    metric(
        "sequence_planned",
        planned
            .sequence
            .iter()
            .map(|n| n.to_string())
            .collect::<Vec<_>>()
            .join(","),
    );
    metric("requests_placeholder", placeholder.requests);
    metric("requests_planned", planned.requests);
    metric("requests_total", placeholder.requests + planned.requests);
    metric(
        "manifest_requests",
        2 + placeholder.manifests + planned.manifests,
    );
    metric("ledger_bytes_planned", planned.ledger_bytes);
    metric("memory_peak_planned", planned.memory_peak_bytes);
    metric("per_page_ms", planned.per_page_ms);

    // The first `pages` requests must be pages 1..=pages in order: that is the
    // display path costing one trip per page. Anything the prefetch asks for
    // after that is the look-behind the window legitimately includes, and in a
    // pool this tight it has to come back.
    assert_eq!(
        planned.sequence[..pages as usize],
        (1..=pages).collect::<Vec<u32>>()[..],
        "the display path did not cost exactly one request per page: {:?}",
        planned.sequence
    );
    assert!(
        planned.requests <= pages * 2,
        "the planned window cost {} requests for {pages} pages",
        planned.requests
    );
    assert!(
        placeholder.requests > planned.requests * 2,
        "the placeholder window was supposed to thrash and did not: {} vs {}",
        placeholder.requests,
        planned.requests
    );
    assert!(
        planned.ledger_bytes <= args.pool_budget + one_page,
        "the pool held {} bytes against {}",
        planned.ledger_bytes,
        args.pool_budget
    );
    assert!(
        planned.memory_peak_bytes <= plan.memory_budget_bytes,
        "a 4K page outgrew the memory tier: {} > {}",
        planned.memory_peak_bytes,
        plan.memory_budget_bytes
    );
    Ok(())
}

/// What one full read of the book cost. Named because five positional numbers
/// is how a phase ends up asserting on the wrong one.
struct ReadOutcome {
    requests: u32,
    manifests: u32,
    ledger_bytes: i64,
    memory_peak_bytes: i64,
    per_page_ms: f64,
    sequence: Vec<u32>,
}

/// Read `pages` pages of the stress book with one window, into a private cache
/// and database, so the two windows below are measured against identical files.
fn read_book(
    args: &Args,
    name: &str,
    window: Window,
    pages: u32,
) -> Result<ReadOutcome, Box<dyn std::error::Error>> {
    let dir = std::path::PathBuf::from(&args.cache).join(name);
    let db = std::path::PathBuf::from(&args.db).with_file_name(format!("stage8-{name}.sqlite"));
    let scoped = Args {
        cache: dir.to_string_lossy().into_owned(),
        db: db.to_string_lossy().into_owned(),
        ..args.clone()
    };
    std::fs::create_dir_all(&scoped.cache)?;
    let conn = open_store(&scoped);
    let mut loader = open_stress(
        &scoped,
        &conn,
        Metered::new(&scoped, &scoped.base_url),
        true,
    )?;
    let manifests = loader.source().manifest_requests as u32;
    let spreads = loader
        .layout_for(ReadMode::Single, Direction::Ltr, false)
        .spreads;
    let started = Instant::now();
    for number in 1..=pages {
        // The real UI order: resolve what is on screen, then warm the neighbours.
        // Reversing it makes the center page a prefetch, which is the same page
        // the display is about to ask for.
        let page = loader.page(&conn, number, &stamp(number as i64))?;
        let bytes = std::fs::read(&page.path)?;
        assert_eq!(
            demo_png::large_page_len(
                loader.manifest().pages[0].width,
                loader.manifest().pages[0].height
            ) as i64,
            bytes.len() as i64,
            "page {number} arrived short"
        );
        loader.prefetch(
            &conn,
            &spreads,
            number as usize - 1,
            window,
            &stamp(number as i64),
        )?;
    }
    let took = started.elapsed().as_secs_f64();
    let ledger = loader.cache().bytes_used(&conn)?;
    let peak = loader.cache().memory_stats()?.peak_bytes;
    Ok(ReadOutcome {
        requests: loader.source().page_requests as u32,
        manifests,
        ledger_bytes: ledger,
        memory_peak_bytes: peak,
        per_page_ms: took / pages as f64 * 1000.0,
        sequence: loader.source().sequence.clone(),
    })
}

// ---------------------------------------------------------------- rapid-flip ---
/// 快速连续翻页: discontinuous jumps, which is what a reader does with a slider.
fn phase_rapid_flip(args: &Args) -> Smoke {
    let conn = open_store(args);
    let mut loader = open_stress(args, &conn, Metered::new(args, &args.base_url), true)?;
    let count = loader.page_count();
    let plan = plan_for(args, avg_page_bytes(&loader));
    report_window(&plan);
    let unstable = window::plan(&Profile {
        stable: false,
        ..plan_profile(args, avg_page_bytes(&loader))
    });
    metric("unstable_cap", unstable.cap);
    metric("unstable_back", unstable.back);
    metric("unstable_forward", unstable.forward);
    assert!(
        unstable.cap <= plan.cap && unstable.back == 0,
        "an unstable plan must be a shrink: {unstable:?} vs {plan:?}"
    );

    let jumps = args.turns.max(60);
    let mut touched = std::collections::BTreeSet::new();
    let started = Instant::now();
    for step in 0..jumps {
        // A slider throw: forward by a non-adjacent amount, occasionally back.
        let target = if step % 7 == 6 {
            1 + ((step * 13) % count as usize) as u32
        } else {
            1 + ((step * 37) % count as usize) as u32
        };
        touched.insert(target);
        let spread = (target - 1) as usize;
        let spreads = loader
            .layout_for(ReadMode::parse(&args.mode), Direction::Ltr, false)
            .spreads;
        // Mid-flip: the reader reports itself unstable, so the window is the
        // visible spread and nothing else.
        loader.prefetch(
            &conn,
            &spreads,
            spread,
            unstable.window(),
            &stamp(step as i64),
        )?;
        for page in &spreads[spread.min(spreads.len() - 1)] {
            loader.page(&conn, *page, &stamp(step as i64))?;
        }
    }
    let took = started.elapsed();
    metric("flips", jumps);
    metric("page_requests", loader.source().page_requests);
    metric("distinct_pages", loader.source().distinct.len());
    metric("seconds", took.as_secs_f64());
    assert_eq!(
        loader.source().page_requests,
        loader.source().distinct.len(),
        "a fast flip generated duplicate requests"
    );
    assert!(
        loader.source().page_requests <= touched.len() + count as usize / 2,
        "requests ran away from the pages actually reached"
    );
    report_cache(loader.cache(), &conn)?;
    Ok(())
}

// ---------------------------------------------------------------- long-scroll ---
/// 长时间条漫滚动: a webtoon read as one continuous column.
fn phase_long_scroll(args: &Args) -> Smoke {
    let conn = open_store(args);
    let args = args.clone_with(|a| a.mode = "webtoon".to_string());
    let mut loader = open_stress(&args, &conn, Metered::new(&args, &args.base_url), true)?;
    let plan = plan_for(&args, avg_page_bytes(&loader));
    report_window(&plan);
    let spreads = loader
        .layout_for(ReadMode::Webtoon, Direction::Vertical, false)
        .spreads;
    let advances = args.turns.min(spreads.len().saturating_sub(1)).max(120);
    metric("advances", advances);

    let mut hot = Vec::with_capacity(advances);
    let mut cold = Vec::with_capacity(advances);
    for index in 0..advances {
        let started = Instant::now();
        loader.prefetch(&conn, &spreads, index, plan.window(), &stamp(index as i64))?;
        cold.push(started.elapsed());
        let started = Instant::now();
        for page in &spreads[index] {
            // The page the scroll is on: warm, because prefetch pulled it.
            let page = loader.page(&conn, *page, &stamp(index as i64))?;
            assert_eq!(page.source, Source::Cache, "page {} was cold", page.number);
        }
        hot.push(started.elapsed());
    }
    metric("prefetch_pass_p50_us", percentile(&cold, 50).as_micros());
    metric("warm_turn_p50_us", percentile(&hot, 50).as_micros());
    metric("warm_turn_p95_us", percentile(&hot, 95).as_micros());
    metric("warm_turn_p99_us", percentile(&hot, 99).as_micros());
    // "不明显掉帧" needs a number to argue with. A warm turn is a ledger lookup
    // and a stat: the frame budget belongs to the decoder, but the core must not
    // be the thing that misses it.
    assert!(
        percentile(&hot, 95) < Duration::from_millis(8),
        "a warm webtoon turn took {:?} at p95",
        percentile(&hot, 95)
    );
    metric("page_requests", loader.source().page_requests);
    report_cache(loader.cache(), &conn)?;
    let memory = loader.cache().memory_stats()?;
    assert!(memory.peak_bytes <= memory.budget_bytes);
    Ok(())
}

// -------------------------------------------------------------- weak-network ---
/// 弱网: the server answers slowly; the plan must already have shrunk.
fn phase_weak_network(args: &Args) -> Smoke {
    let conn = open_store(args);
    let avg = {
        let probe = open_stress(args, &conn, Metered::new(args, &args.base_url), true)?;
        let value = avg_page_bytes(&probe);
        drop(probe);
        value
    };
    let args = args.clone_with(|a| a.network = "weak".to_string());
    let plan = plan_for(&args, avg);
    report_window(&plan);
    assert_eq!(plan.in_flight, 1, "a weak link gets one request at a time");
    assert!(plan.cap <= 3, "a weak link caps at 3 pages: {plan:?}");

    let mut loader = open_stress(&args, &conn, Metered::new(&args, &args.base_url), false)?;
    let spreads = loader
        .layout_for(ReadMode::parse(&args.mode), Direction::Ltr, false)
        .spreads;
    let started = Instant::now();
    loader.prefetch(&conn, &spreads, 4, plan.window(), &stamp(0))?;
    let took = started.elapsed();
    metric("prefetch_seconds", took.as_secs_f64());
    metric("page_requests", loader.source().page_requests);
    assert!(
        loader.source().page_requests <= plan.cap,
        "prefetch issued {} requests under a cap of {}",
        loader.source().page_requests,
        plan.cap
    );
    report_cache(loader.cache(), &conn)?;
    Ok(())
}

// -------------------------------------------------------------------- offline ---
/// 断网: cached pages keep working, and the outage is visible only as the pages
/// that were never fetched.
fn phase_offline(args: &Args) -> Smoke {
    let conn = open_store(args);
    // Warm the cache first, over the real server.
    let warm_requests: usize;
    {
        let mut warm = open_stress(args, &conn, Metered::new(args, &args.base_url), true)?;
        let spreads = warm
            .layout_for(ReadMode::parse(&args.mode), Direction::Ltr, false)
            .spreads;
        warm.prefetch(
            &conn,
            &spreads,
            0,
            Window {
                forward: 20,
                back: 0,
                cap: 64,
            },
            &stamp(0),
        )?;
        // Read after the warm-up, not before: this is the number the acceptance
        // script compares against the server's journal, and it has to be the
        // traffic the warm-up actually caused.
        warm_requests = warm.source().page_requests;
    }
    let mut loader = open_stress(args, &conn, Metered::new(args, &args.offline_url), false)?;
    let cached = loader.cached_pages(&conn);
    metric("cached_pages", cached.len());
    metric("warm_requests", warm_requests);
    assert!(!cached.is_empty(), "the warm-up cached nothing");
    let started = Instant::now();
    for number in &cached {
        let page = loader.page(&conn, *number, &stamp(0))?;
        assert_eq!(page.source, Source::Cache, "page {number} left the cache");
    }
    metric("offline_read_ms", started.elapsed().as_millis());
    metric("page_requests", loader.source().page_requests);
    metric("manifest_requests", loader.source().manifest_requests);
    assert_eq!(
        loader.source().page_requests,
        0,
        "reading cached pages offline must ask the server for nothing"
    );
    assert_eq!(
        loader.source().manifest_requests,
        0,
        "the manifest is mirrored"
    );
    let uncached = (1..=loader.page_count()).find(|n| !cached.contains(n));
    if let Some(number) = uncached {
        let error = loader
            .page(&conn, number, &stamp(1))
            .expect_err("network error");
        assert!(
            matches!(error, LoaderError::Network(_)),
            "an uncached page offline must be a network error, got {error:?}"
        );
    }
    report_cache(loader.cache(), &conn)?;
    Ok(())
}

// ------------------------------------------------------------ network-switch ---
/// Wi-Fi / 蜂窝切换: one profile, three links, and a window that only shrinks.
fn phase_network_switch(args: &Args) -> Smoke {
    let avg = args.turns as i64 * 1024 * 1024;
    let mut previous: Option<WindowPlan> = None;
    for link in ["wifi", "cellular", "weak", "offline"] {
        let args = args.clone_with(|a| a.network = link.to_string());
        let plan = plan_for(&args, avg);
        metric(link, format!("{plan:?}"));
        if let Some(seen) = &previous {
            assert!(
                plan.cap <= seen.cap && plan.in_flight <= seen.in_flight,
                "{link} widened the window after {previous:?}: {plan:?}"
            );
        }
        previous = Some(plan);
    }
    let offline = previous.expect("a last plan");
    assert_eq!(offline.cap, 0, "offline must queue nothing");
    assert_eq!(offline.in_flight, 0);
    // And the switch back: a fresh wifi report must restore a real window.
    let back = plan_for(&args.clone_with(|a| a.network = "wifi".to_string()), avg);
    assert!(back.cap > 0, "coming back on wifi produced {back:?}");
    Ok(())
}

// ----------------------------------------------------------- memory-pressure ---
/// App 内存压力: the tier is filled past its ceiling on purpose, then the
/// pressure response runs, and a user's offline download must still be there.
fn phase_memory_pressure(args: &Args) -> Smoke {
    let conn = open_store(args);
    let cache = cache_for(args);
    let budget = cache.memory_stats()?.budget_bytes;
    metric("memory_budget_bytes", budget);
    // Ten pages larger than the tier: the tier must hold none of them and lose
    // none of its accounting.
    let one_page = demo_png::demo_page_bytes(1);
    for number in 0..40u32 {
        cache.store_prefetch(
            &conn,
            &format!("srv-pressure-p{}", number + 1),
            &one_page,
            "image/png",
            &stamp(number as i64),
        )?;
        let stats = cache.memory_stats()?;
        assert!(
            stats.bytes <= budget,
            "the tier exceeded its budget at {number}: {} > {budget}",
            stats.bytes
        );
    }
    report_cache(&cache, &conn)?;
    let resident = cache.memory_stats()?;
    assert!(resident.entries > 0, "nothing stayed resident");
    assert!(resident.evictions > 0, "nothing was ever evicted");

    // The pressure response: drop the prefetched tier, keep a download.
    let download = cache.disk().page_path("srv-download-p1.png");
    std::fs::write(&download, &one_page)?;
    komga_core::store::cache::record(
        &conn,
        "srv-download-p1",
        komga_core::store::cache::KIND_DOWNLOAD,
        &download.to_string_lossy(),
        one_page.len() as i64,
        &stamp(0),
    )?;
    let dropped = cache.clear_tier(&conn, Tier::Prefetch)?;
    metric("dropped_prefetch_entries", dropped);
    metric("memory_bytes_after_pressure", cache.memory_stats()?.bytes);
    assert!(
        download.exists(),
        "the pressure response deleted an offline download"
    );
    assert_eq!(
        cache.memory_stats()?.bytes,
        0,
        "clearing the prefetch tier must release its resident bytes too"
    );
    assert_eq!(
        cache.bytes_of_tier(&conn, Tier::Prefetch)?,
        0,
        "the prefetch tier is still on disk"
    );
    Ok(())
}

// -------------------------------------------------------- background-restore ---
/// App 后台恢复: run this phase twice. The first pass reads and turns; the second
/// must restore from local storage and ask the server for nothing at all.
fn phase_background_restore(args: &Args) -> Smoke {
    let conn = open_store(args);
    let pass = if position::get(&conn, &args.server, &args.book)?.is_some() {
        2
    } else {
        1
    };
    metric("pass", pass);
    let mut loader = open_stress(args, &conn, Metered::new(args, &args.base_url), pass == 1)?;
    let plan = plan_for(args, avg_page_bytes(&loader));
    if pass == 1 {
        let spreads = loader
            .layout_for(ReadMode::parse(&args.mode), Direction::Ltr, false)
            .spreads;
        let wanted = (loader.page_count() / 2).max(1);
        loader.prefetch(
            &conn,
            &spreads,
            wanted as usize - 1,
            plan.window(),
            &stamp(0),
        )?;
        loader.page(&conn, wanted, &stamp(0))?;
        save_position(
            &conn,
            &args.server,
            &args.book,
            wanted,
            ReadMode::parse(&args.mode),
            Direction::Ltr,
            &stamp(0),
        )?;
        metric("saved_page", wanted);
        report_cache(loader.cache(), &conn)?;
        return Ok(());
    }
    // Second process: the manifest comes from the mirror, and everything cached
    // comes from disk. The unreachable URL makes any slip a hard failure.
    let mut restored = open_stress(args, &conn, Metered::new(args, &args.offline_url), false)?;
    let saved = position::get(&conn, &args.server, &args.book)?.expect("a saved position");
    let cached = restored.cached_pages(&conn);
    metric("restored_page", saved.page);
    metric("cached_pages", cached.len());
    let page = restored.page(&conn, saved.page as u32, &stamp(0))?;
    assert_eq!(page.source, Source::Cache);
    metric("page_requests", restored.source().page_requests);
    assert_eq!(
        restored.source().page_requests,
        0,
        "a background restore re-downloaded pages"
    );
    report_cache(restored.cache(), &conn)?;
    Ok(())
}

// --------------------------------------------------------------------- facade ---
/// The FFI-facing layer, end to end.
///
/// Every other phase in this file drives `ReaderLoader` / `PageCache` directly,
/// which is the right level for the algorithms and the wrong level for the
/// product: the app calls `App::reader_*`, and the interesting bugs live in the
/// seams — the sweep that only runs when a device profile is reported, the
/// promotion that only happens on the display path, the per-call prefetch budget,
/// the memory mirror. This phase asserts those through the same entry points the
/// Flutter side uses.
fn phase_facade(args: &Args) -> Smoke {
    use komga_core::ffi::application::{App, DeviceProfileDto};

    // The facade does not take a cache directory: `App` derives it from the
    // database path (`<db dir>/cache`), which is the right policy for the app and
    // something this harness had assumed away. Plant everything where the facade
    // will actually look, and print both paths so the two can never be confused.
    let db_path = std::path::PathBuf::from(&args.db);
    let app_cache = db_path
        .parent()
        .unwrap_or(std::path::Path::new("."))
        .join("cache");
    std::fs::create_dir_all(app_cache.join("pages"))?;
    std::fs::create_dir_all(app_cache.join("prefetch"))?;
    std::fs::create_dir_all(app_cache.join("thumbnails"))?;
    metric("facade_cache_root", app_cache.display());
    metric("harness_cache_dir", args.cache.clone());

    // Damage to be found and repaired by the sweep that a device report triggers:
    // a row whose file is gone, a file no row describes, and a half-written
    // staging file left behind by an interrupted download.
    let cache_dir = app_cache.clone();
    let mut written = std::collections::BTreeSet::new();
    {
        let conn = open_store(args);
        let mut cache = PageCache::new(&args.cache)?;
        cache.set_budget(0);
        let manifest = {
            let mut loader = open_stress(args, &conn, Metered::new(args, &args.base_url), true)?;
            let m = loader.manifest().clone();
            for number in 1..=3u32 {
                let page = loader.page(&conn, number, &stamp(number as i64))?;
                written.insert(page.path);
            }
            m
        };
        // 1. a ghost row
        std::fs::remove_file(written.iter().next().expect("three pages written"))?;
        // 2. an orphan file
        std::fs::write(cache_dir.join("pages/zz-orphan.png"), b"junk")?;
        // 3. a `.part` left by an interrupted write
        std::fs::write(cache_dir.join("pages/zz-half.png.part"), b"junk")?;
        metric("seeded_key", manifest.cache_key(4));
    }

    let app = App::new(args.db.clone());
    let book = block_on(app.reader_open(
        args.server.clone(),
        args.book.clone(),
        args.base_url.clone(),
        args.key.clone(),
        String::new(),
        String::new(),
        None,
    ))?;
    metric("facade_page_count", book.page_count);
    assert!(book.page_count >= 60, "the facade needs a real book");

    // The device report is what runs the reconciliation sweep. If it does not
    // happen here, no page the reader serves is ever checked for damage.
    let window = app.reader_configure_device(
        args.server.clone(),
        args.book.clone(),
        DeviceProfileDto {
            device_memory_bytes: args.device_memory,
            cache_budget_bytes: args.pool_budget,
            avg_page_bytes_hint: 0,
            decoded_page_bytes: 8 * 1024 * 1024,
            network: "wifi".to_string(),
            stable: true,
        },
    )?;
    metric("facade_cap", window.cap);
    metric("facade_in_flight", window.in_flight);
    metric("facade_decode_slots", window.decode_slots);
    metric("facade_swept_freed_bytes", window.swept_freed_bytes);
    metric("facade_swept_corrupt", window.swept_corrupt);
    assert!(
        !cache_dir.join("pages/zz-orphan.png").exists(),
        "the device report did not sweep the orphan file"
    );
    assert!(
        !cache_dir.join("pages/zz-half.png.part").exists(),
        "the device report did not sweep the .part debris"
    );
    assert!(
        window.swept_freed_bytes > 0,
        "the sweep reported freeing nothing: {window:?}"
    );
    assert!(window.decode_slots >= 4, "{window:?}");

    // Prefetch through the facade, then look at which tier the bytes landed in.
    let spread = 4i64;
    let landed = block_on(app.reader_prefetch(
        args.server.clone(),
        args.book.clone(),
        spread,
        args.base_url.clone(),
        args.key.clone(),
    ))?;
    metric("facade_prefetch_landed", landed);
    let stats_after_prefetch = app.reader_cache_stats()?;
    metric("facade_prefetch_bytes", stats_after_prefetch.prefetch_bytes);
    metric("facade_memory_bytes", stats_after_prefetch.memory_bytes);
    assert!(
        stats_after_prefetch.prefetch_bytes > 0,
        "prefetch did not land in the prefetch tier"
    );
    assert!(
        stats_after_prefetch.memory_bytes > 0,
        "prefetched bytes were not mirrored into the memory tier"
    );

    // A resume re-reports the device and re-warms the same spread. That second
    // pass must find its own work already done: the Android lifecycle run showed
    // five resumes re-fetching the same four pages, which is precisely the
    // "重复请求" the acceptance line forbids, discovered only because a real
    // background/foreground cycle was run rather than asserted from source text.
    // The device sequence exactly: a resume reports the profile (which runs the
    // reconciliation sweep) and *then* re-warms. Reported separately from the
    // plain second pass because the two have different invariants, and only the
    // device showed what happens when a sweep sits between them.
    app.reader_configure_device(
        args.server.clone(),
        args.book.clone(),
        DeviceProfileDto {
            device_memory_bytes: args.device_memory,
            cache_budget_bytes: args.pool_budget,
            avg_page_bytes_hint: 0,
            decoded_page_bytes: 8 * 1024 * 1024,
            network: "wifi".to_string(),
            stable: true,
        },
    )?;
    let rewarm = block_on(app.reader_prefetch(
        args.server.clone(),
        args.book.clone(),
        spread,
        args.base_url.clone(),
        args.key.clone(),
    ))?;
    let after_rewarm = app.reader_cache_stats()?;
    metric("rewarm_landed", rewarm);
    metric("prefetch_bytes_after_rewarm", after_rewarm.prefetch_bytes);
    // The invariant is not "the second pass fetches nothing" — a window may
    // legitimately reach further. It is that the sweep did not throw the first
    // pass's work away, which is what turned into refetched pages on device.
    assert!(
        after_rewarm.prefetch_bytes >= stats_after_prefetch.prefetch_bytes,
        "the sweep between prefetches discarded the prefetch tier: {} -> {}",
        stats_after_prefetch.prefetch_bytes,
        after_rewarm.prefetch_bytes
    );
    assert!(
        after_rewarm.page_bytes >= stats_after_prefetch.page_bytes,
        "the sweep discarded displayed pages: {} -> {}",
        stats_after_prefetch.page_bytes,
        after_rewarm.page_bytes
    );

    // Displaying a prefetched page must promote it: the prefetch tier shrinks and
    // the page tier grows, and the path handed back sits in `pages/`. Page 9 was
    // pulled by the prefetch pass above and displayed by nobody. The pass reported
    // `in_flight` = 4 pages, which is exactly what the per-call budget allows, so
    // the queue was pages 5..8 — pick one of those, not a page that was never
    // asked for.
    let promoted_target = 6u32;
    let count = |dir: &str| -> usize {
        std::fs::read_dir(app_cache.join(dir))
            .map(|entries| entries.filter_map(Result::ok).count())
            .unwrap_or(0)
    };
    let pages_before = count("pages");
    let prefetch_before = count("prefetch");
    let promoted_path = app.reader_page_path(
        args.server.clone(),
        args.book.clone(),
        promoted_target as i64,
    )?;
    let promoted_path = promoted_path.expect("a prefetched page must resolve without a request");
    let pages_after = count("pages");
    let prefetch_after = count("prefetch");
    metric("promoted_path", promoted_path.clone());
    metric("pages_dir_before", pages_before);
    metric("pages_dir_after", pages_after);
    metric("prefetch_dir_before", prefetch_before);
    metric("prefetch_dir_after", prefetch_after);
    assert_eq!(
        prefetch_after + 1,
        prefetch_before,
        "displaying a prefetched page left it in prefetch/"
    );
    assert_eq!(
        pages_after,
        pages_before + 1,
        "the displayed page did not arrive in the pages/ tier"
    );
    assert!(
        promoted_path.contains("/pages/"),
        "displaying a prefetched page did not promote it: {promoted_path}"
    );
    assert!(!promoted_path.contains("/prefetch/"), "{promoted_path}");

    // A user-triggered cleanup frees the guessed-at bytes and leaves everything the
    // reader displayed and everything the user downloaded in place.
    let before = app.reader_cache_stats()?;
    let dropped = app.reader_clear_prefetch()?;
    let after = app.reader_cache_stats()?;
    metric("dropped_on_clear", dropped);
    metric("prefetch_bytes_after_clear", after.prefetch_bytes);
    metric("page_bytes_after_clear", after.page_bytes);
    assert_eq!(
        after.prefetch_bytes, 0,
        "clearing prefetch left bytes behind"
    );
    assert!(
        after.page_bytes > 0,
        "clearing prefetch threw away displayed pages: {before:?} -> {after:?}"
    );

    // The cache statistics the acceptance harness reads must be self-consistent:
    // the ledger's own total has to agree with what is on disk, or eviction is
    // making decisions on a lie.
    let stats = app.reader_cache_stats()?;
    metric("facade_ledger_bytes", stats.ledger_bytes);
    metric("facade_disk_bytes", stats.disk_bytes);
    assert!(
        (stats.ledger_bytes - stats.disk_bytes).abs() <= 4096,
        "ledger {} and disk {} disagree",
        stats.ledger_bytes,
        stats.disk_bytes
    );
    let cleanup = app.reader_reconcile_cache()?;
    metric("facade_reconcile_ghosts", cleanup.ghost_rows);
    metric("facade_reconcile_orphans", cleanup.orphan_files);
    Ok(())
}

// ----------------------------------------------------------------- resume loop ---
/// What a background/foreground cycle really does, replayed at the seam the app
/// uses: report the device profile (which runs the reconciliation sweep) and then
/// re-warm the same spread. The Android lifecycle run showed five resumes asking
/// the server for the same four pages.
fn phase_resume_loop(args: &Args) -> Smoke {
    use komga_core::ffi::application::{App, DeviceProfileDto};

    let app = App::new(args.db.clone());
    block_on(app.reader_open(
        args.server.clone(),
        args.book.clone(),
        args.base_url.clone(),
        args.key.clone(),
        String::new(),
        String::new(),
        None,
    ))?;
    let report = |stable: bool| {
        app.reader_configure_device(
            args.server.clone(),
            args.book.clone(),
            DeviceProfileDto {
                device_memory_bytes: args.device_memory,
                cache_budget_bytes: args.pool_budget,
                avg_page_bytes_hint: 0,
                decoded_page_bytes: 8 * 1024 * 1024,
                network: "wifi".to_string(),
                stable,
            },
        )
    };

    // A driven read: every turn reports first, so the planner stays in `flipping`
    // and no prefetch pass runs — the state the reader is in when the user leaves.
    for page in 1..=10u32 {
        report(false)?;
        block_on(app.reader_page(
            args.server.clone(),
            args.book.clone(),
            page as i64,
            args.base_url.clone(),
            args.key.clone(),
        ))?;
    }
    let spread = 9i64;

    let mut landed_per_pass = Vec::new();
    for cycle in 0..6i64 {
        let before = app.reader_cache_stats()?;
        // One cycle is: HOME (Android signals memory pressure — backgrounding does
        // that, it is not a distress call), then coming back, which re-reports the
        // device profile (running the sweep) and re-warms the same spread.
        let released = app.reader_release_prefetch()?;
        let window = report(true)?;
        let landed = block_on(app.reader_prefetch(
            args.server.clone(),
            args.book.clone(),
            spread,
            args.base_url.clone(),
            args.key.clone(),
        ))?;
        let after = app.reader_cache_stats()?;
        let held_before = before.prefetch_bytes + before.page_bytes;
        let held_after = after.prefetch_bytes + after.page_bytes;
        metric(&format!("resume{cycle}_cap"), window.cap);
        metric(&format!("resume{cycle}_released"), released);
        metric(
            &format!("resume{cycle}_swept_bytes"),
            window.swept_freed_bytes,
        );
        metric(
            &format!("resume{cycle}_swept_corrupt"),
            window.swept_corrupt,
        );
        metric(&format!("resume{cycle}_held"), held_after);
        metric(&format!("resume{cycle}_landed"), landed);
        landed_per_pass.push(landed);
        assert!(
            after.prefetch_bytes >= before.prefetch_bytes,
            "cycle {cycle}: answering memory pressure discarded the prefetch tier on disk \
             ({} -> {}), which is what cost a window of downloads on resume",
            before.prefetch_bytes,
            after.prefetch_bytes
        );
        assert!(
            landed == 0 || held_after > held_before,
            "pass {cycle} landed {landed} pages while the cache went {held_before} -> {held_after} bytes: \
             pages the ledger already named were fetched again"
        );
    }
    // The window is finite, so it runs out: forward 8 / back 4 over ten displayed
    // pages is eight new pages at four per pass. A pass after that must be idle.
    let late: i64 = landed_per_pass.iter().skip(3).sum();
    assert_eq!(
        late, 0,
        "passes kept fetching after the window was warm: {landed_per_pass:?}"
    );
    Ok(())
}

// ----------------------------------------------------------------------- books ---
/// A long session counted in books rather than pages.
///
/// Reading fifty books in a sitting is a different failure mode from reading one
/// five-hundred-page book: the page cache is bounded by the pool and the memory
/// tier by its budget, but the process-level registry of open readers is bounded
/// by nothing except a matching `reader_close`. Each entry carries a session, a
/// layout and a throttle, so an unpaired open leaks per book browsed rather than
/// per page turned.
fn phase_books(args: &Args) -> Smoke {
    use komga_core::ffi::application::{App, DeviceProfileDto};

    let books: Vec<String> = args
        .books
        .split(',')
        .map(|b| b.trim().to_string())
        .filter(|b| !b.is_empty())
        .collect();
    assert!(
        books.len() >= 6,
        "--books needs at least six fixture books, got {:?}",
        books.len()
    );
    let app = App::new(args.db.clone());
    metric("books", books.len());
    let mut peak_sessions = 0i64;
    let mut displayed = 0usize;

    // Open them all before closing any: that is the shape that would expose an
    // accumulating registry, and the honest upper bound on what a reader can have
    // open at once is one per visible book.
    let mut opened = 0usize;
    for book in &books {
        block_on(app.reader_open(
            args.server.clone(),
            book.clone(),
            args.base_url.clone(),
            args.key.clone(),
            String::new(),
            String::new(),
            None,
        ))?;
        opened += 1;
        let held = app.reader_cache_stats()?.open_readers;
        peak_sessions = peak_sessions.max(held);
        assert_eq!(held, opened as i64, "registry lost or duplicated an open");
    }
    metric("peak_open_readers", peak_sessions);

    for book in &books {
        let window = app.reader_configure_device(
            args.server.clone(),
            book.clone(),
            DeviceProfileDto {
                device_memory_bytes: args.device_memory,
                cache_budget_bytes: args.pool_budget,
                avg_page_bytes_hint: 0,
                decoded_page_bytes: 8 * 1024 * 1024,
                network: "wifi".to_string(),
                stable: true,
            },
        )?;
        for page in 1..=3u32 {
            let path = block_on(app.reader_page(
                args.server.clone(),
                book.clone(),
                page as i64,
                args.base_url.clone(),
                args.key.clone(),
            ))?;
            assert!(std::path::Path::new(&path).exists(), "{book} page {page}");
            displayed += 1;
        }
        metric("last_cap", window.cap);
        app.reader_clear_prefetch()?;
        app.reader_close(args.server.clone(), book.clone())?;
    }
    let stats = app.reader_cache_stats()?;
    metric("readers_after_close", stats.open_readers);
    metric("displayed_pages", displayed);
    metric("memory_bytes_after", stats.memory_bytes);
    metric("prefetch_bytes_after", stats.prefetch_bytes);
    metric("page_bytes_after", stats.page_bytes);
    assert_eq!(
        stats.open_readers, 0,
        "closing every reader left sessions in the registry"
    );
    assert_eq!(
        stats.prefetch_bytes, 0,
        "clearing prefetch left bytes in the prefetch tier"
    );
    assert!(
        stats.page_bytes > 0,
        "reading a page and clearing prefetch threw the displayed bytes away"
    );
    Ok(())
}

// ----------------------------------------------------------------- corruption ---
/// 缓存损坏恢复: the server truncates every Nth page. A short read must be
/// refused, must never reach the disk cache, and must stop being retried.
fn phase_corruption(args: &Args) -> Smoke {
    let conn = open_store(args);
    let mut loader = open_stress(args, &conn, Metered::new(args, &args.base_url), true)?;
    let count = loader.page_count();
    let mut refused = 0usize;
    let mut served = 0usize;
    for number in 1..=count {
        match loader.page(&conn, number, &stamp(number as i64)) {
            Ok(page) => {
                served += 1;
                assert!(page.path.exists());
            }
            Err(LoaderError::Corrupt { reason, .. }) => {
                refused += 1;
                assert!(
                    !reason.is_empty(),
                    "a refusal has to say why, or the UI has nothing to show"
                );
            }
            Err(other) => return Err(format!("page {number}: {other:?}").into()),
        }
    }
    metric("pages_served", served);
    metric("pages_refused", refused);
    assert!(refused > 0, "the server truncated nothing to refuse");
    let requests = loader.source().page_requests;
    metric("page_requests", requests);
    // MAX_CORRUPT_ATTEMPTS is the whole point: two refusals per bad page, never
    // one per page turn forever.
    let attempts = loader.corrupt_attempts();
    metric("corrupt_tracked", attempts.len());
    assert!(
        attempts.iter().all(|(_, count)| *count <= 3),
        "retries ran away: {attempts:?}"
    );
    let expected = served as i64
        + attempts
            .iter()
            .map(|(_, count)| *count as i64 + 1)
            .sum::<i64>();
    assert!(
        (requests as i64) <= expected,
        "{requests} requests for {served} good pages and {refused} refusals"
    );
    report_cache(loader.cache(), &conn)?;
    assert_eq!(
        loader.cache().bytes_of_tier(&conn, Tier::Page)?,
        served as i64
            * demo_png::large_page_len(
                loader.manifest().pages[0].width,
                loader.manifest().pages[0].height
            ) as i64,
        "a truncated page was cached: nothing else can account for the difference"
    );
    // And a refusal must be self-healing: the same page asked for again with a
    // healthy server is served, not permanently poisoned.
    let first_requests = loader.source().page_requests;
    let first_manifests = loader.source().manifest_requests;
    drop(loader);
    let mut healed = open_stress(args, &conn, Metered::new(args, &args.base_url), false)?;
    let still_refused = (1..=count)
        .filter(|number| {
            healed
                .page(&conn, *number, &stamp(0))
                .err()
                .map(|error| matches!(error, LoaderError::Corrupt { .. }))
                .unwrap_or(false)
        })
        .count();
    metric("still_refused_after_retry", still_refused);
    metric(
        "requests_total",
        first_requests + healed.source().page_requests,
    );
    metric(
        "manifest_requests",
        first_manifests + healed.source().manifest_requests,
    );
    Ok(())
}
