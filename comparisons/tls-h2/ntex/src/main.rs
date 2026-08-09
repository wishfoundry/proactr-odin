//! TLS/H2 peer for comparisons/tls-h2.
//! ntex + OpenSSL; bind_openssl sets ALPN h2|http/1.1.
//! Instrumentation: GET /_matrix/stats (reqs + body bytes).

use ntex::web::{self, App, HttpResponse, HttpServer};
use once_cell::sync::Lazy;
use openssl::ssl::{SslAcceptor, SslFiletype, SslMethod};
use std::env;
use std::sync::atomic::{AtomicU64, Ordering};

static REQS: AtomicU64 = AtomicU64::new(0);
static BYTES: AtomicU64 = AtomicU64::new(0);

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
static PLAIN: &[u8] = b"Hello, World!";
static SSE: &[u8] = b"event: ping\ndata: 1\n\nevent: ping\ndata: 2\n\n";

fn note(body: &[u8]) {
    REQS.fetch_add(1, Ordering::Relaxed);
    BYTES.fetch_add(body.len() as u64, Ordering::Relaxed);
}

async fn plaintext() -> HttpResponse {
    note(PLAIN);
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(PLAIN)
}

async fn s4k() -> HttpResponse {
    note(&P_4K);
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(P_4K.as_slice())
}

async fn s64k() -> HttpResponse {
    note(&P_64K);
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(P_64K.as_slice())
}

async fn s1m() -> HttpResponse {
    note(&P_1M);
    HttpResponse::Ok()
        .content_type("text/plain")
        .body(P_1M.as_slice())
}

async fn sse() -> HttpResponse {
    note(SSE);
    HttpResponse::Ok()
        .content_type("text/event-stream")
        .body(SSE)
}

async fn stats() -> HttpResponse {
    let body = format!(
        "peer=ntex\nreqs={}\nbytes={}\ntls=openssl\nio=neon-uring\n",
        REQS.load(Ordering::Relaxed),
        BYTES.load(Ordering::Relaxed)
    );
    HttpResponse::Ok().content_type("text/plain").body(body)
}

async fn reset() -> HttpResponse {
    REQS.store(0, Ordering::Relaxed);
    BYTES.store(0, Ordering::Relaxed);
    HttpResponse::Ok().body("ok\n")
}

#[ntex::main]
async fn main() -> std::io::Result<()> {
    let port: u16 = env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(18443);
    let workers: usize = env::var("WORKERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(8);
    let cert = env::var("CERT_FILE").unwrap_or_else(|_| "certs/cert.pem".into());
    let key = env::var("KEY_FILE").unwrap_or_else(|_| "certs/key.pem".into());

    let mut builder = SslAcceptor::mozilla_intermediate(SslMethod::tls())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
    builder
        .set_private_key_file(&key, SslFiletype::PEM)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
    builder
        .set_certificate_chain_file(&cert)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
    // ntex bind_openssl also injects ALPN h2|http/1.1.

    let addr = format!("0.0.0.0:{port}");
    eprintln!(
        "ntex tls-h2 on {addr} workers={workers} tls=openssl alpn=h2|http/1.1 io=neon-uring instrument=reqs+bytes"
    );

    HttpServer::new(|| {
        App::new()
            .route("/plaintext", web::get().to(plaintext))
            .route("/api/tiny", web::get().to(plaintext))
            .route("/s/4k", web::get().to(s4k))
            .route("/s/64k", web::get().to(s64k))
            .route("/s/1m", web::get().to(s1m))
            .route("/sse", web::get().to(sse))
            .route("/_matrix/stats", web::get().to(stats))
            .route("/_matrix/reset", web::post().to(reset))
            .route("/_matrix/reset", web::get().to(reset))
    })
    .workers(workers)
    .bind_openssl(&addr, builder)?
    .run()
    .await
}
