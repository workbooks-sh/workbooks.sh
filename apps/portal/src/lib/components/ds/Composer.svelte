<!--
  Composer — the big AI-product chat input on the lander hero.
  Doesn't actually send (no agent backend yet) — captures intent + bounces
  to /app/auth/sign-up?intent=... so the prompt seeds the agent post-signup.
-->
<script lang="ts">
  let value = $state("");
  let active = $state(false);

  const prompts = [
    "Research nike.com",
    "Compare lululemon vs alo",
    "Build a brand book for glossier.com",
    "Pull every ad adidas has run this month",
  ];

  function setPrompt(p: string) {
    value = p;
    active = true;
  }

  function submit(e: SubmitEvent) {
    e.preventDefault();
    const q = value.trim();
    if (!q) return;
    // Until the agent backend exists, send the prompt as a query string to
    // sign-up so it can be replayed after the user lands in /app.
    const params = new URLSearchParams({
      redirect_url: `/app?prompt=${encodeURIComponent(q)}`,
    });
    window.location.href = `/app/auth/sign-up?${params}`;
  }
</script>

<div class="w-full max-w-2xl mx-auto">
  <form
    onsubmit={submit}
    class="relative rounded-2xl bg-white shadow-[0_1px_3px_rgba(0,0,0,0.04),0_8px_28px_-12px_rgba(0,0,0,0.12)] ring-1 ring-line transition-shadow focus-within:shadow-[0_1px_3px_rgba(0,0,0,0.04),0_12px_36px_-12px_rgba(44,95,181,0.18)] focus-within:ring-blue text-left"
  >
    <textarea
      bind:value
      onfocus={() => (active = true)}
      onblur={() => (active = !!value)}
      placeholder="Ask brandnana to research a brand, find competitors, or build a brand book…"
      class="block w-full resize-none bg-transparent text-fg placeholder:text-fg-subtle text-[15px] leading-relaxed px-5 pt-4 pb-14 rounded-2xl outline-none min-h-[110px]"
      rows="3"
    ></textarea>
    <div class="absolute bottom-2 right-2">
      <button
        type="submit"
        class="inline-flex items-center gap-1.5 rounded-xl bg-banana hover:bg-banana-deep text-fg font-semibold text-[13px] px-4 py-2 transition-colors disabled:opacity-50 disabled:hover:bg-banana"
        disabled={!value.trim()}
        aria-label="Send prompt"
      >
        ask
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <path d="M3 8h10M9 4l4 4-4 4" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
      </button>
    </div>
  </form>

  <!-- prompt chips, centered under composer -->
  <div class="mt-3 flex flex-wrap justify-center gap-2">
    {#each prompts as p}
      <button
        type="button"
        onclick={() => setPrompt(p)}
        class="rounded-full bg-bg-tint hover:bg-blue-soft hover:text-blue-deep text-fg-muted text-[12px] px-3 py-1.5 transition-colors"
      >
        {p}
      </button>
    {/each}
  </div>
</div>
