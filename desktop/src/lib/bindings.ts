/**
 * bindings.ts — typed `commands` object SHAPED to match tauri-specta v2
 * generated output. Each method maps one Rust `#[tauri::command]`
 * (snake_case) to a camelCase async fn with typed args + return.
 *
 * Today every method returns MOCK data so the frontend builds + runs as
 * a plain Vite SPA. When the Rust backend + tauri-specta land, this file
 * is REGENERATED — the real version forwards each call through
 * `TAURI_INVOKE(...)`. The signatures here are the contract the app
 * depends on; the generated file keeps them identical.
 *
 * TODO(tauri-shell): regenerate via `tauri-specta` and delete the mocks.
 *   The generated body for each command is:
 *     return await TAURI_INVOKE("<snake_case_name>", args);
 */

/* ─────────────────────────── Types ─────────────────────────── */

export interface AgentSettings {
  defaultAgentSlug: string;
  defaultModel: string;
}
export interface AgentSettingsUpdate {
  defaultAgentSlug?: string;
  defaultModel?: string;
}
export interface AgentSource {
  source: string;
}
export interface AgentCatalogEntry {
  slug: string;
  title: string;
  tagline: string | null;
  model: string | null;
  icon: string | null;
  parseError: boolean;
}
export interface Bookmark {
  id: string;
  title: string;
  path: string;
  commandSlot: number | null;
}
export interface ConnectionRedacted {
  id: string;
  service: string;
  kind: "local_cli" | "managed_oauth" | "api_key";
  version?: string | null;
}
export interface ConnectionCreate {
  service: string;
  kind: string;
}
export interface Probe {
  found: boolean;
  path: string | null;
  version: string | null;
}
export interface EngineStatus {
  state: "stopped" | "starting" | "running" | "crashed";
  pid: number | null;
}
export interface EnvVarRedacted {
  id: string;
  name: string;
  preview: string;
}
export interface EnvVarCreate {
  name: string;
  value: string;
}
export interface BulkImportRequest {
  dotenv: string;
}
export interface BulkImportResult {
  imported: number;
  skipped: number;
}
export interface TreeNode {
  name: string;
  path: string;
  isDir: boolean;
  children?: TreeNode[];
}
export interface TreeWalkResult {
  root: string;
  nodes: TreeNode[];
}
export interface ApiKeyRedacted {
  id: string;
  name: string;
  provider: string;
  preview: string;
}
export interface KeyCreate {
  name: string;
  provider: string;
  value: string;
}
export interface McpServer {
  id: string;
  name: string;
  command: string;
  enabled: boolean;
}
export interface McpCreate {
  name: string;
  command: string;
}
export interface McpUpdate {
  id: string;
  name?: string;
  command?: string;
  enabled?: boolean;
}
export interface IdentityView {
  handle: string;
  did: string;
  publicKey: string;
  workosUserId: string | null;
}
export interface PublishArgs {
  workbookPath: string;
  visibility: "public" | "unlisted";
}
export interface PublishResult {
  url: string;
}
export interface StoredSession {
  bearer: string;
  email: string | null;
  expiresAt: number;
}
export interface WorkgateInstallArgs {
  packageName: string;
}
export interface WorkgateInstallResult {
  installed: boolean;
}
export interface WorkbookForkArgs {
  url: string;
}
export interface WorkbookForkResult {
  path: string;
}
export interface Package {
  name: string;
  icon: string;
  viewMode: "grid" | "tree";
  folders: string[];
  active: boolean;
  subtree: string | null;
}
export interface WorkbookEntry {
  name: string;
  path: string;
  kind: "workbook" | "org" | "code" | "text";
}
/** One slice of a server-paginated list. `total` is the full count so
 *  the client can render the pager without holding every row. The old
 *  app never paged (SearchDrawer hard-capped at 200); the rebuild makes
 *  the slice explicit so the sidecar can stream pages later. */
export interface EntriesPageReq {
  offset: number;
  limit: number;
  query: string;
}
export interface EntriesPage {
  items: WorkbookEntry[];
  total: number;
}
export interface Plugin {
  id: string;
  name: string;
  enabled: boolean;
}
export interface PluginCreate {
  source: string;
}
export interface SetupStatus {
  keychainInitialized: boolean;
}
export interface SidecarStatus {
  reachable: boolean;
  state: "ok" | "starting" | "unhealthy" | "stopped";
}
export interface Skill {
  id: string;
  name: string;
  slug: string;
  scope: "workspace" | "package" | "global";
}
export interface SkillScopeUpdate {
  id: string;
  scope: string;
}
export interface Tab {
  id: string;
  title: string;
  path: string;
  kind: "workbook" | "org" | "code" | "text";
  dirty: boolean;
}
export interface TabsSnapshot {
  tabs: Tab[];
  activeId: string | null;
}
export interface SpawnOptions {
  cwd?: string;
  cols: number;
  rows: number;
}
export interface Theme {
  id: string;
  name: string;
  description: string;
  light_tokens: Record<string, string>;
  dark_tokens: Record<string, string>;
  builtin: boolean;
  created_at: number;
}
export interface ThemesSnapshot {
  active_id: string | null;
  themes: Theme[];
}
export interface BundleResult {
  output: string;
}
export interface UnbundleResult {
  outputDir: string;
}
export interface Workspace {
  id: string;
  name: string;
  icon: string;
  packages: string[];
  subtree: string | null;
}
export interface SaveResult {
  mtime_ms: number;
}

/* ──────────────────────── Mock helpers ─────────────────────── */

import { isTauri } from "./tauri";
import { rt, daemon } from "./runtime";

const now = () => Date.now();
const ok = <T>(v: T): Promise<T> => Promise.resolve(v);

/* The two seeded built-in themes mirror the on-disk `themes.org`. */
const BUILTIN_THEMES: Theme[] = [
  {
    id: "builtin-mono-light",
    name: "Monochrome",
    description: "The default neutral surface palette.",
    light_tokens: {},
    dark_tokens: {},
    builtin: true,
    created_at: 0,
  },
  {
    id: "builtin-ink",
    name: "Ink",
    description: "Higher-contrast charcoal with a warm accent.",
    light_tokens: {
      "color-page": "#f6f5f3",
      "color-surface": "#ffffff",
      "color-fg": "#161413",
      "color-accent": "#7c4a2d",
    },
    dark_tokens: {
      "color-page": "#141210",
      "color-surface": "#1d1a17",
      "color-fg": "#f1ece6",
      "color-accent": "#d9a066",
    },
    builtin: true,
    created_at: 0,
  },
];

/* A deterministic 137-row corpus so the pager has enough to page. */
const ENTRY_KINDS: WorkbookEntry["kind"][] = ["workbook", "org", "code", "text"];
const ENTRY_EXT: Record<WorkbookEntry["kind"], string> = {
  workbook: "wb",
  org: "org",
  code: "ts",
  text: "md",
};
const MOCK_ENTRIES: WorkbookEntry[] = Array.from({ length: 137 }, (_, i) => {
  const kind = ENTRY_KINDS[i % ENTRY_KINDS.length];
  const name = `entry-${String(i + 1).padStart(3, "0")}`;
  return { name: `${name}.${ENTRY_EXT[kind]}`, path: `Sandbox/${name}.${ENTRY_EXT[kind]}`, kind };
});

/* ───────────────────────── Commands ────────────────────────── */

export const commands = {
  // Agent settings
  agentSettingsGet: (): Promise<AgentSettings> =>
    ok({ defaultAgentSlug: "workhorse", defaultModel: "xiaomi/mimo-v2.5" }),
  agentSettingsSet: (req: AgentSettingsUpdate): Promise<AgentSettings> =>
    ok({
      defaultAgentSlug: req.defaultAgentSlug ?? "workhorse",
      defaultModel: req.defaultModel ?? "xiaomi/mimo-v2.5",
    }),

  // Agents
  // TODO(tauri): real catalog is served by the sidecar over HTTP
  // (GET /api/agents); this mock stands in until the shell lands.
  agentsList: (): Promise<AgentCatalogEntry[]> =>
    ok([
      {
        slug: "workhorse",
        title: "Workhorse",
        tagline: "The default do-anything agent.",
        model: null,
        icon: null,
        parseError: false,
      },
      {
        slug: "strategist",
        title: "Strategist",
        tagline: "Plans multi-step work before touching code.",
        model: "anthropic/claude-opus-4",
        icon: null,
        parseError: false,
      },
    ]),
  agentsRead: (slug: string): Promise<AgentSource> =>
    ok({ source: `# agent: ${slug}\n` }),
  agentsCreate: (_req: { slug: string; source: string }): Promise<void> =>
    ok(undefined),
  agentsPatch: (req: { slug: string; source: string }): Promise<AgentSource> =>
    ok({ source: req.source }),
  agentsDelete: (_slug: string): Promise<void> => ok(undefined),

  // Bookmarks
  bookmarksList: (): Promise<Bookmark[]> => ok([]),
  bookmarksCreate: (req: {
    title: string;
    path: string;
    command_slot: number | null;
  }): Promise<Bookmark> =>
    ok({ id: "bm-1", title: req.title, path: req.path, commandSlot: req.command_slot }),
  bookmarksUpdate: (_req: { id: string; title: string }): Promise<void> =>
    ok(undefined),
  bookmarksDelete: (_id: string): Promise<void> => ok(undefined),
  bookmarksSetSlot: (_req: { id: string; slot: number }): Promise<void> =>
    ok(undefined),

  // Connections
  connectionsList: (): Promise<ConnectionRedacted[]> =>
    ok([
      { id: "cx-github", service: "GitHub", kind: "managed_oauth", version: null },
      { id: "cx-claude", service: "Claude Code", kind: "local_cli", version: "1.2.0" },
    ]),
  connectionsCreate: (req: ConnectionCreate): Promise<ConnectionRedacted> =>
    ok({ id: "conn-1", service: req.service, kind: "api_key" }),
  connectionsDelete: (_id: string): Promise<void> => ok(undefined),
  connectionsDetectLocalCli: (_name: string): Promise<Probe> =>
    ok({ found: false, path: null, version: null }),
  connectionsCreateLocalCli: (_req: {
    service: string;
    path: string;
    version: string;
  }): Promise<void> => ok(undefined),
  connectionsCreateManagedOauth: (_req: { service: string }): Promise<void> =>
    ok(undefined),
  connectionsRevealApiKey: (_service: string): Promise<string> => ok(""),

  // Engine
  engineStatus: (): Promise<EngineStatus> => ok({ state: "running", pid: 4242 }),
  engineInstall: (): Promise<void> => ok(undefined),
  engineUninstall: (): Promise<void> => ok(undefined),

  // Env vars
  envVarsList: (): Promise<EnvVarRedacted[]> => ok([]),
  envVarsCreate: (req: EnvVarCreate): Promise<EnvVarRedacted> =>
    ok({ id: "env-1", name: req.name, preview: "••••" }),
  envVarsUpdate: (_req: { id: string; value: string }): Promise<void> =>
    ok(undefined),
  envVarsDelete: (_id: string): Promise<void> => ok(undefined),
  envVarsCopyToClipboard: (_id: string): Promise<void> => ok(undefined),
  envVarsBulkImport: (_req: BulkImportRequest): Promise<BulkImportResult> =>
    ok({ imported: 0, skipped: 0 }),

  // File system
  readFileText: (_path: string): Promise<string> => ok(""),
  readFileBytesBase64: (_path: string): Promise<string> => ok(""),
  fileMtime: (_path: string): Promise<number> => ok(now()),
  fileSave: (_args: { path: string; content: string }): Promise<SaveResult> =>
    ok({ mtime_ms: now() }),
  treeWalk: (root: string): Promise<TreeWalkResult> => ok({ root, nodes: [] }),
  openInOs: (_path: string): Promise<void> => ok(undefined),

  // Keys
  keysList: (): Promise<ApiKeyRedacted[]> => ok([]),
  keysCreate: (req: KeyCreate): Promise<ApiKeyRedacted> =>
    ok({ id: "key-1", name: req.name, provider: req.provider, preview: "sk-••••" }),
  keysRename: (_req: { id: string; name: string }): Promise<void> => ok(undefined),
  keysDelete: (_id: string): Promise<void> => ok(undefined),
  keysCopyToClipboard: (_id: string): Promise<void> => ok(undefined),
  keysKnownProviders: (): Promise<string[]> =>
    ok(["openai", "anthropic", "openrouter", "google"]),

  // MCP servers
  mcpList: (): Promise<McpServer[]> =>
    ok([
      { id: "mcp-gh", name: "GitHub", command: "npx @mcp/server-github", enabled: true },
      { id: "mcp-fs", name: "Filesystem", command: "npx @mcp/server-fs ~/Workbooks", enabled: false },
    ]),
  mcpCreate: (req: McpCreate): Promise<McpServer> =>
    ok({ id: "mcp-1", name: req.name, command: req.command, enabled: true }),
  mcpUpdate: (req: McpUpdate): Promise<McpServer> =>
    ok({
      id: req.id,
      name: req.name ?? "",
      command: req.command ?? "",
      enabled: req.enabled ?? true,
    }),
  mcpDelete: (_id: string): Promise<void> => ok(undefined),

  // Network / identity / publish / auth
  networkIdentityLoad: (): Promise<IdentityView | null> => ok(null),
  networkIdentityGenerate: (args: {
    handle: string;
    workosUserId: string;
  }): Promise<IdentityView> =>
    ok({
      handle: args.handle,
      did: "did:key:zMock",
      publicKey: "z6Mk-mock",
      workosUserId: args.workosUserId,
    }),
  networkIdentitySetHandle: (args: { handle: string }): Promise<IdentityView> =>
    ok({ handle: args.handle, did: "did:key:zMock", publicKey: "z6Mk-mock", workosUserId: null }),
  networkIdentitySetWorkos: (args: {
    workosUserId: string | null;
  }): Promise<IdentityView> =>
    ok({ handle: "anon", did: "did:key:zMock", publicKey: "z6Mk-mock", workosUserId: args.workosUserId }),
  networkPublisherPublish: (_args: PublishArgs): Promise<PublishResult> =>
    ok({ url: "https://example.invalid/mock" }),
  networkWorkosSignIn: (_args: { brokerUrl: string }): Promise<StoredSession> =>
    ok({ bearer: "mock-bearer", email: "you@example.com", expiresAt: now() + 3_600_000 }),
  networkWorkosLoadSession: (): Promise<StoredSession | null> => ok(null),
  networkWorkosClearSession: (): Promise<void> => ok(undefined),
  networkWorkspacePackage: (_args: { workspaceName: string }): Promise<string> =>
    ok(""),
  networkWorkgateInstall: (
    _args: WorkgateInstallArgs,
  ): Promise<WorkgateInstallResult> => ok({ installed: true }),
  networkWorkbookFork: (_args: WorkbookForkArgs): Promise<WorkbookForkResult> =>
    ok({ path: "" }),

  // Packages
  packageList: (): Promise<string[]> => ok(["Sandbox"]),
  packageGetActive: (): Promise<Package | null> =>
    ok({ name: "Sandbox", icon: "📦", viewMode: "grid", folders: [], active: true, subtree: null }),
  packageLoad: (args: { name: string }): Promise<Package> =>
    ok({ name: args.name, icon: "📦", viewMode: "grid", folders: [], active: false, subtree: null }),
  packageCreate: (args: { name: string; icon: string }): Promise<Package> =>
    ok({ name: args.name, icon: args.icon, viewMode: "grid", folders: [], active: true, subtree: null }),
  packageImportFolder: (args: {
    packageName: string;
    icon: string;
  }): Promise<Package> =>
    ok({ name: args.packageName, icon: args.icon, viewMode: "tree", folders: [], active: true, subtree: null }),
  packageAddFolder: (args: { name: string }): Promise<Package> =>
    ok({ name: args.name, icon: "📦", viewMode: "tree", folders: [], active: true, subtree: null }),
  packageRemoveFolder: (args: { name: string }): Promise<Package> =>
    ok({ name: args.name, icon: "📦", viewMode: "tree", folders: [], active: true, subtree: null }),
  packageDelete: (_args: { name: string }): Promise<void> => ok(undefined),
  packageSetIcon: (args: { name: string; icon: string }): Promise<Package> =>
    ok({ name: args.name, icon: args.icon, viewMode: "grid", folders: [], active: true, subtree: null }),
  packageSetLayout: (args: {
    name: string;
    viewMode: "grid" | "tree";
  }): Promise<Package> =>
    ok({ name: args.name, icon: "📦", viewMode: args.viewMode, folders: [], active: true, subtree: null }),
  packageSetViewMode: (args: {
    name: string;
    viewMode: "grid" | "tree";
  }): Promise<Package> =>
    ok({ name: args.name, icon: "📦", viewMode: args.viewMode, folders: [], active: true, subtree: null }),
  packageSetActive: (_args: { name: string | null }): Promise<void> => ok(undefined),
  packageSetSubtree: (args: { name: string; subtree: string }): Promise<Package> =>
    ok({ name: args.name, icon: "📦", viewMode: "grid", folders: [], active: true, subtree: args.subtree }),
  packageWorkbooks: (_args: { name: string }): Promise<WorkbookEntry[]> => ok([]),
  packageRefreshActive: (): Promise<void> => ok(undefined),
  // Server-paginated entry list. Mock builds a deterministic corpus and
  // slices it after an optional name/path filter, mirroring the real
  // sidecar contract (offset/limit in, items+total out).
  // TODO(sidecar): forward to the engine's paged file index.
  entriesPage: (req: EntriesPageReq): Promise<EntriesPage> => {
    const all = MOCK_ENTRIES.filter(
      (e) =>
        !req.query ||
        e.name.toLowerCase().includes(req.query.toLowerCase()) ||
        e.path.toLowerCase().includes(req.query.toLowerCase()),
    );
    return ok({ items: all.slice(req.offset, req.offset + req.limit), total: all.length });
  },

  // Plugins
  pluginsList: (): Promise<Plugin[]> =>
    ok([
      { id: "plg-stripe", name: "Stripe (OQL)", enabled: true },
      { id: "plg-linear", name: "Linear (OQL)", enabled: false },
    ]),
  pluginsInstall: (req: PluginCreate): Promise<Plugin> =>
    ok({ id: "plg-1", name: req.source, enabled: true }),
  pluginsSetEnabled: (_req: { id: string; enabled: boolean }): Promise<void> =>
    ok(undefined),
  pluginsRemove: (_id: string): Promise<void> => ok(undefined),

  // Setup
  setupStatus: (): Promise<SetupStatus> => ok({ keychainInitialized: true }),
  setupInitializeKeychain: (): Promise<void> => ok(undefined),

  // Sidecar — REAL in the desktop shell: probe the runtime's /health through the
  // discovered URL+token; restart drives the deploy-kit daemon. Mocked in a plain
  // SPA (always reachable, so a browser build isn't gated offline).
  sidecarStatus: async (): Promise<SidecarStatus> => {
    if (!isTauri()) return { reachable: true, state: "ok" };
    try {
      const res = await rt("/health");
      return { reachable: res.ok, state: res.ok ? "ok" : "unhealthy" };
    } catch {
      return { reachable: false, state: "stopped" };
    }
  },
  sidecarRestart: async (): Promise<void> => {
    if (!isTauri()) return;
    await daemon.up();
  },

  // Skills
  skillsList: (): Promise<Skill[]> =>
    ok([
      { id: "sk-web", name: "Web search", slug: "web-search", scope: "global" },
      { id: "sk-git", name: "Git toolkit", slug: "git", scope: "workspace" },
      { id: "sk-brand", name: "Brand book", slug: "brandnana", scope: "package" },
    ]),
  skillsSetScope: (_req: SkillScopeUpdate): Promise<void> => ok(undefined),
  skillsDelete: (_id: string): Promise<void> => ok(undefined),

  // Tabs
  tabList: (): Promise<TabsSnapshot> => ok({ tabs: [], activeId: null }),
  tabOpen: (args: { path: string }): Promise<TabsSnapshot> =>
    ok({
      tabs: [{ id: "tab-1", title: args.path.split("/").pop() ?? args.path, path: args.path, kind: "text", dirty: false }],
      activeId: "tab-1",
    }),
  tabClose: (_args: { id: string }): Promise<TabsSnapshot> =>
    ok({ tabs: [], activeId: null }),
  tabFocus: (args: { id: string }): Promise<TabsSnapshot> =>
    ok({ tabs: [], activeId: args.id }),
  tabSetDirty: (_args: { id: string; dirty: boolean }): Promise<void> =>
    ok(undefined),

  // Terminal
  terminalSpawn: (_req: SpawnOptions): Promise<{ session_id: string }> =>
    ok({ session_id: "pty-1" }),
  terminalWrite: (_req: { session_id: string; data: string }): Promise<void> =>
    ok(undefined),
  terminalResize: (_req: {
    session_id: string;
    cols: number;
    rows: number;
  }): Promise<void> => ok(undefined),
  terminalKill: (_args: { sessionId: string }): Promise<void> => ok(undefined),

  // Themes
  themesList: (): Promise<ThemesSnapshot> =>
    ok({ active_id: BUILTIN_THEMES[0].id, themes: BUILTIN_THEMES }),
  themesCreate: (req: {
    name: string;
    description: string;
    light_tokens: Record<string, string>;
    dark_tokens: Record<string, string>;
  }): Promise<Theme> =>
    ok({
      id: `theme-${now()}`,
      name: req.name,
      description: req.description,
      light_tokens: req.light_tokens,
      dark_tokens: req.dark_tokens,
      builtin: false,
      created_at: now(),
    }),
  themesUpdate: (_req: {
    id: string;
    name: string;
    description: string;
    light_tokens: Record<string, string>;
    dark_tokens: Record<string, string>;
  }): Promise<void> => ok(undefined),
  themesDelete: (_id: string): Promise<void> => ok(undefined),
  themesSetActive: (_id: string | null): Promise<void> => ok(undefined),

  // Workbooks
  workbookBundle: (args: { output: string }): Promise<BundleResult> =>
    ok({ output: args.output }),
  workbookUnbundle: (args: { outputDir: string }): Promise<UnbundleResult> =>
    ok({ outputDir: args.outputDir }),
  workbookCheckPortability: (_args: { workdir: string }): Promise<unknown> =>
    ok({ portable: true }),
  workbookLoadAsMemory: (args: {
    htmlPath: string;
  }): Promise<{ canonical_path: string }> => ok({ canonical_path: args.htmlPath }),

  // Workspaces
  workspacesList: (): Promise<Workspace[]> =>
    ok([{ id: "ws-1", name: "Personal", icon: "🗂️", packages: ["Sandbox"], subtree: null }]),
  workspacesGetActive: (): Promise<Workspace | null> =>
    ok({ id: "ws-1", name: "Personal", icon: "🗂️", packages: ["Sandbox"], subtree: null }),
  workspacesCreate: (req: { name: string; icon: string }): Promise<Workspace> =>
    ok({ id: `ws-${now()}`, name: req.name, icon: req.icon, packages: [], subtree: null }),
  workspacesSetActive: (_args: { id: string | null }): Promise<void> => ok(undefined),
  workspacesRename: (_req: { id: string; name: string }): Promise<void> =>
    ok(undefined),
  workspacesSetIcon: (_req: { id: string; icon: string }): Promise<void> =>
    ok(undefined),
  workspacesDelete: (_args: { id: string }): Promise<void> => ok(undefined),
  workspacesAddPackage: (_req: {
    workspace_id: string;
    package_name: string;
  }): Promise<void> => ok(undefined),
  workspacesRemovePackage: (_req: {
    workspace_id: string;
    package_name: string;
  }): Promise<void> => ok(undefined),
  workspacesSetSubtree: (_req: { id: string; subtree: string }): Promise<void> =>
    ok(undefined),

  // Google OAuth
  googleOauthSignIn: (): Promise<{ account_email: string | null }> =>
    ok({ account_email: null }),
} as const;

export type Commands = typeof commands;
