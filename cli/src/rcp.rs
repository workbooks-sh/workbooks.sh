//! Thin runtime client. Engine verbs become one RCP call; the runtime owns the
//! logic. This is the whole point: the CLI never reimplements the engine.

use crate::io::{HttpReq, Io};
use anyhow::Result;

/// GET/POST an RCP path on the running runtime.
pub fn call(io: &dyn Io, method: &str, path: &str, body: Option<&str>) -> Result<String> {
    io.http(HttpReq { method, path, body })
}
