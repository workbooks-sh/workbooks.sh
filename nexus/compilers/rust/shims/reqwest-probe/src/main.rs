//! An async reqwest CLI — the kind of code a real vendored CLI (gws) is built from: `#[tokio::main]`,
//! `reqwest::get(...).await`, JSON. Compiled to wasm32-wasip1, it reaches the network through the
//! reqwest shim → host_http → the host transport. No sockets, no TLS, no tokio-net in the guest.

#[tokio::main(flavor = "current_thread")]
async fn main() {
    match reqwest::get("https://example.com/").await {
        Ok(resp) => {
            let status = resp.status();
            match resp.text().await {
                Ok(body) => println!("status={} bytes={}", status, body.len()),
                Err(e) => {
                    eprintln!("read error: {}", e);
                    std::process::exit(2);
                }
            }
        }
        Err(e) => {
            eprintln!("error: {}", e);
            std::process::exit(1);
        }
    }
}
