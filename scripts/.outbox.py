import io

# ---------------------------------------------------------------- Rust store
p = 'android/komga_core/src/store/prune.rs'
s = io.open(p, encoding='utf-8').read()

s = s.replace('''//! Cascade rules mirror `specs/contracts/delete-propagation/README.md`:
//! covers / cache records for the deleted entity are dropped (the facade
//! removes the files from disk), and pending Outbox entries for a deleted
//! book are discarded — uploading progress for a book the server deleted is
//! meaningless.''',
'''//! Cascade rules mirror `specs/contracts/delete-propagation/README.md`:
//! covers / cache records for the deleted entity go with it (the facade removes
//! the files from disk). Queued Outbox entries deliberately *survive*: a remote
//! deletion is inferred from "this id was not in the sweep", and offset
//! pagination can skip an id when rows shift under a concurrent change. Getting
//! that wrong would silently discard a user action that can never be
//! re-derived, while every mirrored row we do delete is refetchable. The upload
//! phase owns the "server says this book is gone" decision.''', 1)

old = '''        "DELETE FROM downloads WHERE server_id = ?1 AND book_id = ?2",
        "DELETE FROM download_pages WHERE server_id = ?1 AND book_id = ?2",
        "DELETE FROM pending_mutations WHERE server_id = ?1 AND entity_id = ?2",
    ] {'''
new = '''        "DELETE FROM downloads WHERE server_id = ?1 AND book_id = ?2",
        "DELETE FROM download_pages WHERE server_id = ?1 AND book_id = ?2",
    ] {'''
assert s.count(old) == 1, 'rust delete list'
s = s.replace(old, new)

# test: the cascade now keeps the queued mutation
old = '''        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM pending_mutations WHERE server_id = ?1"),
            0
        );'''
new = '''        // The queued upload is *not* discarded here: a deletion inferred from a
        // sweep can be a pagination artefact, and a lost user action cannot be
        // re-derived. The upload phase owns that call.
        assert_eq!(
            count(&conn, "SELECT COUNT(*) FROM pending_mutations WHERE server_id = ?1"),
            1
        );
        assert_eq!(
            conn.query_row::<String, _, _>(
                "SELECT mutation_type FROM pending_mutations WHERE server_id = ?1",
                params!["srv"],
                |row| row.get(0)
            )
            .unwrap(),
            "READ_PROGRESS"
        );'''
assert s.count(old) == 1, 'rust test'
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8').write(s)

# --------------------------------------------------------------- Swift store
p = 'apple/KomgaKit/Sources/KomgaStore/Prune.swift'
s = io.open(p, encoding='utf-8').read()
i = s.index('"DELETE FROM pending_mutations WHERE server_id = ? AND entity_id = ?",')
# drop that list entry, whatever the surrounding syntax is
line_start = s.rindex('\n', 0, i)
line_end = s.index('\n', i)
s = s[:line_start] + s[line_end:]
io.open(p, 'w', encoding='utf-8').write(s)
print('removed the outbox delete on both platforms')
