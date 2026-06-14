<script lang="ts">
  /**
   * Workgate approval modal — the desktop safety prompt for `os.*` capabilities.
   *
   * Minimal + legible: an icon for the capability TYPE, one clear question, the
   * agent's reason, the exact scope (kept — it's the security signal), a
   * remember choice, and Deny / Allow. The chrome stays consistent with the
   * env-request modal so users build one mental model.
   */
  import { workgate, type RememberKind } from "./store.svelte";
  import {
    File,
    Globe,
    Camera,
    Microphone,
    Monitor,
    Rocket,
    ShieldCheck,
  } from "phosphor-svelte";

  let remember = $state<RememberKind>("one_time");
  let acting = $state(false);

  const req = $derived(workgate.current);

  // Capability → a type icon + a plain-language phrase.
  const cap = $derived.by(() => {
    const c = (req?.capability ?? "").toLowerCase();
    if (c.startsWith("fs") || c.includes("file"))
      return { icon: File, phrase: "read and write files on your computer" };
    if (c.startsWith("net") || c.includes("http") || c.includes("fetch"))
      return { icon: Globe, phrase: "reach the network" };
    if (c.includes("camera")) return { icon: Camera, phrase: "use your camera" };
    if (c.includes("mic") || c.includes("audio"))
      return { icon: Microphone, phrase: "use your microphone" };
    if (c.includes("screen") || c.includes("display"))
      return { icon: Monitor, phrase: "capture your screen" };
    if (c.includes("launch") || c.includes("app") || c.includes("exec"))
      return { icon: Rocket, phrase: "launch an app" };
    return { icon: ShieldCheck, phrase: `use ${req?.capability ?? "a capability"}` };
  });

  async function onAllow() {
    if (!req || acting) return;
    acting = true;
    try {
      await workgate.allow({ remember });
    } finally {
      acting = false;
      remember = "one_time";
    }
  }

  async function onDeny() {
    if (!req || acting) return;
    acting = true;
    try {
      await workgate.deny();
    } finally {
      acting = false;
      remember = "one_time";
    }
  }
</script>

{#if req}
  <div class="overlay" data-testid="workgate-overlay">
    <div class="modal" role="dialog" aria-modal="true" aria-labelledby="wg-title">
      <div class="logo" aria-hidden="true">
        {@const CapIcon = cap.icon}
        <CapIcon weight="fill" size={24} />
      </div>

      <h2 id="wg-title">Let Waldo {cap.phrase}?</h2>
      {#if req.reason}<p class="sub">{req.reason}</p>{/if}

      <code class="cap">{req.capability}</code>

      {#if Object.keys(req.scope).length > 0}
        <pre class="scope">{JSON.stringify(req.scope, null, 2)}</pre>
      {/if}

      <select id="wg-remember" bind:value={remember} disabled={acting} class="remember">
        <option value="one_time">Just this once</option>
        <option value="this_session">For this session</option>
        <option value="this_workspace">For this workspace</option>
      </select>

      <div class="actions">
        <button class="btn deny" onclick={onDeny} disabled={acting} data-testid="workgate-deny">
          Deny
        </button>
        <button class="btn allow" onclick={onAllow} disabled={acting} data-testid="workgate-allow">
          Allow
        </button>
      </div>
    </div>
  </div>
{/if}

<style>
  .overlay {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.5);
    backdrop-filter: blur(2px);
    z-index: 9999;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1rem;
  }
  .modal {
    background: var(--color-surface);
    color: var(--color-fg);
    border: 1px solid var(--color-border);
    border-radius: 16px;
    box-shadow: 0 24px 60px rgba(0, 0, 0, 0.28);
    padding: 1.6rem 1.5rem 1.25rem;
    width: 100%;
    max-width: 360px;
    display: flex;
    flex-direction: column;
    align-items: center;
    text-align: center;
    gap: 0.5rem;
  }
  .logo {
    width: 52px;
    height: 52px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 13px;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    color: var(--color-fg);
    margin-bottom: 0.15rem;
  }
  h2 {
    margin: 0;
    font-size: 1.05rem;
    font-weight: 600;
    letter-spacing: -0.01em;
  }
  .sub {
    margin: 0;
    font-size: 0.85rem;
    line-height: 1.45;
    color: var(--color-fg-muted);
    max-width: 32ch;
  }
  .cap {
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 0.74rem;
    color: var(--color-fg-subtle);
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 5px;
    padding: 0.1rem 0.4rem;
    margin-top: 0.1rem;
  }
  .scope {
    width: 100%;
    margin: 0.3rem 0 0;
    padding: 0.5rem 0.6rem;
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    font-size: 0.72rem;
    line-height: 1.4;
    text-align: left;
    overflow-x: auto;
    color: var(--color-fg-muted);
  }
  .remember {
    width: 100%;
    margin-top: 0.5rem;
    padding: 0.45rem 0.55rem;
    border: 1px solid var(--color-border);
    border-radius: 9px;
    background: var(--color-surface-soft);
    color: var(--color-fg);
    font-size: 0.84rem;
    font-family: inherit;
  }
  .actions {
    display: flex;
    gap: 0.5rem;
    width: 100%;
    margin-top: 0.6rem;
  }
  .btn {
    flex: 1;
    height: 38px;
    border-radius: 10px;
    font-size: 0.88rem;
    font-weight: 550;
    font-family: inherit;
    cursor: pointer;
    border: 1px solid var(--color-border);
    background: var(--color-surface-soft);
    color: var(--color-fg);
    transition: opacity 0.12s, filter 0.12s, background 0.12s;
  }
  .btn:disabled {
    opacity: 0.45;
    cursor: default;
  }
  .btn.allow {
    background: var(--color-brand, var(--color-fg));
    color: #fff;
    border-color: transparent;
  }
  .btn.allow:not(:disabled):hover {
    filter: brightness(1.06);
  }
  .btn.deny:not(:disabled):hover {
    background: rgba(239, 68, 68, 0.12);
    border-color: rgba(239, 68, 68, 0.4);
  }
</style>
