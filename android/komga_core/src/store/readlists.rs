//! Readlists local store — mirror rows + ordered membership
//! (`readlist_books`, position preserved from the remote `bookIds`).

use rusqlite::{params, params_from_iter, Connection, Row};

use crate::model::readlist::ReadList;

/// Locally stored readlist row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadlistRow {
    pub server_id: String,
    pub remote_id: String,
    pub name: String,
    pub summary: Option<String>,
    pub ordered: bool,
    pub filtered: bool,
    pub created_date: Option<String>,
    pub last_modified_date: Option<String>,
}

fn row_to_readlist(row: &Row) -> rusqlite::Result<ReadlistRow> {
    Ok(ReadlistRow {
        server_id: row.get("server_id")?,
        remote_id: row.get("remote_id")?,
        name: row.get("name")?,
        summary: row.get("summary")?,
        ordered: row.get("ordered")?,
        filtered: row.get("filtered")?,
        created_date: row.get("created_date")?,
        last_modified_date: row.get("last_modified_date")?,
    })
}

/// Batch upsert with membership replacement, in one transaction.
pub fn save_readlists_batch(
    conn: &Connection,
    server_id: &str,
    readlists: &[ReadList],
) -> rusqlite::Result<usize> {
    let tx = conn.unchecked_transaction()?;
    let mut written = 0;
    for item in readlists {
        tx.execute(
            "INSERT INTO readlists (server_id, remote_id, name, summary, ordered, filtered, created_date, last_modified_date)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(server_id, remote_id) DO UPDATE SET
               name = excluded.name,
               summary = excluded.summary,
               ordered = excluded.ordered,
               filtered = excluded.filtered,
               created_date = excluded.created_date,
               last_modified_date = excluded.last_modified_date",
            params![
                server_id,
                item.id,
                item.name,
                item.summary,
                item.ordered,
                item.filtered,
                item.created_date,
                item.last_modified_date,
            ],
        )?;
        tx.execute(
            "DELETE FROM readlist_books WHERE server_id = ?1 AND readlist_id = ?2",
            params![server_id, item.id],
        )?;
        for (position, book_id) in item.book_ids.iter().enumerate() {
            tx.execute(
                "INSERT OR IGNORE INTO readlist_books (server_id, readlist_id, book_id, position)
                 VALUES (?1, ?2, ?3, ?4)",
                params![server_id, item.id, book_id, position as i64],
            )?;
        }
        written += 1;
    }
    tx.commit()?;
    Ok(written)
}

/// Searchable paged list (LIKE-based local search — SQLite only).
pub fn list_readlists(
    conn: &Connection,
    server_id: &str,
    search: Option<&str>,
    limit: i64,
    offset: i64,
) -> rusqlite::Result<Vec<ReadlistRow>> {
    let (mut sql, mut params) = search_clause(server_id, search);
    params.push(Box::new(limit));
    params.push(Box::new(offset));
    sql.insert_str(0, "SELECT * FROM readlists ");
    sql.push_str(&format!(
        " ORDER BY name COLLATE NOCASE LIMIT ?{} OFFSET ?{}",
        params.len() - 1,
        params.len()
    ));
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(params), row_to_readlist)?;
    rows.collect()
}

pub fn count_readlists(
    conn: &Connection,
    server_id: &str,
    search: Option<&str>,
) -> rusqlite::Result<i64> {
    let (where_sql, params) = search_clause(server_id, search);
    conn.query_row(
        &format!("SELECT COUNT(*) FROM readlists {where_sql}"),
        params_from_iter(params),
        |row| row.get(0),
    )
}

fn search_clause(
    server_id: &str,
    search: Option<&str>,
) -> (String, Vec<Box<dyn rusqlite::types::ToSql>>) {
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(server_id.to_string())];
    let mut sql = "WHERE server_id = ?1".to_string();
    if let Some(term) = search {
        if !term.trim().is_empty() {
            sql.push_str(" AND (name LIKE ?2 COLLATE NOCASE OR summary LIKE ?2 COLLATE NOCASE)");
            params.push(Box::new(format!("%{}%", term.trim())));
        }
    }
    (sql, params)
}

/// One readlist row (detail endpoint).
pub fn get_readlist(
    conn: &Connection,
    server_id: &str,
    readlist_id: &str,
) -> rusqlite::Result<Option<ReadlistRow>> {
    let mut stmt =
        conn.prepare("SELECT * FROM readlists WHERE server_id = ?1 AND remote_id = ?2")?;
    let mut rows = stmt.query_map(params![server_id, readlist_id], row_to_readlist)?;
    rows.next().transpose()
}

/// Book remote_ids in list order (position column).
pub fn list_readlist_books(
    conn: &Connection,
    server_id: &str,
    readlist_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT book_id FROM readlist_books WHERE server_id = ?1 AND readlist_id = ?2 ORDER BY position",
    )?;
    let rows = stmt.query_map(params![server_id, readlist_id], |row| row.get(0))?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::readlist::ReadList;
    use crate::store::open_in_memory;

    fn readlist(id: &str, name: &str, books: Vec<&str>) -> ReadList {
        ReadList {
            id: id.into(),
            name: name.into(),
            summary: Some("A list.".into()),
            ordered: true,
            filtered: false,
            book_ids: books.into_iter().map(String::from).collect(),
            created_date: Some("2025-01-01T00:00:00Z".into()),
            last_modified_date: Some("2025-01-01T00:00:00Z".into()),
        }
    }

    #[test]
    fn save_list_search_and_order_preserved() {
        let conn = open_in_memory().unwrap();
        save_readlists_batch(
            &conn,
            "server-1",
            &[readlist("rl1", "Weekend", vec!["b3", "b1", "b2"])],
        )
        .unwrap();
        save_readlists_batch(&conn, "server-2", &[readlist("rl1", "Other", vec!["b9"])]).unwrap();

        let rows = list_readlists(&conn, "server-1", None, 10, 0).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].name, "Weekend");
        assert!(rows[0].ordered);

        assert_eq!(count_readlists(&conn, "server-1", Some("week")).unwrap(), 1);
        assert_eq!(count_readlists(&conn, "server-1", Some("nope")).unwrap(), 0);

        // Order preserved from the remote bookIds.
        assert_eq!(
            list_readlist_books(&conn, "server-1", "rl1").unwrap(),
            vec!["b3", "b1", "b2"]
        );
        assert_eq!(
            list_readlist_books(&conn, "server-2", "rl1").unwrap(),
            vec!["b9"]
        );
    }

    #[test]
    fn upsert_replaces_membership() {
        let conn = open_in_memory().unwrap();
        let mut rl = readlist("rl1", "Weekend", vec!["b1"]);
        save_readlists_batch(&conn, "s", &[rl.clone()]).unwrap();
        rl.book_ids = vec!["b2".into(), "b3".into()];
        save_readlists_batch(&conn, "s", &[rl]).unwrap();
        assert_eq!(
            list_readlist_books(&conn, "s", "rl1").unwrap(),
            vec!["b2", "b3"]
        );
    }
}
