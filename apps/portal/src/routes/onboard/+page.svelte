<!--
  Single-step welcome. Form POSTs name to the server action, which updates
  Clerk + redirects to /app/keys. Falls through cleanly without JS.
-->
<script lang="ts">
  import { enhance } from "$app/forms";
  import type { PageData } from "./$types";

  let { data }: { data: PageData } = $props();
  let busy = $state(false);

  const initialName = [data.user?.firstName, data.user?.lastName].filter(Boolean).join(" ");
</script>

<svelte:head><title>welcome · brandnana</title></svelte:head>

<div class="min-h-screen flex flex-col bg-white text-fg">
  <header class="px-6 md:px-10 py-5 flex items-center justify-between">
    <a href="/" class="flex items-center gap-2 text-fg font-medium tracking-tight">
      <span class="font-serif text-[20px] leading-none">brandnana</span>
      <span class="inline-block w-1.5 h-1.5 rounded-full bg-banana"></span>
    </a>
    <span class="text-[12px] text-fg-muted uppercase tracking-wider">welcome</span>
  </header>

  <main class="flex-1 grid place-items-center px-6 pb-16">
    <div class="w-full max-w-xl">
      <h1 class="font-serif text-[36px] leading-tight tracking-tight text-fg mb-2">Welcome to brandnana.</h1>
      <p class="text-fg-muted text-[15px] mb-8">
        Quick name check, then we'll drop you in the dashboard.
      </p>

      <form
        method="POST"
        use:enhance={() => {
          busy = true;
          return ({ update }) => update().then(() => (busy = false));
        }}
        class="space-y-5"
      >
        <div>
          <label class="block text-[12px] text-fg-muted mb-1.5 uppercase tracking-wider" for="name">Your name</label>
          <input
            id="name"
            name="name"
            type="text"
            value={initialName}
            placeholder="full name"
            class="w-full px-4 py-3 rounded-lg border border-line focus:border-blue-deep focus:ring-2 focus:ring-blue-deep/15 outline-none text-[15px]"
          />
        </div>
        <div>
          <label class="block text-[12px] text-fg-muted mb-1.5 uppercase tracking-wider" for="email">Email</label>
          <input
            id="email"
            type="email"
            value={data.user?.email ?? ""}
            disabled
            class="w-full px-4 py-3 rounded-lg border border-line bg-bg-soft text-fg-muted text-[15px] cursor-not-allowed"
          />
        </div>
        <button
          type="submit"
          disabled={busy}
          class="w-full py-3 rounded-lg bg-banana hover:bg-banana-soft text-fg font-semibold transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
        >
          {busy ? "saving…" : "Take me to the dashboard →"}
        </button>
      </form>

      <p class="text-[11px] text-fg-subtle mt-5">
        You'll create API keys at <code class="font-mono">/app/keys</code>,
        grab skills at <code class="font-mono">/app/skills</code>,
        and run <code class="font-mono">brandnana login</code> from the CLI.
      </p>
    </div>
  </main>
</div>
