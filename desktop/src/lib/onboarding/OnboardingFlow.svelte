<script lang="ts">
  /**
   * OnboardingFlow (wb-aakl.20) — a guided build-up, not a gate.
   *
   * Owns the view. A non-interactive PREVIEW of the browser builds up one
   * concept at a time (titlebar → sidebar → search → theme → agent), and
   * each pick restyles that piece live in the preview. The welcome card
   * starts centered like a modal; pressing Start drops it into a coach
   * docked at the bottom while the preview animates in. Choices persist as
   * plain prefs the agent can also write; theme is system by default and
   * lands near the end once there's a whole UI to recolor.
   */
  import { ArrowRight, CheckCircle, Copy, MagnifyingGlass } from "phosphor-svelte";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { applyThemeMode } from "$lib/onboarding/prefs";
  import { nav } from "$lib/bridge/nav.svelte";
  import NexusMark from "$lib/components/NexusMark.svelte";
  import WaldoMark from "$lib/components/WaldoMark.svelte";

  let { oncomplete }: { oncomplete: () => void } = $props();

  const STEPS = ["welcome", "sidebar", "search", "theme", "agent"] as const;
  type Step = (typeof STEPS)[number];
  let step = $state<Step>("welcome");
  const stepIdx = $derived(STEPS.indexOf(step));
  /** false on welcome (centered modal); true once we've dropped to the dock. */
  const started = $derived(step !== "welcome");

  type Prefs = {
    theme: "system" | "dark" | "light";
    sidebar: "rail" | "library";
    search: { ai: "summary" | "first" | "off" };
  };
  let prefs = $state<Prefs>({
    theme: "system", // safe default; chosen near the end
    sidebar: nav.layout,
    search: { ai: "summary" },
  });

  function pickTheme(t: Prefs["theme"]) {
    prefs.theme = t;
    applyThemeMode(t); // recolors the whole preview live
  }
  function pickSidebar(s: Prefs["sidebar"]) {
    prefs.sidebar = s; // restyles the preview sidebar live
  }

  // Demo data for the preview so it never looks blank.
  const folders = [
    { name: "Clients", hue: "var(--color-chip-blue)" },
    { name: "Side Projects", hue: "var(--color-chip-green)" },
    { name: "Research", hue: "var(--color-chip-peach)" },
    { name: "Design", hue: "var(--color-chip-lavender)" },
  ];
  const cards = ["Recipe Box", "Trip Planner", "Beta CRM", "Invoices"];

  // ── agent hookup ──
  const CMD_SKILLS = "npx skills add workbooks-sh/workbooks.sh";
  const CMD_MCP = "claude mcp add workbooks -- wb desktop mcp";
  let copied = $state<string | null>(null);
  async function copy(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      copied = text;
      setTimeout(() => (copied = null), 1600);
    } catch {
      /* selectable fallback */
    }
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
      localStorage.setItem(
        "wb.browser.prefs",
        JSON.stringify({ ...prefs, completedAt: new Date().toISOString() }),
      );
    } catch {
      /* prefs are a convenience, never a gate */
    }
    oncomplete();
  }
</script>

<div class="screen">
  <div class="grid" aria-hidden="true"></div>

  <!-- The build-up PREVIEW — non-interactive; pieces reveal per step. -->
  <div class="stage" class:show={started}>
    <div class="frame">
      <div class="tb">
        <span class="lights"><i></i><i></i><i></i></span>
        <span class="tab">untitled</span>
        <span class="sp"></span>
        <span class="badge"><NexusMark size={12} /></span>
        {#if stepIdx >= 4}
          <span class="badge waldo" in:fly={{ y: -6, duration: 220 }}><WaldoMark size={12} /></span>
        {/if}
      </div>
      <div class="cols">
        <aside class="side {prefs.sidebar}" class:in={stepIdx >= 1}>
          <div class="ws"><span class="ws-dot"></span> Personal</div>
          {#if stepIdx >= 2}
            <div class="search" in:fly={{ y: -4, duration: 200 }}>
              <MagnifyingGlass size={11} weight="bold" /> <span>Search…</span>
            </div>
          {/if}
          <div class="rows">
            {#each folders as f (f.name)}
              <div class="row"><span class="sq" style="background:{f.hue}"></span><span class="lbl">{f.name}</span></div>
            {/each}
          </div>
        </aside>
        <div class="canvas" class:in={stepIdx >= 1}>
          <div class="ask"><MagnifyingGlass size={11} weight="bold" /> Ask the workspace…</div>
          <div class="cardgrid">
            {#each cards as c (c)}<div class="cd"><span class="cd-i"></span>{c}</div>{/each}
          </div>
        </div>
      </div>
    </div>
  </div>

  <!-- Coach: centered modal on welcome, dropped to the dock after Start. -->
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
              <p>Let's build your workbooks browser together — a few quick choices, each landing live as we go. Your agent can change anything later.</p>
            </div>
            <button type="button" class="primary" onclick={next}>Start <ArrowRight size={14} weight="bold" /></button>

          {:else if step === "sidebar"}
            <div class="text">
              <span class="kicker">Your sidebar</span>
              <h1>Pick a left side</h1>
              <p>Rail is compact; Library gives full labels. Watch it restyle.</p>
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
              <span class="kicker">Agent</span>
              <h1>Wire up your agent</h1>
              <p>Everything here is plain config. Give your agent the keys; Waldo's up top too.</p>
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
  .screen {
    position: relative;
    flex: 1 1 auto;
    min-height: 0;
    overflow: hidden;
    background: var(--color-page);
    display: flex;
    flex-direction: column;
  }
  .grid {
    position: absolute;
    inset: 0;
    pointer-events: none;
    background-image:
      linear-gradient(var(--color-grid-line) 1px, transparent 1px),
      linear-gradient(90deg, var(--color-grid-line) 1px, transparent 1px);
    background-size: 32px 32px;
    -webkit-mask-image: radial-gradient(ellipse 80% 70% at 50% 38%, transparent 35%, #000 100%);
    mask-image: radial-gradient(ellipse 80% 70% at 50% 38%, transparent 35%, #000 100%);
  }

  /* ── the build-up preview ───────────────────────────────────────── */
  .stage {
    flex: 1 1 auto;
    min-height: 0;
    display: grid;
    place-items: center;
    padding: 3rem 2rem 0.5rem;
    opacity: 0;
    transform: scale(0.97) translateY(10px);
    transition: opacity 0.5s ease, transform 0.5s cubic-bezier(0.2, 0.8, 0.2, 1);
    pointer-events: none; /* preview is non-interactive */
  }
  .stage.show { opacity: 1; transform: none; }
  .frame {
    width: min(880px, 100%);
    aspect-ratio: 16 / 10;
    max-height: 100%;
    display: flex;
    flex-direction: column;
    border: 1px solid var(--color-border);
    border-radius: 14px;
    overflow: hidden;
    background: var(--color-page);
    box-shadow: var(--shadow-pop);
  }
  .tb {
    flex-shrink: 0;
    height: 38px;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 12px;
    background: var(--color-chrome);
    border-bottom: 1px solid var(--color-border);
  }
  .lights { display: flex; gap: 6px; }
  .lights i { width: 9px; height: 9px; border-radius: 50%; background: var(--color-border-strong); }
  .tab {
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--color-fg-muted);
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    border-radius: 7px;
    padding: 3px 10px;
  }
  .sp { flex: 1; }
  .badge {
    display: grid;
    place-items: center;
    width: 24px; height: 24px;
    border: 1px solid var(--color-border);
    border-radius: 7px;
    background: var(--color-surface-soft);
    color: var(--color-ok);
  }
  .badge.waldo { color: var(--color-fg); }
  .cols { flex: 1; min-height: 0; display: flex; }
  .side {
    flex-shrink: 0;
    width: 184px;
    border-right: 1px solid var(--color-border);
    background: var(--color-chrome);
    padding: 12px 10px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    opacity: 0;
    transform: translateX(-12px);
    transition: opacity 0.45s ease, transform 0.45s cubic-bezier(0.2, 0.8, 0.2, 1), width 0.35s ease;
  }
  .side.in { opacity: 1; transform: none; }
  .side.rail { width: 150px; }
  .ws { display: flex; align-items: center; gap: 7px; font-size: 12px; font-weight: 600; color: var(--color-fg); }
  .ws-dot { width: 14px; height: 14px; border-radius: 5px; background: var(--color-chip-green); }
  .search {
    display: flex; align-items: center; gap: 6px;
    padding: 6px 9px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-surface);
    color: var(--color-fg-subtle);
    font-family: var(--font-mono);
    font-size: 10.5px;
  }
  .rows { display: flex; flex-direction: column; gap: 2px; margin-top: 2px; }
  .row { display: flex; align-items: center; gap: 9px; height: 30px; padding: 0 6px; border-radius: 8px; }
  .side.rail .row { height: 26px; gap: 7px; }
  .sq { width: 20px; height: 20px; border-radius: 6px; flex-shrink: 0; }
  .side.rail .sq { width: 17px; height: 17px; }
  .lbl {
    font-family: var(--font-mono);
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--color-fg-muted);
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  .side.rail .lbl { font-size: 9px; }
  .canvas {
    flex: 1; min-width: 0;
    padding: 18px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    opacity: 0;
    transition: opacity 0.5s ease 0.1s;
  }
  .canvas.in { opacity: 1; }
  .ask {
    align-self: center;
    display: inline-flex; align-items: center; gap: 7px;
    padding: 8px 16px;
    border: 1px solid var(--color-border);
    border-radius: 999px;
    background: var(--color-surface);
    color: var(--color-fg-subtle);
    font-family: var(--font-mono);
    font-size: 11px;
  }
  .cardgrid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 10px; }
  .cd {
    display: flex; align-items: center; gap: 9px;
    padding: 14px;
    border: 1px solid var(--color-border);
    border-radius: 12px;
    background: var(--color-surface);
    font-size: 12.5px;
    font-weight: 500;
    color: var(--color-fg);
  }
  .cd-i { width: 22px; height: 22px; border-radius: 6px; background: var(--color-surface-soft); border: 1px solid var(--color-border); }

  /* ── coach: centered → docked ───────────────────────────────────── */
  .dock {
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 0 0 26px;
    z-index: 5;
    transform: none;
    transition: transform 0.55s cubic-bezier(0.3, 0.8, 0.25, 1);
  }
  /* lift the bottom-docked coach up to the vertical center for welcome */
  .dock.centered {
    transform: translateY(calc(-50vh + 50% + 26px));
  }
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
  }
  .skip:hover { color: var(--color-fg-muted); }
  .coach {
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

  @media (prefers-reduced-motion: reduce) {
    .stage, .dock, .side, .canvas { transition: none; }
  }
</style>
