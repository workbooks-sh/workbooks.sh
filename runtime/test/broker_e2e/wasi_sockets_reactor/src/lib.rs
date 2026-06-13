#[allow(warnings)]
mod bindings;
use bindings::Guest;
struct Component;
impl Guest for Component {
    fn probe(target: String) -> String {
        // "udp:HOST:PORT" -> a real std::net::UdpSocket DNS query (the STANDARD wasi:sockets UDP path,
        // brokered via socket_addr_check); anything else -> the raw-TCP path.
        if let Some(addr) = target.strip_prefix("udp:") {
            return udp_dns_probe(addr);
        }

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

// Send a DNS A-query for example.com to `addr` over a standard std::net::UdpSocket and report the answer
// count. Exercises the STANDARD wasi:sockets UDP send path (socket_addr_check), the sibling of raw TCP.
fn udp_dns_probe(addr: &str) -> String {
    use std::net::UdpSocket;
    let sock = match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(e) => return format!("ERR bind {}", e),
    };
    // DNS query: id=0x1234, RD set, 1 question, example.com A/IN
    let query: &[u8] = &[
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 7, b'e', b'x', b'a',
        b'm', b'p', b'l', b'e', 3, b'c', b'o', b'm', 0, 0x00, 0x01, 0x00, 0x01,
    ];
    if let Err(e) = sock.send_to(query, addr) {
        return format!("ERR send {}", e);
    }
    let mut buf = [0u8; 512];
    match sock.recv_from(&mut buf) {
        Ok((n, _)) if n >= 8 => {
            let ancount = ((buf[6] as u16) << 8) | (buf[7] as u16);
            format!("OK dns ancount={}", ancount)
        }
        Ok((n, _)) => format!("ERR short n={}", n),
        Err(e) => format!("ERR recv {}", e),
    }
}
bindings::export!(Component with_types_in bindings);
