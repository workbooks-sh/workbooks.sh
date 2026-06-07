<script lang="ts">
  // PageData flattens the server load's discriminated union into a
  // single record with all fields optional, which breaks the kind-
  // based narrowing here. Use the explicit RunnerLoad type so TS keeps
  // the union and `data.html` is `string` inside `kind === "ok"`.
  import type { RunnerLoad } from "./+page.server";
  import type { ActionData } from "./$types";
  import { onDestroy } from "svelte";
  import { browser } from "$app/environment";
  import { PresenceClient, type Peer } from "$lib/presence/PresenceClient";
  import RosterStrip from "$lib/presence/RosterStrip.svelte";
  import CursorOverlay from "$lib/presence/CursorOverlay.svelte";
  import { CellAnchorObserver } from "$lib/cellAnchor/observer.svelte";
  import CellOverlay from "$lib/cellAnchor/CellOverlay.svelte";
  import { attachIframePointer } from "$lib/presence/iframePointer";

  let { data, form }: { data: RunnerLoad; form: ActionData } = $props();

  const wrongPassword = $derived(form?.error === "wrong_password");
  const commentPosted = $derived(form?.commentPosted === true);

  // Comment composer — closed by default, opens via the floating
  // bottom-right "Comment" pill OR by clicking a cell in the
  // overlay. When opened from a cell click, anchorCellId carries
  // the target id and the form submits with anchor_kind=cell.
  let composerOpen = $state(false);
  let composerName = $state("");
  let composerBody = $state("");
  let anchorCellId = $state<string | null>(null);

  function openComposerForPage() {
    anchorCellId = null;
    composerOpen = true;
  }
  function openComposerForCell(id: string) {
    anchorCellId = id;
    composerOpen = true;
  }

  $effect(() => {
    if (data.kind === "ok" && data.identity) {
      composerName = data.identity.name;
    }
  });

  $effect(() => {
    if (commentPosted) {
      composerOpen = false;
      composerBody = "";
    }
  });

  let iframeBlobUrl = $state<string | null>(null);
  let iframeEl: HTMLIFrameElement | null = $state(null);

  // Cell-anchor observer — scrapes the iframe DOM (allow-same-origin)
  // for [data-cell-id] elements and exposes a reactive
  // Map<cell_id, rect>. Re-runs on MutationObserver / ResizeObserver
  // / scroll signals, batched per rAF. Detaches cleanly on tab close.
  const anchor = new CellAnchorObserver();
  $effect(() => {
    if (!browser) return;
    if (data.kind !== "ok") return;
    if (!iframeEl) return;
    anchor.attach(iframeEl);
    return () => anchor.detach();
  });

  // Per-cell counts of OPEN comments. Drives the amber pin badges
  // in the cell overlay. Stranded comments (anchor_resolved=false)
  // get their own tinted ring instead.
  const commentCounts = $derived.by(() => {
    const m = new Map<string, number>();
    if (data.kind !== "ok") return m;
    for (const c of data.comments) {
      if (c.anchor_kind !== "cell" || !c.anchor_target) continue;
      if (c.resolved_at != null) continue;     // owner marked done
      if (!c.anchor_resolved) continue;        // stranded — counted below
      m.set(c.anchor_target, (m.get(c.anchor_target) ?? 0) + 1);
    }
    return m;
  });
  const strandedCells = $derived.by(() => {
    const s = new Set<string>();
    if (data.kind !== "ok") return s;
    for (const c of data.comments) {
      if (c.anchor_kind !== "cell" || !c.anchor_target) continue;
      if (c.resolved_at != null) continue;
      if (!c.anchor_resolved) s.add(c.anchor_target);
    }
    return s;
  });

  // Presence (wb-v9ys.6). Boots when the runner enters the `ok`
  // state AND we know the viewer's name. We bootstrap from the
  // identity cookie if available; the comment composer also sets
  // one on first comment. If neither, the recipient is anonymous
  // until they comment — we still join the WS but without a name
  // they don't appear in the roster.
  let peers = $state<Peer[]>([]);
  let presence = $state<PresenceClient | null>(null);
  // The identity this viewer broadcasts (cookie identity or a random
  // guest). Set when presence connects; drives the roster's "you" chip.
  let myIdentity = $state<{ name: string; color: string } | null>(null);
  let self = $derived(myIdentity);

  // Identity for presence. Use the comment-identity cookie if set;
  // otherwise generate a random distinguishable guest (two anonymous
  // viewers must NOT collapse to the same name+color, or you can't
  // tell whose cursor is whose).
  const GUEST_ANIMALS = [
    "Otter", "Falcon", "Marmot", "Heron", "Lynx", "Wren",
    "Bison", "Civet", "Ibex", "Kestrel", "Tapir", "Vole",
  ];
  const GUEST_COLORS = [
    "#ff7a59", "#3b82f6", "#10b981", "#f59e0b", "#8b5cf6",
    "#ec4899", "#06b6d4", "#84cc16", "#f97316", "#a855f7",
  ];
  function randomGuest(): { name: string; color: string } {
    const a = GUEST_ANIMALS[Math.floor(Math.random() * GUEST_ANIMALS.length)];
    const c = GUEST_COLORS[Math.floor(Math.random() * GUEST_COLORS.length)];
    const n = 1 + Math.floor(Math.random() * 99);
    return { name: `${a} ${n}`, color: c };
  }

  $effect(() => {
    if (!browser) return;
    if (data.kind !== "ok") return;
    if (presence) return; // already connected

    const ident = data.identity ?? randomGuest();
    const name = ident.name;
    const color = ident.color;
    myIdentity = { name, color };

    const p = new PresenceClient({
      slug: data.slug,
      name,
      color,
      unlockToken: data.unlockToken ?? undefined,
      onPeersChange: (next) => { peers = next; },
      onComment: () => {
        // Slice 5 thread refresh: a comment landed in the room.
        // Recipient-side we don't currently render the thread, so
        // this is a no-op for now. Desktop side consumes the same
        // event via its own WS connection.
      },
    });
    p.connect();
    presence = p;
  });

  onDestroy(() => {
    try { presence?.close(); } catch { /* */ }
    presence = null;
  });

  // Cursor tracking has to listen INSIDE the iframe document — when
  // the pointer is over the full-bleed workbook, the parent window
  // never sees pointermove. allow-same-origin lets us attach to the
  // iframe's contentDocument. Coordinates are already normalized
  // [0,1] by the bridge. Also forwards clicks as ping ripples.
  $effect(() => {
    if (!browser) return;
    if (data.kind !== "ok") return;
    if (!iframeEl) return;
    const detach = attachIframePointer(iframeEl, {
      onMove: (x, y) => presence?.setLocalCursor(x, y),
      onClick: (x, y) => presence?.sendClick(x, y),
    });
    return detach;
  });

  // Also track cursor in the parent margins (outside the iframe) — the
  // overlay regions, the comment composer, etc. Harmless overlap with
  // the iframe bridge; whichever fires last wins, both normalize the
  // same way.
  function onPointerMove(ev: PointerEvent) {
    if (!presence) return;
    presence.setLocalCursor(ev.clientX / window.innerWidth, ev.clientY / window.innerHeight);
  }

  // Reuse the same blob-URL sandbox pattern as /w/[rid]. The .html is
  // assembled by the broker side; here we just stream the bytes into
  // an iframe so author-side JS can't reach the parent page.
  //
  // IMPORTANT: this effect must NOT read iframeBlobUrl — it only
  // writes it. createObjectURL returns a fresh string each run, so a
  // read+write of the same $state self-retriggers forever
  // (effect_update_depth_exceeded). The cleanup function revokes the
  // previous URL instead.
  $effect(() => {
    if (data.kind !== "ok") {
      iframeBlobUrl = null;
      return;
    }
    const blob = new Blob([data.html], { type: "text/html" });
    const url = URL.createObjectURL(blob);
    iframeBlobUrl = url;
    return () => URL.revokeObjectURL(url);
  });
</script>

<svelte:head>
  {#if data.kind === "ok"}
    <title>{data.workbook_id} — Workbooks</title>
  {:else}
    <title>Workbooks</title>
  {/if}
</svelte:head>

<svelte:window onpointermove={onPointerMove} />

{#if data.kind === "ok"}
  {#if iframeBlobUrl}
    <iframe
      bind:this={iframeEl}
      title={data.workbook_id}
      src={iframeBlobUrl}
      sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-downloads"
      referrerpolicy="no-referrer"
    ></iframe>
  {/if}

  {#if anchor.ready}
    <CellOverlay
      rects={anchor.rects}
      {commentCounts}
      stranded={strandedCells}
      onCellClick={openComposerForCell}
      onCellHover={() => {}}
    />
  {/if}

  <RosterStrip {peers} {self} />
  <CursorOverlay {peers} />

  <!-- Comment composer. Two entry points:
         1. Floating pill bottom-right → page-anchored comment.
         2. Click a cell ring in the overlay → cell-anchored comment.
       The composer surfaces which it'll be via the anchor breadcrumb. -->
  {#if !composerOpen}
    <button class="cmt-pill" onclick={openComposerForPage} aria-label="Add a comment">
      Comment
    </button>
  {:else}
    <div class="cmt-panel">
      <form method="POST" action="?/comment">
        <div class="cmt-anchor">
          {#if anchorCellId}
            <span class="cmt-anchor-kind">Cell</span>
            <code class="cmt-anchor-target">{anchorCellId}</code>
            <button
              type="button"
              class="cmt-anchor-clear"
              onclick={() => (anchorCellId = null)}
              aria-label="Comment on the whole page instead"
            >clear</button>
          {:else}
            <span class="cmt-anchor-kind">Whole page</span>
          {/if}
        </div>
        <input type="hidden" name="anchor_kind" value={anchorCellId ? "cell" : "page"} />
        {#if anchorCellId}
          <input type="hidden" name="anchor_target" value={anchorCellId} />
        {/if}
        <div class="cmt-row">
          <label for="cmt-name">Your name</label>
          <input
            id="cmt-name"
            name="name"
            type="text"
            bind:value={composerName}
            maxlength="64"
            required
          />
        </div>
        <div class="cmt-row">
          <label for="cmt-body">Comment</label>
          <textarea
            id="cmt-body"
            name="body"
            bind:value={composerBody}
            rows="4"
            required
          ></textarea>
        </div>
        {#if form?.error && !commentPosted && form?.error !== "wrong_password"}
          <p class="cmt-err">Couldn't send: {form.error}</p>
        {/if}
        <div class="cmt-actions">
          <button type="submit" class="primary">Send</button>
          <button type="button" class="ghost" onclick={() => (composerOpen = false)}>Cancel</button>
        </div>
      </form>
    </div>
  {/if}
{:else}
  <div class="status">
    <div class="card">
      <div class="mark">W</div>
      {#if data.kind === "not_found"}
        <h1>This URL doesn't exist</h1>
        <p>The live URL <code>{data.slug}</code> isn't recognized. It may have been deleted, or the link may be wrong.</p>
      {:else if data.kind === "disabled"}
        <h1>This URL is paused</h1>
        <p>The author has turned this live URL off. Check back later, or get in touch with them.</p>
      {:else if data.kind === "password_required"}
        <h1>Password required</h1>
        <p>The author set a password on this URL. Enter it to view.</p>
        <form method="POST" action="?/unlock" class="pw-form">
          <input
            type="password"
            name="password"
            placeholder="Password"
            autocomplete="current-password"
            required
            aria-label="Password"
            aria-invalid={wrongPassword ? "true" : undefined}
          />
          <button type="submit">Unlock</button>
          {#if wrongPassword}
            <p class="pw-err">Wrong password — try again.</p>
          {/if}
        </form>
      {:else if data.kind === "network_auth_required"}
        <h1>Sign in required</h1>
        <p>This URL requires a Workbooks account.</p>
      {:else if data.kind === "live_url_unsupported"}
        <h1>Hosted runtime not provisioned</h1>
        <p>
          This workbook contains cells that need a hosted engine to run
          (shell, LLM, or native code). The Live URL runtime that would
          host those cells isn't online yet. Track <code>wb-hqtg</code>
          Phase F for the rollout.
        </p>
      {:else if data.kind === "desktop_only_share"}
        <h1>Workbooks Desktop required</h1>
        <p>
          This workbook writes to the recipient's local
          <code>.workbooks/</code> directory and can only be opened in
          Workbooks Desktop. Ask the sender to share it directly to your
          Workbooks identity.
        </p>
      {:else if data.kind === "error"}
        <h1>Couldn't load</h1>
        <p>{data.message}</p>
      {/if}
      <a class="home" href="https://workbooks.sh">workbooks.sh</a>
    </div>
  </div>
{/if}

<style>
  /* The @.svelte suffix on the page name resets the layout chain, so
     this template renders directly inside app.html with no header,
     nav, or footer chrome. The iframe takes the full viewport. */
  :global(html, body) {
    margin: 0;
    padding: 0;
    height: 100%;
    background: #000;
  }
  iframe {
    border: 0;
    width: 100vw;
    height: 100vh;
    display: block;
    background: #fff;
  }
  .status {
    min-height: 100vh;
    display: grid;
    place-items: center;
    background: var(--color-page, #0c0c0d);
    color: var(--color-fg, #e8e8ea);
    font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    padding: 24px;
  }
  .card {
    max-width: 480px;
    text-align: center;
    padding: 32px;
    border-radius: 12px;
    border: 1px solid var(--color-border, #2a2a2e);
    background: var(--color-surface, #161618);
  }
  .mark {
    display: inline-grid;
    place-items: center;
    width: 32px;
    height: 32px;
    border-radius: 8px;
    background: var(--color-fg, #e8e8ea);
    color: var(--color-page, #0c0c0d);
    font-weight: 700;
    font-size: 1rem;
    margin-bottom: 16px;
  }
  h1 {
    font-size: 1.25rem;
    margin: 0 0 8px 0;
    font-weight: 600;
  }
  p {
    margin: 0;
    color: var(--color-fg-muted, #a0a0a8);
    line-height: 1.5;
  }
  code {
    font-family: ui-monospace, SF Mono, Menlo, monospace;
    font-size: 0.85em;
    padding: 2px 6px;
    border-radius: 4px;
    background: var(--color-surface-soft, #1f1f23);
  }
  .home {
    display: inline-block;
    margin-top: 20px;
    color: var(--color-fg-muted, #a0a0a8);
    text-decoration: none;
    font-size: 0.85rem;
  }
  .home:hover { color: var(--color-fg, #e8e8ea); }

  .pw-form {
    display: flex;
    flex-direction: column;
    gap: 10px;
    margin-top: 18px;
    align-items: stretch;
  }
  .pw-form input {
    padding: 9px 12px;
    border-radius: 8px;
    border: 1px solid var(--color-border, #2a2a2e);
    background: var(--color-surface-soft, #1f1f23);
    color: var(--color-fg, #e8e8ea);
    font: inherit;
    text-align: center;
  }
  .pw-form input[aria-invalid="true"] {
    border-color: #ef4444;
  }
  .pw-form button {
    padding: 9px 12px;
    border-radius: 8px;
    border: 1px solid var(--color-fg, #e8e8ea);
    background: var(--color-fg, #e8e8ea);
    color: var(--color-page, #0c0c0d);
    font: inherit;
    font-weight: 500;
    cursor: pointer;
  }
  .pw-form button:hover { opacity: 0.92; }
  .pw-err {
    color: #ef4444;
    font-size: 0.78rem;
    margin: 0;
  }

  /* Comment composer */
  .cmt-pill {
    position: fixed;
    bottom: 20px;
    right: 20px;
    padding: 10px 16px;
    border-radius: 999px;
    border: 1px solid rgba(255, 255, 255, 0.15);
    background: rgba(20, 20, 24, 0.92);
    color: #fff;
    font: inherit;
    font-size: 0.85rem;
    cursor: pointer;
    backdrop-filter: blur(8px);
    box-shadow: 0 6px 20px rgba(0, 0, 0, 0.35);
    z-index: 50;
  }
  .cmt-pill:hover { background: rgba(40, 40, 46, 0.95); }
  .cmt-panel {
    position: fixed;
    bottom: 20px;
    right: 20px;
    width: 340px;
    max-width: calc(100vw - 40px);
    padding: 14px;
    border-radius: 12px;
    border: 1px solid rgba(255, 255, 255, 0.15);
    background: rgba(20, 20, 24, 0.96);
    color: #fff;
    z-index: 50;
    box-shadow: 0 10px 32px rgba(0, 0, 0, 0.45);
    backdrop-filter: blur(10px);
    font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  }
  .cmt-anchor {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-bottom: 10px;
    padding: 6px 8px;
    border-radius: 6px;
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.08);
    font-size: 0.72rem;
  }
  .cmt-anchor-kind {
    color: rgba(255, 255, 255, 0.6);
    text-transform: uppercase;
    letter-spacing: 0.05em;
    font-weight: 600;
  }
  .cmt-anchor-target {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    background: rgba(255, 255, 255, 0.08);
    padding: 1px 6px;
    border-radius: 4px;
    color: #fff;
  }
  .cmt-anchor-clear {
    margin-left: auto;
    background: transparent;
    border: 0;
    color: rgba(255, 255, 255, 0.55);
    cursor: pointer;
    font: inherit;
    font-size: 0.7rem;
    text-decoration: underline;
  }
  .cmt-anchor-clear:hover { color: #fff; }
  .cmt-row {
    display: flex;
    flex-direction: column;
    gap: 4px;
    margin-bottom: 10px;
  }
  .cmt-row label {
    font-size: 0.72rem;
    color: rgba(255, 255, 255, 0.6);
  }
  .cmt-row input,
  .cmt-row textarea {
    padding: 7px 10px;
    border-radius: 6px;
    border: 1px solid rgba(255, 255, 255, 0.15);
    background: rgba(0, 0, 0, 0.25);
    color: #fff;
    font: inherit;
    font-size: 0.85rem;
    resize: vertical;
  }
  .cmt-row textarea { font-family: inherit; }
  .cmt-err {
    color: #ef4444;
    font-size: 0.74rem;
    margin: 0 0 8px 0;
  }
  .cmt-actions {
    display: flex;
    gap: 6px;
  }
  .cmt-actions .primary {
    padding: 7px 14px;
    border-radius: 6px;
    border: 0;
    background: #fff;
    color: #18181b;
    font: inherit;
    font-weight: 500;
    cursor: pointer;
  }
  .cmt-actions .primary:hover { opacity: 0.92; }
  .cmt-actions .ghost {
    padding: 7px 14px;
    border-radius: 6px;
    border: 1px solid rgba(255, 255, 255, 0.15);
    background: transparent;
    color: #fff;
    font: inherit;
    cursor: pointer;
  }
  .cmt-actions .ghost:hover { background: rgba(255, 255, 255, 0.06); }
</style>
