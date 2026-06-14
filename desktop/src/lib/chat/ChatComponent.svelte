<script lang="ts">
  /**
   * Waldo in-chat component dispatcher.
   *
   * Renders one inline component authored by Waldo as a
   * `#+begin_src component :type <t> …` block. Switches on `type`.
   * Reads structured props/body — never {@html}s LLM output. Chrome
   * uses the app's --color-* tokens (desktop/src/app.css) so it
   * matches the chat surface.
   *
   * Slice-1 types: `callout` (info/warn/ok/error banner), `kv`
   * (key/value table). Unknown types fall back to a labeled code
   * block so nothing silently vanishes.
   */
  import { WarningCircle, Info, CheckCircle, XCircle } from "phosphor-svelte";
  import { parseKvBody } from "./messageRender";

  let {
    type,
    props,
    body,
  }: {
    type: string;
    props: Record<string, string>;
    body: string;
  } = $props();

  const tone = $derived(
    (props.tone ?? "info") as "info" | "warn" | "ok" | "error",
  );
  const rows = $derived(type === "kv" ? parseKvBody(body) : []);
  const ToneIcon = $derived(
    tone === "warn"
      ? WarningCircle
      : tone === "ok"
        ? CheckCircle
        : tone === "error"
          ? XCircle
          : Info,
  );
</script>

{#if type === "callout"}
  <div class="cc callout tone-{tone}">
    <ToneIcon weight="fill" size={14} class="cc-icon" aria-hidden="true" />
    <div class="callout-body">
      {#if props.title}<div class="callout-title">{props.title}</div>{/if}
      <div class="callout-text">{body}</div>
    </div>
  </div>
{:else if type === "kv"}
  <div class="cc kv">
    {#if props.title}<div class="kv-title">{props.title}</div>{/if}
    <table>
      <tbody>
        {#each rows as [k, v] (k)}
          <tr>
            <th>{k}</th>
            <td>{v}</td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{:else}
  <div class="cc unknown">
    <div class="unknown-label">component: {type}</div>
    <pre>{body}</pre>
  </div>
{/if}

<style>
  .cc {
    max-width: 720px;
    align-self: flex-start;
    font-size: 13px;
    border-radius: var(--radius-md);
  }

  /* callout */
  .callout {
    display: flex;
    gap: 0.55rem;
    padding: 0.6rem 0.8rem;
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    line-height: 1.5;
  }
  :global(.callout .cc-icon) {
    flex-shrink: 0;
    margin-top: 1px;
    color: var(--color-fg-muted);
  }
  .callout-title {
    font-weight: 600;
    color: var(--color-fg);
    margin-bottom: 0.1rem;
  }
  .callout-text {
    color: var(--color-fg);
    white-space: pre-wrap;
    word-break: break-word;
  }
  .tone-warn {
    border-color: rgba(245, 158, 11, 0.4);
    background: rgba(245, 158, 11, 0.06);
  }
  :global(.tone-warn .cc-icon) {
    color: #b45309;
  }
  .tone-ok {
    border-color: rgba(16, 185, 129, 0.4);
    background: rgba(16, 185, 129, 0.06);
  }
  :global(.tone-ok .cc-icon) {
    color: #047857;
  }
  .tone-error {
    border-color: rgba(239, 68, 68, 0.4);
    background: rgba(239, 68, 68, 0.06);
  }
  :global(.tone-error .cc-icon) {
    color: var(--color-err);
  }

  /* kv table */
  .kv {
    border: 1px solid var(--color-border);
    background: var(--color-surface);
    overflow: hidden;
  }
  .kv-title {
    padding: 0.45rem 0.7rem;
    font-weight: 600;
    color: var(--color-fg);
    border-bottom: 1px solid var(--color-border);
    background: var(--color-surface-soft);
  }
  .kv table {
    width: 100%;
    border-collapse: collapse;
  }
  .kv th,
  .kv td {
    text-align: left;
    padding: 0.4rem 0.7rem;
    border-bottom: 1px solid var(--color-border);
    vertical-align: top;
  }
  .kv tr:last-child th,
  .kv tr:last-child td {
    border-bottom: 0;
  }
  .kv th {
    width: 40%;
    color: var(--color-fg-muted);
    font-weight: 500;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    font-size: 12px;
  }
  .kv td {
    color: var(--color-fg);
  }

  /* unknown fallback */
  .unknown {
    border: 1px dashed var(--color-border-strong);
    background: var(--color-surface-soft);
    padding: 0.5rem 0.7rem;
  }
  .unknown-label {
    font-size: 10.5px;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--color-fg-subtle);
    margin-bottom: 0.3rem;
  }
  .unknown pre {
    margin: 0;
    white-space: pre-wrap;
    font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
    font-size: 12px;
    color: var(--color-fg);
  }
</style>
