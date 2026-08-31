//! The log ring, wired to the real `log` backend and fed by a real core path.
//!
//! Unit tests in `diagnostics::log` cover the ring's own arithmetic, and they
//! can cover nothing else: the `log` crate has exactly one global slot, so the
//! question "does a line the core writes end up readable by the UI" can only be
//! answered in a process of its own. This file is that process.
//!
//! It is one test on purpose. The ring is process-global state, and three
//! `#[test]`s in this file would run on three threads and reset each other's
//! fixture — the failure would look like a flaky backend, not like a race.
//!
//! This is also the mutation check for the install point: delete the
//! `diagnostics::log::install()` call from `App::new` and the assertions below
//! go red while the crate still compiles. That is the exact failure this stage
//! exists to close — the core was already calling `log` in a dozen places with
//! nothing on the other end for two stages.

use komga_core::diagnostics::log;
use komga_core::ffi::application::App;

#[tokio::test]
async fn a_line_the_core_writes_is_readable_without_the_ui_asking_for_it() {
    let dir = std::env::temp_dir().join(format!("comic-diagnostics-log-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    let db = dir.join("comic.sqlite");

    // `App::new` is the funnel every FFI entry point goes through. Until it
    // runs, nobody has claimed the slot.
    let app = App::new(db.to_str().unwrap().to_string());
    let stats = log::stats();
    assert!(
        stats.installed,
        "constructing the facade did not install the log backend"
    );
    assert!(
        log::install(),
        "a second install must report the slot as still ours"
    );
    // `log`'s own default is `Off`, which would leave the ring as empty as the
    // sink it replaced; `install` lifts it, and only if nothing else chose.
    assert_eq!(log::max_level_name(), "info");

    log::reset();
    assert_eq!(log::stats().retained, 0, "the ring started non-empty");

    // The offline demo bootstrap logs its cover counts on the happy path.
    // Nothing here calls `log::` to make that happen: a core path the app
    // already runs has to be enough on its own.
    app.bootstrap_demo("gate".to_string())
        .await
        .expect("demo bootstrap");

    let records = log::records(64, None);
    assert!(
        !records.is_empty(),
        "a full demo bootstrap produced no readable log line"
    );
    let messages: Vec<&str> = records.iter().map(|r| r.message.as_str()).collect();
    assert!(
        messages
            .iter()
            .any(|message| message.starts_with("demo covers backfilled")),
        "the cover count is missing from the ring: {messages:?}"
    );
    for record in &records {
        assert_eq!(record.level, "info");
        assert!(
            record.target.starts_with("komga_core"),
            "unexpected target: {}",
            record.target
        );
        assert!(!record.at.is_empty());
    }

    // Below the installed filter means below the ring, too.
    let before = log::stats().retained;
    ::log::debug!(target: "diagnostics_log_probe", "gate probe");
    assert_eq!(
        log::stats().retained,
        before,
        "a debug line slipped past an info filter"
    );
    ::log::info!(target: "diagnostics_log_probe", "gate probe");
    assert_eq!(log::stats().retained, before + 1);
    let newest = log::records(1, None).pop().expect("the info probe");
    assert_eq!(
        (newest.level.as_str(), newest.message.as_str()),
        ("info", "gate probe")
    );
    assert_eq!(newest.target, "diagnostics_log_probe");

    // An error line is visible as a counter even after the window moves on, and
    // `last_error` names it — that pair is what a support export leads with.
    ::log::error!(target: "diagnostics_log_probe", "cache died");
    let stats = log::stats();
    assert_eq!(stats.errors, 1);
    assert_eq!(
        stats.last_error.as_deref(),
        Some("diagnostics_log_probe: cache died")
    );
    assert_eq!(log::records(1, log::parse_level("error")).len(), 1);
    assert_eq!(
        log::records(64, log::parse_level("error"))
            .iter()
            .filter(|r| r.level == "info")
            .count(),
        0
    );

    std::fs::remove_dir_all(&dir).ok();
}
