// Menu-bar tray icon for Workbooks Desktop.
//
// macOS only for now. Lives next to the clock/wifi/battery cluster
// on the right side of the menu bar while the desktop is running.
// Once a tray icon is attached, the app keeps running even after the
// window is closed — that's the "background process" UX: closing
// the window hides it (see CloseRequested handler in lib.rs); the
// engine + tray stay alive. Cmd-Q or the tray's Quit menu item
// exits cleanly.
//
// Menu shape (top to bottom) — rebuilt-on-click via live MenuItem
// label updates so the user always sees fresh status:
//   ──────────────────────────────
//   Engine: Running (daemon) — :51425   ← live status, disabled
//   Desktop: Foreground                 ← window state, disabled
//   Activity: 2 active sessions         ← session count from /api/sessions
//   ──────────────────────────────
//   Restart engine                      ← clickable only when engine != Ready
//   Open Workbooks                      ← shows + focuses the main window
//   ──────────────────────────────
//   Quit Workbooks Desktop
//
// Engine status updates whenever the sidecar emits a `sidecar-state`
// event. Desktop window state + sessions count are refreshed every
// time the tray is left-clicked (TrayIconEvent::Click — Down phase)
// so the user gets fresh numbers as the NSMenu pops. We keep handles
// to every live row in process-global state so the listener +
// refresh task can call `set_text` / `set_enabled` without rebuilding
// the whole menu — native NSMenu updates atomically while the menu
// is open.

use std::sync::OnceLock;
use std::time::Duration;

use serde::Deserialize;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Listener, Manager, Wry};

use crate::sidecar::{self, SidecarState, SidecarStatus};

const TRAY_ID: &str = "workbooks-tray";

/// Cap on every status-probe network/IPC call so a hung engine
/// can't freeze the menu while the user is staring at it.
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);

/// Handles to the live-updating menu items. The desktop binary uses
/// the Wry runtime, so we pin to Wry directly — no generic gymnastics
/// (and no `unsafe` cast, which CLAUDE.md forbids).
struct TrayMenu {
    engine_status: MenuItem<Wry>,
    window_status: MenuItem<Wry>,
    sessions_status: MenuItem<Wry>,
    restart: MenuItem<Wry>,
}

static TRAY_MENU: OnceLock<TrayMenu> = OnceLock::new();

/// Last-known sidecar status, mirrored from the `sidecar-state`
/// listener. We re-read it on tray clicks to decide what to show on
/// the engine row (and to know whether the sessions row is meaningful).
static LAST_STATUS: OnceLock<std::sync::Mutex<Option<SidecarStatus>>> = OnceLock::new();

fn last_status_slot() -> &'static std::sync::Mutex<Option<SidecarStatus>> {
    LAST_STATUS.get_or_init(|| std::sync::Mutex::new(None))
}

pub fn build(app: &AppHandle<Wry>) -> tauri::Result<()> {
    // Status rows — disabled (read-only). Placeholder text gets
    // overwritten by the first sidecar-state event the listener
    // receives (within a tick of app boot) plus the first tray click.
    let engine_status: MenuItem<Wry> =
        MenuItem::with_id(app, "engine_status", "Engine: starting…", false, None::<&str>)?;
    let window_status: MenuItem<Wry> =
        MenuItem::with_id(app, "window_status", "Desktop: …", false, None::<&str>)?;
    let sessions_status: MenuItem<Wry> = MenuItem::with_id(
        app,
        "sessions_status",
        "Activity: …",
        false,
        None::<&str>,
    )?;

    let sep1 = PredefinedMenuItem::separator(app)?;

    // Restart engine — clickable only when the engine isn't healthy.
    // Hidden-vs-disabled tradeoff: macOS NSMenu can't easily hide
    // items at runtime, so we toggle enabled state. Disabled text
    // reads as "no action needed right now."
    let restart: MenuItem<Wry> =
        MenuItem::with_id(app, "restart_engine", "Restart engine", false, None::<&str>)?;
    let open_item: MenuItem<Wry> =
        MenuItem::with_id(app, "open", "Open Workbooks", true, None::<&str>)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let quit_item: MenuItem<Wry> =
        MenuItem::with_id(app, "quit", "Quit Workbooks Desktop", true, None::<&str>)?;

    let menu = Menu::with_items(
        app,
        &[
            &engine_status,
            &window_status,
            &sessions_status,
            &sep1,
            &restart,
            &open_item,
            &sep2,
            &quit_item,
        ],
    )?;

    // Stash the live-updating items so the listener + refresh task
    // can reach them. OnceLock::set fails-silent on re-init (e.g.,
    // hot-reload during dev): the items themselves are still wired
    // into the menu; only dynamic updates would be skipped, which is
    // acceptable since hot-reload also rebuilds the listener.
    let _ = TRAY_MENU.set(TrayMenu {
        engine_status: engine_status.clone(),
        window_status: window_status.clone(),
        sessions_status: sessions_status.clone(),
        restart: restart.clone(),
    });

    let tray_icon_bytes = include_bytes!("../icons/tray-template.png");
    let tray_image = tauri::image::Image::from_bytes(tray_icon_bytes)?;

    let _tray = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip("Workbooks")
        .icon(tray_image)
        // Template image: macOS adapts to light/dark menu bars (white
        // on dark, black on light). Without this the icon appears
        // full-color and looks out of place in either appearance.
        .icon_as_template(true)
        .menu(&menu)
        // Left click pops the dropdown — the menu IS the interaction
        // surface now (Open Workbooks moved into it as a menu item).
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main_window(app),
            "restart_engine" => {
                let handle = app.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(e) = sidecar::sidecar_restart(handle).await {
                        log::warn!("[tray] sidecar_restart failed: {e}");
                    }
                });
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            // Refresh dynamic rows on click-Down. The NSMenu appears
            // on Up, so this gives the refresh ~one frame to land
            // labels before the user sees the menu — and any
            // straggling reads update live while the menu is open.
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Down,
                ..
            } = event
            {
                let handle = tray.app_handle().clone();
                tauri::async_runtime::spawn(async move {
                    refresh_dynamic_rows(&handle).await;
                });
            }
        })
        .build(app)?;

    subscribe_to_sidecar_state(app.clone());

    // Kick a refresh now so the menu shows real state from the moment
    // it's built, not the "starting…" placeholders. Without this the
    // first click sees stale text for one frame; more importantly,
    // tooltips / accessibility readers see the placeholder until then.
    {
        let handle = app.clone();
        tauri::async_runtime::spawn(async move {
            refresh_dynamic_rows(&handle).await;
        });
    }

    Ok(())
}

fn show_main_window(app: &AppHandle<Wry>) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.unminimize();
        let _ = win.set_focus();
    }
}

/// Listen to the `sidecar-state` event the sidecar lifecycle emits
/// whenever state changes. Updates the tooltip + the engine row, and
/// caches the latest status so click-refresh can format the row with
/// the engine port even when no state change happened.
fn subscribe_to_sidecar_state(app: AppHandle<Wry>) {
    app.clone().listen("sidecar-state", move |event| {
        let Ok(status) = serde_json::from_str::<SidecarStatus>(event.payload()) else {
            return;
        };
        let tooltip = tooltip_for(&status);
        if let Some(tray) = app.tray_by_id(TRAY_ID) {
            let _ = tray.set_tooltip(Some(&tooltip));
        }

        if let Some(tm) = TRAY_MENU.get() {
            let label = menu_label_for(&status);
            let _ = tm.engine_status.set_text(label);
            // Restart engine becomes clickable when the engine isn't
            // ready. When it is, the row reads disabled — no point in
            // restarting a healthy process.
            let _ = tm.restart.set_enabled(matches!(
                status.state,
                SidecarState::Stopped | SidecarState::Crashed | SidecarState::Unhealthy,
            ));
        }

        if let Ok(mut slot) = last_status_slot().lock() {
            *slot = Some(status);
        }
    });
}

/// Refresh the three live rows. Every probe is wrapped in a 500ms
/// timeout — if it doesn't land we render "unknown" rather than
/// blocking the UI thread that paints the menu.
async fn refresh_dynamic_rows(app: &AppHandle<Wry>) {
    let Some(tm) = TRAY_MENU.get() else { return };

    // ── Desktop window state ──────────────────────────────────────
    // Foreground if the main window exists, is visible, and focused.
    // Background-only if hidden (tray-only mode after window close).
    // Background (open) if visible but not focused (user clicked away).
    let window_label = match app.get_webview_window("main") {
        Some(win) => {
            let visible = win.is_visible().unwrap_or(false);
            let focused = win.is_focused().unwrap_or(false);
            match (visible, focused) {
                (true, true) => "Desktop: Foreground",
                (true, false) => "Desktop: Open (background)",
                (false, _) => "Desktop: Background only",
            }
        }
        None => "Desktop: window missing",
    };
    let _ = tm.window_status.set_text(window_label);

    // ── Engine row — direct probe is the source of truth ──
    // The sidecar-state listener only fires when the desktop SPAWNS
    // the engine. When launchd has already started the daemon (the
    // common case), no event ever arrives and the cache stays at
    // "starting" forever. So we ignore the cache for label purposes
    // and read listen.json + kill -0 the pid directly — that's the
    // ground truth for "is the engine alive right now."
    let engine_port = read_engine_port_alive().await;
    let engine_label = match engine_port {
        Some(port) => format!("Engine: Ready — :{port}"),
        None => "Engine: not running".to_string(),
    };
    let _ = tm.engine_status.set_text(engine_label);
    // Restart engine clickable only when the engine is NOT alive.
    let _ = tm.restart.set_enabled(engine_port.is_none());

    // ── Activity row — count running sessions if engine reachable ──
    if engine_port.is_none() {
        let _ = tm
            .sessions_status
            .set_text("Activity: engine not running");
        let _ = tm.sessions_status.set_enabled(false);
        return;
    }

    let label = match fetch_active_session_count().await {
        Some(0) => "Activity: idle".to_string(),
        Some(1) => "Activity: 1 active session".to_string(),
        Some(n) => format!("Activity: {n} active sessions"),
        None => "Activity: unknown".to_string(),
    };
    let _ = tm.sessions_status.set_text(label);
    let _ = tm.sessions_status.set_enabled(false);
}

/// Read `~/Workbooks/Engine/listen.json`, parse pid + port, confirm
/// the pid is alive via `kill -0`. Returns Some(port) on success.
async fn read_engine_port_alive() -> Option<u16> {
    tokio::time::timeout(PROBE_TIMEOUT, async {
        let home = std::env::var_os("HOME")?;
        let path = std::path::PathBuf::from(home)
            .join("Workbooks")
            .join("Engine")
            .join("listen.json");
        let body = tokio::fs::read_to_string(&path).await.ok()?;
        let v: serde_json::Value = serde_json::from_str(&body).ok()?;
        let port = v.get("port")?.as_u64()? as u16;
        let pid = v.get("pid")?.as_u64()? as u32;
        if pid_alive(pid) {
            Some(port)
        } else {
            None
        }
    })
    .await
    .ok()
    .flatten()
}

fn pid_alive(pid: u32) -> bool {
    // `kill -0 <pid>` is the canonical POSIX existence probe — signal
    // 0 sends no signal, only validates that the pid is deliverable.
    // We shell out to /bin/kill rather than calling libc::kill so this
    // file stays under `#![forbid(unsafe_code)]`. The cost is a fork
    // (<1ms on macOS) — negligible for a once-per-click status probe.
    std::process::Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

#[derive(Deserialize)]
struct SessionsResp {
    sessions: Vec<SessionRow>,
}

#[derive(Deserialize)]
struct SessionRow {
    #[allow(dead_code)]
    session_id: String,
    status: String,
}

/// Hit `GET /api/sessions` and count entries with `status == "running"`.
/// Returns None on any failure so the row can render "unknown" instead
/// of misleading zero.
async fn fetch_active_session_count() -> Option<usize> {
    tokio::time::timeout(PROBE_TIMEOUT, async {
        let home = std::env::var_os("HOME")?;
        let path = std::path::PathBuf::from(home)
            .join("Workbooks")
            .join("Engine")
            .join("listen.json");
        let body = tokio::fs::read_to_string(&path).await.ok()?;
        let v: serde_json::Value = serde_json::from_str(&body).ok()?;
        let url = v.get("url")?.as_str()?.to_string();

        let client = reqwest::Client::builder()
            .timeout(PROBE_TIMEOUT)
            .build()
            .ok()?;
        let resp = client
            .get(format!("{url}/api/sessions?active=true"))
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        let parsed: SessionsResp = resp.json().await.ok()?;
        Some(
            parsed
                .sessions
                .into_iter()
                .filter(|s| s.status == "running")
                .count(),
        )
    })
    .await
    .ok()
    .flatten()
}

fn tooltip_for(status: &SidecarStatus) -> String {
    match status.state {
        SidecarState::Starting => "Workbooks — starting engine…".to_string(),
        SidecarState::Ready => match status.mode.as_deref() {
            Some("daemon") => "Workbooks — engine ready (daemon)".to_string(),
            Some(other) => format!("Workbooks — engine ready ({other})"),
            None => "Workbooks — engine ready".to_string(),
        },
        SidecarState::Unhealthy => "Workbooks — engine unhealthy".to_string(),
        SidecarState::Restarting => "Workbooks — engine restarting…".to_string(),
        SidecarState::Crashed => "Workbooks — engine crashed".to_string(),
        SidecarState::Stopped => "Workbooks — engine stopped".to_string(),
    }
}

fn menu_label_for(status: &SidecarStatus) -> String {
    match status.state {
        SidecarState::Starting => "Engine: starting…".to_string(),
        SidecarState::Ready => match status.mode.as_deref() {
            Some("daemon") => "Engine: running (daemon)".to_string(),
            Some(other) => format!("Engine: running ({other})"),
            None => "Engine: running".to_string(),
        },
        SidecarState::Unhealthy => "Engine: unhealthy".to_string(),
        SidecarState::Restarting => "Engine: restarting…".to_string(),
        SidecarState::Crashed => "Engine: crashed".to_string(),
        SidecarState::Stopped => "Engine: not running".to_string(),
    }
}
