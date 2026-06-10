<script>
  // §4.8 Crew panel — a CHARACTER GRID + PROFILE + a terminal COMMIT CONSOLE
  // (founder, 2026-06-10, replaces the org chart). Opens from the masthead
  // ◉ crew toggle on every page as a slide-in right panel (light Notion
  // surface); ALSO renders inline on /design as the specimen.
  //
  //   HOME view  → a full-bleed responsive GRID of character cards (avatar +
  //                name + job type + a status pill). Whole card → that member's
  //                PROFILE.
  //   PROFILE    → a larger avatar with a face→bust→full crop reveal, a bio
  //                line, and that agent's recent commits. Back-arrow → grid.
  //   CONSOLE    → below, a terminal-styled scrollable commit feed of the whole
  //                newsroom history (mono, tag-colored). A draggable divider
  //                between top + console resizes it; height persists in
  //                localStorage. (DESIGN §4.8.)
  //
  // Avatars are the LOCAL open-peeps pack now (DESIGN §4.8a) — crops drive the
  // profile reveal. Data: /_activity (crew) + /_changes (commits) live; the
  // feed.js specimen offline (honest "specimen data" tag).
  import Avatar from './Avatar.svelte';
  import { BIOS } from './feed.js';
  import { classify, rel } from './commits.js';

  let {
    open = false,
    inline = false,
    filter = null,         // agent name the panel is scoped to (from a byline click)
    clock = '14:02:33',
    agents = [],
    commits = [],          // the full newsroom commit history (/_changes)
    pipeline = '',
    specimen = false,      // honest flag: the runtime feed isn't wired yet
    onclose,
  } = $props();

  // job-type label per role (mono uppercase on the grid card)
  const JOB = { assignment: 'assignment', research: 'research', writer: 'writer', editor: 'editor' };
  const jobOf = (a) => JOB[a.role] ?? a.role;

  // a short, glanceable status from the doing-line: "<verb>…" or "idle".
  function statusOf(a) {
    if (a.state === 'idle') return 'idle';
    const verb = (a.doing || '').split(/[:\s]/)[0];
    return verb ? `${verb}…` : 'working…';
  }

  // ── view state: null = grid, else the selected member name ──────────────
  let selected = $state(null);
  // a byline click (filter) deep-links straight into that member's profile;
  // a cleared filter (masthead/footer toggle) returns to the grid home.
  $effect(() => { selected = filter; });
  const member = $derived(agents.find((a) => a.name === selected) ?? null);
  function openMember(name) { selected = name; }
  function backToGrid() { selected = null; }


  // this member's authored commits (match on author name)
  const myCommits = $derived(
    member ? commits.filter((c) => (c.author || '').toLowerCase() === member.name.toLowerCase()) : []
  );

  // pipeline string → [{label, n}] chips
  const chips = $derived(
    pipeline
      .split('·')
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => {
        const m = s.match(/^(.*?)\s+(\d+)$/);
        return m ? { label: m[1], n: m[2] } : { label: s, n: '' };
      })
  );

  // ── console resize: a draggable divider; height persists in localStorage ─
  const LS_KEY = 'bitml.crew.consoleH';
  const MIN_H = 96, MAX_H = 520;
  const clamp = (h) => Math.max(MIN_H, Math.min(MAX_H, h));
  let consoleH = $state(clamp(readH()));
  function readH() {
    try { return parseInt(localStorage.getItem(LS_KEY) || '', 10) || 200; }
    catch { return 200; }
  }
  function saveH(h) { try { localStorage.setItem(LS_KEY, String(h)); } catch {} }

  let drag = $state(null);   // { startY, startH }
  function onDragStart(e) {
    drag = { startY: e.clientY, startH: consoleH };
    window.addEventListener('pointermove', onDragMove);
    window.addEventListener('pointerup', onDragEnd);
    e.preventDefault();
  }
  function onDragMove(e) {
    if (!drag) return;
    // dragging the divider DOWN shrinks the console (it's below); UP grows it
    const dy = e.clientY - drag.startY;
    consoleH = clamp(drag.startH - dy);
  }
  function onDragEnd() {
    drag = null;
    saveH(consoleH);
    window.removeEventListener('pointermove', onDragMove);
    window.removeEventListener('pointerup', onDragEnd);
  }
  // keyboard resize on the divider (a11y)
  function onDividerKey(e) {
    if (e.key === 'ArrowUp')   { consoleH = clamp(consoleH + 24); saveH(consoleH); e.preventDefault(); }
    if (e.key === 'ArrowDown') { consoleH = clamp(consoleH - 24); saveH(consoleH); e.preventDefault(); }
  }
</script>

<aside
  class="crew"
  class:inline
  class:open={inline || open}
  aria-hidden={!(inline || open)}
>
  <div class="phead">
    <span class="title mono">THE CREW</span>
    {#if specimen}<span class="spectag mono" title="the crew runtime is a parallel build (wb-wc0.2) — this feed is static for now">specimen data</span>{/if}
    <span class="time mono">{clock} UTC</span>
    {#if !inline}<button class="x" onclick={onclose} aria-label="close crew panel">×</button>{/if}
  </div>

  <!-- ── TOP REGION (grid OR profile) — flexes; console takes the rest ──── -->
  <div class="top">
    {#if member}
      <!-- ── MEMBER PROFILE — the "about the author" view ─────────────── -->
      <div class="profile">
        <button class="back mono" onclick={backToGrid} aria-label="back to the crew">← crew</button>

        <div class="pfig">
          <Avatar seed={member.avatarSeed ?? member.name} name={member.name}
                  size="xl" crop="full" live={member.state !== 'idle'} />
        </div>

        <div class="pname">{member.name}</div>
        <div class="prole mono">{jobOf(member)}</div>
        <p class="pbio">{BIOS[member.name] ?? member.doing}</p>

        <div class="shead mono">RECENT COMMITS</div>
        {#if myCommits.length}
          <div class="pcommits">
            {#each myCommits as c}
              {@const k = classify(c.msg)}
              <div class="pcrow">
                <span class="psha mono">{(c.sha || '').slice(0, 7)}</span>
                <span class="pcm">{#if k.tag}<span class="ptag mono" style="color:{k.color}">{k.tag}</span>{/if}{k.body}</span>
                <span class="pct mono">{rel(c.ts ?? c.time)}</span>
              </div>
            {/each}
          </div>
        {:else}
          <p class="empty mono">no commits yet</p>
        {/if}
      </div>
    {:else}
      <!-- ── CHARACTER GRID — the home view ───────────────────────────── -->
      <div class="grid">
        {#each agents as a}
          <button class="card" class:hit={filter === a.name} onclick={() => openMember(a.name)}>
            <Avatar seed={a.avatarSeed ?? a.name} name={a.name} size="lg" crop="bust" live={a.state !== 'idle'} />
            <span class="cname">{a.name}</span>
            <span class="cjob mono">{jobOf(a)}</span>
            <span class="badge mono" class:live={a.state !== 'idle'}>
              {#if a.state !== 'idle'}<span class="dot"></span>{/if}{statusOf(a)}
            </span>
          </button>
        {/each}
      </div>

      <!-- PIPELINE — Notion-ish stat chips (only on the grid home) -->
      {#if chips.length}
        <div class="shead mono pipehead">PIPELINE</div>
        <div class="chips">
          {#each chips as c}
            <span class="chip">
              <span class="cn">{c.n}</span>
              <span class="cl mono">{c.label}</span>
            </span>
          {/each}
        </div>
      {/if}
    {/if}
  </div>

  <!-- ── the draggable divider ─────────────────────────────────────────── -->
  <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <div
    class="divider"
    class:dragging={drag != null}
    role="separator"
    aria-orientation="horizontal"
    aria-label="resize the commit console"
    tabindex="0"
    onpointerdown={onDragStart}
    onkeydown={onDividerKey}
  >
    <span class="grip" aria-hidden="true"></span>
  </div>

  <!-- ── COMMIT CONSOLE — terminal-styled newsroom history ─────────────── -->
  <div class="console" style="height:{consoleH}px">
    <div class="conhead mono">
      <span class="prompt">$</span> tail -f newsroom.log
      <span class="cncount">{commits.length} commits</span>
    </div>
    <div class="conbody">
      {#each commits as c}
        {@const k = classify(c.msg)}
        <div class="line mono">
          <span class="lsha">{(c.sha || '').slice(0, 7)}</span>
          <span class="lwho">{c.author}</span>
          {#if k.tag}<span class="ltag" style="color:{k.color}">{k.tag}:</span>{/if}
          <span class="lmsg">{k.body}</span>
          <span class="lt">{rel(c.ts ?? c.time)}</span>
        </div>
      {/each}
    </div>
  </div>
</aside>

<style>
  .crew {
    background: var(--paper);
    color: var(--ink);
    font-family: var(--sans);
    font-size: 13px; line-height: 1.5;
    display: flex; flex-direction: column;
  }

  /* docked overlay (toggle) — a floating Notion surface, soft lift, no stroke */
  .crew:not(.inline) {
    position: fixed; top: 0; right: 0; z-index: 80;
    width: 420px; max-width: 92vw; height: 100vh;
    transform: translateX(100%);
    transition: transform .15s ease-out;   /* §4.8 slide-in 150ms */
    box-shadow: var(--shadow);
    border-radius: var(--r) 0 0 var(--r);
    overflow: hidden;                       /* the console scrolls, not the panel */
  }
  .crew:not(.inline).open { transform: none; }

  /* inline specimen — a card on the page (fixed height so the console reads) */
  .crew.inline {
    width: 100%;
    border-radius: var(--r);
    box-shadow: var(--shadow);
    height: 620px;
    overflow: hidden;
  }

  .phead {
    display: flex; align-items: baseline; gap: 12px;
    padding: 20px 22px 16px; flex: 0 0 auto;
  }
  .title { font-size: 11px; letter-spacing: 0.08em; color: var(--ink); font-weight: 500; }
  .spectag {
    font-size: 9.5px; text-transform: uppercase; letter-spacing: 0.08em;
    color: var(--ink-3); background: var(--surface);
    border-radius: var(--r-s); padding: 3px 7px; align-self: center;
  }
  .time { font-size: 11px; color: var(--wire); margin-left: auto; font-variant-numeric: tabular-nums; letter-spacing: 0.04em; }
  .x {
    background: none; border: 0; color: var(--ink-3);
    font-size: 20px; line-height: 1; padding: 0 0 0 6px; cursor: pointer;
  }
  .x:hover { color: var(--ink); }

  /* the top region flexes; the console (below the divider) takes a fixed h */
  .top { flex: 1 1 auto; overflow-y: auto; padding: 4px 22px 22px; min-height: 0; }

  /* ── shared section head ── */
  .shead {
    font-size: 11px; text-transform: uppercase; letter-spacing: 0.07em;
    color: var(--ink); margin: 0 0 12px;
  }
  .pipehead { margin-top: 26px; }

  /* ── CHARACTER GRID ── */
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
    gap: 18px;
    margin-top: 6px;
  }
  .card {
    display: flex; flex-direction: column; align-items: center; text-align: center;
    gap: 4px; padding: 22px 14px 18px;
    background: var(--surface); border: 0; border-radius: var(--r);
    box-shadow: var(--shadow);
    cursor: pointer;
    transition: transform .14s ease, box-shadow .14s ease;
  }
  .card:hover { transform: translateY(-2px); }
  .card.hit { outline: 2px solid color-mix(in srgb, var(--wire) 50%, transparent); outline-offset: -2px; }
  .cname { font-size: 15px; font-weight: 600; color: var(--ink); margin-top: 12px; letter-spacing: -0.01em; }
  .cjob {
    font-size: 10px; text-transform: uppercase; letter-spacing: 0.07em;
    color: var(--ink-3);
  }
  .badge {
    display: inline-flex; align-items: center; gap: 5px;
    margin-top: 8px; padding: 3px 9px; border-radius: 999px;
    font-size: 10px; letter-spacing: 0.03em;
    background: color-mix(in srgb, var(--ink) 4%, transparent);
    color: var(--ink-3);
  }
  .badge.live {
    background: color-mix(in srgb, var(--wire) 9%, transparent);
    color: var(--wire);
  }
  .badge .dot {
    width: 6px; height: 6px; border-radius: 999px; background: var(--wire);
    animation: breathe 2.4s ease-in-out infinite;
  }

  /* ── pipeline chips ── */
  .chips { display: flex; flex-wrap: wrap; gap: 8px; }
  .chip {
    display: inline-flex; align-items: baseline; gap: 6px;
    background: var(--surface); border-radius: var(--r-s);
    padding: 8px 12px;
  }
  .cn { font-size: 16px; font-weight: 600; color: var(--ink); font-variant-numeric: tabular-nums; }
  .cl { font-size: 10px; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3); }

  /* ── MEMBER PROFILE ── */
  .back {
    background: none; border: 0; padding: 4px 0; cursor: pointer;
    font-size: 11px; color: var(--ink-3); letter-spacing: 0.04em;
  }
  .back:hover { color: var(--wire); }
  .pfig { display: flex; flex-direction: column; align-items: center; gap: 10px; margin: 8px 0 14px; }
  .reveal {
    background: none; border: 0; padding: 0; cursor: pointer; line-height: 0;
    border-radius: var(--r);
    transition: transform .14s ease;
  }
  .reveal:hover { transform: scale(1.02); }
  .pname { text-align: center; font-size: 22px; font-weight: 600; color: var(--ink); letter-spacing: -0.02em; }
  .prole {
    text-align: center; font-size: 10.5px; text-transform: uppercase;
    letter-spacing: 0.07em; color: var(--ink-3); margin-top: 2px;
  }
  .pbio {
    margin: 16px auto 26px; max-width: 42ch; text-align: center;
    font-size: 13.5px; line-height: 1.55; color: var(--ink-2);
  }
  .pcommits { display: flex; flex-direction: column; gap: 2px; }
  .pcrow {
    display: grid; grid-template-columns: 56px 1fr auto; gap: 10px;
    align-items: baseline; padding: 7px 8px; margin: 0 -8px;
    border-radius: var(--r-s); transition: background .12s ease;
  }
  .pcrow:hover { background: var(--wash); }
  .psha { font-size: 11px; color: var(--ink-3); }
  .pcm { font-size: 12.5px; color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; }
  .ptag { font-size: 11px; letter-spacing: 0.02em; margin-right: 5px; }
  .pct { font-size: 10.5px; color: var(--ink-3); white-space: nowrap; }
  .empty { font-size: 11px; color: var(--ink-3); padding: 6px 0; }

  /* ── the draggable divider ── */
  .divider {
    flex: 0 0 auto; height: 14px; cursor: row-resize;
    display: flex; align-items: center; justify-content: center;
    background: var(--paper);
    border-top: 1px solid var(--rule);
    touch-action: none;
  }
  .divider:hover .grip, .divider.dragging .grip { background: var(--wire); }
  .divider:focus-visible { outline: 2px solid var(--wire); outline-offset: -2px; }
  .grip { width: 34px; height: 3px; border-radius: 999px; background: var(--rule); transition: background .14s ease; }

  /* ── COMMIT CONSOLE — terminal-flavored, subtle tint ── */
  .console {
    flex: 0 0 auto; display: flex; flex-direction: column;
    background: var(--surface);            /* a subtle terminal tint within B&W */
    min-height: 0;
  }
  .conhead {
    flex: 0 0 auto; padding: 9px 22px; font-size: 10.5px;
    color: var(--ink-3); letter-spacing: 0.03em;
    border-bottom: 1px solid var(--rule);
    display: flex; align-items: center; gap: 8px;
  }
  .conhead .prompt { color: var(--wire); }
  .conhead .cncount { margin-left: auto; color: var(--ink-3); }
  .conbody { flex: 1 1 auto; overflow-y: auto; padding: 8px 0; min-height: 0; }
  .line {
    display: flex; align-items: baseline; gap: 8px;
    padding: 3px 22px; font-size: 11.5px; line-height: 1.45;
    white-space: nowrap;
  }
  .line:hover { background: var(--wash); }
  .lsha { color: var(--ink-3); flex: 0 0 auto; }
  .lwho { color: var(--ink); font-weight: 500; flex: 0 0 auto; }
  .ltag { flex: 0 0 auto; letter-spacing: 0.01em; }
  .lmsg { color: var(--ink-2); overflow: hidden; text-overflow: ellipsis; flex: 1 1 auto; min-width: 0; }
  .lt { color: var(--ink-3); flex: 0 0 auto; font-variant-numeric: tabular-nums; }

  @keyframes breathe { 50% { opacity: .45; } }
</style>
