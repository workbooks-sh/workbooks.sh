<script lang="ts">
  import { page } from "$app/stores";
  import { goto } from "$app/navigation";
  import { sessionJwt } from "$lib/session.js";

  interface Props {
    children: import("svelte").Snippet;
    data: {
      user: { id: string; email: string; firstName?: string; lastName?: string } | null;
      sessionJwt: string | null;
    };
  }
  let { children, data }: Props = $props();

  // Mirror the server-side session JWT into the client store so $lib/api.ts
  // can attach it to /v1/auth/portal/* requests.
  $effect(() => {
    sessionJwt.set(data.sessionJwt ?? null);
  });

  const NAV = [
    { href: "/app/keys", label: "keys", key: "k" },
    { href: "/app/skills", label: "skills", key: "l" },
    { href: "/app/connections", label: "connections", key: "c" },
    { href: "/app/verbs", label: "verbs", key: "v" },
    { href: "/app/activity", label: "activity", key: "t" },
    { href: "/app/spend", label: "spend", key: "s" },
    { href: "/app/data", label: "data", key: "d" },
    { href: "/app/account", label: "account", key: "a" },
  ];

  // Global keyboard navigation: g+k/c/v/t/s/d/a
  let pendingG = false;
  function handleKeydown(e: KeyboardEvent) {
    if (
      e.target instanceof HTMLInputElement ||
      e.target instanceof HTMLTextAreaElement
    )
      return;

    if (pendingG) {
      pendingG = false;
      const match = NAV.find((n) => n.key === e.key);
      if (match) goto(match.href);
      return;
    }
    if (e.key === "g") {
      pendingG = true;
      setTimeout(() => (pendingG = false), 1000);
    }
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="min-h-screen flex flex-col bg-white text-fg">

  <header class="border-b border-border-warm px-5 py-2.5 flex items-center justify-between">
    <nav class="flex items-center gap-5">
      <a href="/" class="font-serif text-base text-fg no-underline tracking-tight">🍌 brandnana</a>
      {#each NAV as item}
        <a
          href={item.href}
          class="text-fg-muted text-xs no-underline pb-px transition-colors hover:text-fg"
          class:active-nav={$page.url.pathname.startsWith(item.href)}
        >
          {item.label}
        </a>
      {/each}
    </nav>
    <a href="/app/auth/sign-out" class="text-fg-subtle font-mono text-xs no-underline hover:text-fg-muted">
      [sign out]
    </a>
  </header>

  <main class="flex-1 px-5 py-6 max-w-3xl w-full">
    {@render children()}
  </main>

  <footer class="border-t border-border-warm px-5 py-2.5 text-xs text-fg-muted">
    brandnana v0.0.1 · <code class="font-mono">curl install.brandnana.net | sh</code> ·
    <a href="https://github.com/workbooks-sh/brandnana" target="_blank" rel="noreferrer" class="text-fg-muted">
      github.com/workbooks-sh/brandnana
    </a>
  </footer>

</div>

<style>
  .active-nav {
    color: var(--color-fg);
    border-bottom: 1px solid var(--color-banana-deep);
    padding-bottom: 1px;
  }
</style>
