//! Guest-side TCP over washy's `host_tcp_*` imports — host-brokered raw sockets (Layer 2).
//!
//! wasm32-wasip1 has no sockets; the host owns a real `:gen_tcp` connection (SSRF-guarded) and the bytes
//! shuttle across the membrane. This is the general path for protocols Layer 1's HTTP shim doesn't cover.
//! A wasip1-socket backend for `std::net`/`mio` would lower onto these same imports.

#[link(wasm_import_module = "env")]
extern "C" {
    fn host_tcp_connect(host: *const u8, host_len: i32, port: i32) -> i32;
    fn host_tcp_send(fd: i32, buf: *const u8, len: i32) -> i32;
    fn host_tcp_recv(fd: i32, buf: *mut u8, cap: i32) -> i32;
    fn host_tcp_close(fd: i32) -> i32;
}

/// A host-brokered TCP stream. Owns the guest-side fd; closes on drop.
pub struct TcpStream {
    fd: i32,
}

impl TcpStream {
    /// Connect to `host:port` through the host (SSRF-guarded host-side). `Err` if no transport is wired
    /// (the run lacks a network grant) or the host refused/failed the connection.
    pub fn connect(host: &str, port: u16) -> Result<TcpStream, &'static str> {
        let fd = unsafe { host_tcp_connect(host.as_ptr(), host.len() as i32, port as i32) };
        if fd < 0 {
            Err("tcp connect failed (no transport or refused)")
        } else {
            Ok(TcpStream { fd })
        }
    }

    /// Send bytes; returns the count written (or a negative error).
    pub fn send(&self, data: &[u8]) -> i32 {
        unsafe { host_tcp_send(self.fd, data.as_ptr(), data.len() as i32) }
    }

    /// Receive up to `max` bytes. An empty vec means EOF or error.
    pub fn recv(&self, max: usize) -> Vec<u8> {
        let mut buf = vec![0u8; max];
        let n = unsafe { host_tcp_recv(self.fd, buf.as_mut_ptr(), max as i32) };
        if n <= 0 {
            Vec::new()
        } else {
            buf.truncate(n as usize);
            buf
        }
    }
}

impl Drop for TcpStream {
    fn drop(&mut self) {
        unsafe {
            host_tcp_close(self.fd);
        }
    }
}
