//! Local org operations, backed by the OQL kernel.
//!
//! The kernel is the same Rust crate (`runtime/kernel`, package `oql`) that
//! compiles to the wasm Component the runtime + desktop embed. Here we link its
//! native rlib, so these verbs run locally with no running runtime — identically
//! on the CLI's native and wasm targets.
//!
//! Reading the source file goes through the Io seam (native fs / wasm Dock).

use crate::io::Io;
use anyhow::Result;

fn read_org(io: &dyn Io, file: &str) -> Result<String> {
    Ok(String::from_utf8(io.read(file)?)?)
}

/// `wb query <file.org>` — structure → headline rows (JSON).
pub fn query(io: &dyn Io, file: &str) -> Result<String> {
    Ok(oql::parse_headlines(&read_org(io, file)?))
}

/// `wb tangle <file.org>` — the WIT-world-shaped build plan (JSON).
pub fn tangle(io: &dyn Io, file: &str) -> Result<String> {
    Ok(oql::tangle_plan(&read_org(io, file)?))
}

/// `wb lint <file.org>` — diagnostics over the plan (JSON).
pub fn lint(io: &dyn Io, file: &str) -> Result<String> {
    Ok(oql::validate(&read_org(io, file)?))
}
