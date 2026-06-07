// Workbooks Desktop — a LEAN Tauri shell. It does only what a browser can't:
//   * drive the runtime daemon via the deploy-kit (`wb deploy local|status|down`)
//   * read the discovery file the runtime writes (port + token)
//   * a menu-bar tray = the daemon's UI; the window = the Svelte frontend
//
// Everything else (data, agents, settings) the frontend gets by talking HTTP/WS
// to the runtime at the discovered URL — NOT through Rust IPC. The shell is a
// supervisor + native chrome, nothing more.

use serde::Serialize;
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager,
};

mod daemon;
mod kernel;
use daemon::Discovery;

/// What the frontend needs to talk to the runtime: the localhost URL + the
/// per-boot bearer token. Returned by the `runtime_url` command.
#[derive(Serialize, Clone)]
pub struct Runtime {
    pub url: String,
    pub token: String,
    pub state: String,
}

#[tauri::command]
fn runtime_url() -> Runtime {
    match Discovery::read() {
        Some(d) => Runtime {
            url: format!("{}://127.0.0.1:{}", d.scheme, d.port),
            token: d.token,
            state: "up".into(),
        },
        None => Runtime {
            url: String::new(),
            token: String::new(),
            state: "down".into(),
        },
    }
}

/// The embedded OQL kernel, exposed LOCALLY (no runtime, no Docker). The
/// workbook-native surface: render/tangle/validate/lint/outline a workbook
/// fully in-process.
#[tauri::command]
fn weave(org: String) -> Result<String, String> {
    kernel::call("render", &org)
}

#[tauri::command]
fn tangle(org: String) -> Result<String, String> {
    kernel::call("tangle-plan", &org)
}

#[tauri::command]
fn validate(org: String) -> Result<String, String> {
    kernel::call("validate", &org)
}

#[tauri::command]
fn lint(org: String) -> Result<String, String> {
    kernel::call("lint", &org)
}

#[tauri::command]
fn outline(org: String) -> Result<String, String> {
    kernel::call("parse-headlines", &org)
}

/// Read a workbook file the user picked (via the dialog plugin, main-thread safe).
/// The dialog returns a path; the actual read/write is plain Rust — no fs-plugin
/// scope to configure. Part of the "shell = capabilities" model.
#[tauri::command]
fn read_file(path: String) -> Result<String, String> {
    std::fs::read_to_string(&path).map_err(|e| e.to_string())
}

#[tauri::command]
fn write_file(path: String, content: String) -> Result<(), String> {
    std::fs::write(&path, content).map_err(|e| e.to_string())
}

#[tauri::command]
fn daemon_status() -> String {
    daemon::wb(&["deploy", "status", "--json"]).unwrap_or_else(|e| e)
}

#[tauri::command]
fn daemon_up() -> String {
    daemon::wb(&["deploy", "local", "--json"]).unwrap_or_else(|e| e)
}

#[tauri::command]
fn daemon_down() -> String {
    daemon::wb(&["deploy", "down", "--json"]).unwrap_or_else(|e| e)
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            weave,
            tangle,
            validate,
            lint,
            outline,
            read_file,
            write_file,
            runtime_url,
            daemon_status,
            daemon_up,
            daemon_down
        ])
        .setup(|app| {
            build_tray(app.handle())?;

            // Bring the runtime up in the background; tell the WebView when it's
            // ready so the frontend can connect to the discovered URL.
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                let _ = daemon::wb(&["deploy", "local", "--json"]);
                let state = if Discovery::read().is_some() { "up" } else { "down" };
                let _ = handle.emit("sidecar-state", state);
            });
            Ok(())
        })
        // Closing the window HIDES it — the daemon (and tray) keep running. Quit
        // is an explicit tray action.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running the Workbooks desktop shell");
}

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let status = MenuItem::with_id(app, "status", "Engine: starting…", false, None::<&str>)?;
    let open = MenuItem::with_id(app, "open", "Open Workbooks", true, None::<&str>)?;
    let restart = MenuItem::with_id(app, "restart", "Restart engine", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Workbooks", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&status, &open, &restart, &sep, &quit])?;

    TrayIconBuilder::with_id("workbooks")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_window(app),
            "restart" => {
                let _ = daemon::wb(&["deploy", "down"]);
                let _ = daemon::wb(&["deploy", "local", "--json"]);
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}

fn show_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
    }
}
