<script lang="ts">
  /**
   * ConnectFlow — modal that takes an ALREADY signed-in user from
   * "no network identity" to "bound handle + signed identity, ready
   * to share."
   *
   * App-level sign-in (the underlying Workbooks account) is gated by
   * the +layout overlay — this modal won't open unless the user is
   * already signed in. ConnectFlow's job is the *network-identity*
   * bind: pick a handle, mint Ed25519, register with the broker.
   *
   * Steps:
   *   1. Welcome           — what creating an identity does
   *   2. Handle pick       — live availability via GET /resolve/:handle
   *   3. Generating        — mint Ed25519 + POST /v1/network/identity
   *   4. Backup            — show the private key once with ack
   *   5. Done              — next steps
   */
  import { fly, fade, slide } from "svelte/transition";
  import { cubicOut } from "svelte/easing";
  import {
    X, ArrowRight, ArrowLeft, Check, ShieldCheck, Copy,
    KeyRound, AlertTriangle, Sparkles,
  } from "@lucide/svelte";
  import {
    generateIdentity, setHandle,
  } from "$lib/bridge/network.svelte";

  let {
    brokerUrl = "https://auth.workbooks.sh",
    onclose,
    onconnected,
  }: {
    brokerUrl?: string;
    onclose: () => void;
    onconnected?: (binding: { handle: string; did: string }) => void;
  } = $props();

  type Step = "welcome" | "handle" | "generating" | "backup" | "done";
  let step = $state<Step>("welcome");

  // ── Step 1: welcome ─────────────────────────────────────────────
  // User is already signed into Workbooks (gated by the app-level
  // overlay). This step is just the "here's what's about to happen"
  // primer — no auth handshake to run, just advance to handle pick.
  function continueFromWelcome() {
    step = "handle";
  }

  // ── Step 2: handle pick ─────────────────────────────────────────
  let handle = $state("");
  type Avail = "idle" | "checking" | "available" | "taken" | "invalid";
  let availability = $state<Avail>("idle");
  let checkSeq = 0;

  const HANDLE_RE = /^[a-z][a-z0-9_-]{0,31}$/;

  async function checkHandle(h: string) {
    const seq = ++checkSeq;
    if (!h) {
      availability = "idle";
      return;
    }
    if (!HANDLE_RE.test(h)) {
      availability = "invalid";
      return;
    }
    availability = "checking";
    try {
      const r = await fetch(`${brokerUrl}/v1/network/resolve/${encodeURIComponent(h)}`);
      // Stale-response guard: if the user kept typing, ignore.
      if (seq !== checkSeq) return;
      if (r.status === 404) {
        availability = "available";
      } else if (r.status === 200) {
        availability = "taken";
      } else if (r.status === 400) {
        availability = "invalid";
      } else {
        // Treat network errors as "let them try" — Broker will reject
        // on bind if it really IS taken; UX shouldn't soft-fail here.
        availability = "available";
      }
    } catch {
      if (seq !== checkSeq) return;
      availability = "available";
    }
  }

  let debounceTimer: ReturnType<typeof setTimeout> | null = null;
  $effect(() => {
    const h = handle.trim().toLowerCase();
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => checkHandle(h), 280);
  });

  const canContinueHandle = $derived(availability === "available");

  // ── Step 3: generating ──────────────────────────────────────────
  let generateError = $state<string | null>(null);
  let mintedDid = $state<string | null>(null);
  // STUB key — Phase 1 bridge replaces this with the real key from
  // Workhorse.Network.Identity.generate/1. We hold the placeholder
  // here so step 4 (backup) has something to display.
  let mintedKey = $state<string | null>(null);

  async function generateAndBind() {
    generateError = null;
    const cleanHandle = handle.trim().toLowerCase();
    try {
      // Real path: Workhorse mints the keypair (or returns the
      // existing one — generateIdentity is idempotent via
      // Identity.ensure on the Elixir side). Also pre-binds the
      // handle locally so the next /identity read carries it.
      let identity;
      try {
        identity = await generateIdentity({ handle: cleanHandle });
      } catch {
        // Tauri bridge not available (running outside the desktop, or
        // sidecar not ready) — fall back to the placeholder stub so
        // the design demo keeps walking through the flow.
        const stub = generateStubIdentity();
        identity = {
          did: stub.did,
          handle: cleanHandle,
          workos_user_id: null,
          public_key_b64: stub.key,
        };
      }
      mintedDid = identity.did;
      mintedKey = identity.public_key_b64;

      // Make sure the handle is actually set (generateIdentity may
      // have returned an existing identity without one).
      if (identity.handle !== cleanHandle) {
        try { await setHandle(cleanHandle); } catch { /* stub mode */ }
      }

      // REAL: bind it on the broker so other peers can resolve.
      const r = await fetch(`${brokerUrl}/v1/network/identity`, {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          handle: cleanHandle,
          did: mintedDid,
          // Note: workos_display_name USED to be sent from here. That
          // was a forgery hole — the Broker now derives the verified
          // real name server-side from the WorkOS profile (wb-u2o0.7.6).
        }),
      });

      if (r.status === 200) {
        step = "backup";
      } else if (r.status === 409) {
        // Race — handle got taken between availability check and bind.
        const body = await r.json().catch(() => ({}));
        generateError = body.detail ?? "Handle was just claimed by someone else.";
        step = "handle";
      } else if (r.status === 401) {
        generateError = "Session expired. Sign in again.";
        step = "welcome";
      } else {
        const body = await r.json().catch(() => ({}));
        generateError = body.detail ?? body.error ?? `Broker error (${r.status})`;
      }
    } catch (e) {
      generateError = e instanceof Error ? e.message : String(e);
    }
  }

  // ── Step 4: backup ──────────────────────────────────────────────
  let backupAcked = $state(false);
  let copiedKey = $state(false);
  let copiedDid = $state(false);

  async function copyToClipboard(text: string, which: "key" | "did") {
    try {
      await navigator.clipboard.writeText(text);
      if (which === "key") {
        copiedKey = true;
        setTimeout(() => (copiedKey = false), 1400);
      } else {
        copiedDid = true;
        setTimeout(() => (copiedDid = false), 1400);
      }
    } catch {
      // Tauri webview clipboard may need a permission; surface silently for v1.
    }
  }

  function finish() {
    if (onconnected && mintedDid) {
      onconnected({ handle: handle.trim().toLowerCase(), did: mintedDid });
    }
    onclose();
  }

  // ── Misc ────────────────────────────────────────────────────────
  function onKey(e: KeyboardEvent) {
    if (e.key === "Escape" && step !== "generating") onclose();
  }

  // Step-machine driven on continue. Keeping logic colocated with the
  // template so the flow reads top-to-bottom.
  function next() {
    if (step === "handle" && canContinueHandle) {
      step = "generating";
      void generateAndBind();
    }
  }

  // Stub key generator — replace via the Tauri bridge in Phase 1.
  // Generates plausible-looking did:key + base64 key strings so the
  // backup screen has something to show during design review.
  function generateStubIdentity(): { did: string; key: string } {
    const rand = (len: number) =>
      Array.from(crypto.getRandomValues(new Uint8Array(len)))
        .map((b) => "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"[b % 58])
        .join("");
    return {
      did: `did:key:z6Mk${rand(44)}`,
      key: btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32)))),
    };
  }

  const stepNumber = $derived(
    step === "welcome" ? 1 :
    step === "handle" ? 2 :
    step === "generating" ? 3 :
    step === "backup" ? 4 :
    5,
  );
</script>

<svelte:window onkeydown={onKey} />
<button
  type="button"
  class="overlay"
  transition:fade={{ duration: 140 }}
  onclick={() => { if (step !== "generating") onclose(); }}
  aria-label="Close"
></button>

<div
  class="pane"
  role="dialog"
  aria-modal="true"
  transition:fly={{ y: 10, duration: 220, easing: cubicOut }}
>
  <header class="head">
    <div class="step-pill">Step {stepNumber} of 5</div>
    {#if step !== "generating" && step !== "done"}
      <button type="button" class="x" onclick={onclose} aria-label="Close">
        <X size={15} strokeWidth={2} />
      </button>
    {/if}
  </header>

  {#if step === "welcome"}
    <div class="body">
      <div class="hero">
        <span class="hero-glyph"><Sparkles size={24} strokeWidth={1.8} /></span>
        <h2>Create your network identity</h2>
        <p>
          Claim a handle and mint a cryptographic identity so you can publish
          workbooks and message friends. Everything you publish is signed
          by your identity key — recipients can verify it without trusting
          any server.
        </p>
      </div>
      <footer class="foot center">
        <button
          type="button"
          class="btn primary lg"
          onclick={continueFromWelcome}
        >
          Get started
          <ArrowRight size={14} strokeWidth={2} />
        </button>
      </footer>
    </div>
  {:else if step === "handle"}
    <div class="body">
      <div class="hero compact">
        <h2>Choose your handle</h2>
        <p>This is how friends will find you on the Network. Lowercase letters, digits, hyphens — 1 to 32 chars. You can't change it later in v1.</p>
      </div>

      <div class="handle-row">
        <span class="at">@</span>
        <input
          type="text"
          bind:value={handle}
          placeholder="alice"
          maxlength={32}
          spellcheck={false}
          autocomplete="off"
          autocapitalize="off"
        />
        <div class="avail" class:av-checking={availability === "checking"}
                             class:av-available={availability === "available"}
                             class:av-taken={availability === "taken"}
                             class:av-invalid={availability === "invalid"}>
          {#if availability === "checking"}<span class="spinner" aria-hidden="true"></span>{:else if availability === "available"}<Check size={13} strokeWidth={2.5} />{:else if availability === "taken"}<X size={13} strokeWidth={2.5} />{:else if availability === "invalid"}<AlertTriangle size={13} strokeWidth={2.5} />{/if}
        </div>
      </div>

      {#if availability !== "idle"}
        <p class="hint {availability}" transition:slide={{ duration: 160 }}>
          {#if availability === "available"}@{handle.trim().toLowerCase()} is available
          {:else if availability === "taken"}@{handle.trim().toLowerCase()} is already taken — try another
          {:else if availability === "invalid"}Use 1–32 chars starting with a letter; only a-z 0-9 _ -
          {:else}Checking…
          {/if}
        </p>
      {/if}

      {#if generateError}
        <p class="hint taken" transition:slide={{ duration: 160 }}>
          {generateError}
        </p>
      {/if}

      <footer class="foot">
        <button type="button" class="btn ghost" onclick={() => (step = "welcome")}>
          <ArrowLeft size={14} strokeWidth={2} /> Back
        </button>
        <button
          type="button"
          class="btn primary"
          disabled={!canContinueHandle}
          onclick={next}
        >
          Continue <ArrowRight size={14} strokeWidth={2} />
        </button>
      </footer>
    </div>
  {:else if step === "generating"}
    <div class="body">
      <div class="generating">
        <span class="big-spinner" aria-hidden="true"></span>
        <h2>Minting your identity…</h2>
        <p>Generating an Ed25519 keypair and binding @{handle.trim().toLowerCase()} on the network.</p>
      </div>
    </div>
  {:else if step === "backup"}
    <div class="body">
      <div class="hero compact">
        <span class="hero-glyph warn"><ShieldCheck size={20} strokeWidth={1.8} /></span>
        <h2>Save your key</h2>
        <p>
          Your private key signs every workbook you publish. If you lose it
          and your machine, your identity is gone — there's no recovery.
          Save it somewhere safe, like a password manager.
        </p>
      </div>

      <div class="kv">
        <span class="kv-label">Handle</span>
        <span class="kv-value">@{handle.trim().toLowerCase()}</span>
      </div>

      <div class="kv">
        <span class="kv-label">DID</span>
        <button
          type="button"
          class="kv-mono"
          onclick={() => mintedDid && copyToClipboard(mintedDid, "did")}
          title="Click to copy"
        >
          <span>{mintedDid}</span>
          {#if copiedDid}
            <span class="copied">copied</span>
          {:else}
            <Copy size={11} strokeWidth={2} />
          {/if}
        </button>
      </div>

      <div class="kv">
        <span class="kv-label key-label">
          <KeyRound size={11} strokeWidth={2} /> Private key
        </span>
        <button
          type="button"
          class="kv-mono key"
          onclick={() => mintedKey && copyToClipboard(mintedKey, "key")}
          title="Click to copy"
        >
          <span>{mintedKey}</span>
          {#if copiedKey}
            <span class="copied">copied</span>
          {:else}
            <Copy size={11} strokeWidth={2} />
          {/if}
        </button>
      </div>

      <label class="ack">
        <input type="checkbox" bind:checked={backupAcked} />
        <span>I've saved my key somewhere safe.</span>
      </label>

      <footer class="foot">
        <span class="spacer"></span>
        <button
          type="button"
          class="btn primary"
          disabled={!backupAcked}
          onclick={() => (step = "done")}
        >
          Continue <ArrowRight size={14} strokeWidth={2} />
        </button>
      </footer>
    </div>
  {:else}
    <div class="body">
      <div class="hero">
        <span class="hero-glyph ok"><Check size={24} strokeWidth={2.25} /></span>
        <h2>You're on the Network</h2>
        <p>
          @{handle.trim().toLowerCase()} is yours. Next: add a friend by handle,
          create a network, or post your first workbook.
        </p>
      </div>
      <footer class="foot center">
        <button type="button" class="btn primary lg" onclick={finish}>
          Get started
        </button>
      </footer>
    </div>
  {/if}
</div>

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(15, 15, 15, 0.48);
    backdrop-filter: blur(3px);
    z-index: 100;
    border: 0;
    padding: 0;
  }
  .pane {
    position: fixed;
    top: 50%;
    left: 50%;
    transform: translate(-50%, -50%);
    width: min(480px, 92vw);
    max-height: 92vh;
    background: var(--color-surface);
    border: 1px solid var(--color-border-strong);
    border-radius: 16px;
    box-shadow: 0 30px 80px rgba(15, 15, 15, 0.32);
    z-index: 101;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0.7rem 0.85rem;
    border-bottom: 1px solid var(--color-border);
  }
  .step-pill {
    padding: 2.5px 8px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 999px;
    font-size: 0.7rem;
    font-weight: 600;
    color: var(--color-fg-muted);
    letter-spacing: 0.01em;
  }
  .x {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border-radius: 7px;
    background: transparent;
    border: 0;
    color: var(--color-fg-muted);
    cursor: pointer;
    transition: background 140ms ease, color 140ms ease;
  }
  .x:hover { background: var(--color-surface-soft); color: var(--color-fg); }

  .body {
    padding: 1.1rem 1.2rem 0.9rem;
    display: flex;
    flex-direction: column;
    gap: 0.85rem;
  }

  .hero {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 0.55rem;
  }
  .hero.compact { gap: 0.4rem; }
  .hero-glyph {
    width: 40px;
    height: 40px;
    border-radius: 11px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
  }
  .hero-glyph.warn {
    color: rgb(150, 95, 10);
    background: rgba(225, 145, 30, 0.10);
    border-color: rgba(225, 145, 30, 0.32);
  }
  .hero-glyph.ok {
    color: rgb(20, 110, 70);
    background: rgba(34, 160, 105, 0.12);
    border-color: rgba(34, 160, 105, 0.32);
  }
  h2 {
    margin: 0;
    font-size: 1.05rem;
    font-weight: 600;
    letter-spacing: -0.015em;
  }
  .body p {
    margin: 0;
    color: var(--color-fg-muted);
    font-size: 0.84rem;
    line-height: 1.55;
  }

  /* Handle pick */
  .handle-row {
    display: grid;
    grid-template-columns: auto 1fr auto;
    align-items: center;
    gap: 8px;
    padding: 11px 13px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border-strong);
    border-radius: 10px;
    transition: border-color 160ms ease, box-shadow 160ms ease;
  }
  .handle-row:focus-within {
    border-color: var(--color-fg);
    box-shadow: 0 0 0 3px var(--color-ring);
    background: var(--color-surface);
  }
  .at {
    color: var(--color-fg-muted);
    font-size: 1rem;
    font-weight: 500;
  }
  .handle-row input {
    background: transparent;
    border: 0;
    outline: none;
    font: inherit;
    font-size: 1rem;
    color: var(--color-fg);
    width: 100%;
  }
  .avail {
    width: 22px;
    height: 22px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    border-radius: 50%;
  }
  .av-available {
    color: rgb(20, 110, 70);
    background: rgba(34, 160, 105, 0.14);
  }
  .av-taken, .av-invalid {
    color: rgb(180, 50, 50);
    background: rgba(220, 60, 60, 0.10);
  }
  .av-checking { color: var(--color-fg-muted); }

  .spinner, .big-spinner {
    display: inline-block;
    border-radius: 50%;
    border: 2px solid var(--color-border);
    border-top-color: var(--color-fg);
    animation: spin 900ms linear infinite;
  }
  .spinner { width: 13px; height: 13px; }
  .big-spinner { width: 32px; height: 32px; border-width: 3px; }
  @keyframes spin { to { transform: rotate(360deg); } }

  .hint {
    margin: -0.3rem 0 0;
    font-size: 0.78rem;
    line-height: 1.5;
  }
  .hint.available { color: rgb(20, 110, 70); }
  .hint.taken, .hint.invalid { color: rgb(180, 50, 50); }
  .hint.checking { color: var(--color-fg-muted); }

  /* Generating */
  .generating {
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 0.6rem;
    padding: 1.6rem 1rem 0.6rem;
  }
  .generating h2 { font-size: 0.98rem; }
  .generating p { max-width: 36ch; }

  /* Key/value rows on backup */
  .kv {
    display: grid;
    grid-template-columns: 100px 1fr;
    align-items: center;
    gap: 12px;
    padding: 0.5rem 0;
    border-top: 1px solid var(--color-border);
    font-size: 0.84rem;
  }
  .kv:first-of-type { border-top: 0; padding-top: 0.2rem; }
  .kv-label {
    color: var(--color-fg-muted);
    font-size: 0.74rem;
    font-weight: 500;
  }
  .key-label {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    color: rgb(150, 95, 10);
  }
  .kv-value {
    color: var(--color-fg);
    font-weight: 600;
  }
  .kv-mono {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 10px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    font-family: ui-monospace, SFMono-Regular, monospace;
    font-size: 0.72rem;
    color: var(--color-fg);
    cursor: pointer;
    text-align: left;
    transition: border-color 160ms ease;
    overflow-wrap: anywhere;
  }
  .kv-mono:hover { border-color: var(--color-border-strong); }
  .kv-mono.key {
    color: rgb(150, 95, 10);
    background: rgba(225, 145, 30, 0.06);
    border-color: rgba(225, 145, 30, 0.22);
  }
  .kv-mono > span:first-child { flex: 1; word-break: break-all; }
  .copied {
    font-family: inherit;
    font-size: 0.66rem;
    color: rgb(20, 110, 70);
    font-weight: 600;
  }

  .ack {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    margin-top: 0.4rem;
    font-size: 0.82rem;
    color: var(--color-fg);
    cursor: pointer;
  }
  .ack input {
    width: 16px;
    height: 16px;
    accent-color: var(--color-fg);
  }

  /* Footer + buttons */
  .foot {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0.7rem 0;
    border-top: 1px solid var(--color-border);
    margin-top: 0.3rem;
  }
  .foot.center { justify-content: center; border-top: 0; padding-top: 1rem; }
  .spacer { flex: 1; }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 34px;
    padding: 0 14px;
    border-radius: 8px;
    font: inherit;
    font-size: 0.83rem;
    font-weight: 500;
    cursor: pointer;
    transition: transform 160ms cubic-bezier(0.22, 1.2, 0.36, 1), background 160ms ease;
  }
  .btn:hover:not(:disabled) { transform: translateY(-1px); }
  .btn:disabled { opacity: 0.45; cursor: not-allowed; }
  .btn.lg { height: 38px; padding: 0 18px; font-size: 0.86rem; }
  .btn.primary {
    background: var(--color-fg);
    color: var(--color-page);
    border: 1px solid var(--color-fg);
  }
  .btn.ghost {
    background: transparent;
    color: var(--color-fg);
    border: 1px solid var(--color-border-strong);
  }
  .btn.ghost:hover { background: var(--color-surface-soft); }
</style>
