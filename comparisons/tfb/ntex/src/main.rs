//! TechEmpower-shaped ntex peer.
//! Uses serde_json (not sonic_rs) — closer to application code than TE max-score builds.

use ntex::web::{self, App, Error, HttpRequest, HttpResponse};
use once_cell::sync::Lazy;
use rand::Rng;
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;
use std::cmp::{max, min};
use std::env;
use std::sync::Mutex;

static DB_PATH: Lazy<String> =
    Lazy::new(|| env::var("DATABASE_PATH").unwrap_or_else(|_| "/tmp/proactr-tfb.sqlite".into()));

/// One connection per worker thread via thread_local would be ideal; ntex handlers
/// are async so we use a small pool of connections behind a mutex for honesty/simplicity.
static DB: Lazy<Mutex<Connection>> = Lazy::new(|| {
    let conn = Connection::open_with_flags(
        &*DB_PATH,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap_or_else(|e| panic!("open {}: {e} (run schema/prepare.sh)", *DB_PATH));
    conn
        .busy_timeout(std::time::Duration::from_secs(5))
        .ok();
    // Reasonable for concurrent readers
    conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        .ok();
    Mutex::new(conn)
});

#[derive(Serialize)]
struct Message {
    message: &'static str,
}

#[derive(Serialize)]
struct World {
    id: i32,
    #[serde(rename = "randomNumber")]
    random_number: i32,
}

struct Fortune {
    id: i32,
    message: String,
}

#[web::get("/json")]
async fn json() -> HttpResponse {
    let body = serde_json::to_vec(&Message {
        message: "Hello, World!",
    })
    .unwrap();
    HttpResponse::Ok()
        .header("Server", "Ntex")
        .header("Content-Type", "application/json")
        .body(body)
}

#[web::get("/plaintext")]
async fn plaintext() -> HttpResponse {
    HttpResponse::Ok()
        .header("Server", "Ntex")
        .header("Content-Type", "text/plain")
        .body("Hello, World!")
}

#[web::get("/fortunes")]
async fn fortunes() -> Result<HttpResponse, Error> {
    let mut list = {
        let conn = DB.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT id, message FROM fortune")
            .map_err(|e| ntex::web::error::ErrorInternalServerError(e))?;
        let rows = stmt
            .query_map([], |row| {
                Ok(Fortune {
                    id: row.get(0)?,
                    message: row.get(1)?,
                })
            })
            .map_err(|e| ntex::web::error::ErrorInternalServerError(e))?;
        let mut v = Vec::with_capacity(16);
        for r in rows {
            v.push(r.map_err(|e| ntex::web::error::ErrorInternalServerError(e))?);
        }
        v
    };
    list.push(Fortune {
        id: 0,
        message: "Additional fortune added at request time.".into(),
    });
    list.sort_by(|a, b| a.message.cmp(&b.message));

    let mut html = String::with_capacity(2048);
    html.push_str("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>");
    html.push_str("<tr><th>id</th><th>message</th></tr>");
    for f in &list {
        html.push_str("<tr><td>");
        html.push_str(&f.id.to_string());
        html.push_str("</td><td>");
        html.push_str(&escape_html(&f.message));
        html.push_str("</td></tr>");
    }
    html.push_str("</table></body></html>");

    Ok(HttpResponse::Ok()
        .header("Server", "Ntex")
        .header("Content-Type", "text/html; charset=utf-8")
        .body(html))
}

#[web::get("/db")]
async fn db() -> Result<HttpResponse, Error> {
    let id = rand::thread_rng().gen_range(1..=10_000);
    let world = {
        let conn = DB.lock().unwrap();
        conn.query_row(
            "SELECT id, randomNumber FROM world WHERE id = ?1",
            [id],
            |row| {
                Ok(World {
                    id: row.get(0)?,
                    random_number: row.get(1)?,
                })
            },
        )
        .map_err(|e| ntex::web::error::ErrorInternalServerError(e))?
    };
    let body = serde_json::to_vec(&world).unwrap();
    Ok(HttpResponse::Ok()
        .header("Server", "Ntex")
        .header("Content-Type", "application/json")
        .body(body))
}

#[web::get("/queries")]
async fn queries(req: HttpRequest) -> Result<HttpResponse, Error> {
    let mut n: u32 = 1;
    if let Some(q) = req.uri().query() {
        for pair in q.split('&') {
            if let Some(v) = pair.strip_prefix("queries=") {
                if let Ok(parsed) = v.parse::<u32>() {
                    n = parsed;
                }
            }
        }
    }
    n = max(1, min(500, n));

    let mut out = Vec::with_capacity(n as usize);
    let mut rng = rand::thread_rng();
    {
        let conn = DB.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT id, randomNumber FROM world WHERE id = ?1")
            .map_err(|e| ntex::web::error::ErrorInternalServerError(e))?;
        for _ in 0..n {
            let id = rng.gen_range(1..=10_000);
            let w = stmt
                .query_row([id], |row| {
                    Ok(World {
                        id: row.get(0)?,
                        random_number: row.get(1)?,
                    })
                })
                .map_err(|e| ntex::web::error::ErrorInternalServerError(e))?;
            out.push(w);
        }
    }
    let body = serde_json::to_vec(&out).unwrap();
    Ok(HttpResponse::Ok()
        .header("Server", "Ntex")
        .header("Content-Type", "application/json")
        .body(body))
}

fn escape_html(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

#[ntex::main]
async fn main() -> std::io::Result<()> {
    let port: u16 = env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(18080);
    // Force DB open early
    let _ = &*DB;
    println!("ntex tfb peer on 0.0.0.0:{port} db={}", *DB_PATH);
    web::server(|| {
        App::new()
            .service(json)
            .service(plaintext)
            .service(fortunes)
            .service(db)
            .service(queries)
    })
    .bind(format!("0.0.0.0:{port}"))?
    .workers(
        env::var("WORKERS")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(1),
    )
    .run()
    .await
}
