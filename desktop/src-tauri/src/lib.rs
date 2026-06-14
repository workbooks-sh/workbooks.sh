// Workbooks Desktop — the LEAN native shell. Phase B widens it from a daemon
// supervisor into the full offline-first capability surface the Svelte frontend
// invoke()s: file tree + watchers, packages/workspaces, bookmarks/themes/MCP/
// plugins, secrets in the OS keychain, PTY terminals, local identity + WorkOS
// sign-in. Network/agent features stay graceful when the runtime is down.
//
// Offline-first split:
//   NATIVE (local, work offline) — fs/doc/tab/workspace/bookmark/theme/terminal
//   RUNTIME (graceful when down)  — agent/chat/network/publish, over the
//                                    control-plane at the discovered URL.

use serde::Serialize;
use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    AppHandle, Emitter, Manager,
};

mod agent_settings;
mod daemon;
mod fs;
mod fs_ops;
mod kernel;
mod keychain;
mod machine;
mod mcp;
mod network;
mod orgprops;
mod packages;
mod paths;
mod setup;
mod store;
mod tabs;
mod terminal;
mod workbooks;
mod workspaces;
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

/// macOS WKWebView media capture for STT + live-voice. The mic entitlement
/// itself is granted by Info.plist's NSMicrophoneUsageDescription (bundled at
/// package time); WKWebView honours getUserMedia once that's present, so this
/// hook is the documented seam where any future per-config tweak lands. Kept as
/// a no-op rather than poking WKWebView internals via raw objc, which would tie
/// the shell to an unstable private API.
fn enable_webview_media(_app: &AppHandle) {}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_store::Builder::new().build())
        .manage(tabs::TabManager::default())
        .manage(fs_ops::Watchers::default())
        .manage(terminal::PtyManager::default())
        .invoke_handler(tauri::generate_handler![
            // Kernel + runtime discovery.
            weave,
            tangle,
            validate,
            lint,
            outline,
            runtime_url,
            // Daemon control-plane.
            daemon::daemon_status,
            daemon::daemon_up,
            daemon::daemon_down,
            daemon::daemon_restart,
            // Install wizard: detect/install the VM backend, boot local, or
            // connect to a cloud engine.
            daemon::engine_detect,
            daemon::engine_install_backend,
            daemon::engine_boot_local,
            daemon::engine_probe,
            daemon::engine_connect_cloud,
            daemon::engine_disconnect_cloud,
            // Tabs.
            tabs::tab_list,
            tabs::tab_open,
            tabs::tab_focus,
            tabs::tab_close,
            tabs::tab_set_dirty,
            // Filesystem.
            fs::fs_tree_walk,
            fs::fs_dir_read,
            fs::fs_read_file,
            fs::fs_write_file,
            fs_ops::fs_reveal,
            fs_ops::fs_rename,
            fs_ops::fs_delete,
            fs_ops::fs_mkdir,
            fs_ops::fs_create_file,
            fs_ops::fs_watch_start,
            fs_ops::fs_watch_stop,
            fs_ops::config_watch_start,
            // Workbooks + memory.
            workbooks::workbook_spec_read,
            workbooks::memory_source_resolve,
            // Packages.
            packages::package_list,
            packages::package_get_active,
            packages::package_load,
            packages::package_create,
            packages::package_import_folder,
            packages::package_set_icon,
            packages::package_delete,
            packages::package_add_folder,
            packages::package_remove_folder,
            packages::package_set_active,
            packages::package_refresh_active,
            packages::package_set_layout,
            packages::package_set_view_mode,
            packages::package_set_subtree,
            packages::package_workbooks,
            packages::package_app_workbook,
            packages::package_move_into,
            // Workspaces.
            workspaces::workspace_list,
            workspaces::workspace_get_active,
            workspaces::workspace_create,
            workspaces::workspace_set_active,
            workspaces::workspace_rename,
            workspaces::workspace_set_icon,
            workspaces::workspace_delete,
            workspaces::workspace_add_package,
            workspaces::workspace_remove_package,
            workspaces::workspace_set_subtree,
            // Bookmarks + themes + MCP + plugins.
            store::bookmark_list,
            store::bookmark_create,
            store::bookmark_rename,
            store::bookmark_delete,
            store::bookmark_set_slot,
            store::theme_list,
            store::theme_set_active,
            store::theme_create,
            store::theme_update,
            store::theme_delete,
            store::mcp_list,
            store::mcp_create,
            store::mcp_update,
            store::mcp_delete,
            store::plugins_list,
            store::plugins_install,
            store::plugins_set_enabled,
            store::plugins_remove,
            // Agent settings.
            agent_settings::agent_settings_get,
            agent_settings::agent_settings_set,
            // Keychain: keys / env-vars / connections.
            keychain::secrets_push,
            keychain::keys_list,
            keychain::keys_known_providers,
            keychain::keys_create,
            keychain::keys_rename,
            keychain::keys_delete,
            keychain::keys_reveal,
            keychain::keys_copy_to_clipboard,
            keychain::env_vars_list,
            keychain::env_vars_create,
            keychain::env_vars_update,
            keychain::env_vars_delete,
            keychain::env_vars_copy_to_clipboard,
            keychain::env_vars_bulk_import,
            keychain::connections_list,
            keychain::connections_create,
            keychain::connections_delete,
            keychain::connections_reveal_api_key,
            // Identity + WorkOS + packaging.
            network::identity_load,
            network::identity_generate,
            network::identity_set_handle,
            network::identity_set_workos,
            network::workspace_package,
            network::workos_sign_in,
            network::workos_load_session,
            network::workos_clear_session,
            // Terminal.
            terminal::terminal_spawn,
            terminal::terminal_write,
            terminal::terminal_resize,
            terminal::terminal_kill,
            // Setup.
            setup::setup_status,
            setup::setup_initialize_keychain,
            setup::setup_complete_first_run,
            setup::setup_save_model_key,
        ])
        .setup(|app| {
            build_tray(app.handle())?;
            enable_webview_media(app.handle());

            // Workbook-native: do NOT auto-start the heavy runtime on launch.
            // CONNECT to a running one if its discovery file is present and
            // report state; starting it is explicit (tray, or an agent feature).
            let handle = app.handle().clone();
            std::thread::spawn(move || {
                let state = if Discovery::read().is_some() { "up" } else { "down" };
                let _ = handle.emit("sidecar-state", state);
            });
            // Live daemon-state poll (discovery + /health), emits `daemon-state`.
            daemon::spawn_state_poll(app.handle().clone());

            // Embedded MCP server (wb-aakl.23) — Claude Code drives the browser.
            // Off by default; `wb desktop mcp` sets WB_MCP=1 before launch. UDS
            // only, local-user, no network listener. See desktop/docs/mcp.md.
            if std::env::var("WB_MCP").as_deref() == Ok("1") {
                mcp::start(app.handle());
            }
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
    let restart = MenuItem::with_id(app, "restart", "Start / restart engine", true, None::<&str>)?;
    let sep = PredefinedMenuItem::separator(app)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Workbooks", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&status, &open, &restart, &sep, &quit])?;

    TrayIconBuilder::with_id("workbooks")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "open" => show_window(app),
            "restart" => {
                // Safe, mode-aware: start if down, restart if it's our container,
                // leave a raw dev runtime alone. Off-thread so the menu never hangs.
                let handle = app.clone();
                std::thread::spawn(move || {
                    let _ = daemon::tray_engine_action(&handle);
                });
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
