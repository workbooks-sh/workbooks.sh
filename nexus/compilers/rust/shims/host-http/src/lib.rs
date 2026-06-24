//! Guest-side client for the washy `host_http` import — host-brokered HTTP for a sandboxed wasm CLI.
//!
//! wasm32-wasip1 has no sockets and the guest has no TLS: a request is handed to the host, which
//! performs it (SSRF-guarded, TLS host-side) and buffers the response back. Same pipe-friendly ABI
//! as `host_exec`: `host_http` returns the response body length (or -1 if no transport is wired);
//! `host_http_read` copies the body into the guest's buffer and returns the HTTP status.
//!
//! This is the one crate a vendored CLI (or a `reqwest` shim patched in via `[patch.crates-io]`)
//! links to reach the network — written once, reused by every CLI, no per-CLI forks.

#[link(wasm_import_module = "env")]
extern "C" {
    fn host_http(req: *const u8, len: i32) -> i32;
    fn host_http_read(buf: *mut u8) -> i32;
}

/// A response from the host transport.
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

impl Response {
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }
}

/// Errors from the host transport (a missing transport = the run lacks a network grant).
#[derive(Debug)]
pub enum Error {
    NoTransport,
}

/// Perform an HTTP request through the host. The wire format the host parses is
/// `"METHOD URL\nHeader: value\n...\n\nbody"` — opaque to washy, interpreted host-side by Dock.serve.
pub fn request(method: &str, url: &str, headers: &[(&str, &str)], body: &[u8]) -> Result<Response, Error> {
    let mut req: Vec<u8> = Vec::with_capacity(method.len() + url.len() + body.len() + 64);
    req.extend_from_slice(method.as_bytes());
    req.push(b' ');
    req.extend_from_slice(url.as_bytes());
    req.push(b'\n');
    for (k, v) in headers {
        req.extend_from_slice(k.as_bytes());
        req.extend_from_slice(b": ");
        req.extend_from_slice(v.as_bytes());
        req.push(b'\n');
    }
    req.push(b'\n');
    req.extend_from_slice(body);

    let n = unsafe { host_http(req.as_ptr(), req.len() as i32) };
    if n < 0 {
        return Err(Error::NoTransport);
    }

    let mut buf = vec![0u8; n as usize];
    let status = unsafe { host_http_read(buf.as_mut_ptr()) };
    Ok(Response {
        status: status as u16,
        body: buf,
    })
}

/// Convenience: a GET.
pub fn get(url: &str) -> Result<Response, Error> {
    request("GET", url, &[], b"")
}
