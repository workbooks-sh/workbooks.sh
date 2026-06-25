// §8 crossterm — terminal control crate (the TUI input/output layer). Blocked on §7 unix std.
// Runtime side proven by unix_termios.c (§4 tty_get/tty_set raw mode + winsize). crossterm
// gates its unix terminal backend on cfg(unix); once std advertises unix it rides §4 tty.
// Enters raw mode, queries terminal size, restores, exits 42.
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, size};

fn main() {
    enable_raw_mode().unwrap();
    let dims = size();
    disable_raw_mode().unwrap();
    std::process::exit(match dims {
        Ok((w, h)) if w > 0 && h > 0 => 42,
        _ => 1,
    });
}
