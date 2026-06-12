//! `wbx dev` — watch → re-render → serve a live preview. Native-only:
//! the wasm build compiles this module but the verb bails (agents in the
//! sandbox use `wbx bundle`; dev is an interactive, long-running verb).
//!
//! Deliberately std-only: a tiny HTTP loop on TcpListener + mtime polling.
//! The preview auto-reloads via an injected poll of `/__v` (a version
//! counter bumped on every re-render).

use anyhow::Result;

#[cfg(target_arch = "wasm32")]
pub fn dev(_src: &str, _port: Option<u16>) -> Result<String> {
    anyhow::bail!("`wbx dev` needs the native binary (it serves a local preview); in-sandbox, use `wbx bundle`")
}

#[cfg(not(target_arch = "wasm32"))]
pub fn dev(src: &str, port: Option<u16>) -> Result<String> {
    use anyhow::Context;
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    let org_path = crate::local::find_org(src)?;
    fn render(org_path: &std::path::Path, bump: u64) -> Result<String> {
        use anyhow::Context;
        let org = std::fs::read_to_string(org_path)
            .with_context(|| format!("read {}", org_path.display()))?;
        let body = oql::render(&org);
        let reload = format!(
            "<script>(()=>{{const v={bump};setInterval(async()=>{{try{{const r=await fetch('/__v');\
             if((await r.text()).trim()!==String(v))location.reload();}}catch(_){{}}}},500)}})()</script>"
        );
        // the kernel renders a fragment — give the preview a real document
        let title = org_path.file_stem().unwrap_or_default().to_string_lossy();
        let html = if body.trim_start().to_lowercase().starts_with("<!doctype")
            || body.trim_start().to_lowercase().starts_with("<html")
        {
            let mut h = body;
            if let Some(i) = h.rfind("</body>") {
                h.insert_str(i, &reload);
            } else {
                h.push_str(&reload);
            }
            h
        } else {
            format!(
                "<!doctype html><html><head><meta charset=\"utf-8\">\
                 <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\
                 <title>{title} — wbx dev</title></head><body>{body}{reload}</body></html>"
            )
        };
        Ok(html)
    }

    let version = Arc::new(AtomicU64::new(1));
    let html = Arc::new(std::sync::RwLock::new(render(&org_path, 1)?));

    // watcher: poll mtime; on change re-render + bump the version counter
    {
        let org_path = org_path.clone();
        let version = Arc::clone(&version);
        let html = Arc::clone(&html);
        std::thread::spawn(move || {
            let mtime = |p: &std::path::Path| {
                std::fs::metadata(p).and_then(|m| m.modified()).ok()
            };
            let mut last = mtime(&org_path);
            loop {
                std::thread::sleep(std::time::Duration::from_millis(300));
                let now = mtime(&org_path);
                if now != last {
                    last = now;
                    let v = version.fetch_add(1, Ordering::SeqCst) + 1;
                    if let Ok(h) = render(&org_path, v) {
                        *html.write().unwrap() = h;
                        eprintln!("wbx dev: rebuilt (v{v})");
                    } else {
                        eprintln!("wbx dev: source has errors — keeping last good build");
                    }
                }
            }
        });
    }

    // bind: requested port, else first free in 4321..4331
    let listener = match port {
        Some(p) => std::net::TcpListener::bind(("127.0.0.1", p))
            .with_context(|| format!("bind 127.0.0.1:{p}"))?,
        None => (4321..4331)
            .find_map(|p| std::net::TcpListener::bind(("127.0.0.1", p)).ok())
            .context("no free port in 4321..4331 — pass --port")?,
    };
    let addr = listener.local_addr()?;
    eprintln!("wbx dev: http://{addr} — watching {} (ctrl-c to stop)", org_path.display());

    for stream in listener.incoming() {
        let Ok(mut s) = stream else { continue };
        let mut buf = [0u8; 1024];
        let n = s.read(&mut buf).unwrap_or(0);
        let req = String::from_utf8_lossy(&buf[..n]);
        let path = req.split_whitespace().nth(1).unwrap_or("/");
        let (status, ctype, body) = if path == "/__v" {
            ("200 OK", "text/plain", version.load(Ordering::SeqCst).to_string())
        } else {
            ("200 OK", "text/html; charset=utf-8", html.read().unwrap().clone())
        };
        let _ = write!(
            s,
            "HTTP/1.1 {status}\r\ncontent-type: {ctype}\r\ncache-control: no-store\r\ncontent-length: {}\r\n\r\n{body}",
            body.len()
        );
    }
    Ok(String::new())
}
