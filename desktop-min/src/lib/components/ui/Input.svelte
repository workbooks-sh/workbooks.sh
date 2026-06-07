<script lang="ts">
  /**
   * Input — labelled text field on the soft surface.
   *
   * `value` is $bindable. Optional `label` renders an uppercase muted
   * caption above; `error` swaps the border to the rose state and shows
   * a line beneath. Focus lifts the border to border-strong + ring.
   */
  let {
    value = $bindable(""),
    label,
    placeholder,
    type = "text",
    disabled = false,
    error = null,
    onkeydown,
  }: {
    value?: string;
    label?: string;
    placeholder?: string;
    type?: "text" | "password" | "email" | "search";
    disabled?: boolean;
    error?: string | null;
    onkeydown?: (e: KeyboardEvent) => void;
  } = $props();
</script>

<label class="field">
  {#if label}<span class="cap">{label}</span>{/if}
  <input
    {type}
    {placeholder}
    {disabled}
    {onkeydown}
    bind:value
    class:err={!!error}
  />
  {#if error}<span class="msg">{error}</span>{/if}
</label>

<style>
  .field { display: flex; flex-direction: column; gap: 0.3rem; }
  .cap {
    font-size: 0.72rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    color: var(--color-fg-muted);
  }
  input {
    background: var(--color-surface-soft);
    border: 1px solid var(--color-border);
    border-radius: 8px;
    padding: 0.5rem 0.65rem;
    font-family: inherit;
    font-size: 0.86rem;
    color: var(--color-fg);
    outline: 0;
    transition: border-color 0.12s ease, box-shadow 0.12s ease;
  }
  input::placeholder { color: var(--color-fg-subtle); }
  input:focus {
    border-color: var(--color-border-strong);
    box-shadow: 0 0 0 3px var(--color-ring);
  }
  input:disabled { opacity: 0.5; cursor: default; }
  input.err { border-color: var(--color-err); }
  .msg { font-size: 0.74rem; color: var(--color-err); }
</style>
