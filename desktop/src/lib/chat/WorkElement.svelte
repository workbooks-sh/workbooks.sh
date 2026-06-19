<script lang="ts">
  /**
   * Mounts an inline element an agent emitted in chat: tag + attrs as
   * attributes, body as textContent — never `{@html}` raw model output. An
   * unknown tag renders its text body inline (graceful), so the chat stays
   * readable without any custom-element registry.
   */
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
