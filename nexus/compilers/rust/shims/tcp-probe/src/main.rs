//! A real Rust CLI doing raw TCP — connect, send, recv — with NO guest sockets. The bytes go through
//! washy's host_tcp_* imports to the host's real :gen_tcp (SSRF-guarded). Proves Layer 2 end-to-end.

fn main() {
    match host_tcp::TcpStream::connect("example.com", 80) {
        Ok(stream) => {
            let sent = stream.send(b"GET / HTTP/1.0\r\n\r\n");
            let resp = stream.recv(64);
            println!("sent={} recv={}", sent, String::from_utf8_lossy(&resp));
        }
        Err(e) => {
            eprintln!("error: {}", e);
            std::process::exit(1);
        }
    }
}
