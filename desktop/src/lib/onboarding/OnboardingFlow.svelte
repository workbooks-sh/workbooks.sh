<script lang="ts">
  /**
   * OnboardingFlow (wb-aakl.20) — a guided tutorial of the REAL UI.
   *
   * The actual app shell renders behind this coach (frozen/inert, with the
   * demo workspace data). As the coach advances it reveals the real pieces
   * one at a time via the `onboarding` store — titlebar → sidebar + content
   * → search → theme → agent — and each pick restyles the real thing live.
   * Welcome is a centered modal; pressing Start drops the coach to the
   * bottom dock while the shell builds up. Theme is system by default and
   * lands near the end. Never a gate.
   */
  import { onMount } from "svelte";
  import { ArrowRight, CheckCircle, Copy } from "phosphor-svelte";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { applyThemeMode } from "$lib/onboarding/prefs";
  import { onboarding } from "$lib/onboarding/onboarding.svelte";
  import { nav } from "$lib/bridge/nav.svelte";

  let { oncomplete }: { oncomplete: () => void } = $props();

  const STEPS = ["welcome", "titlebar", "sidebar", "search", "theme", "agent"] as const;
  type Step = (typeof STEPS)[number];
  let step = $state<Step>("welcome");
  const stepIdx = $derived(STEPS.indexOf(step));
  const started = $derived(step !== "welcome");

  type Prefs = {
    theme: "system" | "dark" | "light";
    sidebar: "rail" | "library";
    search: { ai: "summary" | "first" | "off" };
  };
  let prefs = $state<Prefs>({ theme: "system", sidebar: nav.layout, search: { ai: "summary" } });

  onMount(() => onboarding.start());

  // Reveal the real shell pieces cumulatively as the coach advances.
  $effect(() => {
    if (stepIdx >= 1) onboarding.reveal("titlebar");
    if (stepIdx >= 2) onboarding.reveal("sidebar", "canvas");
    if (stepIdx >= 5) onboarding.reveal("agent");
  });

  function pickTheme(t: Prefs["theme"]) { prefs.theme = t; applyThemeMode(t); }
  function pickSidebar(s: Prefs["sidebar"]) { prefs.sidebar = s; nav.setLayout(s); }

  const CMD_SKILLS = "npx skills add workbooks-sh/workbooks.sh";
  const CMD_MCP = "claude mcp add workbooks -- wb desktop mcp";
  let copied = $state<string | null>(null);
  async function copy(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      copied = text;
      setTimeout(() => (copied = null), 1600);
    } catch { /* selectable */ }
  }

  function next() {
    const i = STEPS.indexOf(step);
    if (i < STEPS.length - 1) step = STEPS[i + 1];
    else finish();
  }
  function back() {
    const i = STEPS.indexOf(step);
    if (i > 0) step = STEPS[i - 1];
  }
  function finish() {
    try {
      localStorage.setItem("wb.browser.prefs", JSON.stringify({ ...prefs, completedAt: new Date().toISOString() }));
    } catch { /* best-effort */ }
    onboarding.done();
    oncomplete();
  }
</script>

<div class="screen">
  {#if !started}
    <div class="grid" aria-hidden="true" transition:fly={{ duration: 200 }}></div>
  {/if}

  <div class="dock" class:centered={!started}>
    {#if started}
      <button type="button" class="skip" onclick={finish} transition:fly={{ y: 6, duration: 160 }}>Skip</button>
    {/if}

    <div class="coach">
      <div class="dots" role="presentation">
        {#each STEPS as s, i (s)}
          <button type="button" class="dot" class:on={i === stepIdx} class:past={i < stepIdx}
            aria-label={s} onclick={() => { if (i <= stepIdx) step = s; }}></button>
        {/each}
      </div>

      {#key step}
        <div class="body" in:fly={{ x: 14, duration: 180, easing: cubicOut }}>
          {#if step === "welcome"}
            <div class="logo">
              <svg viewBox="0 0 113.444 65.6002" width="28" height="16" aria-hidden="true" style="display:block">
                <path d="M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z" fill="currentColor" />
              </svg>
            </div>
            <div class="text">
              <h1>Make it yours</h1>
              <p>Let's set up your workbooks browser — it'll build up around you as we go. A few quick choices; your agent can change anything later.</p>
            </div>
            <button type="button" class="primary" onclick={next}>Start <ArrowRight size={14} weight="bold" /></button>

          {:else if step === "titlebar"}
            <div class="text">
              <span class="kicker">The titlebar</span>
              <h1>This is your top bar</h1>
              <p>Tabs live here, with your nexus status and the Waldo agent on the right. It stays put while everything else is yours to arrange.</p>
            </div>

          {:else if step === "sidebar"}
            <div class="text">
              <span class="kicker">Your sidebar</span>
              <h1>Pick a left side</h1>
              <p>Rail is compact; Library shows full labels. It restyles live — look left.</p>
            </div>
            <div class="opts">
              <button type="button" class="opt" class:sel={prefs.sidebar === "rail"} onclick={() => pickSidebar("rail")}>Rail</button>
              <button type="button" class="opt" class:sel={prefs.sidebar === "library"} onclick={() => pickSidebar("library")}>Library</button>
            </div>

          {:else if step === "search"}
            <div class="text">
              <span class="kicker">Search</span>
              <h1>How should search answer?</h1>
              <p>It lives above your bookmarks. Web, files + bookmarks are in; add Exa later.</p>
            </div>
            <div class="opts">
              {#each [["summary", "AI on top"], ["first", "AI only"], ["off", "Links only"]] as [id, label] (id)}
                <button type="button" class="opt" class:sel={prefs.search.ai === id} onclick={() => (prefs.search.ai = id as Prefs["search"]["ai"])}>{label}</button>
              {/each}
            </div>

          {:else if step === "theme"}
            <div class="text">
              <span class="kicker">Theme</span>
              <h1>Pick a look</h1>
              <p>The whole browser recolors. System follows your OS.</p>
            </div>
            <div class="opts">
              {#each [["system", "System"], ["dark", "Dark"], ["light", "Light"]] as [id, label] (id)}
                <button type="button" class="opt" class:sel={prefs.theme === id} onclick={() => pickTheme(id as Prefs["theme"])}>{label}</button>
              {/each}
            </div>

          {:else}
            <div class="text">
              <span class="kicker">Your agent</span>
              <h1>Meet Waldo</h1>
              <p>Top-right. Give your agent the keys and ask for the rest — it's all plain config.</p>
            </div>
            <div class="cmds">
              <button type="button" class="cmd" onclick={() => void copy(CMD_SKILLS)}>
                <code>{CMD_SKILLS}</code>
                {#if copied === CMD_SKILLS}<CheckCircle size={13} weight="fill" class="ok" />{:else}<Copy size={13} weight="fill" />{/if}
              </button>
              <button type="button" class="cmd" onclick={() => void copy(CMD_MCP)}>
                <code>{CMD_MCP}</code>
                {#if copied === CMD_MCP}<CheckCircle size={13} weight="fill" class="ok" />{:else}<Copy size={13} weight="fill" />{/if}
              </button>
            </div>
          {/if}
        </div>
      {/key}

      {#if started}
        <div class="nav">
          <button type="button" class="ghost" onclick={back}>Back</button>
          <button type="button" class="primary" onclick={next}>
            {step === "agent" ? "Open the browser" : "Continue"}
            <ArrowRight size={14} weight="bold" />
          </button>
        </div>
      {/if}
    </div>
  </div>
</div>

<style>
  /* Overlays the real app; pointer-events pass through except on the coach
   * so the shell behind stays visually live while it's inert. */
  .screen {
    position: absolute;
    inset: 0;
    z-index: 60;
    pointer-events: none;
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
  }
  .grid {
    position: absolute;
    inset: 0;
    background: var(--color-page);
    background-image:
      linear-gradient(var(--color-grid-line) 1px, transparent 1px),
      linear-gradient(90deg, var(--color-grid-line) 1px, transparent 1px);
    background-size: 32px 32px;
  }
  .dock {
    position: relative;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 0 0 26px;
    transition: transform 0.55s cubic-bezier(0.3, 0.8, 0.25, 1);
  }
  .dock.centered { transform: translateY(calc(-50vh + 50% + 26px)); }
  .skip {
    margin-bottom: 10px;
    padding: 4px 12px;
    border: 0; border-radius: 999px;
    background: color-mix(in srgb, var(--color-surface) 70%, transparent);
    backdrop-filter: blur(8px);
    color: var(--color-fg-subtle);
    font-family: var(--font-mono);
    font-size: 11px;
    cursor: pointer;
    pointer-events: auto;
  }
  .skip:hover { color: var(--color-fg-muted); }
  .coach {
    pointer-events: auto;
    width: min(620px, calc(100vw - 48px));
    display: flex;
    flex-direction: column;
    gap: 0.85rem;
    padding: 1.1rem 1.3rem 1.15rem;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 16px;
    box-shadow: var(--shadow-pop);
  }
  .dots { display: flex; justify-content: center; gap: 6px; }
  .dot {
    width: 6px; height: 6px; border-radius: 50%; border: 0; padding: 0;
    background: var(--color-border-strong);
    cursor: pointer;
    transition: background 0.15s, transform 0.15s;
  }
  .dot.on { background: var(--color-chip-green); transform: scale(1.3); }
  .dot.past { background: color-mix(in srgb, var(--color-chip-green) 50%, transparent); }
  .body { display: flex; align-items: center; gap: 1rem; min-height: 64px; }
  .logo {
    flex-shrink: 0;
    display: grid; place-items: center;
    width: 46px; height: 46px;
    border-radius: 13px;
    background: var(--color-fg);
    color: var(--color-page);
    box-shadow: var(--shadow-pop);
  }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
  .kicker {
    font-family: var(--font-mono);
    font-size: 10px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase;
    color: var(--color-fg-subtle);
  }
  h1 { margin: 0; font-size: 1.05rem; font-weight: 600; letter-spacing: -0.01em; color: var(--color-fg); }
  p { margin: 0; font-size: 0.82rem; line-height: 1.5; color: var(--color-fg-muted); }
  .opts { display: flex; gap: 7px; flex-shrink: 0; }
  .opt {
    padding: 8px 16px;
    border: 1px solid var(--color-border);
    border-radius: 10px;
    background: var(--color-page);
    color: var(--color-fg-muted);
    font-family: var(--font-mono);
    font-size: 12px; font-weight: 500;
    cursor: pointer;
    transition: border-color 0.15s, color 0.15s, background 0.15s;
  }
  .opt:hover { color: var(--color-fg); border-color: var(--color-border-strong); }
  .opt.sel {
    color: var(--color-fg);
    border-color: var(--color-chip-green);
    background: color-mix(in srgb, var(--color-chip-green) 16%, var(--color-surface));
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-chip-green) 45%, transparent);
  }
  .cmds { display: flex; flex-direction: column; gap: 6px; flex: 1; min-width: 0; }
  .cmd {
    display: flex; align-items: center; gap: 10px;
    padding: 7px 11px;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    background: var(--color-page);
    color: var(--color-fg-muted);
    cursor: pointer; text-align: left;
  }
  .cmd:hover { border-color: var(--color-border-strong); }
  .cmd code {
    flex: 1;
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--color-fg);
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
  }
  .cmd :global(.ok) { color: var(--color-ok); }
  .nav { display: flex; justify-content: space-between; align-items: center; }
  .primary {
    display: inline-flex; align-items: center; justify-content: center; gap: 7px;
    padding: 10px 18px;
    border: 0; border-radius: 10px;
    background: var(--color-fg);
    color: var(--color-page);
    font-family: var(--font-mono);
    font-size: 0.8rem; font-weight: 500; letter-spacing: 0.02em;
    cursor: pointer;
    box-shadow: 0 8px 22px rgba(18, 19, 22, 0.2);
    transition: filter 0.12s, box-shadow 0.12s, transform 0.12s;
  }
  .primary:hover { filter: brightness(1.08); transform: translateY(-1px); }
  .primary:active { transform: scale(0.985); }
  .ghost {
    padding: 9px 14px; border: 0; border-radius: 10px;
    background: transparent; color: var(--color-fg-muted);
    font: inherit; font-size: 0.82rem; cursor: pointer;
  }
  .ghost:hover { color: var(--color-fg); }
  @media (prefers-reduced-motion: reduce) { .dock { transition: none; } }
</style>
