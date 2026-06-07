// Shared resolution of the per-user desktop config root.
//
// AS OF wb-80q0.3+ (the data-root migration), the user-visible
// folder is `~/Workbooks/` with three siblings inside:
//
//   ~/Workbooks/
//   ├── Engine/         per-machine server infra (postgres, logs)
//   ├── Workbox/        per-machine toolchain container
//   └── monorepo/       git'd user content — what desktop_root()
//                       now returns
//
// `desktop_root()` returns `~/Workbooks/monorepo/`. Every config
// file the desktop persists (workspaces.org, packages, bookmarks,
// keys, env-vars, mcp-servers, plugins, themes) lives under that
// root. Secrets-tagged files SHOULD migrate to ~/Workbooks/Engine/
// in a follow-up cleanup so they don't get accidentally git-committed
// — for now they sit in monorepo and rely on per-user gitignore.
//
// Overrides (in resolution order):
//   1. OQL_DESKTOP_HOME — explicit override of desktop_root() to
//      an arbitrary path. The legacy env, kept for backwards-compat
//      with existing tests that set it directly to a tmpdir.
//   2. OQL_DATA_ROOT    — sets the ~/Workbooks/ equivalent;
//      desktop_root() = $OQL_DATA_ROOT/monorepo/. Aligns with the
//      Elixir side's Workbooks.Engine.DataRoot.root/0 resolution.
//   3. Platform default  — ~/Workbooks/monorepo/.
//
// Lives in its own module so keys.rs / mcp_servers.rs / plugins.rs
// don't each fork the path logic and drift from workspace.rs.

use std::path::PathBuf;

/// `~/Workbooks/` — the data root. The outermost boundary; every file
/// the agent or desktop touches lives under it. Honors `OQL_DATA_ROOT`
/// to stay aligned with the Elixir `Workbooks.Engine.DataRoot.root/0`.
/// This is the single source the IPC guard (`ensure_in_data_root`)
/// checks against, so the boundary has one definition across runtimes.
pub fn data_root() -> PathBuf {
    if let Ok(data_root) = std::env::var("OQL_DATA_ROOT") {
        return PathBuf::from(data_root);
    }
    dirs_home().join("Workbooks")
}

pub fn desktop_root() -> PathBuf {
    if let Ok(override_root) = std::env::var("OQL_DESKTOP_HOME") {
        return PathBuf::from(override_root);
    }
    data_root().join("monorepo")
}

/// `~/Workbooks/Engine/` — per-machine server infrastructure: logs,
/// transient state, network identity, socket discovery. NEVER git'd.
pub fn workhorse_root() -> PathBuf {
    data_root().join("Engine")
}

fn dirs_home() -> PathBuf {
    #[cfg(unix)]
    {
        std::env::var("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/tmp"))
    }
    #[cfg(windows)]
    {
        std::env::var("USERPROFILE")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("C:\\"))
    }
}
