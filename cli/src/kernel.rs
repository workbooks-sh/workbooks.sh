//! Local Work-format operations, backed by the kernel.
//!
//! The kernel is the same Rust crate (`runtime/kernel`, package `oql`) that
//! compiles to the wasm Component the runtime + desktop embed. Here we link its
//! native rlib, so these verbs run locally with no running runtime — identically
//! on the CLI's native and wasm targets.
//!
//! Reading the source file goes through the Io seam (native fs / wasm Dock).

use crate::io::Io;
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

/// `wb query <file.work>` — structure → node rows (JSON).
pub fn query(io: &dyn Io, file: &str) -> Result<String> {
    Ok(oql::parse_headlines(&read_src(io, file)?))
}

/// `wb tangle <file.work>` — the WIT-world-shaped build plan (JSON).
pub fn tangle(io: &dyn Io, file: &str) -> Result<String> {
    Ok(oql::tangle_plan(&read_src(io, file)?))
}

/// `wb lint <file.work>` — diagnostics over the plan (JSON).
pub fn lint(io: &dyn Io, file: &str) -> Result<String> {
    Ok(oql::validate(&read_src(io, file)?))
}
