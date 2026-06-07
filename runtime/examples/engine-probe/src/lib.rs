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
        // On "command", exercise run-command through the Dock with argv. Both are
        // prebuilt wasm commands (no Javy needed). jq + grep are :stdin1 commands —
        // the host folds argv into the first stdin line per the command's arg mode.
        let cmd = if input == "command" {
            bindings::run_command("jq", "{\"n\":42}", &[".n".to_string()]) // expect 42
        } else {
            String::new()
        };
        let argv = if input == "command" {
            bindings::run_command("grep", "alpha\nwasm rocks\nbeta", &["wasm".to_string()]) // expect "wasm rocks"
        } else {
            String::new()
        };
        format!(
            "{{\"input\":\"{}\",\"info\":{},\"vfs\":{},\"command\":\"{}\",\"argv\":\"{}\"}}",
            input, info, rows, cmd, argv
        )
    }
}

bindings::export!(Probe with_types_in bindings);
