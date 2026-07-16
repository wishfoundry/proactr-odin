use ntex::web::{self, App, HttpResponse};

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
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(18080);
    println!("ntex empty-ok on 0.0.0.0:{port}");
    web::server(|| App::new().service(index).service(health))
        .bind(format!("0.0.0.0:{port}"))?
        .run()
        .await
}
