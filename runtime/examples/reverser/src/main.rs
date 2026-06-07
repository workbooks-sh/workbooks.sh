use std::io::{Read, Write};

fn main() {
    let mut s = String::new();
    std::io::stdin().read_to_string(&mut s).unwrap();
    let reversed: String = s.trim().chars().rev().collect();
    let v = serde_json::json!({ "reversed": reversed, "len": reversed.len() });
    std::io::stdout().write_all(v.to_string().as_bytes()).unwrap();
}
