//! Local workbook structure operations, read straight from HTML.
//!
//! A workbook IS an HTML file built from `work-*` web components; `crate::workbook`
//! reads its structure with a small standard HTML scanner (no kernel, no wasm), so
//! these verbs run locally with no running runtime — identically on the CLI's
//! native and wasm targets. Reading the source file goes through the Io seam
//! (native fs / wasm Dock).

use crate::io::Io;
use crate::workbook;
use anyhow::Result;

fn read_src(io: &dyn Io, file: &str) -> Result<String> {
    if file == "-" {
        use std::io::Read;
        let mut s = String::new();
        std::io::stdin().read_to_string(&mut s)?;
        return Ok(s);
    }
    Ok(String::from_utf8(io.read(file)?)?)
}

/// `wb query <workbook.html>` — the `work-*` structure → node rows (JSON).
pub fn query(io: &dyn Io, file: &str) -> Result<String> {
    Ok(workbook::parse_headlines(&read_src(io, file)?))
}

/// `wb tangle <workbook.html>` — the build plan (worlds + components, JSON).
pub fn tangle(io: &dyn Io, file: &str) -> Result<String> {
    Ok(workbook::tangle_plan(&read_src(io, file)?))
}

/// `wb lint <workbook.html>` — diagnostics over the component graph (JSON).
pub fn lint(io: &dyn Io, file: &str) -> Result<String> {
    Ok(workbook::validate(&read_src(io, file)?))
}
