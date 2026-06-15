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
   * Types:
   *   - `callout`  — info/warn/ok/error banner
   *   - `kv`       — key/value table
   *   - `button`   — an action button (props.label, fires a chat-action event)
   *   - `link`     — an inline link (props.label + props.href)
   *   - `share`    — share-to-org card: member list + an invite button
   * Unknown types fall back to a labeled code block so nothing silently
   * vanishes. Interactive components emit a `wb-chat-action` CustomEvent the
   * chat surface can observe — they never run arbitrary LLM output.
   */
  import {
    WarningCircle,
    Info,
    CheckCircle,
    XCircle,
    PaperPlaneTilt,
    ArrowSquareOut,
    UsersThree,
  } from "phosphor-svelte";
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
  // share body is also key:value (target/members/role) — reuse the kv parser.
  const shareFields = $derived(
    type === "share" ? Object.fromEntries(parseKvBody(body)) : {},
  );
  const shareMembers = $derived(
    (shareFields.members ?? "")
      .split(",")
      .map((m) => m.trim())
      .filter(Boolean),
  );
  let actioned = $state(false);
  const ToneIcon = $derived(
    tone === "warn"
      ? WarningCircle
      : tone === "ok"
        ? CheckCircle
        : tone === "error"
          ? XCircle
          : Info,
  );

  /** Fire a sideband action event the chat surface (or a host) can observe,
   *  then mark the component done. Never executes LLM-authored code. */
  function fire(action: string, detail: Record<string, unknown> = {}) {
    actioned = true;
    if (typeof window !== "undefined") {
      window.dispatchEvent(
        new CustomEvent("wb-chat-action", { detail: { action, ...detail } }),
      );
    }
  }
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
{:else if type === "button"}
  <div class="cc btn-wrap">
    <button
      type="button"
      class="action-btn"
      class:done={actioned}
      onclick={() => fire(props.action ?? "button", { label: props.label ?? body })}
    >
      {#if actioned}<CheckCircle weight="fill" size={14} />{:else}<PaperPlaneTilt weight="fill" size={14} />{/if}
      {actioned ? (props.doneLabel ?? "Done") : (props.label ?? body ?? "Run")}
    </button>
  </div>
{:else if type === "link"}
  <a class="cc chat-link" href={props.href ?? "#"} target="_blank" rel="noreferrer">
    <ArrowSquareOut weight="bold" size={13} />
    {props.label ?? body ?? props.href}
  </a>
{:else if type === "share"}
  <div class="cc share">
    <div class="share-head">
      <UsersThree weight="fill" size={15} />
      <span>{props.title ?? "Share with your org"}</span>
    </div>
    {#if shareFields.target}<div class="share-target">{shareFields.target}</div>{/if}
    {#if shareMembers.length}
      <div class="share-members">
        {#each shareMembers as m (m)}
          <span class="member" title={m}>{m.split(" ").map((w) => w[0]).join("").slice(0, 2).toUpperCase()}</span>
        {/each}
        <span class="member-count">{shareMembers.length} people · {shareFields.role ?? "Editor"}</span>
      </div>
    {/if}
    <button
      type="button"
      class="action-btn"
      class:done={actioned}
      onclick={() => fire("share", { target: shareFields.target, members: shareMembers, role: shareFields.role })}
    >
      {#if actioned}<CheckCircle weight="fill" size={14} /> Invited{:else}<PaperPlaneTilt weight="fill" size={14} /> Send invite{/if}
    </button>
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

  /* interactive: button / link / share */
  .action-btn {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    padding: 0.45rem 0.85rem;
    border: 0;
    border-radius: var(--radius-md, 8px);
    background: var(--color-brand, #3fe081);
    color: #06231a;
    font: inherit;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: filter 0.12s, opacity 0.12s;
  }
  .action-btn:hover { filter: brightness(1.06); }
  .action-btn.done {
    background: color-mix(in srgb, var(--color-brand, #3fe081) 18%, var(--color-surface));
    color: var(--color-fg);
    cursor: default;
  }
  .chat-link {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    padding: 0.3rem 0.6rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 8px);
    background: var(--color-surface);
    color: var(--color-brand, #149157);
    font-size: 13px;
    font-weight: 500;
    text-decoration: none;
    width: fit-content;
  }
  .chat-link:hover { border-color: var(--color-border-strong); }

  .share {
    display: flex;
    flex-direction: column;
    gap: 0.55rem;
    padding: 0.7rem 0.85rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md, 10px);
    background: var(--color-surface);
  }
  .share-head {
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
    font-weight: 600;
    color: var(--color-fg);
  }
  .share-target {
    font-size: 12.5px;
    color: var(--color-fg-muted);
  }
  .share-members {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    flex-wrap: wrap;
  }
  .member {
    display: inline-grid;
    place-items: center;
    width: 26px;
    height: 26px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--color-brand, #3fe081) 22%, var(--color-surface-soft));
    color: var(--color-fg);
    font-size: 10px;
    font-weight: 700;
    border: 1px solid var(--color-border);
  }
  .member-count {
    margin-left: 0.3rem;
    font-size: 12px;
    color: var(--color-fg-muted);
  }
  .btn-wrap { display: flex; }
</style>
