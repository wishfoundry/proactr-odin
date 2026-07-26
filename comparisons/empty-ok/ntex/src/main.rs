use ntex::web::{self, App, HttpResponse};
use std::env;

#[web::get("/")]
async fn index() -> HttpResponse {
    HttpResponse::Ok().body("OK")
}

#[web::get("/health")]
async fn health() -> HttpResponse {
    HttpResponse::Ok().body("ok")
}

#[ntex::main]
async fn main() -> std::io::Result<()> {
    let port: u16 = env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(18080);
    // Default 1; harness should pass WORKERS=8 for fair multi-peer runs.
    let workers: usize = env::var("WORKERS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1)
        .max(1);
    println!("ntex empty-ok on 0.0.0.0:{port} workers={workers}");
    web::server(|| App::new().service(index).service(health))
        .bind(format!("0.0.0.0:{port}"))?
        .workers(workers)
        .run()
        .await
}
