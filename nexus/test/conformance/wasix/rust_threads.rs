use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
fn main() {
    let counter = Arc::new(AtomicI32::new(0));
    let mut handles = vec![];
    for _ in 0..2 {
        let c = counter.clone();
        handles.push(thread::spawn(move || {
            for _ in 0..1000 { c.fetch_add(1, Ordering::SeqCst); }
        }));
    }
    for h in handles { h.join().unwrap(); }
    std::process::exit(if counter.load(Ordering::SeqCst) == 2000 { 42 } else { 1 });
}
