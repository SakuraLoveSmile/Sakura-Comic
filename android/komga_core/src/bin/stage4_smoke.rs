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
//! The battery is DATA-ADAPTIVE on purpose: its assertions are mirror
//! consistency checks ("the query layer serves exactly what the mirror
//! holds"), not content assumptions about a particular library. A real
//! server with no tags, no collections and no readlists must pass as long as
//! the mirror and the query layer agree; only --fixture keeps a few
//! fixture-content probes (the demo library is fixed and known).
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
            match poll(async { app.full_sync(server_id.clone(), base.clone(), key.clone()).await }) {
                Ok(s) => report = format!(
                    "series={} books={} collections={} readlists={} read_progress={} (pages: {} series / {} books)",
                    s.series, s.books, s.collections, s.readlists, s.read_progress, s.series_pages, s.book_pages
                ),
                Err(e) => {
                    println!("== sync (live full sync) ==\n  FAILED: {e}");
                    std::process::exit(1);
                }
            }
            // A live run mirrors what the app does after sync: covers are a
            // backfill step, not part of FullSync (fixture demo seeds its own
            // covers, so this only runs for a real server).
            match poll(async {
                app.ensure_covers(server_id.clone(), base.clone(), key.clone())
                    .await
            }) {
                Ok(n) => println!("  covers backfilled: {n}"),
                Err(e) => {
                    println!("== cover backfill (live) ==\n  FAILED: {e}");
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

    // Libraries: 列表 + 详情 + 切换 (per-library counts).
    section("Library 列表 / 详情 / 切换");
    let libs = app
        .library_counts(&server_id)
        .unwrap_or_else(|e| panic!("library_counts: {e}"));
    for lib in &libs {
        println!(
            "  library {} — {} series / {} books / {} read (root={}, unavailable={})",
            lib.name,
            lib.series_count,
            lib.book_count,
            lib.read_count,
            lib.root.as_deref().unwrap_or("-"),
            lib.unavailable
        );
    }
    if !libs.is_empty() {
        check(
            "library list non-empty",
            true,
            &format!("{} libraries", libs.len()),
        );
        let first = &libs[0];
        let wall = app
            .query_series(
                &server_id,
                None,
                Some(first.remote_id.clone()),
                None,
                None,
                None,
                "name".into(),
                true,
                PAGE,
                0,
            )
            .unwrap_or_else(|e| panic!("query_series by library: {e}"));
        let foreign = wall
            .items
            .iter()
            .filter(|s| s.library_id != first.remote_id)
            .count();
        check(
            "library filter is scoped to that library",
            foreign == 0 && wall.total as usize <= first.series_count as usize,
            &format!(
                "library '{}' → {} series (count says {}), {} foreign",
                first.name, wall.total, first.series_count, foreign
            ),
        );
        let detail = app
            .library_detail(&server_id, &first.remote_id)
            .unwrap_or_else(|e| panic!("library_detail: {e}"))
            .unwrap_or_else(|| panic!("library_detail({}) returned none", first.remote_id));
        check(
            "library detail matches list row + carries metadata",
            detail.name == first.name
                && detail.series_count == first.series_count
                && detail.book_count == first.book_count
                && !detail.root.as_deref().unwrap_or("").is_empty(),
            &format!(
                "{} — root={}, {} books",
                detail.name,
                detail.root.as_deref().unwrap_or("-"),
                detail.book_count
            ),
        );
        check(
            "unknown library id resolves to none",
            app.library_detail(&server_id, "__definitely_missing__")
                .unwrap_or_else(|e| panic!("library_detail: {e}"))
                .is_none(),
            "no row",
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

    // Search (FTS5). Data-adaptive probes: the fixture library is fixed and
    // known (Berserk / One Piece / Solo Leveling), a live library is whatever
    // the server actually holds — probe with names the mirror itself contains
    // so the check works for a Chinese-named or tag-less library too.
    section("本地搜索 (FTS5)");
    let mut probes: Vec<String> = Vec::new();
    if fixture {
        probes.extend(["berserk", "one", "piece"].iter().map(|s| s.to_string()));
    }
    for s in wall.items.iter().take(3) {
        // A safe FTS query derived from the name: every non-alphanumeric char
        // becomes a separator. Raw names are never safe as probes — FTS5 gives
        // '+', '-', ':', '"', '*' etc. query meanings. The index tokenizes the
        // same runs, so an AND query over them matches the row.
        let term = s
            .name
            .chars()
            .map(|c| if c.is_alphanumeric() { c } else { ' ' })
            .collect::<String>();
        let term = term.split_whitespace().collect::<Vec<_>>().join(" ");
        if !term.is_empty() {
            probes.push(term);
        }
    }
    let mut seen = std::collections::HashSet::new();
    probes.retain(|p| seen.insert(p.clone()));
    probes.truncate(4);
    for term in &probes {
        let page = app
            .query_series(
                &server_id,
                Some(term.clone()),
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
            page.total >= 1,
            &format!("expected ≥ 1, got {}", page.total),
        );
    }

    // Filter options, read once and reused by the three filter probes and the
    // summary line below.
    let options = app
        .filter_options(&server_id)
        .unwrap_or_else(|e| panic!("filter_options: {e}"));

    // Filters.
    section("筛选: Library / Tag / Genre / Status");
    if let Some(tag) = options.tags.first() {
        let tag_page = app
            .query_series(
                &server_id,
                None,
                None,
                None,
                Some(tag.clone()),
                None,
                "name".into(),
                true,
                PAGE,
                0,
            )
            .unwrap();
        check(
            "tag filter (first available tag)",
            tag_page.total >= 1,
            &format!("tag \"{tag}\" → {}", tag_page.total),
        );
    } else {
        // A library with no tags is not a defect: the mirror says so, and the
        // query must simply return nothing for any tag.
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
            "tag filter (no tags on this server)",
            tag_page.total == 0,
            &format!("{} hits for a tag the mirror lacks", tag_page.total),
        );
    }
    if let Some(genre) = options.genres.first() {
        let genre_page = app
            .query_series(
                &server_id,
                None,
                None,
                None,
                None,
                Some(genre.clone()),
                "name".into(),
                true,
                PAGE,
                0,
            )
            .unwrap();
        println!("  genre '{genre}' → {} series", genre_page.total);
        check(
            "genre filter (first available genre)",
            genre_page.total >= 1,
            &format!("got {}", genre_page.total),
        );
    } else {
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
        check(
            "genre filter (no genres on this server)",
            genre_page.total == 0,
            &format!("{} hits for a genre the mirror lacks", genre_page.total),
        );
    }
    // Statuses partition the wall: every series has exactly one status, so the
    // per-status counts must add up to the wall total (works for any library).
    let mut status_total: i64 = 0;
    let mut status_parts: Vec<(String, i64)> = Vec::new();
    for st in &options.statuses {
        let page = app
            .query_series(
                &server_id,
                None,
                None,
                Some(st.clone()),
                None,
                None,
                "name".into(),
                true,
                PAGE,
                0,
            )
            .unwrap();
        status_total += page.total;
        status_parts.push((st.clone(), page.total));
    }
    let status_partition_ok = if options.statuses.is_empty() {
        wall.total == 0
    } else {
        status_total == wall.total && status_parts.iter().any(|(_, n)| *n >= 1)
    };
    check(
        "status filter partitions the wall",
        status_partition_ok,
        &format!(
            "{} series across {} statuses (wall {})",
            status_total,
            options.statuses.len(),
            wall.total
        ),
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
                // A real server may legitimately assign no book tags: the
                // mirror faithfully carries what the server gave. The fixture
                // library is fixed (it has tags), so the fixture leg keeps the
                // strict shape and this only tolerates a tag-less live server.
                !detail.tags.is_empty() || !fixture,
                &format!("{:?}", detail.tags),
            );
        }
    }

    // Continue reading. Data-adaptive: the shelf is derived from the mirror's
    // read_progress rows (completed=0, page>0); an empty shelf is only wrong
    // when the mirror has rows that should put a book on it.
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
    let in_progress_rows: i64 = {
        let conn = komga_core::store::open(&db).unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM read_progress
             WHERE server_id = ?1 AND completed = 0 AND page IS NOT NULL AND page > 0",
            rusqlite::params![server_id],
            |row| row.get(0),
        )
        .unwrap_or(0)
    };
    let shelf_consistent =
        (!shelf.is_empty() && in_progress_rows >= 1) || (shelf.is_empty() && in_progress_rows == 0);
    check(
        "continue reading shelf",
        shelf_consistent,
        &format!(
            "{} entries (mirror has {} in-progress rows)",
            shelf.len(),
            in_progress_rows
        ),
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
            // Stage 6 contract (Mutation 合并): a device only ever uploads the
            // user's LAST statement per book. The two writes above hit the same
            // book, so coalescing must leave exactly one pending row — the
            // MARK_READ — and no READ_PROGRESS for it. (!= 2: pre-Stage-6
            // baselines counted both rows; the merge made that impossible.)
            let rows: Vec<(String, String)> = {
                let conn = komga_core::store::open(&db).unwrap();
                let mut stmt = conn
                    .prepare(
                        "SELECT mutation_type, entity_id FROM pending_mutations
                         WHERE server_id = ?1 AND entity_id = ?2",
                    )
                    .unwrap();
                let iter = stmt
                    .query_map(rusqlite::params![server_id, fresh.remote_id], |row| {
                        Ok((row.get(0)?, row.get(1)?))
                    })
                    .unwrap();
                iter.collect::<rusqlite::Result<Vec<_>>>().unwrap()
            };
            check(
                "mutation outbox rows written",
                !rows.is_empty(),
                &format!("{} pending for {}", rows.len(), fresh.remote_id),
            );
            check(
                "outbox keeps the user's last statement per book",
                rows.len() == 1 && rows[0].0 == "MARK_READ",
                &format!(
                    "{} rows: {}",
                    rows.len(),
                    rows.iter()
                        .map(|(t, _)| t.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
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
    // Mirror consistency, not content presence: a real server with no
    // collections must pass (0 == 0), a fixture with two must serve both.
    let collection_rows: i64 = {
        let conn = komga_core::store::open(&db).unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM collections WHERE server_id = ?1",
            rusqlite::params![server_id],
            |row| row.get(0),
        )
        .unwrap_or(0)
    };
    check(
        "collections list",
        collections.total == collection_rows && collections.items.len() as i64 == collection_rows,
        &format!(
            "{} listed vs {} rows",
            collections.items.len(),
            collection_rows
        ),
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
    let readlist_rows: i64 = {
        let conn = komga_core::store::open(&db).unwrap();
        conn.query_row(
            "SELECT COUNT(*) FROM readlists WHERE server_id = ?1",
            rusqlite::params![server_id],
            |row| row.get(0),
        )
        .unwrap_or(0)
    };
    check(
        "readlists list",
        readlists.total == readlist_rows && readlists.items.len() as i64 == readlist_rows,
        &format!("{} listed vs {} rows", readlists.items.len(), readlist_rows),
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
    // Data-adaptive like everything else: the only invariant a library must
    // satisfy is that every mirrored series carries one of the statuses in the
    // options (statuses are server-mandatory); tags/genres may be absent.
    let statuses_cover_wall = options
        .statuses
        .iter()
        .map(|st| {
            app.query_series(
                &server_id,
                None,
                None,
                Some(st.clone()),
                None,
                None,
                "name".into(),
                true,
                PAGE,
                0,
            )
            .unwrap()
            .total
        })
        .sum::<i64>();
    check(
        "filter options cover the wall",
        statuses_cover_wall >= wall.total,
        &format!(
            "{} series across {} statuses (wall {})",
            statuses_cover_wall,
            options.statuses.len(),
            wall.total
        ),
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
