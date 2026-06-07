// Workbooks Desktop — Tauri host process.
//
// wb-i38o.2 lands the always-bundled sidecar lifecycle here. The
// Elixir `oql-agent` (packages/oql/elixir/oql-agent) is spawned
// at app boot; its stdout is parsed for `OQL_LISTEN=localhost:<port>`
// (Burrito contract, wb-i38o.17), health-checked every 5s, and
// SIGTERM/SIGKILL'd on window close.
//
// In dev (when the Burrito binary isn't built yet) we fall back to
// `mix run --no-halt` against the package source and assume the
// agent's compile-time default port (`config/config.exs` → 4000).
//
// wb-i38o.8 adds the tab system (Rust-owned canonical tab list +
// `tab_open` / `tab_close` / `tab_focus` / `tab_list` commands +
// `read_file_text` / `read_file_bytes_base64` for the renderer).
//
// Safe-Rust posture per workbooks CLAUDE.md — `deny(unsafe_code)` at
// the crate root, with one scoped exception in `media` (macOS-only
// WKWebView ObjC interop for mic enablement, wb-dj5r). Every other
// module remains forbidden by default.

#![deny(unsafe_code)]

mod agent_settings;
mod agents_io;
mod auth_loopback;
mod bookmarks;
mod config_paths;
mod connections;
mod crypto;
mod editor_io;
mod engine;
mod env_vars;
mod fs_tree;
mod google_oauth;
mod keys;
mod mcp_servers;
#[cfg(target_os = "macos")]
mod media;
mod memory_sources;
mod network;
mod org_kv;
mod plugins;
mod setup;
mod sidecar;
mod skills;
mod tabs;
mod terminal;
mod themes;
mod tray;
mod workbook_io;
mod workbook_marker;
mod package;
mod workspaces;

use tauri::{Manager, RunEvent, WindowEvent};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // Bridge `log` → stderr so [sidecar:*] lines show up in `tauri dev`.
    let _ = env_logger::Builder::from_env(
        env_logger::Env::default().default_filter_or("info"),
    )
    .try_init();

    let mut builder = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init());

    #[cfg(feature = "ui-automation")]
    {
        builder = builder.plugin(
            tauri_plugin_mcp_bridge::Builder::new()
                .bind_address("127.0.0.1")
                .build(),
        );
    }

    builder
        .invoke_handler(tauri::generate_handler![
            sidecar::sidecar_status,
            sidecar::sidecar_restart,
            package::package_list,
            package::package_load,
            package::package_create,
            package::package_delete,
            package::package_add_folder,
            package::package_remove_folder,
            package::package_set_active,
            package::package_refresh_active,
            package::package_get_active,
            package::package_set_view_mode,
            package::package_set_subtree,
            package::package_set_icon,
            package::package_set_layout,
            package::package_workbooks,
            package::package_import_folder,
            fs_tree::tree_walk,
            fs_tree::open_in_os,
            tabs::tab_list,
            tabs::tab_open,
            tabs::tab_close,
            tabs::tab_focus,
            tabs::tab_set_dirty,
            tabs::read_file_text,
            tabs::read_file_bytes_base64,
            tabs::demo_kitchen_sink_path,
            keys::keys_list,
            keys::keys_create,
            keys::keys_rename,
            keys::keys_delete,
            keys::keys_copy_to_clipboard,
            keys::keys_known_providers,
            connections::connections_list,
            connections::connections_create,
            connections::connections_delete,
            connections::connections_reveal_api_key,
            connections::connections_detect_local_cli,
            connections::connections_create_local_cli,
            connections::connections_open_auth_terminal,
            connections::connections_create_managed_oauth,
            google_oauth::google_oauth_sign_in,
            terminal::terminal_spawn,
            terminal::terminal_write,
            terminal::terminal_resize,
            terminal::terminal_kill,
            agent_settings::agent_settings_get,
            agent_settings::agent_settings_set,
            agents_io::agents_create,
            agents_io::agents_update,
            agents_io::agents_patch,
            agents_io::agents_read,
            agents_io::agents_delete,
            skills::skills_list,
            skills::skills_set_scope,
            skills::skills_delete,
            mcp_servers::mcp_list,
            mcp_servers::mcp_create,
            mcp_servers::mcp_update,
            mcp_servers::mcp_delete,
            plugins::plugins_list,
            plugins::plugins_install,
            plugins::plugins_set_enabled,
            plugins::plugins_remove,
            setup::setup_status,
            setup::setup_initialize_keychain,
            engine::engine_status,
            engine::engine_install,
            engine::engine_uninstall,
            workbook_io::workbook_bundle,
            workbook_io::workbook_unbundle,
            workbook_io::workbook_check_portability,
            editor_io::file_save,
            editor_io::file_mtime,
            memory_sources::workbook_load_as_memory,
            workspaces::workspaces_list,
            workspaces::workspaces_get_active,
            workspaces::workspaces_create,
            workspaces::workspaces_set_active,
            workspaces::workspaces_rename,
            workspaces::workspaces_set_icon,
            workspaces::workspaces_delete,
            workspaces::workspaces_add_package,
            workspaces::workspaces_remove_package,
            workspaces::workspaces_set_subtree,
            workspaces::workspaces_file_path,
            env_vars::env_vars_list,
            env_vars::env_vars_create,
            env_vars::env_vars_update,
            env_vars::env_vars_delete,
            env_vars::env_vars_copy_to_clipboard,
            env_vars::env_vars_bulk_import,
            bookmarks::bookmarks_list,
            bookmarks::bookmarks_create,
            bookmarks::bookmarks_update,
            bookmarks::bookmarks_delete,
            bookmarks::bookmarks_set_slot,
            themes::themes_list,
            themes::themes_set_active,
            themes::themes_create,
            themes::themes_update,
            themes::themes_delete,
            // Workbooks Network bridge layer:
            //   wb-u2o0.9.1 — IPC into oql-agent for Identity + Publisher
            //   wb-u2o0.9.2 — WorkOS sign-in via Tauri child window
            //   wb-u2o0.9.3 — workspace → workbook `.html` packager
            network::network_identity_load,
            network::network_identity_generate,
            network::network_identity_set_handle,
            network::network_identity_set_workos,
            network::network_publisher_publish,
            network::network_workos_sign_in,
            network::network_workos_load_session,
            network::network_workos_clear_session,
            network::network_workspace_package,
            network::network_workgate_install,
            network::network_workbook_fork,
        ])
        .setup(|app| {
            // Grant the mcp-bridge permission only when the ui-automation
            // feature actually compiled the plugin. Keeping it out of the
            // always-scanned default.json lets the default/production build
            // (no feature) succeed — the build-time ACL check no longer
            // references a permission from an uncompiled optional plugin.
            #[cfg(feature = "ui-automation")]
            app.add_capability(
                r#"{
                    "identifier": "ui-automation",
                    "description": "UI automation bridge (mcp-bridge), feature-gated.",
                    "windows": ["main"],
                    "permissions": ["mcp-bridge:default"]
                }"#,
            )?;

            app.manage(tabs::TabsState::default());
            sidecar::start(app.handle().clone());
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                package::boot(handle).await;
            });
            fs_tree::boot_watcher(app.handle().clone());
            if let Err(e) = tray::build(app.handle()) {
                log::warn!("[tray] build failed: {e}");
            }

            // wb-dj5r — expose navigator.mediaDevices in the WKWebView
            // so the palette's voice mode (Gemini Live, brainstorm)
            // and the chat voice button can call getUserMedia. On
            // anything other than macOS this is a no-op.
            #[cfg(target_os = "macos")]
            {
                if let Some(win) = app.get_webview_window("main") {
                    if let Err(e) = media::configure(&win) {
                        log::warn!("[media] WKWebView configure failed: {e}");
                    }
                }
            }

            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| match event {
            // Intercept the user clicking the window's red close
            // button: hide the window instead of quitting the whole
            // app. The tray icon keeps the app alive as a "running
            // in the background" status indicator. Cmd-Q (or the
            // tray's Quit menu item) still exits cleanly.
            RunEvent::WindowEvent {
                event: WindowEvent::CloseRequested { api, .. },
                label,
                ..
            } if label == "main" => {
                if let Some(win) = app_handle.get_webview_window("main") {
                    let _ = win.hide();
                }
                api.prevent_close();
            }
            RunEvent::WindowEvent {
                event: WindowEvent::Destroyed,
                ..
            } => {
                let handle = app_handle.clone();
                tauri::async_runtime::block_on(async move {
                    sidecar::shutdown(handle).await;
                });
            }
            _ => {}
        });
}
