//! wb-pkh.12 — a component that reaches the Dock through the dock SDK wrapper
//! (dock::command::run), NOT raw bindings. Proves the SDK's bind! macro + cap
//! wrapper work through a real cargo-component build + Instance. run(input)
//! uppercases via the `upper` command; run("nope") exercises the error path.
#[allow(warnings)]
mod bindings;
use bindings::Guest;

dock::bind!(bindings, command);

struct Probe;
impl Guest for Probe {
    fn run(input: String) -> String {
        match command::run("upper", &input, &[]) {
            Ok(out) => out,
            Err(e) => format!("DOCK_ERR:{}", e.0),
        }
    }
}
bindings::export!(Probe with_types_in bindings);
