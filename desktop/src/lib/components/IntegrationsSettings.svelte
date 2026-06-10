<script lang="ts">
  /**
   * IntegrationsSettings — unified "secrets + connected services" tab.
   *
   * Combines what used to be two separate settings tabs (API Keys +
   * Environment) into one surface. Conceptually they're the same
   * thing — named values forwarded to the agent as env vars — and
   * the bifurcation was confusing the model.
   *
   * Top row: three connected-service cards (GitHub / Composio /
   * Doppler) as stubs. Each will gain its own OAuth + sync flow
   * incrementally.
   *
   * Below: one unified secrets list. Each row shows:
   *   - name + masked value + reveal eye
   *   - kind chip (API key | Env var)
   *   - scope chip (User | Workspace | Package · <name>)
   *   - permission badges:
   *       Agent  • read  (default) | none
   *       Workbook • none (default) | read
   *
   * The Rust storage stays bifurcated for now (keys.org + env-vars.org)
   * — the UI unification is what matters. A real schema merge can
   * land later without changing this surface.
   */
  import { onMount } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { Plus, Copy, Trash as Trash2, ClipboardText as ClipboardPaste, Check, Key as KeyRound, Sparkle as Sparkles, Stack as Layers, Cube as Boxes } from "phosphor-svelte";
  import { ArrowSquareOut as ExternalLink, LinkBreak as Unlink, Question as HelpCircle } from "phosphor-svelte";
  import { confirm as tauriConfirm } from "@tauri-apps/plugin-dialog";
  import { keys, providerEnvVar, providerLabel } from "$lib/bridge/keys.svelte";
  import {
    envVars,
    type EnvScope,
  } from "$lib/bridge/env_vars.svelte";
  import {
    connections,
    type ConnectionService,
  } from "$lib/bridge/connections.svelte";
  import { workspaces } from "$lib/bridge/workspaces.svelte";
  import { packageStore } from "$lib/bridge/package.svelte";
  import { sidecar } from "$lib/bridge/sidecar.svelte";
  import SettingsPanel from "./settings/SettingsPanel.svelte";
  import EmptyState from "./ui/EmptyState.svelte";
  import Dropdown from "./ui/Dropdown.svelte";
  import ConnectModal from "./ConnectModal.svelte";
  import ComposioPickerModal from "./ComposioPickerModal.svelte";
  import DetectModal from "./DetectModal.svelte";
  import GithubLogo from "$lib/integrations/logos/github.svg?raw";
  import ComposioLogo from "$lib/integrations/logos/composio.svg?raw";
  import DopplerLogo from "$lib/integrations/logos/doppler.svg?raw";
  import OpenRouterLogo from "$lib/integrations/logos/openrouter.svg?raw";
  import ClaudeLogo from "$lib/integrations/logos/claude.svg?raw";
  import OpenAILogo from "$lib/integrations/logos/openai.svg?raw";
  import GoogleWorkspaceLogo from "$lib/integrations/logos/google-workspace.svg?raw";
  import MetaLogo from "$lib/integrations/logos/meta.svg?raw";
  import FalLogo from "$lib/integrations/logos/fal.svg?raw";
  import GeminiLogo from "$lib/integrations/logos/gemini.svg?raw";

  type Kind = "api-key" | "env-var";

  // ── Connected-service cards ──────────────────────────────────────────
  // `getKeyUrl` is where the modal sends the user to grab their API
  // key BEFORE connecting. The post-connect "Manage ↗" link comes from
  // the persisted connection record (set by Rust as the dashboard
  // root) so a user can override per-machine if they self-host.
  type ServiceDef = {
    id: ConnectionService;
    name: string;
    description: string;
    svg: string;
    /** Where the user gets their API key. Linked from the modal. */
    getKeyUrl: string;
    /** Placeholder hint shown in the modal's key field. */
    apiKeyHint: string;
    /** Whether the v1 connect flow is enabled. GitHub + Meta are
     *  custom OAuth (later); they stay "Coming soon" until the
     *  broker side lands. */
    available: boolean;
    /** Which connect surface this service uses. Drives which modal
     *  opens when the user clicks Connect. */
    connectFlow: "paste_key" | "detect_cli" | "oauth" | "managed_oauth";
    /** For `managed_oauth` services: the OAuth provider id. Today
     *  only `"google"` is wired. The Tauri command for that
     *  provider owns the PKCE dance + browser open + token capture. */
    managedOAuthProvider?: "google";
    /** For `detect_cli` services: the binary name to probe + the
     *  install command users see when not detected. */
    binaryName?: string;
    installCommand?: string;
    /** For local-CLI services whose own CLI ships an interactive
     *  auth flow (e.g. `gws auth login`, `claude /login`). When set,
     *  the connected card grows a Sign-in button that opens this
     *  command in a terminal. */
    signInCommand?: string;
    /** Optional one-click setup script. When set, the SignInModal's
     *  primary action runs this in the embedded terminal drawer
     *  instead of just opening Terminal.app with `signInCommand`.
     *  Useful for services whose first-run flow needs more than one
     *  command (gws: install gcloud → install gws → auth setup). */
    signInScript?: string;
  };
  const services: ServiceDef[] = [
    {
      id: "github",
      name: "GitHub",
      description:
        "Connect your GitHub account to back the install up as a true monorepo. Each Workspace lives as a top-level directory; Packages can publish themselves as subtrees to their own remotes.",
      svg: GithubLogo,
      getKeyUrl: "https://github.com/settings/tokens",
      apiKeyHint: "ghp_…",
      available: false,
      connectFlow: "oauth",
    },
    {
      id: "composio",
      name: "Composio",
      description:
        "Composio plugs hundreds of pre-built integrations — Slack, Notion, Linear, Gmail, Drive — into your agent without per-service auth code. Connect once and the agent can call any of them via the Composio SDK.",
      svg: ComposioLogo,
      getKeyUrl: "https://app.composio.dev/developers",
      apiKeyHint: "ck_…",
      available: true,
      connectFlow: "paste_key",
    },
    {
      id: "doppler",
      name: "Doppler",
      description:
        "Doppler centralizes environment variables and secrets across every project and stage. Connect to sync your team's values directly into the Values list below — no more pasting .env files by hand.",
      svg: DopplerLogo,
      getKeyUrl: "https://dashboard.doppler.com/workplace/tokens",
      apiKeyHint: "dp.st.…",
      available: true,
      connectFlow: "paste_key",
    },

    // ── AI providers ────────────────────────────────────────────────
    // These wire into the agent's model layer rather than as data
    // sources. OpenRouter is the canonical default per CLAUDE.md
    // (xiaomi/mimo-v2.5-pro for evals). Claude Code + Codex are
    // local CLIs the agent can call as tools — same envelope as the
    // cloud cards so the surface stays consistent, but the "Connect"
    // flow for the CLIs is a binary-detect (deferred to a follow-up
    // turn). When wired, each will route through ACP so the agent
    // can invoke them as sub-agents.
    {
      id: "open_router",
      name: "OpenRouter",
      description:
        "OpenRouter routes inference across every major LLM provider through one API key. Connect to give the agent + workbooks access to Claude, GPT, Gemini, Mistral, and local models behind a single bill.",
      svg: OpenRouterLogo,
      getKeyUrl: "https://openrouter.ai/keys",
      apiKeyHint: "sk-or-…",
      available: true,
      connectFlow: "paste_key",
    },
    {
      id: "gemini",
      name: "Gemini",
      description:
        "Connect a Google AI Studio API key to enable live (audio) sessions with any agent. The renderer holds the Gemini Live WebSocket; the agent's prompts, skills, and bash tool are unchanged — only the transport differs from the OpenRouter path.",
      svg: GeminiLogo,
      getKeyUrl: "https://aistudio.google.com/apikey",
      apiKeyHint: "AIza…",
      available: true,
      connectFlow: "paste_key",
    },
    {
      id: "claude_code",
      name: "Claude Code",
      description:
        "Connect Anthropic's Claude Code CLI on this machine. The agent can hand work off to it as a sub-agent via ACP, or call it as a tool when a specific task needs Claude's coding strengths.",
      svg: ClaudeLogo,
      getKeyUrl: "https://docs.claude.com/en/docs/claude-code/quickstart",
      apiKeyHint: "claude",
      available: true,
      connectFlow: "detect_cli",
      binaryName: "claude",
      installCommand: "npm install -g @anthropic-ai/claude-code",
      // First-run auth: just launch `claude` — the interactive REPL
      // prompts to log in on first use. `/login` is a slash command
      // *inside* a running session, not a shell argument.
      signInCommand: "claude",
    },
    {
      id: "codex",
      name: "Codex",
      description:
        "Connect OpenAI's Codex CLI on this machine. Same shape as Claude Code — the agent invokes it via ACP for sub-agent work or calls it as a tool. Useful when a task benefits from GPT-class reasoning behind a CLI envelope.",
      svg: OpenAILogo,
      getKeyUrl: "https://github.com/openai/codex#install",
      apiKeyHint: "codex",
      available: true,
      connectFlow: "detect_cli",
      binaryName: "codex",
      installCommand: "npm install -g @openai/codex",
      // First-run auth: launch `codex` and select "Sign in with
      // ChatGPT" at the interactive prompt — same shape as Claude
      // Code, no dedicated auth subcommand.
      signInCommand: "codex",
    },

    // ── More cloud integrations ────────────────────────────────────
    // Three more scaffolds. Per-service connect-flow research:
    //
    //   - Google Workspace: detect/install the `gws` CLI
    //     (brew install googleworkspace-cli). OAuth lives in the CLI
    //     itself; we shell out + auto-load the skills it ships at
    //     ~/.openclaw/skills/.
    //   - Meta: custom OAuth WE host (Workbooks-owned developer app).
    //     User clicks Connect → browser OAuth → deep-link back with
    //     access token. Same broker pattern as GitHub. Stored as
    //     META_ACCESS_TOKEN.
    //   - fal.ai: paste API key (FAL_KEY). Sidecar wraps fal's REST
    //     for image / video / audio / music / speech / 3D generation
    //     across 1,000+ models.
    {
      id: "google_workspace",
      name: "Google Workspace",
      description:
        "Connect Google Workspace via the official gws CLI on this machine. The agent gets Gmail, Drive, Calendar, Sheets, Docs, Chat and Admin operations behind one OAuth — plus the 100+ skill files the CLI auto-installs for richer agent task vocabulary.",
      svg: GoogleWorkspaceLogo,
      getKeyUrl: "https://github.com/googleworkspace/cli",
      apiKeyHint: "gws",
      available: true,
      // Managed OAuth: we own a Google OAuth client + PKCE flow.
      // No `gws auth setup`, no GCP-project setup, no client secret
      // paste. User clicks Connect → browser → done. The gws CLI is
      // still useful as the agent's tool surface and can be installed
      // lazily (or via a separate flow); the connection itself only
      // requires the OAuth token. See `src-tauri/src/google_oauth.rs`
      // for the PKCE dance + token storage.
      connectFlow: "managed_oauth",
      managedOAuthProvider: "google",
      binaryName: "gws",
      installCommand: "brew install googleworkspace-cli",
      // First-time auth is `gws auth setup` (one-time: creates a GCP
      // project, enables APIs, logs you in). `gws auth login` only
      // works AFTER setup has registered an OAuth client. Setup
      // requires `gcloud` CLI to be installed.
      signInCommand: "gws auth setup",
      // One-click setup: chain gcloud install → gws install (if
      // missing) → gws auth setup. Each step is idempotent and
      // skipped when the binary is already on PATH. exec'ing the
      // final command replaces the bash shell with gws so the pty
      // stays attached for the interactive browser-OAuth dance.
      //
      // Why the PATH dance: brew's `gcloud-cli` cask installs to
      // /opt/homebrew/Caskroom/gcloud-cli/<version>/google-cloud-sdk/
      // and does NOT symlink into /opt/homebrew/bin/. The Cloud SDK
      // ships its own `path.bash.inc` that adds the bin dir to PATH;
      // we source it so the current shell sees gcloud right after
      // install. The version-pinned subdir is unpredictable across
      // brew updates, so we glob + pick the most recent.
      signInScript: `set -eo pipefail
echo ""
echo "── Workbooks · Google Workspace setup ──"
echo ""

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: Homebrew is required for the auto-install path."
  echo "Install it from https://brew.sh first, then come back."
  exit 1
fi

BREW_PREFIX="$(brew --prefix)"

# The gcloud-cli cask doesn't symlink to a PATH location; add its
# bin dir (or source the SDK's own path.bash.inc) so the current
# shell can find gcloud right after the install.
ensure_gcloud_on_path() {
  if command -v gcloud >/dev/null 2>&1; then return 0; fi
  # \`|| true\` so a no-match ls under \`set -eo pipefail\` doesn't kill
  # the whole script before we get a chance to install. The cask
  # subdir doesn't exist until brew creates it.
  local sdk_dir
  sdk_dir=$(ls -td "$BREW_PREFIX"/Caskroom/gcloud-cli/*/google-cloud-sdk 2>/dev/null | head -n1 || true)
  if [ -n "$sdk_dir" ] && [ -f "$sdk_dir/path.bash.inc" ]; then
    # shellcheck disable=SC1091
    source "$sdk_dir/path.bash.inc"
  fi
}

ensure_gcloud_on_path
if command -v gcloud >/dev/null 2>&1; then
  echo "✓ gcloud already installed at $(command -v gcloud)"
else
  echo "→ Installing Google Cloud SDK (gcloud)..."
  brew install --cask gcloud-cli
  ensure_gcloud_on_path
fi

if ! command -v gcloud >/dev/null 2>&1; then
  echo ""
  echo "ERROR: gcloud installed but isn't on PATH. Add this to your shell rc:"
  echo "  source \\"$BREW_PREFIX/Caskroom/gcloud-cli/latest/google-cloud-sdk/path.bash.inc\\""
  exit 1
fi

echo ""
if command -v gws >/dev/null 2>&1; then
  echo "✓ gws already installed at $(command -v gws)"
else
  echo "→ Installing Google Workspace CLI (gws)..."
  brew install googleworkspace-cli
fi

echo ""
echo "→ Running gws auth setup (browser will open)..."
exec gws auth setup`,
    },
    {
      id: "meta",
      name: "Meta",
      description:
        "Connect your Meta accounts (Facebook Pages, Instagram, Ads Manager) via OAuth. We handle the developer-app side — you just click Connect and pick which assets to share. The agent can read insights, draft posts, and analyze ads across the Graph + Marketing APIs.",
      svg: MetaLogo,
      getKeyUrl: "https://business.facebook.com/",
      apiKeyHint: "OAuth — no key to paste",
      available: false,
      connectFlow: "oauth",
    },
    {
      id: "fal",
      name: "fal.ai",
      description:
        "Connect fal.ai for generative image, video, audio, music, speech, and 3D models. Once connected the agent can render media inline in workbooks via fal's 1,000+ hosted model endpoints — same paste-API-key shape as Composio.",
      svg: FalLogo,
      getKeyUrl: "https://fal.ai/dashboard/keys",
      apiKeyHint: "fal_…",
      available: true,
      connectFlow: "paste_key",
    },
  ];

  // ── Connect-modal state ──────────────────────────────────────────────
  // Which service's modal (if any) is currently open. The modal lives
  // outside the `{#each services}` so we only ever render one.
  let connectingService = $state<ServiceDef | null>(null);
  let connectBusy = $state(false);
  let connectError = $state<string | null>(null);

  function openConnect(svc: ServiceDef) {
    if (!svc.available) return;
    connectError = null;
    if (svc.connectFlow === "managed_oauth" && svc.managedOAuthProvider) {
      // No modal — go straight to the browser OAuth flow. The Tauri
      // command handles the PKCE dance + listener + token capture;
      // we just persist the result on success.
      void runManagedOAuth(svc);
      return;
    }
    connectingService = svc;
  }

  /** Per-service managed-OAuth indicator so the card can show a
   *  "Signing in…" state while the browser flow is in progress. */
  let oauthPendingServiceId = $state<string | null>(null);

  async function runManagedOAuth(svc: ServiceDef) {
    if (oauthPendingServiceId) return;
    oauthPendingServiceId = svc.id;
    try {
      if (svc.managedOAuthProvider === "google") {
        const tokens = await invoke<{
          access_token: string;
          refresh_token: string | null;
          expires_at_ms: number;
          account_email: string | null;
        }>("google_oauth_sign_in");
        await invoke("connections_create_managed_oauth", {
          req: {
            service: svc.id,
            access_token: tokens.access_token,
            refresh_token: tokens.refresh_token,
            expires_at_ms: tokens.expires_at_ms,
            account_email: tokens.account_email,
          },
        });
        await connections.refresh();
      }
    } catch (e) {
      // Common failure modes: user closed the browser tab (timeout),
      // declined the consent screen, or hit Google's 100-user cap
      // before being added as a test user. Surface as a top-level
      // panel error since there's no per-service modal to host it.
      opError = e instanceof Error ? e.message : String(e);
    } finally {
      oauthPendingServiceId = null;
    }
  }
  function closeConnect() {
    if (connectBusy) return;
    connectingService = null;
    connectError = null;
  }

  async function submitConnect(req: {
    apiKey: string;
    accountLabel: string | null;
  }) {
    if (!connectingService) return;
    connectBusy = true;
    connectError = null;
    try {
      await connections.connect({
        service: connectingService.id,
        api_key: req.apiKey,
        account_label: req.accountLabel ?? undefined,
      });
      connectingService = null;
    } catch (e) {
      connectError = e instanceof Error ? e.message : String(e);
    } finally {
      connectBusy = false;
    }
  }

  async function disconnect(svc: ServiceDef) {
    const existing = connections.forService(svc.id);
    if (!existing) return;
    const ok = await tauriConfirm(
      `Disconnect ${svc.name}? The agent will lose access to ${svc.name}'s SDK until you reconnect.`,
      { kind: "warning" },
    );
    if (!ok) return;
    try {
      await connections.disconnect(existing.id);
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  // ── Add-secret form state ────────────────────────────────────────────
  let creating = $state(false);
  let newKind = $state<Kind>("api-key");
  let newName = $state("");
  let newValue = $state("");
  let newProvider = $state("openrouter");
  let newCustomProvider = $state("");
  let newScope = $state<EnvScope>("user");
  let newPackageName = $state<string>("");
  let opError = $state<string | null>(null);

  // ── Composio picker state ────────────────────────────────────────────
  // Opens the modal that lists the user's connected Composio accounts
  // (fetched from the sidecar) so they can drop one into the values
  // list. Only available when a Composio connection exists.
  let composioPickerOpen = $state(false);

  // ── Bulk-paste state ─────────────────────────────────────────────────
  let pasteOpen = $state(false);
  let pasteText = $state("");
  let pasteScope = $state<EnvScope>("user");
  let pastePackageName = $state<string>("");
  let pasteResult = $state<{ imported: number; skipped: string[] } | null>(
    null,
  );

  // ── Reveal state (per id) ────────────────────────────────────────────
  // Per-row "Copied ✓" affordance — short-lived pulse keyed on row id,
  // cleared after 1.5s. We never hold plaintext in JS; the value goes
  // Rust → OS clipboard directly.
  let copiedAt = $state<Record<string, number>>({});

  onMount(() => {
    keys.init();
    envVars.init();
    connections.init();
  });

  function defaultPkgName(): string {
    return packageStore.active?.name ?? packageStore.workspaces[0] ?? "";
  }

  $effect(() => {
    if (newScope === "package" && !newPackageName) newPackageName = defaultPkgName();
  });
  $effect(() => {
    if (pasteScope === "package" && !pastePackageName) pastePackageName = defaultPkgName();
  });

  /** When an integration drops a value into this list, it tags the
   *  row with the brand mark of its origin. Composio pulls the
   *  underlying app's logo (Slack/Gmail/etc) and stores it on the
   *  individual record; Doppler stamps every synced row with the
   *  Doppler swoosh; GitHub stamps GITHUB_TOKEN with the Octocat.
   *  Manually-entered values leave `source` empty.
   *
   *  Persisted shape (planned):
   *    source: { service: "composio" | "doppler" | "github",
   *              app?: "slack" | "gmail" | ...,
   *              logo_svg?: string,   // inline mark, theme-adaptive
   *              label?: string }
   */
  type RowSource = {
    service: "composio" | "doppler" | "github";
    /** Underlying app for Composio rows; ignored for the others. */
    app?: string;
    /** Inline SVG markup. Uses currentColor or its own brand fills. */
    logo_svg?: string;
    /** Display label ("Slack via Composio", "Doppler", "GitHub"). */
    label?: string;
  };

  // Combined view — every key + every env var as a single row stream.
  type Row =
    | {
        kind: "api-key";
        id: string;
        name: string;
        masked: string;
        scope: "user";
        provider: string;
        provider_label: string;
        env_var_name: string | null;
        created_at: number;
        source: RowSource | null;
      }
    | {
        kind: "env-var";
        id: string;
        name: string;
        masked: string;
        scope: EnvScope;
        workspace_id: string | null;
        package_name: string | null;
        created_at: number;
        source: RowSource | null;
      };

  const combined = $derived.by<Row[]>(() => {
    const a: Row[] = keys.keys.map((k) => ({
      kind: "api-key",
      id: k.id,
      name: k.name,
      masked: k.masked,
      scope: "user",
      provider: k.provider,
      provider_label: providerLabel(k.provider),
      env_var_name: providerEnvVar(k.provider, k.custom_provider ?? undefined),
      created_at: k.created_at,
      // Source tag — populated by integration sync flows once they
      // land. v1 leaves it null for manually-entered values.
      source: null,
    }));
    const b: Row[] = envVars.vars.map((v) => ({
      kind: "env-var",
      id: v.id,
      name: v.name,
      masked: v.masked,
      scope: v.scope,
      workspace_id: v.workspace_id,
      package_name: v.package_name,
      created_at: v.created_at,
      source: deriveSource(v.name),
    }));
    return [...a, ...b].sort((x, y) => y.created_at - x.created_at);
  });

  // Derive the source tag from the env-var name. Composio rows are
  // written by the picker as `COMPOSIO_<TOOLKIT_SLUG>`; Doppler-synced
  // rows (when sync lands) follow `DOPPLER_*`; GitHub's single token is
  // exactly `GITHUB_TOKEN`. Manually-entered values fall through with
  // a null source and render with the standard "Env" kind chip.
  //
  // This is a UI-only derivation — the source tag isn't stored in the
  // org file. If a user happens to name an env var `COMPOSIO_FOO`
  // themselves, they'll get the Composio mark too; we treat that as
  // user-driven labelling rather than a bug.
  function deriveSource(name: string): RowSource | null {
    if (name === "GITHUB_TOKEN") {
      return {
        service: "github",
        logo_svg: GithubLogo,
        label: "GitHub",
      };
    }
    if (name.startsWith("COMPOSIO_")) {
      const slug = name.slice("COMPOSIO_".length).toLowerCase();
      return {
        service: "composio",
        app: slug,
        logo_svg: ComposioLogo,
        label: `${prettifySlug(slug)} via Composio`,
      };
    }
    if (name.startsWith("DOPPLER_") || name === "DOPPLER_TOKEN") {
      return {
        service: "doppler",
        logo_svg: DopplerLogo,
        label: "Doppler",
      };
    }
    return null;
  }

  function prettifySlug(slug: string): string {
    if (!slug) return "Unknown app";
    return slug
      .split(/[_-]/)
      .filter(Boolean)
      .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
      .join(" ");
  }

  function scopeLabel(r: Row): string {
    if (r.kind === "api-key") return "User";
    if (r.scope === "user") return "User";
    if (r.scope === "workspace") {
      const ws = workspaces.workspaces.find((w) => w.id === r.workspace_id);
      return `Workspace · ${ws?.name ?? "?"}`;
    }
    return `Package · ${r.package_name ?? "?"}`;
  }

  function scopeTargets(scope: EnvScope, packageName: string): {
    workspace_id?: string;
    package_name?: string;
  } {
    if (scope === "user") return {};
    const wsId = workspaces.active?.id;
    if (!wsId) throw new Error("No active workspace.");
    if (scope === "workspace") return { workspace_id: wsId };
    const pkg = packageName.trim();
    if (!pkg) throw new Error("Pick a package for package-scoped values.");
    return { workspace_id: wsId, package_name: pkg };
  }

  async function createValue() {
    opError = null;
    try {
      if (newKind === "api-key") {
        if (!newName.trim() || !newValue) return;
        await keys.create({
          name: newName.trim(),
          provider: newProvider,
          custom_provider: newProvider === "custom" ? newCustomProvider : undefined,
          value: newValue,
        });
      } else {
        if (!newName.trim() || !newValue) return;
        const targets = scopeTargets(newScope, newPackageName);
        await envVars.create({
          name: newName.trim(),
          value: newValue,
          scope: newScope,
          ...targets,
        });
      }
      newName = "";
      newValue = "";
      creating = false;
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  async function commitBulk() {
    if (!pasteText.trim()) return;
    opError = null;
    try {
      const targets = scopeTargets(pasteScope, pastePackageName);
      const r = await envVars.bulkImport({
        text: pasteText,
        scope: pasteScope,
        ...targets,
      });
      pasteResult = { imported: r.imported.length, skipped: r.skipped };
      pasteText = "";
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  async function copyRow(r: Row) {
    opError = null;
    try {
      if (r.kind === "api-key") await keys.copyToClipboard(r.id);
      else await envVars.copyToClipboard(r.id);
      const stamp = Date.now();
      copiedAt = { ...copiedAt, [r.id]: stamp };
      // Clear the pulse after 1.5s — only if no newer copy on the
      // same row has happened in the meantime.
      setTimeout(() => {
        if (copiedAt[r.id] === stamp) {
          const next = { ...copiedAt };
          delete next[r.id];
          copiedAt = next;
        }
      }, 1500);
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  async function deleteRow(r: Row) {
    opError = null;
    try {
      if (r.kind === "api-key") await keys.delete(r.id);
      else await envVars.delete(r.id);
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    }
  }

  const dirty = $derived(keys.dirty || envVars.dirty || connections.dirty);

  let restarting = $state(false);
  async function restartSidecar() {
    if (restarting) return;
    restarting = true;
    try {
      await keys.restartSidecar();
      envVars.dirty = false;
      connections.dirty = false;
    } catch (e) {
      opError = e instanceof Error ? e.message : String(e);
    } finally {
      restarting = false;
    }
  }
</script>

<SettingsPanel
  title="Integrations"
  lede="Connected services, API keys, and environment variables — anything the agent or your workbooks might need at runtime. Permissions decide who can see and use each value."
>
  {#snippet actions()}
    {#if dirty}
      <button
        type="button"
        class="btn primary"
        disabled={restarting || sidecar.status.state === "starting"}
        onclick={restartSidecar}
      >
        {restarting ? "Restarting…" : "Restart sidecar"}
      </button>
    {/if}
  {/snippet}

  <!-- ── Connected-service cards ─────────────────────────────────── -->
  <!-- Compact one-row cards: logo + name (+ connected indicator) +
       info-on-hover + actions on the right. Description used to sit
       below; it's behind a ? tooltip now to keep the grid tight. -->
  <div class="services">
    {#each services as svc (svc.id)}
      {@const conn = connections.forService(svc.id)}
      <article
        class="service"
        class:connected={conn !== null}
        aria-label="{svc.name} integration"
      >
        <div class="logo" aria-hidden="true">{@html svc.svg}</div>
        <h3>{svc.name}</h3>
        {#if conn}
          <span
            class="connected-dot"
            aria-label="Connected"
            title="Connected"
          ></span>
        {/if}
        <button
          type="button"
          class="info-btn"
          aria-label="About {svc.name}"
          title={svc.description}
        >
          <HelpCircle weight="fill" size={13} />
        </button>
        <span class="spacer"></span>
        {#if conn}
          <!-- No separate "Sign in" button — Connect is one step:
               detect/install → auth → connected. If the user needs to
               re-authenticate, they Disconnect + Connect again. -->
          <a
            class="manage-link"
            href={conn.dashboard_url}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="Open {svc.name} dashboard"
            title="Open {svc.name} dashboard"
          >
            <ExternalLink weight="fill" size={12} />
          </a>
          <button
            type="button"
            class="icon-action"
            onclick={() => disconnect(svc)}
            aria-label="Disconnect {svc.name}"
            title="Disconnect"
          >
            <Unlink weight="fill" size={12} />
          </button>
        {:else}
          {@const pending = oauthPendingServiceId === svc.id}
          <button
            type="button"
            class="connect-btn"
            disabled={!svc.available || pending}
            title={pending
              ? "Sign in to complete in your browser"
              : svc.available
                ? "Connect"
                : "Coming soon"}
            onclick={() => openConnect(svc)}
          >
            {pending
              ? "Signing in…"
              : svc.available
                ? "Connect"
                : "Coming soon"}
          </button>
        {/if}
      </article>
    {/each}
  </div>

  {#if connectingService && connectingService.connectFlow === "paste_key"}
    <ConnectModal
      serviceName={connectingService.name}
      serviceLogo={connectingService.svg}
      apiKeyHint={connectingService.apiKeyHint}
      getKeyUrl={connectingService.getKeyUrl}
      busy={connectBusy}
      error={connectError}
      onsubmit={submitConnect}
      oncancel={closeConnect}
    />
  {:else if connectingService && connectingService.connectFlow === "detect_cli" && connectingService.binaryName && connectingService.installCommand}
    <DetectModal
      serviceId={connectingService.id}
      serviceName={connectingService.name}
      serviceLogo={connectingService.svg}
      binaryName={connectingService.binaryName}
      installCommand={connectingService.installCommand}
      installUrl={connectingService.getKeyUrl}
      signInScript={connectingService.signInScript}
      oncancel={closeConnect}
      onconnected={() => {
        // Single-flow connect: DetectModal handles detect → setup →
        // OAuth → persist in one modal lifecycle. By the time we
        // land here, the user has actually signed in (the script
        // exited 0). No second modal to chase.
        connectingService = null;
        connectError = null;
      }}
    />
  {/if}

  <!-- ── Unified secrets list head ──────────────────────────────── -->
  <div class="list-head">
    <h3>Values</h3>
    <div class="head-actions">
      {#if connections.forService("composio")}
        <button
          type="button"
          class="btn ghost small"
          onclick={() => (composioPickerOpen = true)}
          title="Pick a connected Composio app to add as a value"
        >
          <span class="inline-logo" aria-hidden="true">{@html ComposioLogo}</span>
          Add from Composio
        </button>
      {/if}
      {#if !pasteOpen}
        <button
          type="button"
          class="btn ghost small"
          onclick={() => (pasteOpen = true)}
        >
          <ClipboardPaste weight="fill" size={12} /> Paste .env
        </button>
      {/if}
      {#if !creating}
        <button
          type="button"
          class="btn ghost small"
          onclick={() => (creating = true)}
        >
          <Plus weight="bold" size={12} /> Add value
        </button>
      {/if}
    </div>
  </div>

  {#if composioPickerOpen}
    <ComposioPickerModal
      scope="user"
      oncancel={() => (composioPickerOpen = false)}
      onpicked={() => {
        composioPickerOpen = false;
        envVars.refresh();
      }}
    />
  {/if}

  {#if pasteOpen}
    <form
      class="paste-card"
      onsubmit={(e) => { e.preventDefault(); commitBulk(); }}
    >
      <textarea
        bind:value={pasteText}
        rows="5"
        spellcheck="false"
        placeholder={`# Paste .env content here\nOPENAI_KEY=sk-...\nANTHROPIC_KEY=sk-...`}
      ></textarea>
      <div class="paste-row">
        <label class="field">
          <span class="field-label">Scope</span>
          <Dropdown
            bind:value={pasteScope}
            items={[
              { value: "user", label: "User", description: "Everywhere" },
              { value: "workspace", label: "Workspace", description: "All packages here" },
              { value: "package", label: "Package", description: "Just one package" },
            ]}
          />
        </label>
        {#if pasteScope === "package"}
          <label class="field">
            <span class="field-label">Package</span>
            <Dropdown
              bind:value={pastePackageName}
              items={packageStore.workspaces.map((p) => ({ value: p, label: p }))}
              placeholder="Pick a package"
            />
          </label>
        {/if}
        <span class="spacer"></span>
        <button
          type="button"
          class="btn ghost"
          onclick={() => { pasteOpen = false; pasteText = ""; pasteResult = null; }}
        >Cancel</button>
        <button type="submit" class="btn primary" disabled={!pasteText.trim()}>
          <Check weight="bold" size={13} /> Import
        </button>
      </div>
      {#if pasteResult}
        <div class="paste-feedback">
          Imported {pasteResult.imported}.
          {#if pasteResult.skipped.length > 0}
            Skipped {pasteResult.skipped.length}.
          {/if}
        </div>
      {/if}
    </form>
  {/if}

  {#if creating}
    <form
      class="create-form"
      onsubmit={(e) => { e.preventDefault(); createValue(); }}
    >
      <div class="kind-row" role="radiogroup" aria-label="Value kind">
        <button
          type="button"
          class="kind-pill"
          class:active={newKind === "api-key"}
          role="radio"
          aria-checked={newKind === "api-key"}
          onclick={() => (newKind = "api-key")}
        >
          <KeyRound weight="fill" size={12} /> API key
        </button>
        <button
          type="button"
          class="kind-pill"
          class:active={newKind === "env-var"}
          role="radio"
          aria-checked={newKind === "env-var"}
          onclick={() => (newKind = "env-var")}
        >
          <Layers weight="fill" size={12} /> Env var
        </button>
      </div>

      <input
        type="text"
        bind:value={newName}
        placeholder={newKind === "api-key" ? "Key label (e.g. personal-openrouter)" : "VAR_NAME"}
        class="name-input"
        class:mono={newKind === "env-var"}
        autofocus
      />
      <input
        type="password"
        bind:value={newValue}
        placeholder="value"
        spellcheck="false"
        autocomplete="off"
      />

      {#if newKind === "api-key"}
        <label class="field">
          <span class="field-label">Provider</span>
          <Dropdown
            bind:value={newProvider}
            items={keys.providers.map((p) => ({ value: p, label: providerLabel(p) }))}
          />
        </label>
        {#if newProvider === "custom"}
          <input
            type="text"
            bind:value={newCustomProvider}
            placeholder="custom provider name"
          />
        {/if}
      {:else}
        <label class="field">
          <span class="field-label">Scope</span>
          <Dropdown
            bind:value={newScope}
            items={[
              { value: "user", label: "User" },
              { value: "workspace", label: "Workspace" },
              { value: "package", label: "Package" },
            ]}
          />
        </label>
        {#if newScope === "package"}
          <label class="field">
            <span class="field-label">Package</span>
            <Dropdown
              bind:value={newPackageName}
              items={packageStore.workspaces.map((p) => ({ value: p, label: p }))}
              placeholder="Pick a package"
            />
          </label>
        {/if}
      {/if}

      <div class="form-actions">
        <button
          type="button"
          class="btn ghost"
          onclick={() => { creating = false; newName = ""; newValue = ""; }}
        >Cancel</button>
        <button type="submit" class="btn primary" disabled={!newName.trim() || !newValue}>
          <Check weight="bold" size={13} /> Save
        </button>
      </div>
    </form>
  {/if}

  {#if combined.length === 0 && !creating && !pasteOpen}
    <EmptyState
      icon={KeyRound}
      title="No values yet"
      description="Add an API key for a model provider, or a custom env var scoped to your User / Workspace / Package. Paste a .env file to bulk-import."
    />
  {:else if combined.length > 0}
    <div class="list">
      {#each combined as r (r.kind + r.id)}
        <article class="row">
          <div class="row-main">
            {#if r.source?.logo_svg}
              <!-- Integration-sourced row — brand mark of the origin
                   (Slack/Gmail/Doppler/GitHub) replaces the kind
                   chip. Tooltip carries the verbose source label. -->
              <span
                class="source-mark"
                title={r.source.label ?? r.source.service}
                aria-label={r.source.label ?? r.source.service}
              >
                {@html r.source.logo_svg}
              </span>
            {:else}
              <span class="kind-chip" class:env={r.kind === "env-var"}>
                {r.kind === "api-key" ? "API key" : "Env"}
              </span>
            {/if}
            <code class="row-name">{r.name}</code>
            <!-- The value is never exposed to JS; we only ever render
                 the masked dots. The copy action below moves the
                 plaintext from Rust straight to the OS clipboard. -->
            <span class="row-value">{r.masked}</span>
            <span class="scope">{scopeLabel(r)}</span>
            {#if r.kind === "api-key" && r.env_var_name}
              <span class="env-target" title="Forwarded to sidecar as">
                → <code>{r.env_var_name}</code>
              </span>
            {/if}
          </div>
          <div class="row-perms" aria-label="Permissions">
            <span class="perm" title="Agent: read"><Sparkles weight="fill" size={11} /> read</span>
            <span class="perm muted" title="Workbook: none"><Boxes weight="fill" size={11} /> none</span>
          </div>
          <div class="row-actions">
            <button
              type="button"
              class="icon-btn"
              class:copied={copiedAt[r.id] !== undefined}
              aria-label="Copy to clipboard"
              title={copiedAt[r.id] !== undefined
                ? "Copied"
                : "Copy to clipboard"}
              onclick={() => copyRow(r)}
            >
              {#if copiedAt[r.id] !== undefined}
                <Check weight="bold" size={13} />
              {:else}
                <Copy weight="fill" size={13} />
              {/if}
            </button>
            <button
              type="button"
              class="icon-btn danger"
              aria-label="Delete"
              title="Delete"
              onclick={() => deleteRow(r)}
            >
              <Trash2 weight="fill" size={13} />
            </button>
          </div>
        </article>
      {/each}
    </div>
  {/if}

  {#if opError}<div class="error">{opError}</div>{/if}
</SettingsPanel>

<style>
  /* ── Connected-service cards ───────────────────────────────────── */
  /* Compact cards laid out as 3-per-row at any reasonable Settings
   * width — six cards form a 3×2 grid. The minmax floor is sized so
   * 6-up never fits in one row (forcing the 3+2 break) while leaving
   * room for full service names like "OpenRouter" and "Claude Code"
   * without truncation. Names wrap to a second line if the panel ever
   * narrows past two columns. */
  .services {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 0.5rem;
  }
  .service {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 9px;
    padding: 0.45rem 0.6rem 0.45rem 0.65rem;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    min-height: 36px;
  }
  .logo {
    width: 18px;
    height: 18px;
    color: var(--color-fg);
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }
  .logo :global(svg) {
    width: 100%;
    height: 100%;
  }
  .service h3 {
    margin: 0;
    font-size: 0.84rem;
    font-weight: 600;
    letter-spacing: -0.005em;
    line-height: 1.2;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    min-width: 0;
  }
  .service .spacer { flex: 1 1 auto; }

  /* "?" tooltip trigger — native title attr carries the description. */
  .info-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: 0;
    color: var(--color-fg-subtle);
    cursor: help;
    padding: 0;
    width: 18px;
    height: 18px;
    border-radius: 4px;
    flex-shrink: 0;
    transition: color 0.1s;
  }
  .info-btn:hover { color: var(--color-fg-muted); }

  .connect-btn {
    background: transparent;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 7px);
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.74rem;
    font-weight: 500;
    padding: 0.28rem 0.7rem;
    cursor: pointer;
    flex-shrink: 0;
    /* Keep label + icon on a single line — at narrow card widths the
     * "Disconnect" label was wrapping under its icon. */
    white-space: nowrap;
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    transition: background 0.1s, color 0.1s, border-color 0.1s;
  }
  .connect-btn:hover:not(:disabled) {
    background: var(--color-surface);
    color: var(--color-fg);
    border-color: var(--color-border-strong);
  }
  .connect-btn:disabled { cursor: default; opacity: 0.55; }

  /* Connected state: faint emerald tint on the card border, small
   * dot next to the name, icon-only Manage ↗, then Disconnect at the
   * far right. */
  .service.connected {
    border-color: color-mix(
      in srgb,
      var(--color-emerald, #10b981) 35%,
      var(--color-border)
    );
  }
  .connected-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--color-emerald, #10b981);
    flex-shrink: 0;
  }
  .manage-link {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 5px;
    color: var(--color-fg-subtle);
    text-decoration: none;
    flex-shrink: 0;
    transition: background 0.1s, color 0.1s;
  }
  .manage-link:hover {
    background: var(--color-surface);
    color: var(--color-fg);
  }

  /* Icon-only action button (Disconnect). Same footprint as
   * `.manage-link` so the connected-card action row is uniform. */
  .icon-action {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 22px;
    height: 22px;
    border-radius: 5px;
    background: transparent;
    border: 0;
    color: var(--color-fg-subtle);
    cursor: pointer;
    flex-shrink: 0;
    transition: background 0.1s, color 0.1s;
  }
  .icon-action:hover {
    background: color-mix(in srgb, #ef4444 12%, transparent);
    color: #ef4444;
  }

  /* ── Unified list head ─────────────────────────────────────────── */
  .list-head {
    display: flex;
    align-items: baseline;
    justify-content: space-between;
    gap: 0.6rem;
    margin-top: 0.4rem;
  }
  .list-head h3 {
    margin: 0;
    font-size: 0.78rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--color-fg-subtle);
    font-weight: 600;
  }
  .head-actions { display: flex; gap: 0.35rem; }

  /* ── Add form ──────────────────────────────────────────────────── */
  .create-form,
  .paste-card {
    display: flex;
    flex-direction: column;
    gap: 0.55rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 9px;
    padding: 0.7rem;
  }
  .kind-row { display: flex; gap: 0.3rem; }
  .kind-pill {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    padding: 0.3rem 0.6rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.74rem;
    cursor: pointer;
  }
  .kind-pill.active {
    background: var(--color-fg);
    color: var(--color-page);
    border-color: var(--color-fg);
  }
  .create-form input,
  .paste-card textarea {
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 7px;
    padding: 0.45rem 0.6rem;
    font-size: 0.85rem;
    color: var(--color-fg);
    font-family: inherit;
    outline: 0;
  }
  .create-form input:focus,
  .paste-card textarea:focus { border-color: var(--color-border-strong); }
  .name-input.mono { font-family: ui-monospace, SFMono-Regular, monospace; }
  .field { display: flex; flex-direction: column; gap: 3px; }
  .field-label {
    font-size: 0.68rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--color-fg-muted);
  }
  .paste-card textarea {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.8rem;
    min-height: 100px;
    resize: vertical;
  }
  .paste-row {
    display: flex;
    align-items: end;
    gap: 0.5rem;
    flex-wrap: wrap;
  }
  .spacer { flex: 1 1 auto; }
  .form-actions { display: flex; gap: 0.4rem; justify-content: flex-end; }
  .paste-feedback {
    font-size: 0.78rem;
    color: var(--color-fg-muted);
  }

  /* ── List ──────────────────────────────────────────────────────── */
  .list {
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
  }
  .row {
    display: flex;
    align-items: center;
    gap: 0.65rem;
    padding: 0.5rem 0.7rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
  }
  .row-main {
    display: flex;
    align-items: center;
    gap: 0.55rem;
    flex: 1 1 auto;
    min-width: 0;
  }
  .kind-chip {
    flex-shrink: 0;
    font-size: 0.66rem;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 2px 7px;
    border-radius: 999px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    color: var(--color-fg-muted);
    font-weight: 600;
  }
  .kind-chip.env { color: var(--color-fg); }

  /* Brand logo that takes the kind-chip's slot when a row was
   * populated by an integration sync (Composio app, Doppler secret,
   * GitHub token). Square, same visual weight as the chip. Inline
   * SVG so currentColor adapts to theme. */
  .source-mark {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 18px;
    height: 18px;
    border-radius: 4px;
    color: var(--color-fg);
    flex-shrink: 0;
  }
  .source-mark :global(svg) {
    width: 100%;
    height: 100%;
  }
  .row-name {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.82rem;
    color: var(--color-fg);
    font-weight: 500;
    flex-shrink: 0;
  }
  .row-value {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.76rem;
    color: var(--color-fg-muted);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
    flex: 1 1 auto;
  }
  /* Brief "copied" state — green tint on the copy icon for 1.5s. */
  .icon-btn.copied {
    color: var(--color-emerald, #10b981);
    border-color: var(--color-emerald, #10b981);
  }
  .scope {
    font-size: 0.68rem;
    color: var(--color-fg-muted);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    padding: 2px 7px;
    white-space: nowrap;
    flex-shrink: 0;
  }
  .env-target {
    font-size: 0.7rem;
    color: var(--color-fg-subtle);
    white-space: nowrap;
  }
  .env-target code {
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.95em;
  }

  /* Permission badges — read-only in v1; real toggleable read/write
   * matrix lands when we extend the Rust schema with permission
   * fields. The visual lives now so the surface is honest. */
  .row-perms {
    display: flex;
    gap: 4px;
    flex-shrink: 0;
  }
  .perm {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 0.66rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    padding: 2px 6px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 5px;
    color: var(--color-fg-muted);
  }
  .perm.muted { color: var(--color-fg-subtle); opacity: 0.7; }

  .row-actions { display: flex; gap: 2px; flex-shrink: 0; }
  .icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border: 0;
    background: transparent;
    color: var(--color-fg-muted);
    border-radius: 5px;
    cursor: pointer;
  }
  .icon-btn:hover { background: var(--color-surface); color: var(--color-fg); }
  .icon-btn.danger:hover {
    background: rgba(239, 68, 68, 0.12);
    color: #ef4444;
  }

  /* ── Buttons ───────────────────────────────────────────────────── */
  .btn {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    height: 28px;
    padding: 0 0.7rem;
    border-radius: 7px;
    font-size: 0.78rem;
    font-weight: 500;
    font-family: inherit;
    cursor: pointer;
    border: 1px solid transparent;
    transition: background 0.1s, color 0.1s, opacity 0.1s;
  }
  .btn:disabled { opacity: 0.5; cursor: default; }
  .btn.primary { background: var(--color-primary-bg); color: var(--color-primary-fg); }
  .btn.primary:hover:not(:disabled) { opacity: 0.88; }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg-muted);
    border-color: var(--color-border);
  }
  .btn.ghost:hover:not(:disabled) {
    background: var(--color-surface);
    color: var(--color-fg);
  }
  .btn.small {
    height: 24px;
    padding: 0 0.55rem;
    font-size: 0.72rem;
  }

  /* Brand mark used inline in a small button (e.g. "+ Add from
   * Composio"). Sized to match a 12px lucide icon, themed via
   * currentColor so the SVG adapts to light/dark. */
  .inline-logo {
    display: inline-flex;
    width: 12px;
    height: 12px;
    margin-right: 0.1rem;
    color: var(--color-fg-muted);
  }
  .inline-logo :global(svg) {
    width: 100%;
    height: 100%;
  }

  .error {
    color: #ef4444;
    font-size: 0.78rem;
  }
</style>
