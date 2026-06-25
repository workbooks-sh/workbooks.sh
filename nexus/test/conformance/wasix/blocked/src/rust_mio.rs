// §8 mio — the unix epoll/poll reactor (tokio/hyper's foundation). Blocked on §7 unix std.
// Runtime side proven by unix_tcp_server.c (§3 sock_* + poll_oneoff). mio gates its Poll
// backend on cfg(unix); once std advertises unix, this drives sock_open/bind/listen +
// poll_oneoff readiness end-to-end. Exit 42 iff the registered listener reports readable.
use mio::net::TcpListener;
use mio::{Events, Interest, Poll, Token};
use std::io::Write;
use std::net::TcpStream;

fn main() {
    let mut poll = Poll::new().unwrap();
    let mut events = Events::with_capacity(8);
    let addr = "127.0.0.1:0".parse().unwrap();
    let mut listener = TcpListener::bind(addr).unwrap();
    let local = listener.local_addr().unwrap();
    poll.registry()
        .register(&mut listener, Token(0), Interest::READABLE)
        .unwrap();

    // a client connects so the listener becomes readable
    let mut client = TcpStream::connect(local).unwrap();
    client.write_all(b"ping").unwrap();

    poll.poll(&mut events, None).unwrap();
    let mut ok = false;
    for event in events.iter() {
        if event.token() == Token(0) && event.is_readable() {
            ok = true;
        }
    }
    std::process::exit(if ok { 42 } else { 1 });
}
