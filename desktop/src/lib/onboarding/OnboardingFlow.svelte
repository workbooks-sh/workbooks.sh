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
  import { ArrowRight, CheckCircle, Palette, Translate, Cards, CaretLeft, CaretRight } from "phosphor-svelte";
  import { fly } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import { applyThemeMode } from "$lib/onboarding/prefs";
  import { setupSaveModelKey, setupCompleteFirstRun } from "$lib/bridge/setup.svelte";
  import { connections } from "$lib/bridge/connections.svelte";
  import { keys } from "$lib/bridge/keys.svelte";
  import ModelPicker from "$lib/chat/ModelPicker.svelte";
  import { getLlmModel, setLlmModel } from "$lib/bridge/llmModel.svelte";
  import { onboarding } from "$lib/onboarding/onboarding.svelte";
  import { nav } from "$lib/bridge/nav.svelte";
  import { dock } from "$lib/bridge/dock.svelte";
  import { chrome } from "$lib/ui/chrome.svelte";
  import { search } from "$lib/search/registry.svelte";
  import { SEARCH_MODES, SEARCH_MODE_ORDER } from "$lib/search/modes";
  import DemoToolkitPanel from "$lib/onboarding/DemoToolkitPanel.svelte";
  import OnboardingAgents from "$lib/onboarding/OnboardingAgents.svelte";
  import LessonOverlay from "$lib/onboarding/LessonOverlay.svelte";
  import Icon from "$lib/ui/Icon.svelte";

  let { oncomplete }: { oncomplete: () => void } = $props();

  // The user's chosen LLM model (recommended picks pinned in the picker).
  let model = $state(getLlmModel());

  const STEPS = ["welcome", "titlebar", "sidebar", "sidebar-tour", "glyph", "search", "theme", "connect", "waldo", "waldo-voice"] as const;
  type Step = (typeof STEPS)[number];
  let step = $state<Step>("welcome");
  const stepIdx = $derived(STEPS.indexOf(step));
  const started = $derived(step !== "welcome");
  // The coach stays centered for welcome AND the titlebar beat — the titlebar
  // just appears above it, no need to move. It drops to the bottom dock once
  // the sidebar comes in (step 2+), so the left side is clear to look at.
  const centered = $derived(stepIdx <= 1);

  // ── Learn-more (port → edge → DOM highlight) ─────────────────────────
  // Learn steps carry "lessons": each points the coach's port at a DOM
  // target and shows a small tip. Arrows navigate lessons (top of the coach);
  // Continue (bottom) advances the step. The first learn step forces the user
  // to explore so they discover the arrows. Form steps have no lessons.
  type Lesson = { target: string; title: string; body: string };
  const LEARN: Record<string, Lesson[]> = {
    titlebar: [
      { target: ".new-tab", title: "Create", body: "The + at the left of your tabs — start a new workbook, folder or board. Your create surface is always one click up here." },
      { target: ".bench-host", title: "The bench", body: "Toolkit shortcuts. Each icon opens a panel on the right — click again to close. Build your own." },
      { target: ".search-badge", title: "Search", body: "A built-in toolkit with a global ⌘K — summon it anywhere to find files, tabs, the web." },
      { target: ".nexus-badge", title: "Nexus", body: "Your runtime connection. The badge shows engine status; click it to manage or switch." },
      { target: ".dock-host", title: "Waldo", body: "Your resident agent, top-right. Ask by text or voice; it works issues with you." },
    ],
    "sidebar-tour": [
      { target: ".folder-row", title: "Folders", body: "Twirl one open to see its files; drag to reorder, or drop a file in to move it. Folders nest." },
      { target: ".sb-body", title: "Your library", body: "Everything in the active workspace lives here. The layout you just picked shapes how it reads." },
    ],
  };
  const lessons = $derived(LEARN[step] ?? []);
  const isLearn = $derived(lessons.length > 0);
  let lessonIdx = $state(-1); // -1 = intro, not yet exploring
  let portEl = $state<HTMLElement | null>(null);
  let coachEl = $state<HTMLElement | null>(null);
  let benchExplored = $state(false);
  const mustExplore = $derived(step === "titlebar");
  const canContinue = $derived(!mustExplore || benchExplored);
  function nextLesson() {
    if (lessonIdx < lessons.length - 1) {
      lessonIdx++;
      if (step === "titlebar" && lessonIdx === lessons.length - 1) benchExplored = true;
    }
  }
  function prevLesson() {
    if (lessonIdx > -1) lessonIdx--;
  }

  type Prefs = {
    theme: "system" | "dark" | "light";
    sidebar: "shelf" | "hub" | "map";
    sidebarTop: "bookmarks" | "search" | "both";
    glyphs: "icon" | "emoji";
    searchMode: "internal" | "web" | "ai";
  };
  let prefs = $state<Prefs>({ theme: "system", sidebar: nav.layout, sidebarTop: nav.sidebarTop, glyphs: nav.glyphs, searchMode: search.mode });

  // Demo bench toolkits — registered only for the tour so the bench has real,
  // toggleable shortcuts to showcase the "build your own toolkit" concept.
  // Unregistered when the flow unmounts (finish).
  const DEMO_TOOLKITS = [
    { id: "demo-palette", title: "Palette", icon: Palette },
    { id: "demo-translate", title: "Translate", icon: Translate },
    { id: "demo-snippets", title: "Snippets", icon: Cards },
  ];

  onMount(() => {
    onboarding.start();
    // Reflect already-saved keys so the form shows "Connected" instead of an
    // empty input — a returning user shouldn't be asked to re-enter a key the
    // app already holds. OpenRouter lives in the keys store (provider), Gemini
    // as a connection. The raw value is never exposed; we only show it's set.
    void (async () => {
      try {
        await keys.init();
        if (keys.keys.some((k) => k.provider === "openrouter")) orConnected = true;
      } catch { /* offline — leave the input */ }
      try {
        await connections.refresh();
        if (connections.forService("gemini")) gemConnected = true;
      } catch { /* offline — leave the input */ }
    })();
    for (const t of DEMO_TOOLKITS)
      dock.register({ id: t.id, title: t.title, icon: t.icon, component: DemoToolkitPanel, props: { title: t.title } });
    return () => {
      for (const t of DEMO_TOOLKITS) dock.unregister(t.id);
      chrome.closeLeft();
      dock.close();
      onboarding.setExpandAll(false);
    };
  });

  // Reveal the real shell pieces cumulatively, then spotlight this step's
  // surface (closing whatever the last step opened). Driven IMPERATIVELY,
  // NOT a $effect — a tracked effect that reads+writes onboarding state froze
  // the app before.
  function go(s: Step) {
    step = s;
    lessonIdx = -1; // back to the step intro; arrows re-enter lessons
    const i = STEPS.indexOf(s);
    // Reveal one surface per beat. Waldo (agent) reveals WITH the titlebar —
    // it's part of the bar from the start; the agent step just opens its
    // panel. The canvas (create screen) holds back until the theme beat, so
    // the sidebar step is purely about the sidebar — no create screen yet.
    if (i >= 1) onboarding.reveal("titlebar", "bench", "agent");
    if (i >= 2) onboarding.reveal("sidebar");
    if (i >= 6) onboarding.reveal("canvas"); // at the theme beat
    spotlight(s);
  }

  // One thing open at a time. Every step first closes the transient surfaces
  // (left panel, right dock, popovers), then opens its own focus — so moving
  // between coach slides never leaves stale panels around.
  function spotlight(s: Step) {
    chrome.closeLeft();
    dock.close();
    chrome.bookmarksOpen = false;
    chrome.nexusOpen = false;
    // "search" focuses the sidebar's own file-search bar (inline, shown by
    // the sidebarTop pick) — NOT the titlebar's ⌘K drawer, so nothing opens.
    if (s === "sidebar" || s === "sidebar-tour" || s === "glyph") chrome.sidebarOpen = true;
    else if (s === "waldo" || s === "waldo-voice") dock.open("waldo");
    // "search" previews the everything-search drawer (right) in the current mode.
    if (s === "search") {
      search.demoQuery = "data pipelines";
      chrome.openSearch();
    }
    // "connect" shows the agents page above the coach — nothing to open.
    // The glyph step expands every folder so the emoji↔icon flip is visible
    // at the file level too.
    onboarding.setExpandAll(s === "glyph");
  }

  function pickTheme(t: Prefs["theme"]) { prefs.theme = t; applyThemeMode(t); }
  function pickSidebar(s: Prefs["sidebar"]) { prefs.sidebar = s; nav.setLayout(s); }
  // Pick a search kind and preview it live: set the mode, seed a demo query,
  // and (re)open the search drawer so it remounts in that mode.
  function pickSearchMode(m: Prefs["searchMode"]) {
    prefs.searchMode = m;
    search.setMode(m);
    search.demoQuery = "data pipelines";
    chrome.closeLeft();
    queueMicrotask(() => chrome.openSearch());
  }
  function pickGlyphs(g: Prefs["glyphs"]) { prefs.glyphs = g; nav.setGlyphs(g); }

  // Key connect — REAL keychain persistence (wb-2s09.3/.4/.5).
  //  • OpenRouter → the model key Waldo's text lane runs on (setup_save_model_key).
  //  • Gemini    → the voice-chat key, revealed to the Gemini Live WS by
  //    connections_reveal_api_key("gemini"). Both land in the OS keychain.
  let orKey = $state("");
  let orBusy = $state(false);
  let orErr = $state<string | null>(null);
  let orConnected = $state(false);
  async function saveOpenRouter() {
    const v = orKey.trim();
    if (!v || orBusy) return;
    orBusy = true;
    orErr = null;
    try {
      await setupSaveModelKey({ name: "OpenRouter", provider: "openrouter", value: v });
      orKey = "";
      orConnected = true;
    } catch (e) {
      orErr = e instanceof Error ? e.message : String(e);
    } finally {
      orBusy = false;
    }
  }

  let gemKey = $state("");
  let gemBusy = $state(false);
  let gemErr = $state<string | null>(null);
  let gemConnected = $state(false);
  async function saveGemini() {
    const v = gemKey.trim();
    if (!v || gemBusy) return;
    gemBusy = true;
    gemErr = null;
    try {
      await connections.connect({ service: "gemini", api_key: v });
      gemKey = "";
      gemConnected = true;
    } catch (e) {
      gemErr = e instanceof Error ? e.message : String(e);
    } finally {
      gemBusy = false;
    }
  }

  function next() {
    const i = STEPS.indexOf(step);
    if (i < STEPS.length - 1) go(STEPS[i + 1]);
    else finish();
  }
  function back() {
    const i = STEPS.indexOf(step);
    if (i > 0) go(STEPS[i - 1]);
  }
  function finish() {
    try {
      localStorage.setItem("wb.browser.prefs", JSON.stringify({ ...prefs, completedAt: new Date().toISOString() }));
    } catch { /* best-effort */ }
    // Persist the DURABLE first-run flag (setup.json) — the boot gate reads this
    // via setupStatus(), not localStorage. Without it the tour re-ran on every
    // reload (and kept re-prompting for keys). Fire-and-forget; the in-memory
    // oncomplete() below dismisses the tour immediately.
    void setupCompleteFirstRun().catch((e) => console.warn("[onboarding] complete_first_run failed", e));
    onboarding.done();
    oncomplete();
  }
</script>

<div class="screen">

  <div class="dock" class:centered={centered}>
    {#if started}
      <button type="button" class="skip" onclick={finish} transition:fly={{ y: 6, duration: 160 }}>Skip</button>
    {/if}

    <div class="coach" class:learn-active={isLearn && lessonIdx >= 0} bind:this={coachEl}>
      <!-- Top row: carousel dots pinned LEFT, learn-more arrows + port pinned
           RIGHT — clearly separate, not stacked/grouped. -->
      <div class="coach-top">
        <div class="dots" role="presentation">
          {#each STEPS as s, i (s)}
            <button type="button" class="dot" class:on={i === stepIdx} class:past={i < stepIdx}
              aria-label={s} onclick={() => { if (i <= stepIdx) go(s); }}></button>
          {/each}
        </div>

        <!-- The port emits an edge to the highlighted DOM target for the
             active lesson; arrows cycle lessons. -->
        {#if isLearn}
          <div class="learn-bar">
            <button type="button" class="larrow" aria-label="Previous tip" onclick={prevLesson} disabled={lessonIdx < 0}>
              <CaretLeft size={12} weight="bold" />
            </button>
            <span class="port" bind:this={portEl} class:emitting={lessonIdx >= 0}></span>
            <span class="lcount">{lessonIdx < 0 ? "Learn" : `${lessonIdx + 1}/${lessons.length}`}</span>
            <button type="button" class="larrow" aria-label="Next tip" onclick={nextLesson} disabled={lessonIdx >= lessons.length - 1}>
              <CaretRight size={12} weight="bold" />
            </button>
          </div>
        {/if}
      </div>

      {#key step}
        <div class="body" in:fly={{ x: 14, duration: 180, easing: cubicOut }}>
          {#if isLearn && lessonIdx >= 0}
            <!-- Active lesson (any learn step) — generic display. -->
            <div class="text">
              <span class="kicker">Learn · {lessonIdx + 1} of {lessons.length}</span>
              <h1>{lessons[lessonIdx].title}</h1>
              <p>{lessons[lessonIdx].body}</p>
            </div>
          {:else if step === "welcome"}
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
              <span class="kicker">The bar</span>
              <h1>What's up top</h1>
              <p>Use the arrows (top-right) to learn what lives up here — the bench, search, nexus and Waldo. Explore them, then continue.</p>
            </div>

          {:else if step === "sidebar-tour"}
            <div class="text">
              <span class="kicker">Your sidebar</span>
              <h1>A quick tour</h1>
              <p>Use the arrows (top-right) to see what the sidebar does — create, folders, your library. Optional; continue when you like.</p>
            </div>

          {:else if step === "sidebar"}
            <div class="text">
              <span class="kicker">Your sidebar</span>
              <h1>Pick a sidebar</h1>
              <p>Shelf is compact + bookmark-forward. Hub adds a workspace rail for many spaces. Map is a roomy page tree. Restyles live — look left.</p>
            </div>
            <div class="opts">
              <button type="button" class="opt" class:sel={prefs.sidebar === "shelf"} onclick={() => pickSidebar("shelf")}>Shelf</button>
              <button type="button" class="opt" class:sel={prefs.sidebar === "hub"} onclick={() => pickSidebar("hub")}>Hub</button>
              <button type="button" class="opt" class:sel={prefs.sidebar === "map"} onclick={() => pickSidebar("map")}>Map</button>
            </div>

          {:else if step === "glyph"}
            <div class="text">
              <span class="kicker">Your style</span>
              <h1>Emoji or icon?</h1>
              <p>Pick how items look — clean icons from the libraries, or emoji. Workspaces, folder badges and files all follow. Look left, folders are open.</p>
            </div>
            <div class="opts">
              <button type="button" class="opt" class:sel={prefs.glyphs === "icon"} onclick={() => pickGlyphs("icon")}>Icons</button>
              <button type="button" class="opt" class:sel={prefs.glyphs === "emoji"} onclick={() => pickGlyphs("emoji")}>Emoji</button>
            </div>

          {:else if step === "search"}
            <div class="text">
              <span class="kicker">Search · ⌘K</span>
              <h1>Pick a search type</h1>
              <p>Each is a composite — pick one to preview it on the right; the card explains what it does.</p>
            </div>
            <div class="opts">
              {#each SEARCH_MODE_ORDER as m (m)}
                <button type="button" class="opt" class:sel={prefs.searchMode === m} onclick={() => pickSearchMode(m)}>{SEARCH_MODES[m].label}</button>
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

          {:else if step === "connect"}
            <!-- The coach expands to host the agent scan + cards inline. -->
            <OnboardingAgents embedded />

          {:else if step === "waldo"}
            <!-- Meet Waldo — the resident agent's TEXT brain, on OpenRouter. -->
            <div class="text">
              <span class="kicker">Your resident agent</span>
              <h1>Meet Waldo</h1>
              <p>Waldo thinks on OpenRouter — one key, every model. Add it to wake him, then pick the model he runs on. Stored locally on this device, never synced.</p>
            </div>
            <div class="keys">
              <div class="keyrow" class:done={orConnected}>
                <span class="klabel">
                  <Icon value="lobe:openrouter" name="OpenRouter" size={15} />
                  OpenRouter <span class="kfor">chat · every model, one key</span>
                </span>
                {#if orConnected}
                  <div class="kfilled">
                    <span class="kdots">••••••••••••••••</span>
                    <span class="kadded"><CheckCircle size={13} weight="fill" /> Added</span>
                  </div>
                {:else}
                  <form class="kform" onsubmit={(e) => { e.preventDefault(); void saveOpenRouter(); }}>
                    <input type="password" bind:value={orKey} placeholder="sk-or-…" spellcheck="false" autocomplete="off" disabled={orBusy} />
                    <button type="submit" disabled={orBusy || !orKey.trim()}>{orBusy ? "…" : "Add"}</button>
                  </form>
                {/if}
                {#if orErr}<div class="kerr">{orErr}</div>{/if}
              </div>

              <div class="kget">
                <a href="https://openrouter.ai/keys" target="_blank" rel="noopener">Get OpenRouter key ↗</a>
              </div>

              <div class="modelrow">
                <span class="klabel">Model <span class="kfor">cheaper-but-better, multimodal first</span></span>
                <ModelPicker bind:value={model} onchange={(m) => void setLlmModel(m)} />
              </div>
            </div>

          {:else}
            <!-- Waldo Voice — the separate voice lane, on Gemini Live. -->
            <div class="text">
              <span class="kicker">Talk to Waldo</span>
              <h1>Waldo Voice</h1>
              <p>For voice chat, Waldo speaks through Gemini Live. Optional — add a Gemini key to talk out loud; skip it and Waldo still works by text.</p>
            </div>
            <div class="keys">
              <div class="keyrow" class:done={gemConnected}>
                <span class="klabel">
                  <Icon value="lobe:gemini-color" name="Gemini" size={15} />
                  Gemini <span class="kfor">voice chat</span>
                </span>
                {#if gemConnected}
                  <div class="kfilled">
                    <span class="kdots">••••••••••••••••</span>
                    <span class="kadded"><CheckCircle size={13} weight="fill" /> Added</span>
                  </div>
                {:else}
                  <form class="kform" onsubmit={(e) => { e.preventDefault(); void saveGemini(); }}>
                    <input type="password" bind:value={gemKey} placeholder="AIza…" spellcheck="false" autocomplete="off" disabled={gemBusy} />
                    <button type="submit" disabled={gemBusy || !gemKey.trim()}>{gemBusy ? "…" : "Add"}</button>
                  </form>
                {/if}
                {#if gemErr}<div class="kerr">{gemErr}</div>{/if}
              </div>

              <div class="kget">
                <a href="https://aistudio.google.com/apikey" target="_blank" rel="noopener">Get Gemini key ↗</a>
              </div>
            </div>
          {/if}
        </div>
      {/key}

      {#if started}
        <div class="nav">
          <button type="button" class="ghost" onclick={back}>Back</button>
          <button type="button" class="primary" onclick={next} disabled={!canContinue}>
            {step === "waldo-voice" ? "Open the browser" : "Continue"}
            <ArrowRight size={14} weight="bold" />
          </button>
        </div>
      {/if}
    </div>
  </div>

  <!-- Learn-more overlay: edge from the coach port to the highlighted target.
       On the intro (no lesson yet), just outline the arrows so "use the arrows"
       is unmistakable — no edge. -->
  {#if isLearn && lessonIdx >= 0}
    <LessonOverlay {portEl} {coachEl} target={lessons[lessonIdx].target} />
  {:else if isLearn}
    <LessonOverlay {portEl} {coachEl} target=".learn-bar" edge={false} />
  {/if}
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
  /* Connect-OpenRouter button in the Waldo coach. */
  /* Key entry — OpenRouter (chat) + Gemini (voice). */
  .keys { display: flex; flex-direction: column; gap: 10px; margin-top: 6px; }
  .keyrow { display: flex; flex-direction: column; gap: 6px; }
  .klabel {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font-size: 0.82rem;
    font-weight: 600;
    color: var(--color-fg);
  }
  .klabel :global(img) { display: block; }
  .kfor { font-weight: 400; color: var(--color-fg-subtle); font-size: 0.74rem; }
  /* Saved-key state: a filled (obfuscated) field so a returning user sees the
     key is already there and isn't asked to re-enter it. */
  .kfilled {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
    padding: 7px 10px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-surface-soft);
  }
  .kdots { color: var(--color-fg-subtle); letter-spacing: 2px; font-size: 0.8rem; overflow: hidden; }
  .kadded {
    flex-shrink: 0;
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 0.78rem;
    font-weight: 600;
    color: var(--color-ok);
  }
  .kform { display: flex; gap: 6px; }
  .kform input {
    flex: 1;
    min-width: 0;
    padding: 7px 10px;
    border: 1px solid var(--color-border);
    border-radius: 8px;
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font: inherit;
    font-size: 0.82rem;
    outline: 0;
    transition: border-color 0.15s;
  }
  .kform input:focus { border-color: var(--color-border-strong); }
  .kform button {
    flex-shrink: 0;
    padding: 0 14px;
    border: 0;
    border-radius: 8px;
    background: var(--color-fg);
    color: var(--color-page);
    font: inherit;
    font-size: 0.82rem;
    font-weight: 600;
    cursor: pointer;
  }
  .kform button:disabled { opacity: 0.45; cursor: default; }
  .kok {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    font-size: 0.8rem;
    font-weight: 550;
    color: var(--color-ok);
  }
  .kerr { color: var(--color-err); font-size: 0.74rem; word-break: break-word; }
  .modelrow { display: flex; flex-direction: column; gap: 6px; margin-top: 2px; }
  .kget { display: flex; gap: 14px; margin-top: 2px; }
  .kget a { color: var(--color-fg-subtle); font-size: 0.72rem; text-decoration: none; }
  .kget a:hover { color: var(--color-fg-muted); text-decoration: underline; }
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
  .coach-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    min-height: 26px;
  }
  .dots { display: flex; justify-content: flex-start; gap: 6px; }
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
  .primary:disabled {
    opacity: 0.4;
    cursor: not-allowed;
    box-shadow: none;
    filter: none;
    transform: none;
  }

  /* Learn-more bar — node-port + lesson arrows, top of the coach. */
  .learn-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    flex-shrink: 0;
  }
  .larrow {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border: 1px solid var(--color-border);
    border-radius: 7px;
    background: var(--color-surface-soft);
    color: var(--color-fg-muted);
    cursor: pointer;
    transition: border-color 0.14s, color 0.14s, background 0.14s;
  }
  .larrow:hover:not(:disabled) { border-color: var(--color-border-strong); color: var(--color-fg); }
  .larrow:disabled { opacity: 0.35; cursor: not-allowed; }
  .lcount {
    min-width: 40px;
    text-align: center;
    font-family: var(--font-mono);
    font-size: 0.66rem;
    letter-spacing: 0.04em;
    color: var(--color-fg-subtle);
    text-transform: uppercase;
  }
  /* The port — a little node-port box that emits the edge when active. */
  .port {
    width: 11px;
    height: 11px;
    border: 1.5px solid var(--color-border-strong);
    border-radius: 3px;
    background: var(--color-surface);
    transition: border-color 0.15s, background 0.15s, box-shadow 0.15s;
  }
  .port.emitting {
    border-color: var(--color-brand);
    background: color-mix(in srgb, var(--color-brand) 30%, var(--color-surface));
    box-shadow: 0 0 0 3px color-mix(in srgb, var(--color-brand) 22%, transparent);
  }
  .ghost {
    padding: 9px 14px; border: 0; border-radius: 10px;
    background: transparent; color: var(--color-fg-muted);
    font: inherit; font-size: 0.82rem; cursor: pointer;
  }
  .ghost:hover { color: var(--color-fg); }
  @media (prefers-reduced-motion: reduce) { .dock { transition: none; } }
</style>
