//! jq command (stdin/stdout). Protocol: first line = the jq filter, the rest =
//! the JSON input. Each output value is printed on its own line. A wasi-clean
//! wrapper around jaq-interpret — the jaq binary itself doesn't cross-compile
//! (fd-lock), but the interpreter library is pure.
use std::io::{Read, Write};
use jaq_interpret::{Ctx, FilterT, ParseCtx, RcIter, Val};

fn main() {
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input).unwrap();
    let (filter_src, json_src) = match input.split_once('\n') {
        Some((f, rest)) => (f.trim(), rest.trim()),
        None => (input.trim(), "null"),
    };

    let json: serde_json::Value = serde_json::from_str(if json_src.is_empty() { "null" } else { json_src })
        .unwrap_or(serde_json::Value::Null);

    let mut defs = ParseCtx::new(Vec::new());
    defs.insert_natives(jaq_core::core());
    defs.insert_defs(jaq_std::std());

    let (f, errs) = jaq_parse::parse(filter_src, jaq_parse::main());
    if !errs.is_empty() {
        eprintln!("jq: parse error");
        std::process::exit(2);
    }
    let f = defs.compile(f.unwrap());

    let inputs = RcIter::new(core::iter::empty());
    let out = f.run((Ctx::new([], &inputs), Val::from(json)));
    let mut w = std::io::stdout();
    for v in out {
        match v {
            Ok(val) => writeln!(w, "{}", val).unwrap(),
            Err(_) => { eprintln!("jq: runtime error"); std::process::exit(3); }
        }
    }
}
