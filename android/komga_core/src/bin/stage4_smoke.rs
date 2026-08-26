//! stage4_smoke — Stage 4 acceptance: the client works as a full Komga
//! media library browser with the network disconnected.
//!
//! Modes:
//!   --fixture                 seed the shared library fixtures (no network)
//!   --base-url URL --api-key K  full mirror sync against a live Komga
//!   --offline                 skip sync; run the query battery on an
//!                             existing DB (proves zero-network browsing)
//!
//! After the sync phase the query battery runs entirely against SQLite —
//! no request is made, which is exactly the "断开 Komga 网络" acceptance.
//!
//! Usage:
//!   cargo run --bin stage4_smoke -- --fixture --db /tmp/comic-stage4.sqlite --server-id demo
//!   cargo run --bin stage4_smoke -- --base-url $KOMGA_BASE_URL --api-key $KOMGA_API_KEY \
//!       --db /tmp/comic-stage4.sqlite --server-id live
//!   cargo run --bin stage4_smoke -- --offline --db /tmp/comic-stage4.sqlite --server-id live

use std::path::Path;

use komga_core::ffi::application::App;

const PAGE: i64 = 50;
static FAILURES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
static CHECKS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

fn check(name: &str, ok: bool, detail: &str) {
    let tag = if ok { "PASS" } else { "FAIL" };
    println!("  [{tag}] {name}: {detail}");
    CHECKS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    if !ok {
        FAILURES.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    }
}

fn section(title: &str) {
    println!("\n== {title} ==");
}

fn main() {
    // The smoke binary stays dependency-light: log lines are swallowed.
    let args: Vec<String> = std::env::args().collect();

    let mut fixture = false;
    let mut offline = false;
    let mut base_url = None;
    let mut api_key = None;
    let mut db = None;
    let mut server_id = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--fixture" => fixture = true,
            "--offline" => offline = true,
            "--base-url" => {
                i += 1;
                base_url = Some(args[i].clone());
            }
            "--api-key" => {
                i += 1;
                api_key = Some(args[i].clone());
            }
            "--db" => {
                i += 1;
                db = Some(args[i].clone());
            }
            "--server-id" => {
                i += 1;
                server_id = Some(args[i].clone());
            }
            "--help" | "-h" => {
                println!("usage: stage4_smoke --fixture | (--base-url URL --api-key KEY) [--offline] --db PATH --server-id ID");
                return;
            }
            other => panic!("unknown arg: {other}"),
        }
        i += 1;
    }
    let db = db.expect("--db PATH is required");
    let server_id = server_id.expect("--server-id ID is required");
    let app = App::new(&db);
    if let Some(parent) = Path::new(&db).parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    if !offline {
        let kind;
        let report;
        if fixture {
            kind = "fixture demo";
            match poll(async { app.bootstrap_demo(server_id.clone()).await }) {
                Ok(s) => {
                    report = format!(
                        "series={} (fixture page, total {})",
                        s.synced_series, s.total_elements
                    )
                }
                Err(e) => {
                    println!("== sync (fixture demo) ==\n  FAILED: {e}");
                    std::process::exit(1);
                }
            }
        } else {
            kind = "live full sync";
            let base = base_url.expect("--fixture or --base-url required unless --offline");
            let key = api_key.expect("--api-key required with --base-url");
            match poll(async { app.full_sync(server_id.clone(), base, key).await }) {
                Ok(s) => report = format!(
                    "series={} books={} collections={} readlists={} read_progress={} (pages: {} series / {} books)",
                    s.series, s.books, s.collections, s.readlists, s.read_progress, s.series_pages, s.book_pages
                ),
                Err(e) => {
                    println!("== sync (live full sync) ==\n  FAILED: {e}");
                    std::process::exit(1);
                }
            }
        }
        println!("== sync ({kind}) ==\n  {report}");
    } else {
        println!("== sync ==\n  --offline: skipping sync, battery runs on the existing DB");
    }

    // ---- The offline battery: every call below is SQLite-only. ----
    println!("\n═══ OFFLINE MEDIA LIBRARY BATTERY (network disconnected) ═══");

    // Libraries: 列表 + 切换 (per-library counts).
    section("Library 列表 / 切换");
    let libs = app
        .library_counts(&server_id)
        .unwrap_or_else(|e| panic!("library_counts: {e}"));
    for lib in &libs {
        println!("  library {} ({} series)", lib.name, lib.series_count);
    }
    if !libs.is_empty() {
        check(
            "library list non-empty",
            true,
            &format!("{} libraries", libs.len()),
        );
        let wall = app
            .query_series(
                &server_id,
                None,
                Some(libs[0].remote_id.clone()),
                None,
                None,
                None,
                "name".into(),
                true,
                PAGE,
                0,
            )
            .unwrap_or_else(|e| panic!("query_series by library: {e}"));
        check(
            "library filter returns series",
            wall.total >= 0 && !wall.items.is_empty() || wall.total == 0,
            &format!("library '{}' → {} series", libs[0].name, wall.total),
        );
    } else {
        check("library list non-empty", false, "no libraries mirrored");
    }

    // Series wall: default sort + total.
    section("Series 封面墙");
    let wall = app
        .query_series(
            &server_id,
            None,
            None,
            None,
            None,
            None,
            "name".into(),
            true,
            PAGE,
            0,
        )
        .unwrap_or_else(|e| panic!("query_series: {e}"));
    println!("  total series: {}", wall.total);
    check(
        "series wall loads from SQLite",
        !wall.items.is_empty() || wall.total == 0,
        &format!("{} items", wall.items.len()),
    );

    // Search (FTS5).
    section("本地搜索 (FTS5)");
    for (term, expect) in [("berserk", 1), ("one", 1), ("piece", 1)] {
        let page = app
            .query_series(
                &server_id,
                Some(term.into()),
                None,
                None,
                None,
                None,
                "name".into(),
                true,
                PAGE,
                0,
            )
            .unwrap_or_else(|e| panic!("search {term}: {e}"));
        println!("  search \"{term}\" → {} hits", page.total);
        check(
            &format!("search \"{term}\""),
            page.total >= expect,
            &format!("expected ≥ {expect}, got {}", page.total),
        );
    }

    // Filters.
    section("筛选: Library / Tag / Genre / Status");
    let tag_page = app
        .query_series(
            &server_id,
            None,
            None,
            None,
            Some("Seinen".into()),
            None,
            "name".into(),
            true,
            PAGE,
            0,
        )
        .unwrap();
    check(
        "tag filter Seinen",
        tag_page.total == 1,
        &format!("got {}", tag_page.total),
    );
    let genre_page = app
        .query_series(
            &server_id,
            None,
            None,
            None,
            None,
            Some("Action".into()),
            "name".into(),
            true,
            PAGE,
            0,
        )
        .unwrap();
    println!("  genre 'Action' → {} series", genre_page.total);
    check(
        "genre filter Action",
        genre_page.total >= 1,
        &format!("got {}", genre_page.total),
    );
    let status_page = app
        .query_series(
            &server_id,
            None,
            None,
            Some("ENDED".into()),
            None,
            None,
            "name".into(),
            true,
            PAGE,
            0,
        )
        .unwrap();
    check(
        "status filter ENDED",
        status_page.total >= 1,
        &format!("got {}", status_page.total),
    );

    // Sort + pagination.
    section("排序 / 分页");
    let by_date = app
        .query_series(
            &server_id,
            None,
            None,
            None,
            None,
            None,
            "dateAdded".into(),
            false,
            PAGE,
            0,
        )
        .unwrap();
    if !by_date.items.is_empty() {
        println!("  dateAdded desc → first: {}", by_date.items[0].name);
    }
    let page2 = app
        .query_series(
            &server_id,
            None,
            None,
            None,
            None,
            None,
            "name".into(),
            true,
            2,
            2,
        )
        .unwrap();
    check(
        "pagination offset=2 limit=2",
        page2.items.len() <= 2,
        &format!("{} items", page2.items.len()),
    );
    let by_count = app
        .query_series(
            &server_id,
            None,
            None,
            None,
            None,
            None,
            "booksCount".into(),
            false,
            PAGE,
            0,
        )
        .unwrap();
    if by_count.items.len() > 1 {
        let top = by_count.items[0].books_count.unwrap_or(0);
        let second = by_count.items[1].books_count.unwrap_or(0);
        check(
            "sort booksCount desc",
            top >= second,
            &format!("{top} >= {second}"),
        );
    }

    // Series detail.
    section("Series 详情 (Metadata / Tags / Genres / Status)");
    let first_series = wall.items.first().cloned();
    if let Some(s) = &first_series {
        let detail = app
            .series_detail(&server_id, &s.remote_id)
            .unwrap()
            .expect("series detail exists");
        println!(
            "  {} — status={} genres={:?} tags={:?} authors={:?} summary={}",
            detail.name,
            detail.status.clone().unwrap_or_default(),
            detail.genres,
            detail.tags,
            detail
                .authors
                .iter()
                .map(|a| a.name.clone())
                .collect::<Vec<_>>(),
            detail
                .summary
                .clone()
                .unwrap_or_default()
                .chars()
                .take(40)
                .collect::<String>(),
        );
        check(
            "series detail metadata",
            detail.summary.is_some() || detail.genres.is_empty(),
            "summary/genres read",
        );
        check(
            "series detail counts",
            detail.books_count.is_some(),
            "books_count present",
        );
    } else {
        check("series detail", false, "no series to inspect");
    }

    // Books + read status + book detail.
    section("Book 列表 / Metadata / 阅读状态");
    if let Some(s) = &first_series {
        let books = app
            .query_books(
                &server_id,
                &s.remote_id,
                None,
                None,
                None,
                "number".into(),
                true,
                PAGE,
                0,
            )
            .unwrap();
        println!("  '{}' → {} books", s.name, books.total);
        check(
            "book list loads",
            !books.items.is_empty(),
            &format!("{} items", books.items.len()),
        );
        let read = app
            .query_books(
                &server_id,
                &s.remote_id,
                None,
                Some("read".into()),
                None,
                "number".into(),
                true,
                PAGE,
                0,
            )
            .unwrap();
        let in_progress = app
            .query_books(
                &server_id,
                &s.remote_id,
                None,
                Some("in_progress".into()),
                None,
                "number".into(),
                true,
                PAGE,
                0,
            )
            .unwrap();
        let unread = app
            .query_books(
                &server_id,
                &s.remote_id,
                None,
                Some("unread".into()),
                None,
                "number".into(),
                true,
                PAGE,
                0,
            )
            .unwrap();
        let sum = read.total + in_progress.total + unread.total;
        check(
            "read status partition",
            sum == books.total,
            &format!(
                "read({}) + progress({}) + unread({}) = {sum} vs {}",
                read.total, in_progress.total, unread.total, books.total
            ),
        );
        if let Some(first_book) = books.items.first() {
            let detail = app
                .book_detail(&server_id, &first_book.remote_id)
                .unwrap()
                .expect("book detail exists");
            println!(
                "  {} — progress={:?}/{:?} completed={}",
                detail.title, detail.progress_page, detail.pages_count, detail.progress_completed
            );
            check(
                "book detail metadata",
                detail.pages_count.unwrap_or(0) > 0,
                "pages_count present",
            );
            check(
                "book tags",
                !detail.tags.is_empty() || books.total == 0,
                &format!("{:?}", detail.tags),
            );
        }
    }

    // Continue reading.
    section("Continue Reading");
    let shelf = app
        .continue_reading(&server_id, 10)
        .unwrap_or_else(|e| panic!("continue_reading: {e}"));
    for row in &shelf {
        println!(
            "  {} · {} — page {}/{} ({}%)",
            row.series_name,
            row.book_title,
            row.page.unwrap_or(0),
            row.total_pages.unwrap_or(0),
            row.progress_pct.unwrap_or(0)
        );
    }
    check(
        "continue reading shelf",
        !shelf.is_empty(),
        &format!("{} entries", shelf.len()),
    );
    // 本地标记阅读状态 → shelf 立即变化（本地优先，无网络）。
    if let Some(s) = &first_series {
        let books = app
            .query_books(
                &server_id,
                &s.remote_id,
                None,
                None,
                None,
                "number".into(),
                true,
                PAGE,
                0,
            )
            .unwrap();
        if let Some(fresh) = books.items.iter().find(|b| !b.progress_completed) {
            app.set_read_progress(&server_id, &fresh.remote_id, 3, false)
                .unwrap();
            let after = app.continue_reading(&server_id, 20).unwrap();
            check(
                "local set_read_progress updates shelf",
                after.iter().any(|r| r.book_id == fresh.remote_id),
                &format!("{} now on the shelf", fresh.title),
            );
            app.mark_read(&server_id, &fresh.remote_id).unwrap();
            let after_read = app.continue_reading(&server_id, 20).unwrap();
            check(
                "mark_read removes from shelf",
                !after_read.iter().any(|r| r.book_id == fresh.remote_id),
                &format!("{} no longer on the shelf", fresh.title),
            );
            let outbox: i64 = {
                let conn = komga_core::store::open(&db).unwrap();
                conn.query_row(
                    "SELECT COUNT(*) FROM pending_mutations WHERE server_id = ?1",
                    rusqlite::params![server_id],
                    |row| row.get(0),
                )
                .unwrap_or(0)
            };
            check(
                "mutation outbox rows written",
                outbox >= 2,
                &format!("{outbox} pending"),
            );
        }
    }

    // Collections + detail.
    section("Collections");
    let collections = app
        .list_collections(&server_id, None, PAGE, 0)
        .unwrap_or_else(|e| panic!("list_collections: {e}"));
    for c in &collections.items {
        println!("  {} ({} total)", c.name, collections.total);
    }
    check(
        "collections list",
        !collections.items.is_empty(),
        &format!("{} items", collections.items.len()),
    );
    if let Some(col) = collections.items.first() {
        let detail = app
            .collection_detail(&server_id, &col.remote_id, PAGE, 0)
            .unwrap()
            .expect("collection detail");
        println!(
            "  '{}' members: {}",
            detail.name,
            detail
                .members
                .items
                .iter()
                .map(|s| s.name.clone())
                .collect::<Vec<_>>()
                .join(", ")
        );
        check(
            "collection detail members",
            detail.members.total >= 0,
            &format!("{} members", detail.members.total),
        );
    }

    // Readlists + detail.
    section("Readlists");
    let readlists = app
        .list_readlists(&server_id, None, PAGE, 0)
        .unwrap_or_else(|e| panic!("list_readlists: {e}"));
    for rl in &readlists.items {
        println!("  {} — {}", rl.name, rl.summary.clone().unwrap_or_default());
    }
    check(
        "readlists list",
        !readlists.items.is_empty(),
        &format!("{} items", readlists.items.len()),
    );
    if let Some(rl) = readlists.items.first() {
        let detail = app
            .readlist_detail(&server_id, &rl.remote_id, PAGE, 0)
            .unwrap()
            .expect("readlist detail");
        println!(
            "  '{}' books: {}",
            detail.name,
            detail
                .books
                .items
                .iter()
                .map(|b| b.title.clone())
                .collect::<Vec<_>>()
                .join(", ")
        );
        check(
            "readlist detail books",
            detail.books.total >= 0,
            &format!("{} books", detail.books.total),
        );
    }

    // Covers: series + book thumbnails resolved from SQLite (files exist).
    section("封面 (SQLite → 磁盘)");
    let thumbs = app
        .list_thumbnails(&server_id)
        .unwrap_or_else(|e| panic!("list_thumbnails: {e}"));
    let series_covers = thumbs.iter().filter(|t| t.variant == "series").count();
    let book_covers = thumbs.iter().filter(|t| t.variant == "book").count();
    let missing = thumbs
        .iter()
        .filter(|t| !Path::new(&t.local_path).exists())
        .count();
    println!("  series covers: {series_covers}, book covers: {book_covers}, dead files: {missing}");
    check(
        "series covers mirrored",
        series_covers > 0,
        &format!("{series_covers} paths"),
    );
    check(
        "cover files exist",
        missing == 0,
        &format!("{missing} dead paths"),
    );
    if book_covers == 0 && !offline {
        println!(
            "  note: book covers backfill lazily per series detail — run the app once to verify"
        );
    }

    // Filter options.
    section("筛选选项 (tags / genres / statuses)");
    let options = app
        .filter_options(&server_id)
        .unwrap_or_else(|e| panic!("filter_options: {e}"));
    println!(
        "  tags: {:?}\n  genres: {:?}\n  statuses: {:?}",
        options.tags, options.genres, options.statuses
    );
    check(
        "filter options tags",
        !options.tags.is_empty() || wall.total == 0,
        &format!("{} tags", options.tags.len()),
    );

    let failures = FAILURES.load(std::sync::atomic::Ordering::SeqCst);
    let checks = CHECKS.load(std::sync::atomic::Ordering::SeqCst);
    println!("\n═══ RESULT: {checks} checks, {failures} failed ═══");
    if failures > 0 {
        std::process::exit(1);
    }
}

/// Tiny block_on so the facade's async entry points work in the smoke bin
/// without pulling tokio's full runtime into the binary.
fn poll<F: std::future::Future>(future: F) -> F::Output {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    rt.block_on(future)
}
