//! Collections local store — mirror rows + membership (`collection_series`).
//! Membership is embedded in the remote CollectionDto (`seriesIds`), so
//! syncing a collection page also replaces its membership (多服务器隔离).

use rusqlite::{params, params_from_iter, Connection, Row};

use crate::model::collection::Collection;

/// Locally stored collection row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollectionRow {
    pub server_id: String,
    pub remote_id: String,
    pub name: String,
    pub ordered: bool,
    pub filtered: bool,
    pub created_date: Option<String>,
    pub last_modified_date: Option<String>,
}

fn row_to_collection(row: &Row) -> rusqlite::Result<CollectionRow> {
    Ok(CollectionRow {
        server_id: row.get("server_id")?,
        remote_id: row.get("remote_id")?,
        name: row.get("name")?,
        ordered: row.get("ordered")?,
        filtered: row.get("filtered")?,
        created_date: row.get("created_date")?,
        last_modified_date: row.get("last_modified_date")?,
    })
}

/// Batch upsert with membership replacement, in one transaction.
pub fn save_collections_batch(
    conn: &Connection,
    server_id: &str,
    collections: &[Collection],
) -> rusqlite::Result<usize> {
    let tx = conn.unchecked_transaction()?;
    let mut written = 0;
    for item in collections {
        tx.execute(
            "INSERT INTO collections (server_id, remote_id, name, ordered, filtered, created_date, last_modified_date)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(server_id, remote_id) DO UPDATE SET
               name = excluded.name,
               ordered = excluded.ordered,
               filtered = excluded.filtered,
               created_date = excluded.created_date,
               last_modified_date = excluded.last_modified_date",
            params![
                server_id,
                item.id,
                item.name,
                item.ordered,
                item.filtered,
                item.created_date,
                item.last_modified_date,
            ],
        )?;
        tx.execute(
            "DELETE FROM collection_series WHERE server_id = ?1 AND collection_id = ?2",
            params![server_id, item.id],
        )?;
        for series_id in &item.series_ids {
            tx.execute(
                "INSERT OR IGNORE INTO collection_series (server_id, collection_id, series_id)
                 VALUES (?1, ?2, ?3)",
                params![server_id, item.id, series_id],
            )?;
        }
        written += 1;
    }
    tx.commit()?;
    Ok(written)
}

/// Searchable paged list (LIKE-based local search — SQLite only).
pub fn list_collections(
    conn: &Connection,
    server_id: &str,
    search: Option<&str>,
    limit: i64,
    offset: i64,
) -> rusqlite::Result<Vec<CollectionRow>> {
    let (mut sql, mut params) = search_clause(server_id, search);
    params.push(Box::new(limit));
    params.push(Box::new(offset));
    sql.insert_str(0, "SELECT * FROM collections ");
    sql.push_str(&format!(
        " ORDER BY name COLLATE NOCASE LIMIT ?{} OFFSET ?{}",
        params.len() - 1,
        params.len()
    ));
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt.query_map(params_from_iter(params), row_to_collection)?;
    rows.collect()
}

pub fn count_collections(
    conn: &Connection,
    server_id: &str,
    search: Option<&str>,
) -> rusqlite::Result<i64> {
    let (where_sql, params) = search_clause(server_id, search);
    conn.query_row(
        &format!("SELECT COUNT(*) FROM collections {where_sql}"),
        params_from_iter(params),
        |row| row.get(0),
    )
}

/// `(WHERE sql, rusqlite params)` — keeps the LIMIT/OFFSET slots free
/// (they are `?2` / `?3` in the caller).
fn search_clause(
    server_id: &str,
    search: Option<&str>,
) -> (String, Vec<Box<dyn rusqlite::types::ToSql>>) {
    let mut params: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(server_id.to_string())];
    let mut sql = "WHERE server_id = ?1".to_string();
    if let Some(term) = search {
        if !term.trim().is_empty() {
            sql.push_str(" AND name LIKE ?2 COLLATE NOCASE");
            params.push(Box::new(format!("%{}%", term.trim())));
        }
    }
    (sql, params)
}

/// One collection row (detail endpoint).
pub fn get_collection(
    conn: &Connection,
    server_id: &str,
    collection_id: &str,
) -> rusqlite::Result<Option<CollectionRow>> {
    let mut stmt =
        conn.prepare("SELECT * FROM collections WHERE server_id = ?1 AND remote_id = ?2")?;
    let mut rows = stmt.query_map(params![server_id, collection_id], row_to_collection)?;
    rows.next().transpose()
}

/// Member series remote_ids (ordered by series name — membership has no
/// intrinsic order for unordered collections).
pub fn list_collection_series(
    conn: &Connection,
    server_id: &str,
    collection_id: &str,
) -> rusqlite::Result<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT cs.series_id FROM collection_series cs
         LEFT JOIN series s ON s.server_id = cs.server_id AND s.remote_id = cs.series_id
         WHERE cs.server_id = ?1 AND cs.collection_id = ?2
         ORDER BY COALESCE(s.name, cs.series_id) COLLATE NOCASE",
    )?;
    let rows = stmt.query_map(params![server_id, collection_id], |row| row.get(0))?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::collection::Collection;
    use crate::store::open_in_memory;

    fn collection(id: &str, name: &str, series: Vec<&str>) -> Collection {
        Collection {
            id: id.into(),
            name: name.into(),
            ordered: false,
            filtered: false,
            series_ids: series.into_iter().map(String::from).collect(),
            created_date: Some("2025-01-01T00:00:00Z".into()),
            last_modified_date: Some("2025-01-01T00:00:00Z".into()),
        }
    }

    #[test]
    fn save_list_search_and_membership() {
        let conn = open_in_memory().unwrap();
        save_collections_batch(
            &conn,
            "server-1",
            &[
                collection("c1", "Favorites", vec!["s1", "s3"]),
                collection("c2", "Dark", vec!["s2"]),
            ],
        )
        .unwrap();
        save_collections_batch(&conn, "server-2", &[collection("c1", "Other", vec!["s9"])])
            .unwrap();

        let rows = list_collections(&conn, "server-1", None, 10, 0).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].name, "Dark"); // COLLATE NOCASE
        assert_eq!(rows[0].remote_id, "c2");

        // Search is SQLite LIKE, server-scoped.
        assert_eq!(
            count_collections(&conn, "server-1", Some("fav")).unwrap(),
            1
        );
        let searched = list_collections(&conn, "server-1", Some("fav"), 10, 0).unwrap();
        assert_eq!(searched[0].name, "Favorites");

        // Membership isolated per server.
        assert_eq!(
            list_collection_series(&conn, "server-1", "c1").unwrap(),
            vec!["s1", "s3"]
        );
        assert_eq!(
            list_collection_series(&conn, "server-2", "c1").unwrap(),
            vec!["s9"]
        );
    }

    #[test]
    fn upsert_replaces_membership() {
        let conn = open_in_memory().unwrap();
        let mut c = collection("c1", "Favorites", vec!["s1"]);
        save_collections_batch(&conn, "s", &[c.clone()]).unwrap();
        c.series_ids = vec!["s2".into()];
        save_collections_batch(&conn, "s", &[c]).unwrap();
        assert_eq!(
            list_collection_series(&conn, "s", "c1").unwrap(),
            vec!["s2"]
        );
    }
}
