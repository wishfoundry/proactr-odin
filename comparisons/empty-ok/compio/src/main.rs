//! Minimal HTTP/1 empty-ok on the compio completion runtime.
//! Intentionally tiny: accept + write fixed response (no full framework).

use std::env;
use std::io;
use std::net::SocketAddr;
use std::sync::Arc;

use compio::net::{TcpListener, TcpStream};
use compio::runtime::spawn;
use compio::io::{AsyncReadExt, AsyncWriteExt};

const RESP: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\nOK";

#[compio::main]
async fn main() -> io::Result<()> {
    let port: u16 = env::var("PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(18080);
    let addr: SocketAddr = format!("0.0.0.0:{port}").parse().unwrap();
    let listener = TcpListener::bind(addr).await?;
    println!("compio empty-ok on {addr}");

    loop {
        let (stream, _) = listener.accept().await?;
        spawn(handle(stream)).detach();
    }
}

async fn handle(mut stream: TcpStream) -> io::Result<()> {
    let mut buf = vec![0u8; 4096];
    loop {
        let n = match stream.read(&mut buf).await {
            Ok(0) => return Ok(()),
            Ok(n) => n,
            Err(e) => return Err(e),
        };
        // Extremely naive: if we got any request bytes, answer OK.
        // Enough for oha keep-alive GETs in empty-ok ceiling tests.
        if n > 0 {
            stream.write_all(RESP).await?;
            // if client closed or sent Connection: close, drop
            let req = std::str::from_utf8(&buf[..n]).unwrap_or("");
            if req.to_ascii_lowercase().contains("connection: close") {
                return Ok(());
            }
        }
    }
}

// silence unused in some feature combos
#[allow(dead_code)]
fn _arc_hint() {
    let _ = Arc::new(0);
}
