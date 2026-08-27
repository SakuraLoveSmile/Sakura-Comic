#!/usr/bin/env python3
"""Generate the Stage 5 sync-scenario fixtures.

Both platforms replay these JSON scenarios (Rust `sync::scenario`, Swift
`SyncScenarioTests`), so the acceptance battery is one shared contract rather
than two hand-written test suites that could drift.

Output:
  specs/contracts/fixtures/sync/scenario-reconcile.json
  specs/contracts/fixtures/sync/scenario-interrupt.json
"""
import copy
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "specs/contracts/fixtures/library")
OUT = os.path.join(ROOT, "specs/contracts/fixtures/sync")


def load(name):
    with open(os.path.join(LIB, name), encoding="utf-8") as handle:
        return json.load(handle)


BASE_SERIES = load("series-page.json")
BASE_BOOKS = load("books-by-series.json")
BASE_COLLECTIONS = load("collections-page.json")
BASE_READLISTS = load("readlists-page.json")
BASE_ONDECK = load("ondeck-page.json")
BASE_LIBRARIES = load("libraries.json")


def series_of(sid):
    return next(s for s in BASE_SERIES["content"] if s["id"] == sid)


def books_of(sid):
    return BASE_BOOKS[sid]["content"]


def collection_of(cid):
    return next(c for c in BASE_COLLECTIONS["content"] if c["id"] == cid)


def readlist_of(rid):
    return next(r for r in BASE_READLISTS["content"] if r["id"] == rid)


def page(items):
    """A single-page Spring Data page body."""
    return [copy.deepcopy(items)]


def snapshot(sid, libraries, series_pages, books, collection_pages, readlist_pages, on_deck):
    return {
        "id": sid,
        "libraries": copy.deepcopy(libraries),
        "series": copy.deepcopy(series_pages),
        "books": copy.deepcopy(books),
        "collections": copy.deepcopy(collection_pages),
        "readlists": copy.deepcopy(readlist_pages),
        "onDeck": copy.deepcopy(on_deck),
    }


def new_series(sid, library_id, name, status, last_modified, genres, tags, summary, books_count):
    return {
        "id": sid,
        "libraryId": library_id,
        "name": name,
        "created": "2025-01-01T00:00:00Z",
        "lastModified": last_modified,
        "booksCount": books_count,
        "booksMetadata": {"authors": [{"name": "New Author", "role": "writer"}], "tags": tags},
        "metadata": {
            "title": name,
            "status": status,
            "summary": summary,
            "publisher": "Shueisha",
            "genres": genres,
            "tags": tags,
            "authors": [{"name": "New Author", "role": "writer"}],
            "readingDirection": "rightToLeft",
            "language": "ja",
            "ageRating": "Everyone",
            "firstBook": None,
        },
    }


def new_book(bid, sid, name, number, last_modified, summary=None, tags=None):
    return {
        "id": bid,
        "seriesId": sid,
        "seriesTitle": name.split(" #")[0],
        "name": name,
        "number": number,
        "oneshot": False,
        "created": "2025-01-01T00:00:00Z",
        "lastModified": last_modified,
        "sizeBytes": 100000,
        "media": {"mediaType": "CBZ", "pagesCount": 24, "status": "READY"},
        "metadata": {
            "title": name,
            "number": str(number),
            "numberSort": float(number),
            "summary": summary or "",
            "authors": [],
            "tags": tags or [],
            "isbn": "",
            "releaseDate": None,
        },
        "readProgress": None,
    }


def new_collection(cid, name, series_ids, last_modified, ordered=False):
    return {
        "id": cid,
        "name": name,
        "ordered": ordered,
        "filtered": False,
        "seriesIds": series_ids,
        "createdDate": "2025-01-01T00:00:00Z",
        "lastModifiedDate": last_modified,
    }


def new_readlist(rid, name, book_ids, last_modified):
    return {
        "id": rid,
        "name": name,
        "summary": "",
        "ordered": False,
        "filtered": False,
        "bookIds": book_ids,
        "createdDate": "2025-01-01T00:00:00Z",
        "lastModifiedDate": last_modified,
    }


# ---------------------------------------------------------------------------
# s0 — what the very first bootstrap sees (the shared library fixtures)
# ---------------------------------------------------------------------------
S0 = snapshot(
    "s0",
    BASE_LIBRARIES,
    [BASE_SERIES["content"]],
    {sid: [books_of(sid)] for sid in ("series-1", "series-2", "series-3")},
    [BASE_COLLECTIONS["content"]],
    [BASE_READLISTS["content"]],
    [BASE_ONDECK["content"]],
)

# ---------------------------------------------------------------------------
# s1 — remote gained a series (+books), a series was renamed, metadata edited,
# a book was added to an existing series, a collection and a readlist changed.
# ---------------------------------------------------------------------------
S1_SERIES = [series_of("series-1"), series_of("series-2"), series_of("series-3")]
# 新建 Series: series-4 (manga, 2 pages of books) + series-5 on page 2.
S1_SERIES[0] = copy.deepcopy(S1_SERIES[0])
S1_SERIES[0]["lastModified"] = "2025-02-01T00:00:00Z"
S1_SERIES[0]["metadata"]["summary"] = "Rewritten synopsis after a metadata scan."
S1_SERIES[0]["metadata"]["genres"] = ["Adventure", "Action"]  # Pirate genre renamed away
S1_SERIES[0]["metadata"]["tags"] = ["Pirate", "Reprint"]
S1_SERIES[0]["booksCount"] = 3
S1_SERIES[1] = copy.deepcopy(S1_SERIES[1])
S1_SERIES[1]["name"] = "Berserk (Final Arc)"  # 修改 Series
S1_SERIES[1]["lastModified"] = "2025-02-02T00:00:00Z"
S1_SERIES[1]["metadata"]["title"] = "Berserk (Final Arc)"
S1_SERIES[1]["metadata"]["status"] = "ENTERED"
PAGE_1B = [
    new_series(
        "series-4",
        "lib-2",
        "Chainsaw Man",
        "ONGOING",
        "2025-02-03T00:00:00Z",
        ["Action", "Horror"],
        ["Devil"],
        "A devils-hunter duo.",
        2,
    )
]
PAGE_2 = [
    new_series(
        "series-5",
        "lib-2",
        "Spy x Family",
        "HIATUS",
        "2025-02-04T00:00:00Z",
        ["Comedy", "Action"],
        ["Spy"],
        "A fake family with real secrets.",
        1,
    )
]
S1_BOOKS = {
    "series-1": [books_of("series-1")],
    "series-2": [books_of("series-2")],
    # 新增 Book: book-3-3 joins an existing series.
    "series-3": [books_of("series-3") + [new_book("book-3-3", "series-3", "Solo Leveling Ch. 21-30", 3, "2025-02-05T00:00:00Z", "New chapter batch.", ["Weekly"])]],
    "series-4": [
        [
            new_book("book-4-1", "series-4", "Chainsaw Man #1", 1, "2025-02-03T00:00:00Z"),
            new_book("book-4-2", "series-4", "Chainsaw Man #2", 2, "2025-02-03T00:00:00Z"),
        ]
    ],
    "series-5": [[new_book("book-5-1", "series-5", "Spy x Family #1", 1, "2025-02-04T00:00:00Z")]],
}
S1_COLLECT = [
    collection_of("col-1"),
    collection_of("col-2"),
]
S1_COLLECT[0]["seriesIds"] = ["series-1", "series-3", "series-4"]
S1_COLLECT.append(
    new_collection("col-3", "New Hits", ["series-4", "series-5"], "2025-02-06T00:00:00Z", True)
)
S1_READLISTS = [
    readlist_of("rl-1"),
    readlist_of("rl-2"),
    new_readlist("rl-3", "New Series Run", ["book-4-1", "book-4-2", "book-5-1"], "2025-02-06T00:00:00Z"),
]
S1_READLISTS[0]["bookIds"] = ["book-1-1", "book-1-2", "book-2-1", "book-3-3"]
S1 = snapshot(
    "s1",
    BASE_LIBRARIES,
    [S1_SERIES + PAGE_1B, PAGE_2],  # two pages: pagination is exercised
    S1_BOOKS,
    [S1_COLLECT],
    [S1_READLISTS],
    [[b for b in BASE_ONDECK["content"]]],
)

# ---------------------------------------------------------------------------
# s2 — remote deletions: 1 series (with its 3 books), 1 loose book,
# 1 collection and 1 readlist all disappear.
# ---------------------------------------------------------------------------
S2_SERIES = [s for s in S1_SERIES + PAGE_1B + PAGE_2 if s["id"] != "series-3"]
S2_BOOKS = {k: v for k, v in S1_BOOKS.items() if k != "series-3"}
S2_BOOKS["series-1"] = [[b for b in books_of("series-1") if b["id"] != "book-1-3"]]
S2_BOOKS["series-4"] = [[b for b in S1_BOOKS["series-4"][0] if b["id"] != "book-4-1"]]
S2_COLLECT = [c for c in S1_COLLECT if c["id"] != "col-2"]
S2_READLISTS = [r for r in S1_READLISTS if r["id"] != "rl-2"]
S2_READLISTS = copy.deepcopy(S2_READLISTS)
S2_READLISTS[0]["bookIds"] = ["book-1-1", "book-1-2", "book-2-1"]
S2 = snapshot(
    "s2",
    BASE_LIBRARIES,
    [S2_SERIES],
    S2_BOOKS,
    [S2_COLLECT],
    [S2_READLISTS],
    [[b for b in BASE_ONDECK["content"] if b["id"] != "book-3-1"]],
)


# ---------------------------------------------------------------------------
# s3 — a bigger, multi-page library used to interrupt a bootstrap mid-sweep.
# ---------------------------------------------------------------------------
S3_SERIES_PAGES = []
S3_BOOKS = {}
for group in range(3):
    items = []
    for n in range(2):
        sid = f"bulk-{group}-{n}"
        items.append(
            new_series(
                sid,
                "lib-1",
                f"Bulk Series {group}-{n}",
                "ONGOING",
                f"2025-03-0{group + 1}T00:00:00Z",
                ["Bulk"],
                ["Bulk"],
                "Bulk series used to interrupt a bootstrap.",
                4,
            )
        )
        S3_BOOKS[sid] = [
            [
                new_book(f"{sid}-a", sid, f"Bulk {group}-{n} #1", 1, "2025-03-01T00:00:00Z"),
                new_book(f"{sid}-b", sid, f"Bulk {group}-{n} #2", 2, "2025-03-01T00:00:00Z"),
            ],
            [
                new_book(f"{sid}-c", sid, f"Bulk {group}-{n} #3", 3, "2025-03-01T00:00:00Z"),
                new_book(f"{sid}-d", sid, f"Bulk {group}-{n} #4", 4, "2025-03-01T00:00:00Z"),
            ],
        ]
    S3_SERIES_PAGES.append(items)
S3 = snapshot(
    "s3",
    BASE_LIBRARIES,
    S3_SERIES_PAGES,
    S3_BOOKS,
    [[new_collection("bulk-col", "Bulk Shelf", ["bulk-0-0", "bulk-1-0"], "2025-03-05T00:00:00Z")],
     [new_collection("bulk-col-2", "Bulk Shelf 2", ["bulk-2-1"], "2025-03-05T00:00:00Z")]],
    [[new_readlist("bulk-rl", "Bulk Run", ["bulk-0-0-a", "bulk-0-0-b"], "2025-03-05T00:00:00Z")]],
    [[]],
)

ALL = {s["id"]: s for s in (S0, S1, S2, S3)}


def count(snap, key, nested=False):
    if key == "books":
        return sum(len(p) for pages in snap["books"].values() for p in pages)
    return sum(len(p) for p in snap[key])


# ---------------------------------------------------------------------------
# s5 — the server edits a book's metadata and a library's root, the two things
# the earlier snapshots only ever created or deleted.
# ---------------------------------------------------------------------------
S5 = copy.deepcopy(S2)
S5['id'] = 's5'
for book in S5['books']['series-1'][0]:
    if book['id'] == 'book-1-1':
        book['lastModified'] = '2025-02-10T00:00:00Z'
        book['metadata']['summary'] = 'Re-scanned summary: the romance arc begins.'
        book['metadata']['tags'] = ['Manga', 'Pirate', 'Reprint']
        book['metadata']['numberSort'] = 1.5
        book['media']['pagesCount'] = 48
S5['libraries'] = copy.deepcopy(S2['libraries'])
S5['libraries'][1]['root'] = '/mnt/webtoons-moved'
S5['libraries'][1]['unavailable'] = True

# ---------------------------------------------------------------------------
# s6 — reading happened on another device: the derived series counters move
# while `series.lastModified` stays exactly where it was.
# ---------------------------------------------------------------------------
S6 = copy.deepcopy(S2)
S6['id'] = 's6'
for page in S6['series']:
    for series in page:
        if series['id'] == 'series-1':
            series['booksReadCount'] = 2
            series['booksUnreadCount'] = 0
            series['booksInProgressCount'] = 1
            # deliberately NOT touched: this is the whole point of the step
            assert 'lastModified' in series

ALL = {s['id']: s for s in (S0, S1, S2, S3, S5, S6)}


reconcile_scenario = {
    "name": "stage5-reconcile",
    "description": "Bootstrap + Reconcile with SSE completely unavailable: every "
    "remote add / change / delete is healed by an id sweep alone.",
    "sse": "disabled",
    "serverId": "stage5",
    "snapshots": [S0, S1, S2, S5, S6],
    "steps": [
        {
            "label": "bootstrap mirrors s0 (Libraries → Series → Books → Collections → Readlists → Progress)",
            "action": "bootstrap_fresh",
            "snapshot": "s0",
            "expect": {
                "requests": {"libraries": 1, "series": 1, "books": 3, "collections": 1, "readlists": 1, "read_progress": 1},
                "tallies": {"series_written": 3, "books_written": 7},
                "mirror": "s0",
            },
        },
        {
            "label": "remote adds a series + books and edits metadata; reconcile heals it with no SSE events",
            "action": "reconcile",
            "snapshot": "s1",
            "trigger": "manual_refresh",
            "expect": {
                "mirror": "s1",
                "clean": False,
                "tallies": {"series_added": 2, "series_changed": 2, "series_removed": 0,
                             "books_added": 4, "books_removed": 0},
                "requests": {"series": 2},
            },
        },
        {
            "label": "remote deletes a series (with its books), a book, a collection and a readlist",
            "action": "reconcile",
            "snapshot": "s2",
            "trigger": "did_become_active",
            "expect": {
                "mirror": "s2",
                "tallies": {"series_removed": 1, "books_removed": 2, "collections_removed": 1,
                            "readlists_removed": 1},
                "tombstoned": {
                    "series": ["series-3"],
                    "books": ["book-1-3", "book-3-1", "book-3-2", "book-3-3", "book-4-1"],
                    "collections": ["col-2"],
                    "readlists": ["rl-2"],
                },
            },
        },
        {
            "label": "reconcile again with nothing changed: a clean sweep touches no rows",
            "action": "reconcile",
            "snapshot": "s2",
            "trigger": "app_launch",
            "expect": {"mirror": "s2", "clean": True, "tallies": {"series_removed": 0, "books_removed": 0}},
        },
        {
            "label": "book metadata edit + library move are mirrored field by field",
            "action": "reconcile",
            "snapshot": "s5",
            "trigger": "manual_refresh",
            "expect": {
                "mirror": "s5",
                "tallies": {"books_changed": 1},
            },
        },
        {
            "label": "another device finished a book: series counters move, lastModified does not",
            "action": "reconcile",
            "snapshot": "s6",
            "trigger": "did_become_active",
            "expect": {"mirror": "s6"},
        },
        {
            "label": "series comes back under the same id: its tombstone is cleared",
            "action": "reconcile",
            "snapshot": "s1",
            "trigger": "network_recovered",
            "expect": {"mirror": "s1", "tombstoned": {"series": [], "books": [], "collections": [], "readlists": []}},
        },
    ],
}

interrupt_scenario = {
    "name": "stage5-interrupt",
    "description": "Bootstrap interrupted mid-sweep resumes from its cursor; an "
    "offline reconcile keeps the mirror readable and heals it when the network returns.",
    "sse": "disabled",
    "serverId": "stage5",
    "snapshots": [S0, S2, S3],
    "steps": [
        {
            "label": "bootstrap a 3-page library but the series sweep dies after page 1",
            "action": "bootstrap",
            "snapshot": "s3",
            "fault": {"kind": "network", "entity": "series", "afterPages": 1},
            "expectSuccess": False,
            "expect": {
                "failedEntities": ["series"],
                "requests": {"libraries": 1, "series": 1, "books": 0, "collections": 0},
                "mirror": "s3-partial-1",
            },
        },
        {
            "label": "relaunch resumes from the stored cursor (page 1) instead of re-downloading",
            "action": "bootstrap",
            "snapshot": "s3",
            "expect": {
                "mirror": "s3",
                "resumedSteps": ["series"],
                "skippedSteps": ["libraries"],
                "requests": {"libraries": 0, "series": 2, "books": 12, "collections": 2, "readlists": 1, "read_progress": 1},
            },
        },
        {
            # Mid-series interruption: the cursor names the series that was
            # still paging, which is the resume path a "skip finished series"
            # loop can walk straight past.
            "label": "a fresh mirror dies inside the books sweep, mid-series",
            "action": "bootstrap_fresh",
            "snapshot": "s3",
            "fault": {"kind": "network", "entity": "books", "afterPages": 3},
            "expectSuccess": False,
            "expect": {
                "failedEntities": ["books"],
                "cursors": {"books": "series=bulk-0-1|page=1"},
                "requests": {"series": 3, "books": 3, "collections": 0},
            },
        },
        {
            "label": "relaunch resumes the interrupted series at its stored page and mirrors the rest",
            "action": "bootstrap",
            "snapshot": "s3",
            "expect": {
                "mirror": "s3",
                "resumedSteps": ["books"],
                "skippedSteps": ["libraries", "series"],
                "requests": {"libraries": 0, "series": 0, "books": 9, "collections": 2, "readlists": 1, "read_progress": 1},
            },
        },
        {
            # Reconcile is interrupted mid-sweep too: the series step has by
            # then already propagated the remote deletions, and the books
            # cursor must point at the series that was never fetched.
            "label": "a reconcile sweep dies inside the books step, at a series boundary",
            "action": "reconcile",
            "snapshot": "s2",
            "trigger": "manual_refresh",
            "fault": {"kind": "network", "entity": "books", "afterPages": 3},
            "expectSuccess": False,
            "expect": {
                "failedEntities": ["books"],
                "cursors": {"books": "series=series-5|page=0"},
                "requests": {"series": 1, "books": 3, "collections": 0},
            },
        },
        {
            "label": "the next sweep resumes at that series and finishes converging",
            "action": "reconcile",
            "snapshot": "s2",
            "trigger": "network_recovered",
            "expect": {
                "mirror": "s2",
                "requests": {"books": 1},
            },
        },
        {
            "label": "the library is browsable offline: a fully failing transport loses nothing",
            "action": "reconcile",
            "snapshot": "s3",
            "trigger": "network_recovered",
            "fault": {"kind": "network", "entity": None, "afterPages": 0},
            "expectSuccess": False,
            "expect": {"mirror": "s2", "failedEntities": ["libraries"], "rollupError": True},
        },
        {
            "label": "network is back and the server now serves a different library: reconcile converges",
            "action": "reconcile",
            "snapshot": "s3",
            "trigger": "network_recovered",
            "expect": {"mirror": "s3"},
        },
        {
            "label": "one more sweep confirms the mirror is stable (SSE never worked)",
            "action": "reconcile",
            "snapshot": "s3",
            "trigger": "sse_reconnected",
            "expect": {"mirror": "s3", "clean": True},
        },
    ],
}

# s3-partial-1: after page 1 of the series sweep committed, only those 2
# series (and no books) are mirrored.
partial = copy.deepcopy(S3)
partial["id"] = "s3-partial-1"
partial["series"] = [S3_SERIES_PAGES[0]]
partial["books"] = {}
partial["collections"] = [[]]
partial["readlists"] = [[]]
partial["onDeck"] = [[]]
ALL["s3-partial-1"] = partial

for scenario in (reconcile_scenario, interrupt_scenario):
    scenario["snapshots"].append(ALL["s3-partial-1"])

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, "scenario-reconcile.json"), "w", encoding="utf-8") as handle:
    json.dump(reconcile_scenario, handle, indent=2, ensure_ascii=False)
    handle.write("\n")
with open(os.path.join(OUT, "scenario-interrupt.json"), "w", encoding="utf-8") as handle:
    json.dump(interrupt_scenario, handle, indent=2, ensure_ascii=False)
    handle.write("\n")

for snap in (S0, S1, S2, S3, S5, S6):
    print(f"{snap['id']}: libraries={count(snap,'libraries')} series={count(snap,'series')} "
          f"books={count(snap,'books')} collections={count(snap,'collections')} "
          f"readlists={count(snap,'readlists')} seriesPages={len(snap['series'])}")
print("wrote", OUT)
