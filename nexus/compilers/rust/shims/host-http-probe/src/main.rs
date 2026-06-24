//! A real Rust CLI that makes an HTTP request — with NO sockets, NO TLS, NO tokio. It links only the
//! `host-http` shim, so the request goes out through washy's host_http import to the host transport.
//! This proves the guest-side path Layer 1 stands on: a compiled Rust program does host-brokered HTTP
//! inside the sandbox.

fn main() {
    match host_http::get("https://example.com/") {
        Ok(r) => println!("status={} bytes={}", r.status, r.body.len()),
        Err(e) => {
            eprintln!("error: {:?}", e);
            std::process::exit(1);
        }
    }
}
