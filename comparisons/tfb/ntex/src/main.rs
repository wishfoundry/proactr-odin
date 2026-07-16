//! Plain text + size ladder + fortunes. Linux: neon-uring (io_uring).

use ntex::web::{self, App, Error, HttpResponse};
use once_cell::sync::Lazy;
use rusqlite::{Connection, OpenFlags};
use std::env;
use std::sync::Mutex;

static DB_PATH: Lazy<String> =
    Lazy::new(|| env::var("DATABASE_PATH").unwrap_or_else(|_| "/tmp/proactr-tfb.sqlite".into()));

static DB: Lazy<Mutex<Connection>> = Lazy::new(|| {
    let conn = Connection::open_with_flags(
        &*DB_PATH,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap_or_else(|e| panic!("open {}: {e} (run schema/prepare.sh)", *DB_PATH));
    conn.busy_timeout(std::time::Duration::from_secs(5)).ok();
    conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        .ok();
    Mutex::new(conn)
});

fn make_payload(n: usize) -> Vec<u8> {
    const PAT: &[u8] = b"0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789ABCDEF";
    let mut b = vec![0u8; n];
    for (i, x) in b.iter_mut().enumerate() {
        *x = PAT[i % PAT.len()];
    }
    b
}

static P_4K: Lazy<Vec<u8>> = Lazy::new(|| make_payload(4 * 1024));
static P_64K: Lazy<Vec<u8>> = Lazy::new(|| make_payload(64 * 1024));
static P_1M: Lazy<Vec<u8>> = Lazy::new(|| make_payload(1024 * 1024));
static P_4M: Lazy<Vec<u8>> = Lazy::new(|| make_payload(4 * 1024 * 1024));

struct Fortune {
    id: i32,
    message: String,
}

fn plain_slice(body: &'static [u8]) -> HttpResponse {
    HttpResponse::Ok()
        .header("Server", "Ntex")
        .header("Content-Type", "text/plain")
        .body(body)
}

fn plain_owned(body: Vec<u8>) -> HttpResponse {
    HttpResponse::Ok()
        .header("Server", "Ntex")
        .header("Content-Type", "text/plain")
        .body(body)
}

#[web::get("/plaintext")]
async fn plaintext() -> HttpResponse {
    plain_slice(b"Hello, World!")
}

#[web::get("/s/4k")]
async fn s4k() -> HttpResponse {
    plain_owned(P_4K.clone())
}

#[web::get("/s/64k")]
async fn s64k() -> HttpResponse {
    plain_owned(P_64K.clone())
}

#[web::get("/s/1m")]
async fn s1m() -> HttpResponse {
    plain_owned(P_1M.clone())
}

#[web::get("/s/4m")]
async fn s4m() -> HttpResponse {
    plain_owned(P_4M.clone())
}

#[web::get("/fortunes")]
async fn fortunes() -> Result<HttpResponse, Error> {
    let mut list = {
        let conn = DB.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT id, message FROM fortune")
            .map_err(ntex::web::error::ErrorInternalServerError)?;
        let rows = stmt
            .query_map([], |row| {
                Ok(Fortune {
                    id: row.get(0)?,
                    message: row.get(1)?,
                })
            })
            .map_err(ntex::web::error::ErrorInternalServerError)?;
        let mut v = Vec::with_capacity(16);
        for r in rows {
            v.push(r.map_err(ntex::web::error::ErrorInternalServerError)?);
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
    let _ = &*DB;
    let _ = (&*P_4K, &*P_64K, &*P_1M, &*P_4M);
    let backend = if cfg!(target_os = "linux") {
        "neon-uring/io_uring"
    } else {
        "tokio (non-Linux dev)"
    };
    println!("ntex tfb peer on 0.0.0.0:{port} db={} io={backend}", *DB_PATH);
    web::server(|| {
        App::new()
            .service(plaintext)
            .service(s4k)
            .service(s64k)
            .service(s1m)
            .service(s4m)
            .service(fortunes)
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
