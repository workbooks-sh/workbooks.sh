// The desktop binary. All logic lives in the lib so it can be tested + reused.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    workbooks_desktop_lib::run()
}
