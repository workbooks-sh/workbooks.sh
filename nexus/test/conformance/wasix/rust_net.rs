// Rust std::net TCP echo over loopback — validates §3 sockets through the RUST STD path.
// NB: wasix std's `local_addr()` returns the CACHED bind addr (it never re-reads the OS-assigned
// port), so bind(:0)+local_addr can't recover an ephemeral port ON WASIX — a std limitation, not a
// runtime one. Real wasix programs use a fixed port; so does this test. SO_REUSEADDR (std sets it)
// makes re-bind clean. Server thread accepts+echoes; main connects, round-trips "ping" → exit 42.
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::thread;

fn main() {
    let addr = "127.0.0.1:34567";
    let listener = TcpListener::bind(addr).unwrap();

    let server = thread::spawn(move || {
        let (mut conn, _) = listener.accept().unwrap();
        let mut buf = [0u8; 4];
        conn.read_exact(&mut buf).unwrap();
        conn.write_all(&buf).unwrap();
    });

    let mut client = TcpStream::connect(addr).unwrap();
    client.write_all(b"ping").unwrap();
    let mut echo = [0u8; 4];
    client.read_exact(&mut echo).unwrap();

    server.join().unwrap();
    std::process::exit(if &echo == b"ping" { 42 } else { 1 });
}
