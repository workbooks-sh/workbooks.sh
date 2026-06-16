<script lang="ts">
  /**
   * Thin Svelte host for the REAL <work-gen-block> custom element (the
   * workponents `ai` domain). Replaces the Svelte twin ChatComponent.svelte:
   * one implementation, shipped from the SDK, themed via the --work-* bridge
   * (workponents/src/theme/bridge.css, imported once in +layout).
   *
   * The agent authors `#+begin_src component :type … #+end_src` blocks;
   * messageRender.splitOrg parses them into { type, props, body }. We forward
   * type + props as ATTRIBUTES and the body as textContent — structured props
   * only, never {@html} of model output (same safety as the twin).
   *
   * Importing the element module registers <work-gen-block> with the platform.
   */
  import "$workponents/elements/ai/wb-gen-block.js";

  let {
    type,
    props,
    body,
  }: {
    type: string;
    props: Record<string, string>;
    body: string;
  } = $props();

  let el = $state<HTMLElement | null>(null);

  // Set the recognized props as attributes + the raw body as textContent.
  // WbGenBlock.props = type,tone,title,label,href,action,target,done — we pass
  // type explicitly and spread the parsed header args (tone/title/label/…).
  $effect(() => {
    const node = el;
    if (!node) return;
    node.setAttribute("type", type);
    for (const [k, v] of Object.entries(props)) {
      if (v == null) continue;
      node.setAttribute(k, v);
    }
    node.textContent = body;
  });
</script>

<work-gen-block bind:this={el}></work-gen-block>
