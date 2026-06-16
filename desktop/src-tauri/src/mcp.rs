// Embedded MCP server — Claude Code drives the browser (wb-aakl.23).
//
// Architecture is LOCKED in desktop/docs/mcp.md (wb-aakl.11). This is the
// build-test implementation:
//
//   1. A `std::os::unix::net::UnixListener` at /tmp/workbooks-mcp.sock
//      (WB_MCP_SOCK override, 0600), thread-per-connection, newline-delimited
//      JSON-RPC 2.0. Methods: initialize / tools/list / tools/call. Started
//      from the Tauri setup() hook, gated by WB_MCP=1.
//
//   2. Native tools dispatch 1:1 onto existing `#[tauri::command]` bodies via
//      app.state::<_>() — no parallel implementation.
//
//   3. The KEYSTONE: the JS bridge. Tauri's `webview.eval()` is fire-and-forget,
//      so eval_js / dom_read / click / type / hover need a round-trip. Tauri
//      2.11 ships `WebviewWindow::eval_with_callback` (the evaluated JS result is
//      serialized to JSON and handed to a callback). We wrap the caller's JS in
//      an async IIFE, run it on the main thread, and block the JSON-RPC worker on
//      a oneshot channel until the callback fires (bounded by a timeout). This is
//      the bulk of the work and the thing that unblocks app-tier recording,
//      UI/UX regression testing, and the Nexus browser cap.
//
// NO network listener, ever — AF_UNIX only, same trust domain as the user.

use crate::store;
use crate::tabs;
use crate::workspaces;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc;
use std::time::Duration;
use tauri::{AppHandle, Manager};

const DEFAULT_SOCK: &str = "/tmp/workbooks-mcp.sock";
/// Hard cap on a single JS-bridge round-trip. Generous (DOM snapshots of large
/// pages, slow async waits) but bounded so a hung webview can't wedge a worker.
const EVAL_TIMEOUT: Duration = Duration::from_secs(15);
const PROTOCOL_VERSION: &str = "2024-11-05";

fn sock_path() -> String {
    std::env::var("WB_MCP_SOCK").unwrap_or_else(|_| DEFAULT_SOCK.to_string())
}

/// Start the accept loop. Called from `setup()` only when WB_MCP=1. Best-effort:
/// a bind failure logs and leaves the app otherwise unchanged.
pub fn start(app: &AppHandle) {
    let path = sock_path();
    // Removed + recreated on app start (a stale socket from a crashed run would
    // otherwise refuse the bind with EADDRINUSE).
    let _ = std::fs::remove_file(&path);

    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("[wb-mcp] could not bind {path}: {e}");
            return;
        }
    };

    // Local-user only.
    if let Err(e) = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)) {
        eprintln!("[wb-mcp] could not chmod {path}: {e}");
    }

    eprintln!("[wb-mcp] listening on {path}");
    let app = app.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    let app = app.clone();
                    std::thread::spawn(move || serve_conn(app, stream));
                }
                Err(e) => eprintln!("[wb-mcp] accept error: {e}"),
            }
        }
    });
}

/// One connection: read newline-delimited JSON-RPC requests, write
/// newline-delimited responses. Notifications (no `id`) get no reply.
fn serve_conn(app: AppHandle, stream: UnixStream) {
    let reader = BufReader::new(match stream.try_clone() {
        Ok(s) => s,
        Err(_) => return,
    });
    let mut writer = stream;

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }

        let req: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                let _ = write_msg(&mut writer, &rpc_error(Value::Null, -32700, &format!("parse error: {e}")));
                continue;
            }
        };

        let id = req.get("id").cloned().unwrap_or(Value::Null);
        let is_notification = req.get("id").is_none();
        let method = req.get("method").and_then(Value::as_str).unwrap_or("");
        let params = req.get("params").cloned().unwrap_or(json!({}));

        let response = handle_method(&app, method, params, id.clone());

        // Notifications expect no response.
        if is_notification {
            continue;
        }
        if let Some(resp) = response {
            if write_msg(&mut writer, &resp).is_err() {
                break;
            }
        }
    }
}

fn write_msg(w: &mut UnixStream, msg: &Value) -> std::io::Result<()> {
    let mut s = serde_json::to_string(msg).unwrap_or_else(|_| "{}".into());
    s.push('\n');
    w.write_all(s.as_bytes())?;
    w.flush()
}

fn rpc_ok(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

fn rpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

fn handle_method(app: &AppHandle, method: &str, params: Value, id: Value) -> Option<Value> {
    match method {
        "initialize" => Some(rpc_ok(
            id,
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "workbooks-browser", "version": env!("CARGO_PKG_VERSION") }
            }),
        )),
        // Some clients send this after `initialize`; ack quietly.
        "notifications/initialized" => None,
        "ping" => Some(rpc_ok(id, json!({}))),
        "tools/list" => Some(rpc_ok(id, json!({ "tools": tool_manifest() }))),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            Some(match call_tool(app, name, args) {
                Ok(content) => rpc_ok(id, json!({ "content": content, "isError": false })),
                Err(msg) => rpc_ok(
                    id,
                    json!({ "content": [text_content(&msg)], "isError": true }),
                ),
            })
        }
        other => Some(rpc_error(id, -32601, &format!("method not found: {other}"))),
    }
}

// ── MCP content helpers ────────────────────────────────────────────

fn text_content(s: &str) -> Value {
    json!({ "type": "text", "text": s })
}

fn json_content(v: &Value) -> Value {
    text_content(&serde_json::to_string_pretty(v).unwrap_or_else(|_| "null".into()))
}

// ── Tool manifest ──────────────────────────────────────────────────

fn tool_manifest() -> Value {
    json!([
        // Workbooks-native (1:1 onto existing commands).
        tool("tabs_list", "List open tabs and the active tab.", json!({})),
        tool("tabs_open", "Open a path/workbook as a tab.",
            json!({ "path": { "type": "string" } })),
        tool("tabs_focus", "Focus a tab by id.",
            json!({ "id": { "type": "string" } })),
        tool("tabs_close", "Close a tab by id.",
            json!({ "id": { "type": "string" } })),
        tool("bookmarks_list", "List bookmarks.", json!({})),
        tool("bookmark_add", "Add a bookmark.",
            json!({ "title": { "type": "string" }, "path": { "type": "string" } })),
        tool("bookmark_remove", "Remove a bookmark by id.",
            json!({ "id": { "type": "string" } })),
        tool("workspace_tree", "The active workspace + packages tree.", json!({})),
        tool("open_workbook", "Open a .html/.org workbook by path (focuses if already open).",
            json!({ "path": { "type": "string" } })),
        tool("weave", "Render (weave) workbook Org source via oql.wasm.",
            json!({ "org": { "type": "string" } })),
        tool("validate", "Validate workbook Org source via oql.wasm.",
            json!({ "org": { "type": "string" } })),
        tool("outline", "Parse headlines (outline) from Org source via oql.wasm.",
            json!({ "org": { "type": "string" } })),
        tool("viewer_state", "What is open + focused (tabs snapshot + window labels).", json!({})),
        // Generic webview (computer-use parity) — the JS bridge.
        tool("eval_js", "Run JavaScript in the focused webview and return its (JSON-serialized) value. Supports async (top-level await).",
            json!({ "js": { "type": "string" } })),
        tool("dom_read", "Snapshot the live DOM. Returns outerHTML by default, or innerText when text=true, optionally scoped to a CSS selector.",
            json!({
                "selector": { "type": "string", "description": "optional CSS selector to scope the read" },
                "text": { "type": "boolean", "description": "return innerText instead of outerHTML" }
            })),
        tool("click", "Dispatch a synthetic click on the first element matching a CSS selector.",
            json!({ "selector": { "type": "string" } })),
        tool("type", "Set the value of an input/textarea matched by a CSS selector and fire input/change events.",
            json!({ "selector": { "type": "string" }, "text": { "type": "string" } })),
        tool("hover", "Dispatch synthetic pointerover/mouseover on a CSS selector.",
            json!({ "selector": { "type": "string" } })),
        tool("screenshot", "Capture the focused webview as a PNG. (Pixel capture is the host/Linux capture tier — see RECORDING-SYSTEM-FINDINGS.md; the bridge returns guidance until that lands.)",
            json!({})),
        tool("list_windows", "List webview window labels.", json!({}))
    ])
}

fn tool(name: &str, description: &str, properties: Value) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties
        }
    })
}

// ── Dispatch ───────────────────────────────────────────────────────

fn arg_str(args: &Value, key: &str) -> Result<String, String> {
    args.get(key)
        .and_then(Value::as_str)
        .map(|s| s.to_string())
        .ok_or_else(|| format!("missing required string argument: {key}"))
}

fn call_tool(app: &AppHandle, name: &str, args: Value) -> Result<Vec<Value>, String> {
    match name {
        // ── Workbooks-native: reuse the exact command bodies ──────────
        "tabs_list" | "viewer_state" => {
            let mgr = app.state::<tabs::TabManager>();
            let snap = tabs::tab_list(mgr);
            let mut v = serde_json::to_value(&snap).map_err(|e| e.to_string())?;
            if name == "viewer_state" {
                let labels: Vec<String> =
                    app.webview_windows().keys().cloned().collect();
                v = json!({ "tabs": v, "windows": labels });
            }
            Ok(vec![json_content(&v)])
        }
        "tabs_open" | "open_workbook" => {
            let path = arg_str(&args, "path")?;
            let mgr = app.state::<tabs::TabManager>();
            let snap = tabs::tab_open(app.clone(), mgr, path);
            Ok(vec![json_content(&serde_json::to_value(&snap).map_err(|e| e.to_string())?)])
        }
        "tabs_focus" => {
            let id = arg_str(&args, "id")?;
            let mgr = app.state::<tabs::TabManager>();
            let snap = tabs::tab_focus(app.clone(), mgr, id);
            Ok(vec![json_content(&serde_json::to_value(&snap).map_err(|e| e.to_string())?)])
        }
        "tabs_close" => {
            let id = arg_str(&args, "id")?;
            let mgr = app.state::<tabs::TabManager>();
            let snap = tabs::tab_close(app.clone(), mgr, id);
            Ok(vec![json_content(&serde_json::to_value(&snap).map_err(|e| e.to_string())?)])
        }
        "bookmarks_list" => {
            Ok(vec![json_content(&serde_json::to_value(store::bookmark_list()).map_err(|e| e.to_string())?)])
        }
        "bookmark_add" => {
            let req = store::BookmarkCreate {
                title: arg_str(&args, "title")?,
                path: arg_str(&args, "path")?,
                command_slot: None,
            };
            let bm = store::bookmark_create(req)?;
            Ok(vec![json_content(&serde_json::to_value(bm).map_err(|e| e.to_string())?)])
        }
        "bookmark_remove" => {
            store::bookmark_delete(arg_str(&args, "id")?)?;
            Ok(vec![text_content("removed")])
        }
        "workspace_tree" => {
            let active = workspaces::workspace_get_active();
            let list = workspaces::workspace_list();
            Ok(vec![json_content(&json!({ "active": active, "workspaces": list }))])
        }
        "weave" => Ok(vec![text_content(&crate::weave(arg_str(&args, "org")?)?)]),
        "validate" => Ok(vec![text_content(&crate::validate(arg_str(&args, "org")?)?)]),
        "outline" => Ok(vec![text_content(&crate::outline(arg_str(&args, "org")?)?)]),

        // ── Generic webview: the JS bridge (the keystone) ─────────────
        "eval_js" => {
            let js = arg_str(&args, "js")?;
            let val = eval_js(app, &js)?;
            Ok(vec![json_content(&val)])
        }
        "dom_read" => {
            let selector = args.get("selector").and_then(Value::as_str);
            let as_text = args.get("text").and_then(Value::as_bool).unwrap_or(false);
            let val = eval_js(app, &dom_read_js(selector, as_text))?;
            // dom_read returns a string payload; unwrap it from JSON for clean output.
            let out = val.as_str().map(|s| s.to_string()).unwrap_or_else(|| val.to_string());
            Ok(vec![text_content(&out)])
        }
        "click" => {
            let selector = arg_str(&args, "selector")?;
            let val = eval_js(app, &click_js(&selector))?;
            Ok(vec![json_content(&val)])
        }
        "type" => {
            let selector = arg_str(&args, "selector")?;
            let text = arg_str(&args, "text")?;
            let val = eval_js(app, &type_js(&selector, &text))?;
            Ok(vec![json_content(&val)])
        }
        "hover" => {
            let selector = arg_str(&args, "selector")?;
            let val = eval_js(app, &hover_js(&selector))?;
            Ok(vec![json_content(&val)])
        }
        "list_windows" => {
            let labels: Vec<String> = app.webview_windows().keys().cloned().collect();
            Ok(vec![json_content(&json!(labels))])
        }
        "screenshot" => Err(
            "screenshot: pixel capture is the host/Linux capture tier (ScreenCaptureKit on \
             mac, x11grab/wf-recorder on Linux) — not the webview JS bridge. Use the record.sh \
             rig (tools/record/) for visual frames; use dom_read for structural assertions. \
             See docs/.plan/RECORDING-SYSTEM-FINDINGS.md."
                .into(),
        ),
        other => Err(format!("unknown tool: {other}")),
    }
}

// ── The JS bridge round-trip ───────────────────────────────────────
//
// Tauri's eval is fire-and-forget; Tauri 2.11's `eval_with_callback` hands the
// JSON-serialized result of the evaluated script to a callback. We wrap the
// caller's JS in an async IIFE so `await` works, JSON-stringify the result with
// an error envelope, and block the worker thread on a oneshot until the callback
// fires (or we time out). eval must run on the webview's main thread.

fn eval_js(app: &AppHandle, user_js: &str) -> Result<Value, String> {
    let window = app
        .get_webview_window("main")
        .ok_or_else(|| "no 'main' webview window".to_string())?;

    // Wrap so the result (or thrown error) comes back as one JSON string the
    // eval_with_callback serializer can hand us verbatim. We do our own
    // JSON.stringify inside the page so async values + structured results survive.
    let wrapped = format!(
        r#"(async () => {{
            try {{
                const __wb_result = await (async () => {{ {user_js}
                }})();
                return JSON.stringify({{ ok: true, value: __wb_result === undefined ? null : __wb_result }});
            }} catch (e) {{
                return JSON.stringify({{ ok: false, error: String(e && e.stack || e) }});
            }}
        }})()"#
    );

    let (tx, rx) = mpsc::channel::<String>();
    let cb = move |result: String| {
        // `result` is the JSON-serialized return value of the evaluated script.
        // Our IIFE resolves to a string, so `result` is that string re-quoted as
        // JSON; deliver it raw and let the caller parse.
        let _ = tx.send(result);
    };

    // eval_with_callback dispatches to the webview; run it on the main thread to
    // be safe across platforms (WebKitGTK/WKWebView require main-thread eval).
    let win = window.clone();
    window
        .run_on_main_thread(move || {
            let _ = win.eval_with_callback(wrapped, cb);
        })
        .map_err(|e| format!("eval dispatch failed: {e}"))?;

    let raw = rx
        .recv_timeout(EVAL_TIMEOUT)
        .map_err(|_| format!("eval_js timed out after {}s", EVAL_TIMEOUT.as_secs()))?;

    // `raw` is the callback's serialization of our IIFE's string return value:
    // a JSON string literal whose contents are themselves a JSON object. Peel
    // both layers; tolerate either single- or double-encoding across platforms.
    let inner: String = match serde_json::from_str::<String>(&raw) {
        Ok(s) => s,
        Err(_) => raw.clone(),
    };
    let envelope: Value = serde_json::from_str(&inner)
        .or_else(|_| serde_json::from_str(&raw))
        .map_err(|e| format!("could not parse bridge result: {e}; raw={raw}"))?;

    if envelope.get("ok").and_then(Value::as_bool) == Some(false) {
        let err = envelope
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("unknown error")
            .to_string();
        return Err(format!("JS error: {err}"));
    }
    Ok(envelope.get("value").cloned().unwrap_or(Value::Null))
}

// JS payloads. Kept as page-side helpers so the bridge stays a single mechanism.

fn js_string(s: &str) -> String {
    // Safe embedding of a Rust string into JS source via JSON encoding.
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

fn dom_read_js(selector: Option<&str>, as_text: bool) -> String {
    let root = match selector {
        Some(sel) => format!("document.querySelector({})", js_string(sel)),
        None => "document.documentElement".to_string(),
    };
    let prop = if as_text { "innerText" } else { "outerHTML" };
    format!(
        "const __el = {root}; if (!__el) throw new Error('no element for selector'); return __el.{prop};"
    )
}

fn click_js(selector: &str) -> String {
    format!(
        r#"const __el = document.querySelector({sel});
           if (!__el) throw new Error('no element for selector');
           __el.scrollIntoView({{ block: 'center', inline: 'center' }});
           const r = __el.getBoundingClientRect();
           const opts = {{ bubbles: true, cancelable: true, view: window,
               clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }};
           __el.dispatchEvent(new PointerEvent('pointerdown', opts));
           __el.dispatchEvent(new MouseEvent('mousedown', opts));
           __el.dispatchEvent(new PointerEvent('pointerup', opts));
           __el.dispatchEvent(new MouseEvent('mouseup', opts));
           __el.dispatchEvent(new MouseEvent('click', opts));
           return {{ clicked: true, tag: __el.tagName.toLowerCase() }};"#,
        sel = js_string(selector)
    )
}

fn type_js(selector: &str, text: &str) -> String {
    format!(
        r#"const __el = document.querySelector({sel});
           if (!__el) throw new Error('no element for selector');
           __el.focus();
           const __setter = Object.getOwnPropertyDescriptor(
               __el.constructor.prototype, 'value');
           if (__setter && __setter.set) {{ __setter.set.call(__el, {txt}); }}
           else {{ __el.value = {txt}; }}
           __el.dispatchEvent(new Event('input', {{ bubbles: true }}));
           __el.dispatchEvent(new Event('change', {{ bubbles: true }}));
           return {{ typed: true, value: __el.value }};"#,
        sel = js_string(selector),
        txt = js_string(text)
    )
}

fn hover_js(selector: &str) -> String {
    format!(
        r#"const __el = document.querySelector({sel});
           if (!__el) throw new Error('no element for selector');
           const r = __el.getBoundingClientRect();
           const opts = {{ bubbles: true, cancelable: true, view: window,
               clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 }};
           __el.dispatchEvent(new PointerEvent('pointerover', opts));
           __el.dispatchEvent(new MouseEvent('mouseover', opts));
           __el.dispatchEvent(new PointerEvent('pointermove', opts));
           __el.dispatchEvent(new MouseEvent('mousemove', opts));
           return {{ hovered: true }};"#,
        sel = js_string(selector)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The bridge envelope: our IIFE resolves to a JSON STRING; eval_with_callback
    /// then JSON-serializes THAT string. So the callback hands us a double-encoded
    /// payload. This reproduces the peel logic from eval_js and asserts both the
    /// double- and single-encoded shapes decode to the inner value.
    fn peel(raw: &str) -> Result<Value, String> {
        let inner: String = match serde_json::from_str::<String>(raw) {
            Ok(s) => s,
            Err(_) => raw.to_string(),
        };
        let envelope: Value = serde_json::from_str(&inner)
            .or_else(|_| serde_json::from_str(raw))
            .map_err(|e| format!("{e}"))?;
        if envelope.get("ok").and_then(Value::as_bool) == Some(false) {
            return Err(envelope
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("?")
                .to_string());
        }
        Ok(envelope.get("value").cloned().unwrap_or(Value::Null))
    }

    #[test]
    fn double_encoded_success() {
        // IIFE returned `JSON.stringify({ok:true,value:42})`; callback re-quoted it.
        let raw = serde_json::to_string(r#"{"ok":true,"value":42}"#).unwrap();
        assert_eq!(peel(&raw).unwrap(), json!(42));
    }

    #[test]
    fn single_encoded_success() {
        // Platform that already hands us the inner JSON unquoted.
        let raw = r#"{"ok":true,"value":"hello"}"#;
        assert_eq!(peel(raw).unwrap(), json!("hello"));
    }

    #[test]
    fn error_envelope_propagates() {
        let raw = serde_json::to_string(r#"{"ok":false,"error":"boom"}"#).unwrap();
        assert_eq!(peel(&raw).unwrap_err(), "boom");
    }

    #[test]
    fn null_value_when_undefined() {
        let raw = serde_json::to_string(r#"{"ok":true,"value":null}"#).unwrap();
        assert_eq!(peel(&raw).unwrap(), Value::Null);
    }

    #[test]
    fn manifest_lists_keystone_tools() {
        let names: Vec<String> = tool_manifest()
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect();
        for required in ["eval_js", "dom_read", "click", "type", "hover", "tabs_list"] {
            assert!(names.contains(&required.to_string()), "missing {required}");
        }
    }

    #[test]
    fn dom_read_js_scopes_and_picks_property() {
        let html = dom_read_js(None, false);
        assert!(html.contains("document.documentElement"));
        assert!(html.contains("outerHTML"));
        let txt = dom_read_js(Some("#app"), true);
        assert!(txt.contains("querySelector(\"#app\")"));
        assert!(txt.contains("innerText"));
    }

    #[test]
    fn js_string_escapes_injection() {
        // A selector with a quote must not break out of the JS string literal:
        // the inner quote has to be backslash-escaped so it can't terminate the
        // literal early. Re-parsing as JSON recovers the original exactly.
        let raw = "a\"]; alert(1); //";
        let s = js_string(raw);
        assert!(s.starts_with('"') && s.ends_with('"'));
        assert!(s.contains("\\\"")); // the embedded quote is escaped
        assert_eq!(serde_json::from_str::<String>(&s).unwrap(), raw);
    }
}
