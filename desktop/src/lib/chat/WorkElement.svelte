<script lang="ts">
  /**
   * Mounts the REAL `<work-*>` custom element an agent emitted inline. Generic
   * over any tag in the SDK (importing the workponents index registers them all).
   * Structured: tag + attrs set as attributes, body as textContent — we never
   * `{@html}` raw model output.
   */
  import "$workponents/index.js";

  let {
    tag,
    attrs,
    body,
  }: {
    tag: string;
    attrs: Record<string, string>;
    body: string;
  } = $props();

  let host = $state<HTMLElement | null>(null);

  $effect(() => {
    const node = host;
    if (!node) return;
    node.replaceChildren();
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (v != null) el.setAttribute(k, v);
    }
    if (body) el.textContent = body;
    node.appendChild(el);
  });
</script>

<div bind:this={host}></div>
