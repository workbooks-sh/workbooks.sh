#[allow(warnings)]
mod bindings;
use bindings::Guest;
struct Component;
impl Guest for Component {
    fn probe(target: String) -> String {
        use std::io::{Read, Write};
        use std::net::TcpStream;
        match TcpStream::connect(&target) {
            Ok(mut s) => {
                let _ = s.write_all(b"GET / HTTP/1.0\r\nHost: x\r\n\r\n");
                let mut b = [0u8; 256];
                let n = s.read(&mut b).unwrap_or(0);
                format!("OK n={} has_http={}", n, String::from_utf8_lossy(&b[..n]).contains("HTTP/"))
            }
            Err(e) => format!("ERR {}", e),
        }
    }
}
bindings::export!(Component with_types_in bindings);
