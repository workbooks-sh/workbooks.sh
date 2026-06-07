//! grep command (stdin/stdout). Protocol: first line = the regex pattern, the
//! rest = the text. Matching lines are printed. A regex-crate wrapper (wasi-clean);
//! ripgrep's recursive file walking doesn't fit a stdin-only command, line-grep does.
use std::io::{Read, Write};
use regex::Regex;

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let (pat, body) = input.split_once('\n').unwrap_or((input.as_str(), ""));
    let re = match Regex::new(pat.trim()) {
        Ok(r) => r,
        Err(_) => { eprintln!("grep: invalid pattern"); std::process::exit(2); }
    };
    let mut w = std::io::stdout();
    for line in body.lines() {
        if re.is_match(line) {
            writeln!(w, "{}", line).unwrap();
        }
    }
}
