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

import { classifyKind } from "$lib/tabs/classify";

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
  console.info("%c[webHost] mock backend active — browser preview, no runtime", "color:#149157");
}

// ── seed data ─────────────────────────────────────────────────────────────
// Rail items are packages. A package is either an `app` (a workbook — bare
// icon) or a `folder` (a container — folder glyph). Kanban ships as a default
// app. Mix of apps + folders so the rail shows the real model + reordering.
// Canonical icon form is mi:<def> (Material Icon Theme — the universal
// icon library). One lucide: legacy value stays on purpose to prove the
// legacy→material mapping; Reading keeps a plain emoji to prove emoji.
const PKG: Record<string, { icon: string; kind: "app" | "folder" }> = {
  Kanban: { icon: "mi:todo", kind: "app" },
  Notes: { icon: "mi:document", kind: "app" },
  Tracker: { icon: "lucide:TrendUp", kind: "app" }, // legacy-mapping example
  Reading: { icon: "📚", kind: "app" }, // emoji example — still supported
  Clients: { icon: "mi:lib", kind: "folder" },
  "Side Projects": { icon: "mi:rocket", kind: "folder" },
  Acme: { icon: "mi:table", kind: "folder" },
  Internal: { icon: "mi:settings", kind: "app" },
  // Extra folders to preview the varied jewel-tone folder colors — one per
  // tint slot so all eight hues show (mi: badges render as white
  // silhouettes on the dark-pastel folder body):
  Photos: { icon: "mi:image", kind: "folder" }, // green
  Design: { icon: "mi:svg", kind: "folder" }, // teal
  People: { icon: "mi:lib", kind: "folder" }, // violet
  Finance: { icon: "mi:table", kind: "folder" }, // amber
  Research: { icon: "mi:database", kind: "folder" }, // gold
  Archive: { icon: "mi:zip", kind: "folder" }, // red
  Brand: { icon: "mi:rocket", kind: "folder" }, // fuchsia
  Marketing: { icon: "mi:video", kind: "folder" }, // blue
};

/** Workbook path served per app. The real Kanban workbook lives as a
 *  static asset (see static/mock/kanban.html); other apps open a clearly
 *  labeled stub page generated on the fly by `read_file_bytes_base64`. */
const APP_WORKBOOK_PATH: Record<string, string> = {
  Kanban: "/mock/kanban.html",
};
const PKG_WORKBOOKS: Record<string, { path: string; title: string }[]> = {
  Clients: [
    { path: "/mock/Clients/acme.html", title: "Acme Dashboard" },
    { path: "/mock/Clients/crm.html", title: "Beta CRM" },
    { path: "/mock/Clients/invoices.html", title: "Invoices" },
  ],
  "Side Projects": [
    { path: "/mock/Side Projects/recipes.html", title: "Recipe Box" },
    { path: "/mock/Side Projects/trips.html", title: "Trip Planner" },
  ],
};

const WORKSPACES = [
  {
    id: "ws_personal",
    name: "Personal",
    icon: "🪐",
    package_names: ["Kanban", "Notes", "Tracker", "Reading", "Clients", "Side Projects", "Photos", "Design", "People", "Finance", "Research", "Archive", "Brand", "Marketing"],
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

// ── agents (AgentDef) seed — backs the agent-as-workbook-tab editor.
// The catalog itself is served over HTTP (engineRequest), which a
// browser preview can't reach; the agents store falls back to
// AGENTS_CATALOG_PREVIEW (exported below) for the list. These sources
// back agents_read / agents_patch so editing a seeded agent in a tab
// round-trips through the host seam.
export interface PreviewAgent {
  slug: string;
  title: string;
  tagline: string;
  icon: string;
  model: string | null;
  scope: "user" | "project" | "builtin";
  toolkits: string[];
  system_prompt_preview: string;
}
export const AGENTS_CATALOG_PREVIEW: PreviewAgent[] = [
  {
    slug: "workhorse",
    title: "Workhorse",
    tagline: "The default Workbooks agent — knows the ecosystem, can do anything reasonable.",
    icon: "lucide:Bot",
    model: null,
    scope: "builtin",
    toolkits: ["bash", "wb"],
    system_prompt_preview: "You are Workhorse, the default Workbooks agent.",
  },
  {
    slug: "researcher",
    title: "Researcher",
    tagline: "Fans out web searches, verifies claims, writes a cited report.",
    icon: "lucide:Telescope",
    model: "google/gemini-3.5-flash",
    scope: "user",
    toolkits: ["bash", "wb", "git"],
    system_prompt_preview:
      "You are a meticulous research agent. Gather sources, verify each claim against at least two independent references, and synthesize a cited report.",
  },
];

const AGENTS_MOCK: Record<string, { source: string; scope: "user" | "project" | "builtin" }> = {
  workhorse: {
    scope: "builtin",
    source: `* Workhorse                                                          :agent:
  :PROPERTIES:
  :ID:           workhorse
  :TYPE:         ai
  :ICON:         lucide:Bot
  :TOOLKITS:     bash wb
  :END:
** System prompt
You are Workhorse, the default Workbooks agent.
`,
  },
  researcher: {
    scope: "user",
    source: `#+EXTENSIONS: ICON TAGLINE TOOLKITS

* Researcher                                                          :agent:
  :PROPERTIES:
  :ID:           researcher
  :TYPE:         ai
  :MODEL:        google/gemini-3.5-flash
  :ICON:         lucide:Telescope
  :TAGLINE:      Fans out web searches, verifies claims, writes a cited report.
  :TOOLKITS:     bash wb git
  :HUMAN_IN_LOOP: true
  :END:
** System prompt
You are a meticulous research agent. Gather sources, verify each claim against at least two independent references, and synthesize a cited report.
`,
  },
};

const agentSettingsMock = { default_model: "", default_agent_slug: "workhorse" };

/** Resolve the workbook path an `app` package opens as a window/tab.
 *  Real Kanban workbook for Kanban; a labeled stub path for every other
 *  app. Folders never call this (they open the folder viewer instead). */
function appWorkbookPath(name: string): string {
  return APP_WORKBOOK_PATH[name] ?? `/mock/${name}.html`;
}

function pkg(name: string) {
  return {
    name,
    folders: [`/mock/${name}`],
    icon: PKG[name]?.icon ?? "📦",
    kind: PKG[name]?.kind ?? "folder",
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

type MockTab = { id: string; path: string; title: string; kind: string; dirty: boolean };

/** Derive a tab title + kind from a path. Classification is shared with the
 *  packaged host via $lib/tabs/classify (wavelet → player, `.html` →
 *  workbook, `.org` → org, else text). */
function tabFromPath(path: string, id: string): MockTab {
  // Agent tabs: `agent://<slug>` → titled by the agent (or "New agent").
  const am = path.match(/^agent:\/\/(.+)$/i);
  if (am) {
    const slug = decodeURIComponent(am[1]);
    const title =
      slug === "__new__"
        ? "New agent"
        : AGENTS_CATALOG_PREVIEW.find((x) => x.slug === slug)?.title ?? slug;
    return { id, path, title, kind: "agent", dirty: false };
  }
  const file = path.split("/").pop() ?? path;
  const base = file.replace(/\.[^.]+$/, "");
  const title = base.charAt(0).toUpperCase() + base.slice(1);
  return { id, path, title, kind: classifyKind(path), dirty: false };
}

/** Stub workbook HTML for any app that lacks a real workbook on disk.
 *  Clearly labeled so it's obvious this is a placeholder, not content. */
function stubWorkbookHtml(path: string): string {
  const name = (path.split("/").pop() ?? path).replace(/\.[^.]+$/, "");
  const label = name.charAt(0).toUpperCase() + name.slice(1);
  return `<!doctype html><html><head><meta charset="utf-8">
<title>${label} (stub)</title>
<style>
  :root { color-scheme: light; }
  body { margin:0; font:15px/1.5 ui-sans-serif,system-ui,sans-serif;
    color:#1c1d22; background:#f7f8fa; display:grid; place-items:center;
    min-height:100vh; }
  .card { text-align:center; padding:40px 48px; border:1px dashed #cdd2da;
    border-radius:16px; background:#fff; max-width:380px; }
  h1 { font-size:20px; margin:0 0 8px; }
  p { margin:0; color:#6b7280; font-size:13px; }
  .tag { display:inline-block; margin-bottom:16px; padding:3px 10px;
    border-radius:999px; background:rgba(20,145,87,.10); color:#149157; font-size:11px;
    font-weight:600; letter-spacing:.04em; text-transform:uppercase; }
</style></head>
<body><div class="card"><span class="tag">Stub workbook</span>
<h1>${label}</h1>
<p>This is a placeholder page. No real workbook is wired for this app yet.</p>
</div></body></html>`;
}

// ── the router ─────────────────────────────────────────────────────────────
function makeInvoke(): Invoke {
  let listenerId = 0;
  let activePackage = "Kanban";

  // Real in-memory tab state. Tauri events aren't bridged in the mock, so
  // the tabs store can't learn about opens from a `tabs-state` event — but
  // it DOES apply tab_open/tab_focus/tab_close return values directly
  // (see tabs/store.svelte.ts #apply(snap)). So as long as we return an
  // honest snapshot here, clicking an app visibly opens a new tab.
  let tabs: MockTab[] = [];
  let activeTabId: string | null = null;
  let tabSeq = 0;
  const snap = () => ({ tabs, active: activeTabId });

  // ?onboarding=fresh — preview the EMPTY first-run path: signed out,
  // runtime stopped, no model key. Stateful so the flow can be walked
  // (sign-in / wizard connect / key save flip the bits).
  const freshOnboarding =
    typeof location !== "undefined" &&
    new URLSearchParams(location.search).get("onboarding") === "fresh";
  const freshState = { signedIn: false, runtime: false, hasKey: false };

  // Stateful bookmark mock — backs the sidebar bookmark grid.
  let bookmarksMock: {
    id: string;
    title: string;
    path: string;
    command_slot: number | null;
    created_at: number;
  }[] = [];
  let bookmarkSeq = 0;

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
      case "identity_load": return freshOnboarding && !freshState.signedIn ? null : IDENTITY;
      case "identity_generate": return IDENTITY;
      case "identity_set_handle": return { ...IDENTITY, handle: a.handle };
      case "identity_set_workos": return { ...IDENTITY, workos_user_id: a.workos_user_id };
      case "workos_load_session":
        return freshOnboarding && !freshState.signedIn ? null : SESSION;
      case "workos_sign_in":
        freshState.signedIn = true;
        return SESSION;
      case "workos_clear_session": return null;

      // ── engine / daemon (local supervision — n/a on web) ──
      case "daemon_status":
        return freshOnboarding && !freshState.runtime
          ? { ...DAEMON, state: "stopped", url: null, pid: null }
          : DAEMON;
      case "daemon_up": case "daemon_down":
      case "daemon_restart": return DAEMON;
      case "sidecar_restart": return null;
      case "engine_detect": return { os: "macos", supported: true, krunvm: true, apfsVolume: true, brew: true };
      case "engine_probe": return true;
      case "engine_boot_local": case "engine_connect_cloud":
        freshState.runtime = true;
        return DAEMON;
      case "engine_disconnect_cloud": case "engine_install_backend": return null;
      case "runtime_url": return { url: DAEMON.url, token: "mock", state: "running" };

      // ── setup (don't auto-open the wizard) ──
      case "setup_status":
        return freshOnboarding
          ? { keychain_initialized: true, has_model_key: freshState.hasKey, first_run_done: false }
          : { keychain_initialized: true, has_model_key: true, first_run_done: true };
      case "setup_save_model_key":
        freshState.hasKey = true;
        return { keychain_initialized: true, has_model_key: true, first_run_done: false };
      case "setup_initialize_keychain": case "setup_complete_first_run":
        return { keychain_initialized: true, has_model_key: true, first_run_done: true };

      // ── workspaces handled via plugin:store above ──

      // ── packages (rail items + springboard) ──
      case "package_list": return Object.keys(PKG);
      case "package_get_active": return activePackage;
      case "package_load": return pkg(a.name);
      case "package_workbooks": return PKG_WORKBOOKS[a.name] ?? [];
      // App packages open as a window/tab; resolve the workbook path the
      // app maps to (real Kanban workbook, or a labeled stub for others).
      case "package_app_workbook": return appWorkbookPath(a.name);
      case "package_set_active": activePackage = a.name; return pkg(a.name);
      case "package_set_icon": case "package_set_layout": case "package_set_view_mode":
      case "package_set_subtree": case "package_add_folder": case "package_remove_folder":
      case "package_create": case "package_refresh_active": return pkg(a.name ?? activePackage);
      case "package_import_folder": return pkg(a.package ?? activePackage);
      case "package_delete": return null;
      // Move an app (its workbook) or a workbook file into a folder
      // package. Mock-stateful so the preview demos the drag; the real
      // Rust command is wb-5fl.12.
      case "package_move_into": {
        const folder = a.folder as string;
        if (PKG[folder]?.kind !== "folder") throw new Error(`not a folder: ${folder}`);
        const list = (PKG_WORKBOOKS[folder] ??= []);
        if (a.kind === "app") {
          const name = a.item as string;
          if (!PKG[name]) throw new Error(`unknown app: ${name}`);
          list.push({ path: appWorkbookPath(name), title: name });
          delete PKG[name];
        } else {
          const path = a.item as string;
          for (const k of Object.keys(PKG_WORKBOOKS)) {
            const idx = PKG_WORKBOOKS[k].findIndex((w) => w.path === path);
            if (idx >= 0) {
              list.push(...PKG_WORKBOOKS[k].splice(idx, 1));
              break;
            }
          }
        }
        return null;
      }

      // ── tabs ──
      // Events aren't bridged in the mock, but the tabs store applies
      // these return snapshots directly, so opens/closes show up live.
      case "tab_list":
        return snap();
      case "tab_open": {
        const existing = tabs.find((t) => t.path === a.path);
        if (existing) {
          activeTabId = existing.id;
        } else {
          const t = tabFromPath(a.path, `tab_${++tabSeq}`);
          tabs = [...tabs, t];
          activeTabId = t.id;
        }
        return snap();
      }
      case "tab_focus":
        if (tabs.some((t) => t.id === a.id)) activeTabId = a.id;
        return snap();
      case "tab_close": {
        const idx = tabs.findIndex((t) => t.id === a.id);
        tabs = tabs.filter((t) => t.id !== a.id);
        if (activeTabId === a.id) {
          const next = tabs[idx] ?? tabs[idx - 1] ?? tabs[tabs.length - 1];
          activeTabId = next ? next.id : null;
        }
        return snap();
      }
      case "tab_set_dirty":
        tabs = tabs.map((t) => (t.id === a.id ? { ...t, dirty: !!a.dirty } : t));
        return snap();

      // ── bookmarks / themes / settings catalogs ──
      // Bookmarks are stateful so the sidebar's bookmark grid (pin by
      // drag, reorder, unpin) is demoable in the browser preview.
      case "bookmark_list": return bookmarksMock;
      case "bookmark_create": {
        const req = a.req as { title: string; path: string; command_slot: number | null };
        const b = {
          id: `bm-${++bookmarkSeq}`,
          title: req.title,
          path: req.path,
          command_slot: req.command_slot ?? null,
          created_at: bookmarkSeq,
        };
        bookmarksMock = [...bookmarksMock, b];
        return b;
      }
      case "bookmark_rename": {
        const req = a.req as { id: string; title: string };
        bookmarksMock = bookmarksMock.map((b) =>
          b.id === req.id ? { ...b, title: req.title } : b,
        );
        return null;
      }
      case "bookmark_delete":
        bookmarksMock = bookmarksMock.filter((b) => b.id !== a.id);
        return null;
      case "bookmark_set_slot": {
        const req = a.req as { id: string; slot: number | null };
        bookmarksMock = bookmarksMock.map((b) =>
          b.id === req.id ? { ...b, command_slot: req.slot } : b,
        );
        return null;
      }
      case "theme_list": return { active_id: null, themes: [] };
      case "theme_set_active": case "theme_create": case "theme_update":
      case "theme_delete": return { active_id: null, themes: [] };
      case "agent_settings_get":
        return { default_model: agentSettingsMock.default_model, default_agent_slug: agentSettingsMock.default_agent_slug };
      case "agent_settings_set": {
        const req = (a.req ?? {}) as { default_model?: string; default_agent_slug?: string };
        if (req.default_model !== undefined) agentSettingsMock.default_model = req.default_model;
        if (req.default_agent_slug !== undefined) agentSettingsMock.default_agent_slug = req.default_agent_slug;
        return { ...agentSettingsMock };
      }

      // ── agents (AgentDef CRUD — runtime cap; mocked for preview) ──
      // The agent editor opens as a workbook tab and reads/writes the
      // agent's .org source through these verbs (feat/agent-tab).
      case "agents_read": {
        const slug = String(a.slug ?? "");
        const src = AGENTS_MOCK[slug]?.source;
        if (src === undefined) throw new Error(`agent not found: ${slug}`);
        return { source: src };
      }
      case "agents_create": {
        const req = a.req as { slug: string; source: string };
        AGENTS_MOCK[req.slug] = { source: req.source, scope: "user" };
        return { source: req.source };
      }
      case "agents_patch": {
        const req = a.req as {
          slug: string;
          properties?: Record<string, string>;
          title?: string | null;
          system_prompt?: string;
        };
        const cur = AGENTS_MOCK[req.slug] ?? (AGENTS_MOCK[req.slug] = { source: "", scope: "user" });
        // Mock patch: regenerate a minimal source so a re-read reflects
        // the saved values (the real runtime patches verbatim).
        const props = req.properties ?? {};
        const lines: string[] = [];
        lines.push(`* ${req.title ?? req.slug}                                                          :agent:`);
        lines.push(`  :PROPERTIES:`);
        lines.push(`  :ID:           ${req.slug}`);
        lines.push(`  :TYPE:         ai`);
        for (const [k, v] of Object.entries(props)) {
          if (v && v.trim()) lines.push(`  :${k}:         ${v.trim()}`);
        }
        lines.push(`  :END:`);
        if (req.system_prompt?.trim()) {
          lines.push(`** System prompt`);
          lines.push(req.system_prompt.trim());
        }
        cur.source = lines.join("\n") + "\n";
        return { source: cur.source };
      }
      case "agents_delete":
        delete AGENTS_MOCK[String(a.slug ?? "")];
        return null;
      case "agent_publish":
        // Best-effort publish/send. Returns a fake nexus URL so the
        // editor can show a "Published → …" confirmation in preview.
        return { ok: true, url: `https://nexus.workbooks.sh/a/${a.slug}` };

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

      // ── workbook bytes (WorkbookView reads base64 → blob → iframe) ──
      // Real workbooks (e.g. /mock/kanban.html) are served as static
      // assets under desktop/static; fetch + base64 them. Anything we
      // can't fetch falls back to a clearly-labeled stub page.
      case "read_file_bytes_base64": {
        const path = String(a.path ?? "");
        let html: string | null = null;
        // Component-toolkit artifacts the mock agent produced live in an
        // in-memory registry (no runtime to write them to disk in the
        // browser preview). Serve those first so an agent-created
        // component renders in its tab.
        const artifacts = (
          window as unknown as {
            __WB_ARTIFACTS__?: { read(p: string): string | undefined };
          }
        ).__WB_ARTIFACTS__;
        const registered = artifacts?.read(path);
        if (registered !== undefined) {
          html = registered;
        } else {
          try {
            const res = await fetch(path);
            if (res.ok) html = await res.text();
          } catch {
            /* fall through to stub */
          }
        }
        if (html === null) html = stubWorkbookHtml(path);
        // base64-encode UTF-8 (mirror Rust's read_file_bytes_base64).
        const bytes = new TextEncoder().encode(html);
        let bin = "";
        for (const b of bytes) bin += String.fromCharCode(b);
        return btoa(bin);
      }

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
