//! A Workbook component that fetches a URL through the Dock. `run(url)` asks the
//! host to browse — the host (Workbooks.Browse) owns network egress, so this
//! component never opens a socket (no wasi:http/sockets granted). The extracted
//! page comes back as a JSON string through the typed `browse-fetch` import,
//! proving the Dock call reaches Workbooks.Browse end to end (Route B).
#[allow(warnings)]
mod bindings;
use bindings::Guest;
struct Probe;
impl Guest for Probe {
    fn run(input: String) -> String {
        bindings::browse_fetch(&input)
    }
}
bindings::export!(Probe with_types_in bindings);
