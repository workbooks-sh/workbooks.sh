/**
 * Web host adapter — lets the real desktop frontend run in a plain browser.
 *
 * The whole UI talks to the native shell through Tauri's
 * `window.__TAURI_INTERNALS__.invoke(cmd, args)` seam. That single seam IS
 * the platform boundary. On the desktop, Tauri injects it. In a browser it's
 * absent, so this module installs a stand-in that answers every command.
 *
 * This is deliberately structured as the seed of a real WEB version, NOT a
 * throwaway dev mock:
 *   - `mock`  domains: return seeded in-memory data (today's default).
 *   - `http`  domains: a future web build routes these to the runtime over
 *             HTTP/WS (agents, chat, skills, memory…). Marked below.
 *   - `local` domains: browser-native replacements for desktop-only OS
 *             commands (stores→IndexedDB, fs→File System Access, etc.).
 *             Mocked for now; the seam is where the real impl lands.
 *
 * Install order: a tiny bootstrap in app.html creates __TAURI_INTERNALS__ and
 * delegates `invoke` to `window.__WB_MOCK_INVOKE__`; importing this module
 * assigns that function. Imported first in +layout.svelte so it's live before
 * any component's onMount fires. In a real Tauri build __TAURI_INTERNALS__
 * already exists, the bootstrap is skipped, and this module no-ops.
 */

type Invoke = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;

declare global {
  interface Window {
    __WB_DEV_MOCK__?: boolean;
    __WB_MOCK_INVOKE__?: Invoke;
    __TAURI_INTERNALS__?: unknown;
  }
}

// Only act in the browser-without-Tauri case the app.html bootstrap flagged.
if (typeof window !== "undefined" && window.__WB_DEV_MOCK__) {
  window.__WB_MOCK_INVOKE__ = makeInvoke();
  // eslint-disable-next-line no-console
  console.info("%c[webHost] mock backend active — browser preview, no runtime", "color:#2f6fe0");
}

// ── seed data ─────────────────────────────────────────────────────────────
// Packages double as the rail items + the springboard. Each has an icon so
// the rail renders real glyphs. Workbooks are the springboard tiles.
const PKG_ICON: Record<string, string> = {
  Budget: "💰",
  Clients: "💼",
  "Side Projects": "🚀",
  Reading: "📚",
  Home: "🏠",
  Acme: "📊",
  Internal: "🔧",
};
const PKG_WORKBOOKS: Record<string, { path: string; title: string }[]> = {
  Budget: [
    { path: "/mock/Budget/monthly.html", title: "Monthly Budget" },
    { path: "/mock/Budget/networth.html", title: "Net Worth" },
  ],
  Clients: [
    { path: "/mock/Clients/acme.html", title: "Acme Dashboard" },
    { path: "/mock/Clients/crm.html", title: "Beta CRM" },
    { path: "/mock/Clients/invoices.html", title: "Invoices" },
  ],
  "Side Projects": [
    { path: "/mock/Side Projects/recipes.html", title: "Recipe Box" },
    { path: "/mock/Side Projects/trips.html", title: "Trip Planner" },
  ],
  Reading: [{ path: "/mock/Reading/list.html", title: "Reading List" }],
  Home: [{ path: "/mock/Home/grocery.html", title: "Grocery" }],
  Acme: [{ path: "/mock/Acme/sales.html", title: "Sales" }],
  Internal: [{ path: "/mock/Internal/oncall.html", title: "On-call" }],
};

const WORKSPACES = [
  {
    id: "ws_personal",
    name: "Personal",
    icon: "🪐",
    package_names: ["Budget", "Clients", "Side Projects", "Reading", "Home"],
    created_at: 1_700_000_000_000,
  },
  {
    id: "ws_work",
    name: "Work",
    icon: "💼",
    package_names: ["Acme", "Internal"],
    created_at: 1_700_000_100_000,
  },
];

const SESSION = {
  bearer: "mock-bearer",
  expires_at: 0,
  sub: "user_mock",
  email: "you@workbooks.sh",
  email_verified: true,
  organization_id: null as string | null,
  display_name: "You",
  picture_url: null as string | null,
};
const IDENTITY = {
  did: "did:key:zMockDemo",
  handle: "you",
  workos_user_id: "user_mock",
  public_key_b64: "AAAA",
};
const DAEMON = { state: "running", url: "http://127.0.0.1:8787", pid: 4242, manager: "krunvm" };

function pkg(name: string) {
  return {
    name,
    folders: [`/mock/${name}`],
    icon: PKG_ICON[name] ?? "📦",
    view_mode: "source",
    layout: "grid",
    subtree: null,
  };
}

// ── plugin:store backing (workspaces.json, tabs.json, …) ───────────────────
const stores = new Map<string, Record<string, unknown>>();
function ensureStore(path: string): Record<string, unknown> {
  if (!stores.has(path)) {
    if (path === "workspaces.json") {
      stores.set(path, { workspaces: WORKSPACES, active_id: "ws_personal" });
    } else {
      stores.set(path, {});
    }
  }
  return stores.get(path)!;
}

// ── the router ─────────────────────────────────────────────────────────────
function makeInvoke(): Invoke {
  let listenerId = 0;
  let activePackage = "Budget";

  return async (cmd, args = {}) => {
    const a = args as Record<string, any>;

    // plugin:store — local domain (browser-native KV later)
    if (cmd.startsWith("plugin:store|")) {
      const op = cmd.split("|")[1];
      const rid = (a.rid as string) ?? (a.path as string);
      if (op === "load") return ((ensureStore(a.path), a.path));
      if (op === "get_store") return stores.has(a.path) ? a.path : null;
      const rec = ensureStore(rid);
      switch (op) {
        case "get": return [rec[a.key] ?? null, a.key in rec];
        case "set": rec[a.key] = a.value; return null;
        case "has": return a.key in rec;
        case "delete": { const had = a.key in rec; delete rec[a.key]; return had; }
        case "keys": return Object.keys(rec);
        case "values": return Object.values(rec);
        case "entries": return Object.entries(rec);
        case "length": return Object.keys(rec).length;
        case "clear": case "reset": stores.set(rid, {}); return null;
        case "save": case "reload": return null;
        default: return null;
      }
    }

    // plugin:event — no live events in preview (return fake unlisten ids)
    if (cmd.startsWith("plugin:event|")) {
      if (cmd.endsWith("|listen")) return ++listenerId;
      return null;
    }
    // plugin:dialog — no native picker in the browser
    if (cmd.startsWith("plugin:dialog|")) return null;
    if (cmd.startsWith("plugin:")) return null;

    switch (cmd) {
      // ── identity / auth (http domain in a real web build) ──
      case "identity_load": return IDENTITY;
      case "identity_generate": return IDENTITY;
      case "identity_set_handle": return { ...IDENTITY, handle: a.handle };
      case "identity_set_workos": return { ...IDENTITY, workos_user_id: a.workos_user_id };
      case "workos_load_session": return SESSION;
      case "workos_sign_in": return SESSION;
      case "workos_clear_session": return null;

      // ── engine / daemon (local supervision — n/a on web) ──
      case "daemon_status": case "daemon_up": case "daemon_down":
      case "daemon_restart": return DAEMON;
      case "sidecar_restart": return null;
      case "engine_detect": return { os: "macos", has_krunvm: true, has_homebrew: true, has_volume: true };
      case "engine_probe": return true;
      case "engine_boot_local": case "engine_connect_cloud": return DAEMON;
      case "engine_disconnect_cloud": case "engine_install_backend": return null;
      case "runtime_url": return { url: DAEMON.url, token: "mock", state: "running" };

      // ── setup (don't auto-open the wizard) ──
      case "setup_status": return { keychain_initialized: true, has_model_key: true, first_run_done: true };
      case "setup_initialize_keychain": case "setup_complete_first_run":
      case "setup_save_model_key": return { keychain_initialized: true, has_model_key: true, first_run_done: true };

      // ── workspaces handled via plugin:store above ──

      // ── packages (rail items + springboard) ──
      case "package_list": return Object.keys(PKG_ICON);
      case "package_get_active": return activePackage;
      case "package_load": return pkg(a.name);
      case "package_workbooks": return PKG_WORKBOOKS[a.name] ?? [];
      case "package_set_active": activePackage = a.name; return pkg(a.name);
      case "package_set_icon": case "package_set_layout": case "package_set_view_mode":
      case "package_set_subtree": case "package_add_folder": case "package_remove_folder":
      case "package_create": case "package_refresh_active": return pkg(a.name ?? activePackage);
      case "package_import_folder": return pkg(a.package ?? activePackage);
      case "package_delete": return null;

      // ── tabs (return-shape only; live events not bridged in preview) ──
      case "tab_list": return { tabs: [], active_id: null };
      case "tab_open": case "tab_focus": case "tab_close": case "tab_set_dirty":
        return { tabs: [], active_id: null };

      // ── bookmarks / themes / settings catalogs ──
      case "bookmark_list": return [];
      case "bookmark_create": case "bookmark_rename": case "bookmark_delete":
      case "bookmark_set_slot": return [];
      case "theme_list": return { active_id: null, themes: [] };
      case "theme_set_active": case "theme_create": case "theme_update":
      case "theme_delete": return { active_id: null, themes: [] };
      case "agent_settings_get": return { default_agent: "workhorse", default_model: null, catalog: [] };
      case "agent_settings_set": return null;

      // ── keychain-backed lists (empty) ──
      case "keys_list": case "env_vars_list": case "connections_list":
      case "mcp_list": case "plugins_list": case "skills_list": return [];
      case "keys_known_providers": return ["openrouter", "anthropic", "openai", "google"];
      case "connections_detect_local_cli": return [];

      // ── filesystem (browser File System Access later) ──
      case "fs_tree_walk": return { path: a.root ?? "/mock", name: "mock", is_dir: true, children: [] };
      case "fs_dir_read": return [];
      case "fs_read_file": return "";
      case "fs_write_file": case "fs_create_file": case "fs_mkdir":
      case "fs_rename": case "fs_delete": case "fs_reveal":
      case "fs_watch_start": case "fs_watch_stop": case "config_watch_start": return null;

      // ── workbook helpers ──
      case "workbook_spec_read": return null;
      case "memory_source_resolve": return a.html_path ?? a.path ?? null;
      case "workspace_package": return "/mock/package.html";

      default:
        // eslint-disable-next-line no-console
        console.debug("[webHost] unhandled command:", cmd, a);
        return null;
    }
  };
}

export {};
