// wb-broker wasi:sockets verification fixture (raw TCP via the STANDARD wasi:sockets API).
//
// BUILD (the guest-build lane, established iter 38):
//   rustup target add wasm32-wasip2
//   rustc --target wasm32-wasip2 -O test/broker_e2e/wasi_sockets_probe.rs -o wasi_sockets.component.wasm
// This produces a real COMPONENT (binary version 0x1000d) importing wasi:sockets/tcp@0.2.0 — std::net on
// wasm32-wasip2 is backed by wasi:sockets. Run via the patched runtime (Wasmex.Components + allow_http) so
// the connect goes through socket_addr_check (SSRF) + the spawn_blocking outbound fix (wb-0beq).
//
// STATUS: it INSTANTIATES (the runtime provides wasi:sockets/tcp), but this is a wasi:cli/run COMMAND
// component and Wasmex.Components.call_function only invokes WORLD-level function exports — so the connect
// can't be triggered yet. CLOSE-OUT: rebuild as a cargo-component REACTOR exporting `probe: func(string)->
// string` (this same std::net body inside), callable via call_function like the net_probe fixture.
use std::io::{Read, Write};
use std::net::TcpStream;

fn main() {
    let target = std::env::var("WB_TARGET").unwrap_or_else(|_| "1.1.1.1:80".to_string());
    match TcpStream::connect(&target) {
        Ok(mut s) => {
            let _ = s.write_all(b"GET / HTTP/1.0\r\nHost: x\r\n\r\n");
            let mut buf = [0u8; 256];
            let n = s.read(&mut buf).unwrap_or(0);
            let body = String::from_utf8_lossy(&buf[..n]);
            println!("OK n={} has_http={}", n, body.contains("HTTP/"));
        }
        Err(e) => println!("ERR {}", e),
    }
}
