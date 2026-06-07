// Pseudo-terminal sessions for the embedded terminal drawer.
//
// Backed by `portable-pty` (the same crate WezTerm uses). Each
// session owns:
//
//   * a PTY pair (master + slave)
//   * a Child handle for the spawned shell or command
//   * a reader thread that pumps the master's stdout/stderr back to
//     the renderer as base64-encoded chunks on the `terminal-output`
//     Tauri event
//   * a writer handle the renderer pokes when the user types
//
// The renderer side (xterm.js) consumes the byte stream and renders
// it natively — ANSI, color, cursor positioning, all of it.
//
// ## Session ids
//
// Each spawn returns a `session_id` the renderer uses for write +
// resize + kill. Sessions are tracked in a process-global ETS-ish
// map (`OnceCell<Mutex<HashMap<>>>`) so multiple drawers / tabs can
// run concurrently in the future.
//
// ## The one-click-install flow rides this same surface
//
// The Install button in `DetectModal` calls `terminal_spawn` with
// the install command instead of a shell. Output streams to the
// same `terminal-output` event the drawer subscribes to. When the
// child exits we emit `terminal-exit` so the UI can re-run detect.

#![allow(clippy::module_name_repetitions)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;

use base64::{engine::general_purpose::STANDARD as B64, Engine};
use once_cell::sync::OnceCell;
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};

#[derive(Clone, Debug, Serialize)]
pub struct SpawnResult {
    pub session_id: String,
}

#[derive(Clone, Debug, Serialize)]
struct OutputEvent {
    session_id: String,
    /// Base64-encoded bytes. xterm.js takes binary input via
    /// `term.write(Uint8Array)` so the renderer just b64-decodes.
    data: String,
}

#[derive(Clone, Debug, Serialize)]
struct ExitEvent {
    session_id: String,
    /// `None` if the process was killed before producing an exit code.
    exit_code: Option<i32>,
}

#[derive(Deserialize, Debug)]
pub struct SpawnRequest {
    /// Optional explicit shell path. Defaults to `$SHELL` then `/bin/zsh`
    /// on macOS, `/bin/bash` on Linux, `cmd.exe` on Windows.
    #[serde(default)]
    pub shell: Option<String>,
    /// Optional one-shot command + args. When set, we spawn this
    /// directly instead of the user's shell. Used by the Install
    /// button — `brew install foo` runs as the child, exits, drawer
    /// can rerun detect.
    #[serde(default)]
    pub command: Option<Vec<String>>,
    /// Working directory. Defaults to `$HOME`.
    #[serde(default)]
    pub cwd: Option<String>,
    /// Initial PTY dimensions. The renderer measures the drawer + the
    /// xterm.js character cell and passes the resulting grid here so
    /// the shell knows the right TERM size from the start.
    pub cols: u16,
    pub rows: u16,
}

struct Session {
    /// Stdin half of the master pty. Held in a Mutex so writes from
    /// the renderer don't race the reader thread.
    writer: Box<dyn Write + Send>,
    /// Master pty handle — we keep it alive so the reader thread
    /// has a stable end to read from, and so we can resize.
    master: Box<dyn portable_pty::MasterPty + Send>,
    /// Child handle so we can kill on `terminal_kill`.
    child: Box<dyn portable_pty::Child + Send + Sync>,
}

fn registry() -> &'static Arc<Mutex<HashMap<String, Session>>> {
    static REG: OnceCell<Arc<Mutex<HashMap<String, Session>>>> = OnceCell::new();
    REG.get_or_init(|| Arc::new(Mutex::new(HashMap::new())))
}

fn new_session_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("t_{:x}", nanos)
}

fn default_shell() -> String {
    if let Ok(s) = std::env::var("SHELL") {
        if !s.is_empty() {
            return s;
        }
    }
    #[cfg(target_os = "windows")]
    {
        "cmd.exe".to_string()
    }
    #[cfg(target_os = "macos")]
    {
        "/bin/zsh".to_string()
    }
    #[cfg(target_os = "linux")]
    {
        "/bin/bash".to_string()
    }
}

#[tauri::command]
pub async fn terminal_spawn(
    app: AppHandle,
    req: SpawnRequest,
) -> Result<SpawnResult, String> {
    let cols = req.cols.max(20);
    let rows = req.rows.max(5);

    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            cols,
            rows,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| format!("openpty: {e}"))?;

    let mut cmd = if let Some(argv) = req.command.filter(|v| !v.is_empty()) {
        let mut c = CommandBuilder::new(&argv[0]);
        for arg in &argv[1..] {
            c.arg(arg);
        }
        c
    } else {
        CommandBuilder::new(req.shell.unwrap_or_else(default_shell))
    };

    let cwd = req
        .cwd
        .filter(|c| !c.is_empty())
        .or_else(|| std::env::var("HOME").ok())
        .unwrap_or_else(|| "/".to_string());
    cmd.cwd(cwd);

    // TERM defaults to "xterm-256color" — what xterm.js advertises and
    // what most CLIs expect for colour/cursor support.
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");

    let child = pair
        .slave
        .spawn_command(cmd)
        .map_err(|e| format!("spawn: {e}"))?;

    // Take the writer half BEFORE we move master into the session, so
    // the reader thread can still hold the master.
    let writer = pair
        .master
        .take_writer()
        .map_err(|e| format!("take_writer: {e}"))?;

    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| format!("clone_reader: {e}"))?;

    let session_id = new_session_id();

    // Reader thread: drain pty → emit events. Exits when read returns
    // 0 or an error (typically when the child exits and the slave end
    // closes).
    {
        let app = app.clone();
        let session_id = session_id.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        let payload = OutputEvent {
                            session_id: session_id.clone(),
                            data: B64.encode(&buf[..n]),
                        };
                        if app.emit("terminal-output", &payload).is_err() {
                            // Renderer is gone — bail out.
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            // Emit a synthetic exit so the renderer can react even if
            // the child is technically still running (e.g. a tty close
            // we couldn't observe). The wait-thread below emits the
            // real exit code separately if reachable.
        });
    }

    // Wait thread: harvest the child's exit code + emit terminal-exit.
    // We need this in addition to the reader-thread close because the
    // reader can EOF before the child fully exits.
    //
    // The child is held in the Session so kill works; we wait on a
    // clone-ish — portable_pty::Child isn't Clone, so we use the
    // builder's wait via try_wait in a poll loop instead.
    //
    // Simpler: the spawn returns ownership of `child`; we stash it
    // and a dedicated thread polls try_wait. When it exits, we emit
    // and remove the session.

    {
        let mut reg = registry().lock().unwrap();
        reg.insert(
            session_id.clone(),
            Session {
                writer,
                master: pair.master,
                child,
            },
        );
    }

    spawn_wait_thread(app, session_id.clone());

    Ok(SpawnResult { session_id })
}

fn spawn_wait_thread(app: AppHandle, session_id: String) {
    thread::spawn(move || {
        loop {
            // Poll under the lock briefly so we don't hold it while
            // sleeping.
            let exit = {
                let mut reg = registry().lock().unwrap();
                match reg.get_mut(&session_id) {
                    Some(s) => match s.child.try_wait() {
                        Ok(Some(status)) => Some(status.exit_code() as i32),
                        Ok(None) => None,
                        Err(_) => Some(-1),
                    },
                    None => return, // session was killed/removed
                }
            };

            if let Some(code) = exit {
                // Session is over — remove + emit.
                registry().lock().unwrap().remove(&session_id);
                let _ = app.emit(
                    "terminal-exit",
                    &ExitEvent {
                        session_id: session_id.clone(),
                        exit_code: Some(code),
                    },
                );
                return;
            }

            thread::sleep(std::time::Duration::from_millis(100));
        }
    });
}

#[derive(Deserialize)]
pub struct WriteRequest {
    pub session_id: String,
    /// Base64-encoded bytes. Renderer encodes user keystrokes
    /// + paste data this way so we can carry arbitrary bytes.
    pub data: String,
}

#[tauri::command]
pub fn terminal_write(req: WriteRequest) -> Result<(), String> {
    let bytes = B64
        .decode(req.data.as_bytes())
        .map_err(|e| format!("decode: {e}"))?;

    let mut reg = registry().lock().unwrap();
    let session = reg
        .get_mut(&req.session_id)
        .ok_or_else(|| format!("no such session: {}", req.session_id))?;

    session
        .writer
        .write_all(&bytes)
        .map_err(|e| format!("write: {e}"))?;
    session.writer.flush().map_err(|e| format!("flush: {e}"))?;
    Ok(())
}

#[derive(Deserialize)]
pub struct ResizeRequest {
    pub session_id: String,
    pub cols: u16,
    pub rows: u16,
}

#[tauri::command]
pub fn terminal_resize(req: ResizeRequest) -> Result<(), String> {
    let reg = registry().lock().unwrap();
    let session = reg
        .get(&req.session_id)
        .ok_or_else(|| format!("no such session: {}", req.session_id))?;

    session
        .master
        .resize(PtySize {
            cols: req.cols.max(20),
            rows: req.rows.max(5),
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| format!("resize: {e}"))?;
    Ok(())
}

#[tauri::command]
pub fn terminal_kill(session_id: String) -> Result<(), String> {
    let mut reg = registry().lock().unwrap();
    if let Some(mut session) = reg.remove(&session_id) {
        // Best-effort kill — even if it fails we've removed the
        // session from the registry so write/resize will start
        // returning "no such session".
        let _ = session.child.kill();
    }
    Ok(())
}
