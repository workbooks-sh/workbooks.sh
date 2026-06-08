//! `wb` — the BEAM-backed runtime API for in-sandbox Rust (wb-ova/wb-1mv).
//!
//! The division of labor: wasm does pure COMPUTE (memory-safe, bounded); the BEAM owns I/O,
//! storage, time, and concurrency (process-safe, supervised, Policy-gated). This crate is the
//! seam — thin, safe Rust wrappers over host functions the runtime (Elixir) implements. A program
//! that needs to cross out of pure compute calls `wb::*`; it never touches a raw socket, file, or
//! clock, and the host does the dangerous part safely.
//!
//! Compile in-sandbox with `no_exceptions: true, allow_undefined: true` so the host_* externs
//! survive as wasm imports, then run via `Workbooks.RustDock.run(wasm, profile: ...)` — the profile's
//! Policy decides which caps exist (request one it didn't grant → the module won't instantiate).
//! It is 1.74-compatible (thin) so it builds with the in-sandbox compiler.
//!
//! WHY this instead of tokio/std::net: those need an OS (threads, epoll) the sandbox doesn't have,
//! and tokio doesn't compile under the ~1.74 ceiling anyway. `wb::*` gives the same CAPABILITIES via
//! a different API, with the BEAM as the async/IO runtime. For concurrency, the system runs many
//! instances at once (each its own process) — so blocking `wb` calls + many instances cover most
//! needs without an in-program executor.

mod ffi {
    extern "C" {
        // Ambient (always available).
        pub fn host_now() -> i64; // unix epoch millis (wall clock — wasm has none)
        // Storage (cap: "vfs") — the Instance's sandboxed key/value store (no host FS reach).
        pub fn host_vfs_write(pp: i32, pl: i32, dp: i32, dl: i32) -> i32; // 0 ok / -1 err
        pub fn host_vfs_read(pp: i32, pl: i32, op: i32, oc: i32) -> i32; // bytes / -1 missing
        // Egress (cap: "http") — the BEAM performs the request; Policy-gated.
        pub fn host_http_get(up: i32, ul: i32, op: i32, oc: i32) -> i32; // body len / -1 err
        // Batch/concurrent egress — the BEAM fetches all URLs in parallel (Task.async_stream).
        pub fn host_http_get_many(up: i32, ul: i32, op: i32, oc: i32) -> i32; // marshaled len / -1
    }
}

#[inline]
fn rd_u32(b: &[u8], p: &mut usize) -> u32 {
    let v = u32::from_le_bytes([b[*p], b[*p + 1], b[*p + 2], b[*p + 3]]);
    *p += 4;
    v
}
#[inline]
fn rd_i32(b: &[u8], p: &mut usize) -> i32 {
    let v = i32::from_le_bytes([b[*p], b[*p + 1], b[*p + 2], b[*p + 3]]);
    *p += 4;
    v
}

/// Wall-clock time, provided by the host (wasm has no clock of its own).
pub mod time {
    /// Milliseconds since the unix epoch.
    pub fn now_millis() -> i64 {
        unsafe { super::ffi::host_now() }
    }
}

/// Sandboxed key/value storage backed by the Instance (cap: "vfs"). Never reaches the host FS.
pub mod vfs {
    /// Store `data` at `path`. Returns false on error / if the cap isn't granted.
    pub fn write(path: &str, data: &[u8]) -> bool {
        unsafe { super::ffi::host_vfs_write(path.as_ptr() as i32, path.len() as i32, data.as_ptr() as i32, data.len() as i32) == 0 }
    }
    /// Read the bytes at `path`, or None if missing / not permitted.
    pub fn read(path: &str) -> Option<Vec<u8>> {
        let mut b = vec![0u8; 1 << 20];
        let n = unsafe { super::ffi::host_vfs_read(path.as_ptr() as i32, path.len() as i32, b.as_mut_ptr() as i32, b.len() as i32) };
        if n < 0 { None } else { b.truncate(n as usize); Some(b) }
    }
    /// Read UTF-8 text at `path`.
    pub fn read_string(path: &str) -> Option<String> {
        read(path).and_then(|v| String::from_utf8(v).ok())
    }
}

/// Network egress, performed by the BEAM (cap: "http"; the program never opens a socket).
pub mod http {
    /// HTTP GET — the host fetches it (verified TLS) and returns the body. None on error / no cap.
    pub fn get(url: &str) -> Option<Vec<u8>> {
        let mut b = vec![0u8; 4 << 20];
        let n = unsafe { super::ffi::host_http_get(url.as_ptr() as i32, url.len() as i32, b.as_mut_ptr() as i32, b.len() as i32) };
        if n < 0 { None } else { b.truncate(n as usize); Some(b) }
    }
    /// HTTP GET, decoded as UTF-8 text.
    pub fn get_string(url: &str) -> Option<String> {
        get(url).and_then(|v| String::from_utf8(v).ok())
    }

    /// CONCURRENT batch GET — one call, the BEAM fetches all URLs in parallel and returns each
    /// body (None on failure), order-preserved. This is "async" done by the BEAM: the program is
    /// synchronous, the parallelism is entirely host-side. Result length == urls.len().
    pub fn get_many(urls: &[&str]) -> Vec<Option<Vec<u8>>> {
        let joined = urls.join("\n");
        let mut out = vec![0u8; 16 << 20]; // 16 MiB total cap
        let n = unsafe {
            super::ffi::host_http_get_many(joined.as_ptr() as i32, joined.len() as i32, out.as_mut_ptr() as i32, out.len() as i32)
        };
        if n < 0 {
            return urls.iter().map(|_| None).collect();
        }
        out.truncate(n as usize);

        let mut p = 0usize;
        let count = super::rd_u32(&out, &mut p) as usize;
        let mut res = Vec::with_capacity(count);
        for _ in 0..count {
            let len = super::rd_i32(&out, &mut p);
            if len < 0 {
                res.push(None);
            } else {
                let l = len as usize;
                res.push(Some(out[p..p + l].to_vec()));
                p += l;
            }
        }
        res
    }
}
