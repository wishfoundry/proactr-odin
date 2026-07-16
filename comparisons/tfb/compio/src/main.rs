//! Size ladder + fortunes on compio (io_uring on Linux).

use compio::buf::BufResult;
use compio::io::{AsyncRead, AsyncWriteExt};
use compio::net::{TcpListener, TcpStream};
use compio::runtime::spawn;
use once_cell::sync::Lazy;
use rusqlite::{Connection, OpenFlags};
use std::env;
use std::io;
use std::net::SocketAddr;
use std::sync::Mutex;

static DB_PATH: Lazy<String> =
    Lazy::new(|| env::var("DATABASE_PATH").unwrap_or_else(|_| "/tmp/proactr-tfb.sqlite".into()));

static DB: Lazy<Mutex<Connection>> = Lazy::new(|| {
    let conn = Connection::open_with_flags(
        &*DB_PATH,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .unwrap_or_else(|e| panic!("open {}: {e}", *DB_PATH));
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

fn fortunes_body() -> String {
    let mut list = {
        let conn = DB.lock().unwrap();
        let mut stmt = conn.prepare("SELECT id, message FROM fortune").unwrap();
        let rows = stmt
            .query_map([], |row| {
                Ok(Fortune {
                    id: row.get(0)?,
                    message: row.get(1)?,
                })
            })
            .unwrap();
        let mut v = Vec::with_capacity(16);
        for r in rows {
            v.push(r.unwrap());
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
    html
}

fn http_response(status: &str, ctype: &str, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len() + 160);
    out.extend_from_slice(format!("HTTP/1.1 {status}\r\n").as_bytes());
    out.extend_from_slice(b"Server: Compio\r\n");
    out.extend_from_slice(format!("Content-Type: {ctype}\r\n").as_bytes());
    out.extend_from_slice(format!("Content-Length: {}\r\n", body.len()).as_bytes());
    out.extend_from_slice(b"Connection: keep-alive\r\n\r\n");
    out.extend_from_slice(body);
    out
}

fn route(req_head: &str) -> Vec<u8> {
    let line = req_head.lines().next().unwrap_or("");
    if line.starts_with("GET /fortunes") {
        let body = fortunes_body();
        http_response("200 OK", "text/html; charset=utf-8", body.as_bytes())
    } else if line.starts_with("GET /s/4k") {
        http_response("200 OK", "text/plain", &P_4K)
    } else if line.starts_with("GET /s/64k") {
        http_response("200 OK", "text/plain", &P_64K)
    } else if line.starts_with("GET /s/1m") {
        http_response("200 OK", "text/plain", &P_1M)
    } else if line.starts_with("GET /s/4m") {
        http_response("200 OK", "text/plain", &P_4M)
    } else if line.starts_with("GET /plaintext") || line.starts_with("GET / ") {
        http_response("200 OK", "text/plain", b"Hello, World!")
    } else {
        http_response("404 Not Found", "text/plain", b"not found")
    }
}

fn find_header_end(buf: &[u8]) -> Option<usize> {
    buf.windows(4).position(|w| w == b"\r\n\r\n")
}

async fn handle(mut stream: TcpStream) -> io::Result<()> {
    let mut pending: Vec<u8> = Vec::with_capacity(4096);
    loop {
        let buf = vec![0u8; 8192];
        let BufResult(res, buf) = stream.read(buf).await;
        let n = res?;
        if n == 0 {
            return Ok(());
        }
        pending.extend_from_slice(&buf[..n]);
        while let Some(pos) = find_header_end(&pending) {
            let head = std::str::from_utf8(&pending[..pos]).unwrap_or("");
            let close = head.to_ascii_lowercase().contains("connection: close");
            let resp = route(head);
            pending.drain(..pos + 4);
            let BufResult(wres, _) = stream.write_all(resp).await;
            wres?;
            if close {
                return Ok(());
            }
        }
        if pending.len() > 2 * 1024 * 1024 {
            return Ok(());
        }
    }
}

#[compio::main]
async fn main() -> io::Result<()> {
    let _ = &*DB;
    let _ = (&*P_4K, &*P_64K, &*P_1M, &*P_4M);
    let port: u16 = env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(18080);
    let addr: SocketAddr = format!("0.0.0.0:{port}").parse().unwrap();
    let listener = TcpListener::bind(addr).await?;
    println!(
        "compio tfb peer on {addr} db={} io=compio/io_uring",
        *DB_PATH
    );
    loop {
        let (stream, _) = listener.accept().await?;
        spawn(handle(stream)).detach();
    }
}
