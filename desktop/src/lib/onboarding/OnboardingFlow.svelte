<script lang="ts">
  /**
   * OnboardingFlow — personalization onboarding (wb-aakl.20).
   *
   * NOT a gate. The CLI owns setup (runtime, keys); by the time this
   * renders the browser is already usable. These are CHOICES — theme,
   * sidebar layout, search composition — and every step carries the
   * same message: all of this is plain config your agent can change.
   * Skippable at any point; choices persist to local prefs that the
   * Browser SDK / agent can also write.
   *
   * Steps: welcome → theme → sidebar → search → agent.
   */
  import {
    ArrowRight,
    CheckCircle,
    Copy,
    MagnifyingGlass,
    PaintBrushBroad,
    SidebarSimple,
  } from "phosphor-svelte";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import WaldoMark from "$lib/components/WaldoMark.svelte";
  import { applyThemeMode } from "$lib/onboarding/prefs";

  let { oncomplete }: { oncomplete: () => void } = $props();

  const STEPS = ["welcome", "theme", "sidebar", "search", "agent"] as const;
  type Step = (typeof STEPS)[number];
  let step = $state<Step>("welcome");
  const stepIdx = $derived(STEPS.indexOf(step));

  // ── the choices ───────────────────────────────────────────────────
  type Prefs = {
    theme: "system" | "dark" | "light";
    sidebar: "rail" | "library";
    search: {
      ai: "summary" | "first" | "off";
      providers: { id: string; on: boolean }[];
    };
  };
  let prefs = $state<Prefs>({
    theme: "system",
    sidebar: "rail",
    search: {
      ai: "summary",
      providers: [
        { id: "web", on: true },
        { id: "files", on: true },
        { id: "bookmarks", on: true },
      ],
    },
  });

  // ── agent hookup ──────────────────────────────────────────────────
  const CMD_SKILLS = "npx skills add workbooks-sh/workbooks.sh";
  const CMD_MCP = "claude mcp add workbooks -- wb desktop mcp";
  let copied = $state<string | null>(null);
  async function copy(text: string) {
    try {
      await navigator.clipboard.writeText(text);
      copied = text;
      setTimeout(() => (copied = null), 1600);
    } catch {
      /* clipboard unavailable — the text is selectable */
    }
  }

  // Per-step "ask your agent" example — the running thread that makes
  // composability legible to a non-technical user.
  const agentHint: Record<Step, string> = {
    welcome: "ask your agent: “set up my workbooks browser”",
    theme: "ask your agent: “make me a theme from my website’s colors”",
    sidebar: "ask your agent: “switch my sidebar to the library layout”",
    search: "ask your agent: “add Exa to my search and put AI answers first”",
    agent: "ask your agent: “change anything you picked here, anytime”",
  };

  // ── navigation ────────────────────────────────────────────────────
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

  <button type="button" class="skip" onclick={finish}>Skip — use defaults</button>

  <div class="card">
    <div class="dots" role="presentation">
      {#each STEPS as s, i (s)}
        <button
          type="button"
          class="dot"
          class:on={i === stepIdx}
          class:past={i < stepIdx}
          aria-label={s}
          onclick={() => {
            if (i <= stepIdx) step = s;
          }}
        ></button>
      {/each}
    </div>

    {#key step}
      <div class="body" in:fly={{ x: 16, duration: 200, easing: cubicOut }}>
        {#if step === "welcome"}
          <div class="hero brand">
            <svg viewBox="0 0 113.444 65.6002" width="30" height="17" aria-hidden="true" style="display:block">
              <path
                d="M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z"
                fill="currentColor"
              />
            </svg>
          </div>
          <h1>The workbooks browser</h1>
          <p class="sub">
            Tabs, bookmarks, your files — and every surface of it is a
            workbook. A few choices to make it yours; your agent can
            change any of them later.
          </p>
          <button type="button" class="primary" onclick={next}>
            Make it mine <ArrowRight size={14} weight="bold" />
          </button>

        {:else if step === "theme"}
          <div class="hero hue-lavender"><PaintBrushBroad size={28} weight="fill" /></div>
          <h1>Pick a theme</h1>
          <p class="sub">
            Themes are tokens, not skins — workbooks, panels and toolkits
            all inherit them.
          </p>
          <div class="choice-row">
            {#each [["system", "System"], ["dark", "Dark"], ["light", "Light"]] as [id, label] (id)}
              <button
                type="button"
                class="choice"
                class:sel={prefs.theme === id}
                onclick={() => {
                  prefs.theme = id as Prefs["theme"];
                  applyThemeMode(prefs.theme); // live preview
                }}
              >
                <span
                  class="swatch"
                  style="background: {id === 'dark'
                    ? '#121316'
                    : id === 'light'
                      ? '#f7f6f1'
                      : 'linear-gradient(105deg, #121316 50%, #f7f6f1 50%)'}"
                  aria-hidden="true"
                >
                  <span class="sw-dot"></span>
                </span>
                {label}
              </button>
            {/each}
          </div>

        {:else if step === "sidebar"}
          <div class="hero hue-blue"><SidebarSimple size={28} weight="fill" /></div>
          <h1>Your left side</h1>
          <p class="sub">
            How do you want to move around? The canvas and titlebar stay
            put — the navigation is yours.
          </p>
          <div class="choice-row wide">
            <button
              type="button"
              class="choice layout"
              class:sel={prefs.sidebar === "rail"}
              onclick={() => (prefs.sidebar = "rail")}
            >
              <span class="wire" aria-hidden="true">
                <span class="wire-rail"></span>
                <span class="wire-main"></span>
              </span>
              <span class="choice-title">Browser rail</span>
              <span class="choice-hint">Compact icons, room for pages</span>
            </button>
            <button
              type="button"
              class="choice layout"
              class:sel={prefs.sidebar === "library"}
              onclick={() => (prefs.sidebar = "library")}
            >
              <span class="wire" aria-hidden="true">
                <span class="wire-nav">
                  <span></span><span></span><span></span><span></span>
                </span>
                <span class="wire-main"></span>
              </span>
              <span class="choice-title">Library</span>
              <span class="choice-hint">Full nav with labels, Notion-style</span>
            </button>
          </div>

        {:else if step === "search"}
          <div class="hero hue-peach"><MagnifyingGlass size={28} weight="fill" /></div>
          <h1>How should search answer?</h1>
          <p class="sub">One choice. Everything else has good defaults.</p>
          <div class="choice-row">
            {#each [["summary", "AI summary on top", "answer first, links under it"], ["first", "AI only", "a researched answer, no link list"], ["off", "Links only", "classic results, no AI"]] as [id, label, hint] (id)}
              <button
                type="button"
                class="choice layout"
                class:sel={prefs.search.ai === id}
                onclick={() => (prefs.search.ai = id as Prefs["search"]["ai"])}
              >
                <span class="wire stack" aria-hidden="true">
                  {#if id !== "off"}<span class="wire-ai"></span>{/if}
                  {#if id !== "first"}
                    <span class="wire-link"></span>
                    <span class="wire-link"></span>
                    {#if id === "off"}<span class="wire-link"></span>{/if}
                  {/if}
                </span>
                <span class="choice-title">{label}</span>
                <span class="choice-hint">{hint}</span>
              </button>
            {/each}
          </div>
          <p class="sub small">
            Web, your files and bookmarks are already in. Exa, Tavily or
            any provider you like is a toolkit away.
          </p>

        {:else}
          <div class="hero hue-green"><WaldoMark size={24} /></div>
          <h1>Wire up your agent</h1>
          <p class="sub">
            Everything you just picked — and everything you didn't — is
            plain config. Give your agent the skills and the keys to this
            browser, and ask for the rest.
          </p>
          <div class="cmds">
            <button type="button" class="cmd" onclick={() => void copy(CMD_SKILLS)}>
              <code>{CMD_SKILLS}</code>
              {#if copied === CMD_SKILLS}<CheckCircle size={14} weight="fill" class="ok" />{:else}<Copy size={14} weight="fill" />{/if}
            </button>
            <button type="button" class="cmd" onclick={() => void copy(CMD_MCP)}>
              <code>{CMD_MCP}</code>
              {#if copied === CMD_MCP}<CheckCircle size={14} weight="fill" class="ok" />{:else}<Copy size={14} weight="fill" />{/if}
            </button>
          </div>
          <p class="sub small">
            New panels, themes, search providers — your agent writes a
            toolkit and it shows up here, already matching your theme.
            And Waldo, the browser's resident agent, is one keypress away
            for questions, search and debugging — by voice or text.
          </p>
        {/if}
      </div>
    {/key}

    <div class="foot">
      <div class="hint">
        <span class="hint-caret">›</span>
        {agentHint[step]}
      </div>
      <div class="nav">
        {#if stepIdx > 0}
          <button type="button" class="ghost" onclick={back}>Back</button>
        {:else}
          <span></span>
        {/if}
        {#if step !== "welcome"}
          <button type="button" class="primary" onclick={next}>
            {step === "agent" ? "Open the browser" : "Continue"}
            <ArrowRight size={14} weight="bold" />
          </button>
        {/if}
      </div>
    </div>
  </div>
</div>

<style>
  /* Lander canon via live tokens — this screen inherits the active
   * theme rather than hard-coding a skin, so "themable" stays true
   * even here. */
  .screen {
    flex: 1 1 auto;
    position: relative;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 2rem;
    background: var(--color-page);
    overflow: hidden;
  }
  /* Faint canon grid texture — replaces the old green ASCII shader so the
   * onboarding reads like the clean app, not the lander hero. */
  .grid {
    position: absolute;
    inset: 0;
    pointer-events: none;
    background-image:
      linear-gradient(var(--color-grid-line) 1px, transparent 1px),
      linear-gradient(90deg, var(--color-grid-line) 1px, transparent 1px);
    background-size: 32px 32px;
    /* fade the grid out toward the center so the card sits on calm space */
    -webkit-mask-image: radial-gradient(ellipse 70% 70% at 50% 45%, transparent 30%, #000 100%);
    mask-image: radial-gradient(ellipse 70% 70% at 50% 45%, transparent 30%, #000 100%);
  }
  .skip {
    position: absolute;
    top: 18px;
    right: 22px;
    z-index: 2;
    border: 0;
    background: transparent;
    color: var(--color-fg-subtle);
    font-family: var(--font-mono);
    font-size: 12px;
    cursor: pointer;
  }
  .skip:hover {
    color: var(--color-fg-muted);
  }

  .card {
    position: relative;
    width: 100%;
    max-width: 520px;
    border-radius: 16px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
    box-shadow: var(--shadow-pop);
    padding: 1.75rem 2rem 1.5rem;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .dots {
    display: flex;
    justify-content: center;
    gap: 7px;
    margin-bottom: 1.1rem;
  }
  .dot {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    border: 0;
    padding: 0;
    background: var(--color-border-strong);
    cursor: pointer;
    transition:
      background 0.15s,
      transform 0.15s;
  }
  .dot.on {
    background: var(--color-chip-green);
    transform: scale(1.3);
  }
  .dot.past {
    background: color-mix(in srgb, var(--color-chip-green) 50%, transparent);
  }

  .body {
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 0.9rem;
    min-height: 290px;
  }
  .hero {
    display: grid;
    place-items: center;
    width: 56px;
    height: 56px;
    border-radius: 16px;
  }
  /* Welcome: the workbooks lander mark on the ink brand chip. */
  .hero.brand {
    background: var(--color-fg);
    color: var(--color-page);
    box-shadow: var(--shadow-pop);
  }
  /* Step heroes — a soft pastel chip per step with a dark (ink) glyph, the
   * same pastel idiom as the sidebar. Pastels, never lime green. */
  .hero.hue-lavender { background: var(--color-chip-lavender); color: #121316; }
  .hero.hue-blue { background: var(--color-chip-blue); color: #121316; }
  .hero.hue-peach { background: var(--color-chip-peach); color: #121316; }
  .hero.hue-green { background: var(--color-chip-green); color: #121316; }
  h1 {
    margin: 0;
    font-size: 1.3rem;
    font-weight: 600;
    letter-spacing: -0.01em;
    color: var(--color-fg);
  }
  .sub {
    margin: 0;
    font-size: 0.86rem;
    line-height: 1.55;
    color: var(--color-fg-muted);
    max-width: 42ch;
  }
  .sub.small {
    font-size: 0.78rem;
    color: var(--color-fg-subtle);
  }

  /* ── choice cards (theme / layout) ── */
  .choice-row {
    display: flex;
    gap: 10px;
    width: 100%;
    justify-content: center;
  }
  .choice {
    flex: 1 1 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 8px;
    padding: 12px 10px;
    border: 1px solid var(--color-border);
    border-radius: 12px;
    background: var(--color-surface);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.82rem;
    cursor: pointer;
    transition:
      border-color 0.15s,
      transform 0.15s;
  }
  .choice:hover {
    transform: translateY(-2px);
  }
  .choice.sel {
    border-color: var(--color-chip-green);
    box-shadow: 0 0 0 2px color-mix(in srgb, var(--color-chip-green) 55%, transparent);
  }
  .swatch {
    width: 100%;
    height: 44px;
    border-radius: 8px;
    border: 1px solid var(--color-border);
    display: grid;
    place-items: center;
  }
  .sw-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    background: var(--color-chip-green);
  }

  /* layout wireframes */
  .choice.layout {
    align-items: stretch;
    text-align: left;
  }
  .wire {
    display: flex;
    gap: 4px;
    height: 64px;
    padding: 6px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-page);
  }
  .wire-rail {
    width: 9px;
    border-radius: 3px;
    background: var(--color-border-strong);
  }
  .wire-nav {
    width: 34px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 3px;
    border-radius: 3px;
    background: var(--color-surface-soft);
  }
  .wire-nav span {
    height: 5px;
    border-radius: 2px;
    background: var(--color-border-strong);
  }
  .wire-nav span:first-child {
    background: var(--color-chip-green);
    opacity: 0.7;
  }
  .wire-main {
    flex: 1;
    border-radius: 3px;
    background: var(--color-surface);
    border: 1px solid var(--color-border);
  }
  .wire.stack {
    flex-direction: column;
    height: 64px;
  }
  .wire-ai {
    height: 20px;
    border-radius: 3px;
    background: color-mix(in srgb, var(--color-chip-green) 35%, transparent);
    border: 1px solid var(--color-chip-green);
  }
  .wire-link {
    height: 8px;
    border-radius: 2px;
    background: var(--color-border-strong);
  }
  .choice-title {
    font-weight: 600;
    font-size: 0.84rem;
  }
  .choice-hint {
    font-size: 0.74rem;
    color: var(--color-fg-subtle);
  }

  /* ── agent step ── */
  .cmds {
    display: flex;
    flex-direction: column;
    gap: 7px;
    width: 100%;
  }
  .cmd {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 12px;
    border: 1px solid var(--color-border);
    border-radius: 10px;
    background: var(--color-page);
    color: var(--color-fg-muted);
    cursor: pointer;
    text-align: left;
  }
  .cmd:hover {
    border-color: var(--color-border-strong);
  }
  .cmd code {
    flex: 1;
    font-family: var(--font-mono);
    font-size: 11.5px;
    color: var(--color-fg);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .cmd :global(.ok) {
    color: var(--color-ok);
  }

  /* ── footer: agent hint + nav ── */
  .foot {
    display: flex;
    flex-direction: column;
    gap: 0.7rem;
    margin-top: 1.1rem;
  }
  .hint {
    display: flex;
    align-items: baseline;
    justify-content: center;
    gap: 7px;
    font-family: var(--font-mono);
    font-size: 11px;
    color: var(--color-fg-subtle);
  }
  .hint-caret {
    color: var(--color-chip-green);
  }
  .nav {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .primary {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    gap: 7px;
    padding: 11px 18px;
    border: 0;
    border-radius: 10px;
    background: var(--color-fg);
    color: var(--color-page);
    font-family: var(--font-mono);
    font-size: 0.82rem;
    font-weight: 500;
    letter-spacing: 0.02em;
    cursor: pointer;
    box-shadow: 0 10px 26px rgba(18, 19, 22, 0.22);
    transition:
      filter 0.12s,
      box-shadow 0.12s,
      transform 0.12s;
  }
  .primary:hover {
    filter: brightness(1.08);
    box-shadow: 0 12px 30px rgba(18, 19, 22, 0.3);
    transform: translateY(-1px);
  }
  .primary:active {
    transform: scale(0.985);
  }
  .ghost {
    padding: 9px 14px;
    border: 0;
    border-radius: 10px;
    background: transparent;
    color: var(--color-fg-muted);
    font: inherit;
    font-size: 0.84rem;
    cursor: pointer;
  }
  .ghost:hover {
    color: var(--color-fg);
  }
</style>
