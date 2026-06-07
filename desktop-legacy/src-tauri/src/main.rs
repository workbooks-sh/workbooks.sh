// Prevents an additional console window on Windows in release builds.
// (Has no effect on macOS / Linux.)
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
#![forbid(unsafe_code)]

fn main() {
    workbooks_desktop_lib::run()
}
