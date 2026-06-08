// Real PTY terminals via portable-pty. Each spawn stashes the master + child +
// writer in State<PtyManager>; a reader thread streams stdout as base64 over
// `terminal-output`, and on EOF emits `terminal-exit`. Write/resize/kill act on
// the stashed session by id.

use base64::Engine as _;
use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, State};

struct Session {
    master: Box<dyn portable_pty::MasterPty + Send>,
    child: Box<dyn portable_pty::Child + Send + Sync>,
    writer: Box<dyn Write + Send>,
}

#[derive(Default)]
pub struct PtyManager {
    sessions: Mutex<HashMap<String, Session>>,
    seq: AtomicU64,
}

#[derive(Deserialize)]
pub struct SpawnRequest {
    pub cols: u16,
    pub rows: u16,
    pub shell: Option<String>,
    pub command: Option<Vec<String>>,
    pub cwd: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpawnResult {
    pub session_id: String,
}

#[derive(Serialize, Clone)]
struct OutputEvent {
    session_id: String,
    data: String,
}

#[derive(Serialize, Clone)]
struct ExitEvent {
    session_id: String,
    exit_code: Option<i32>,
}

#[tauri::command]
pub fn terminal_spawn(
    app: AppHandle,
    mgr: State<PtyManager>,
    req: SpawnRequest,
) -> Result<SpawnResult, String> {
    let pty_system = NativePtySystem::default();
    let pair = pty_system
        .openpty(PtySize {
            rows: req.rows,
            cols: req.cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| e.to_string())?;

    // Build the command: explicit argv, else $SHELL / zsh as a login shell.
    let mut cmd = if let Some(argv) = req.command.filter(|c| !c.is_empty()) {
        let mut c = CommandBuilder::new(&argv[0]);
        for a in &argv[1..] {
            c.arg(a);
        }
        c
    } else {
        let shell = req
            .shell
            .or_else(|| std::env::var("SHELL").ok())
            .unwrap_or_else(|| "zsh".into());
        CommandBuilder::new(shell)
    };
    if let Some(cwd) = req.cwd {
        cmd.cwd(cwd);
    }

    let child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;

    let id = format!("pty-{}", mgr.seq.fetch_add(1, Ordering::SeqCst));

    mgr.sessions.lock().unwrap().insert(
        id.clone(),
        Session {
            master: pair.master,
            child,
            writer,
        },
    );

    // Reader thread: pump bytes → base64 → `terminal-output`. On EOF, reap the
    // child for its exit code and emit `terminal-exit`, then drop the session.
    let app_reader = app.clone();
    let reader_id = id.clone();
    std::thread::spawn(move || {
        let mut buf = [0u8; 8192];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let data = base64::engine::general_purpose::STANDARD.encode(&buf[..n]);
                    let _ = app_reader.emit(
                        "terminal-output",
                        OutputEvent {
                            session_id: reader_id.clone(),
                            data,
                        },
                    );
                }
                Err(_) => break,
            }
        }
        // EOF: pull the session out and reap the child.
        let state: State<PtyManager> = app_reader.state();
        let exit_code = {
            let mut map = state.sessions.lock().unwrap();
            map.remove(&reader_id)
                .and_then(|mut s| s.child.wait().ok())
                .map(|status: portable_pty::ExitStatus| status.exit_code() as i32)
        };
        let _ = app_reader.emit(
            "terminal-exit",
            ExitEvent {
                session_id: reader_id,
                exit_code,
            },
        );
    });

    Ok(SpawnResult { session_id: id })
}

#[derive(Deserialize)]
pub struct WriteRequest {
    pub session_id: String,
    /// base64-encoded bytes.
    pub data: String,
}

#[tauri::command]
pub fn terminal_write(mgr: State<PtyManager>, req: WriteRequest) -> Result<(), String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(req.data.as_bytes())
        .map_err(|e| e.to_string())?;
    let mut map = mgr.sessions.lock().unwrap();
    let s = map
        .get_mut(&req.session_id)
        .ok_or("no such terminal session")?;
    s.writer.write_all(&bytes).map_err(|e| e.to_string())?;
    s.writer.flush().map_err(|e| e.to_string())
}

#[derive(Deserialize)]
pub struct ResizeRequest {
    pub session_id: String,
    pub cols: u16,
    pub rows: u16,
}

#[tauri::command]
pub fn terminal_resize(mgr: State<PtyManager>, req: ResizeRequest) -> Result<(), String> {
    let map = mgr.sessions.lock().unwrap();
    let s = map.get(&req.session_id).ok_or("no such terminal session")?;
    s.master
        .resize(PtySize {
            rows: req.rows,
            cols: req.cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn terminal_kill(mgr: State<PtyManager>, session_id: String) -> Result<(), String> {
    let mut map = mgr.sessions.lock().unwrap();
    if let Some(mut s) = map.remove(&session_id) {
        let _ = s.child.kill();
        // Dropping the master closes the pty → the reader thread sees EOF and
        // emits terminal-exit.
    }
    Ok(())
}
