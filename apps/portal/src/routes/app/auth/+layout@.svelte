<!--
  Auth layout — full-bleed, no /app sidebar/nav. Used for sign-in, sign-up,
  and the CLI-connect approval screen. Banana-mascot-aware brand wrapper
  around the embedded Clerk component.
-->
<script lang="ts">
  interface Props {
    children: import("svelte").Snippet;
  }
  let { children }: Props = $props();
</script>

<div class="min-h-screen flex flex-col bg-white text-fg">
  <header class="px-6 md:px-10 py-5 flex items-center justify-between">
    <a href="/" class="flex items-center gap-2 text-fg font-medium tracking-tight">
      <span class="font-serif text-[20px] leading-none">brandnana</span>
      <span class="inline-block w-1.5 h-1.5 rounded-full bg-banana"></span>
    </a>
    <a href="/" class="text-[13px] text-fg-muted hover:text-fg transition-colors">← back to site</a>
  </header>

  <main class="flex-1 grid place-items-center px-6 pb-16">
    <div class="w-full max-w-md">
      {@render children()}
    </div>
  </main>

  <footer class="px-6 md:px-10 py-5 border-t border-line text-[12px] text-fg-muted flex items-center justify-between">
    <span>© brandnana</span>
    <div class="flex gap-4">
      <a href="https://brandnana.net/privacy" class="hover:text-fg transition-colors">privacy</a>
      <a href="https://brandnana.net/terms" class="hover:text-fg transition-colors">terms</a>
    </div>
  </footer>
</div>
