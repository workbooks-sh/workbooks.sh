//! Test fixture for the workbooks:engine Dock. `run` calls back into the host
//! imports and returns what it saw — proving typed component imports work end
//! to end. `run("spin")` loops forever, to prove the Instance fuel cap traps a
//! runaway component.
#[allow(warnings)]
mod bindings;
use bindings::Guest;

struct Probe;

impl Guest for Probe {
    fn run(input: String) -> String {
        if input == "spin" {
            #[allow(clippy::empty_loop)]
            loop {}
        }
        let info = bindings::session_info();
        let rows = bindings::vfs_query("SELECT path FROM vfs ORDER BY path");
        // On "command", exercise run-command (uppercase via a WASM command).
        let cmd = if input == "command" {
            bindings::run_command("upper", "made loud")
        } else {
            String::new()
        };
        format!(
            "{{\"input\":\"{}\",\"info\":{},\"vfs\":{},\"command\":\"{}\"}}",
            input, info, rows, cmd
        )
    }
}

bindings::export!(Probe with_types_in bindings);
