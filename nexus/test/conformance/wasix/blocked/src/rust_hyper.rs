// §8 hyper — the marquee HTTP server crate (over tokio/mio). Blocked on §7 unix std.
// Runtime side proven by unix_tcp_server.c (§3) + rust_tokio (async runtime). Serves one
// request on loopback, fetches it in-process, asserts the body, exits 42. Once mio's unix
// reactor compiles, hyper rides §3 sockets + §0-B poll with no new host import.
use hyper::body::Bytes;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response};
use http_body_util::Full;
use std::convert::Infallible;
use tokio::net::{TcpListener, TcpStream};

async fn hello(_: Request<hyper::body::Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    Ok(Response::new(Full::new(Bytes::from("ok"))))
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let io = hyper_util::rt::TokioIo::new(stream);
        let _ = http1::Builder::new()
            .serve_connection(io, service_fn(hello))
            .await;
    });

    // minimal client: write a raw GET, read the response, assert 200 + "ok"
    let mut conn = TcpStream::connect(addr).await.unwrap();
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    conn.write_all(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        .await
        .unwrap();
    let mut buf = Vec::new();
    conn.read_to_end(&mut buf).await.unwrap();
    let resp = String::from_utf8_lossy(&buf);
    std::process::exit(if resp.contains("200") && resp.contains("ok") { 42 } else { 1 });
}
